#!/usr/bin/env python3
"""Builds an offline chart region for Leeway.

Combines EMODnet Bathymetry (depth, ~115 m) with the OpenStreetMap coastline
(crisp land mask) into a depth grid, and collects OpenSeaMap seamarks,
harbours and marinas from OSM.

    python3 -m venv .venv && .venv/bin/pip install numpy scipy shapely pillow tifffile
    .venv/bin/python tools/build_region.py kvarner "Kvarner" 13.80 44.35 15.00 45.45

Outputs Leeway/Charts/<id>.depth (raw-deflate UInt8 grid, row 0 = north),
Leeway/Charts/<id>.land (raw-deflate coastline polygons for crisp drawing) and
Leeway/Charts/<id>.json (grid metadata + seamarks).

Data: EMODnet Bathymetry (CC BY 4.0), © OpenStreetMap contributors (ODbL).
"""
import io
import json
import sys
import time
import urllib.parse
import urllib.request
import zlib
from pathlib import Path

import numpy as np
import tifffile
from PIL import Image, ImageDraw
from scipy import ndimage
from shapely.geometry import LineString, box
from shapely.ops import linemerge, polygonize, unary_union

USER_AGENT = "Leeway-chart-builder/0.1"
OVERPASS = "https://overpass-api.de/api/interpreter"
EMODNET = "https://ows.emodnet-bathymetry.eu/wcs"
EMODNET_RES = 1 / 960  # 1/16 arc-minute

# Assumed steepest seabed slope next to the coast when the survey data is coarser than the grid.
SHORE_SLOPE = 0.2

# Grid cell size (~67 m at 45°N).
LAT_STEP = 0.0006
LON_STEP = 0.00085

LAND = 255  # depth codes 0...250 are half-metres (0–125 m)


def fetch(url, data=None, timeout=300):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception as e:  # Overpass rate-limits; back off and retry.
            if attempt == 3:
                raise
            print(f"  retrying after {e}")
            time.sleep(10 * (attempt + 1))


def overpass(query):
    body = urllib.parse.urlencode({"data": query}).encode()
    return json.loads(fetch(OVERPASS, body))["elements"]


def emodnet(west, south, east, north):
    params = {
        "service": "wcs", "version": "1.0.0", "request": "getcoverage",
        "coverage": "emodnet:mean", "crs": "EPSG:4326",
        "bbox": f"{west},{south},{east},{north}", "format": "image/tiff",
        "resx": EMODNET_RES, "resy": EMODNET_RES,
    }
    raw = fetch(EMODNET + "?" + urllib.parse.urlencode(params))
    elevation = tifffile.imread(io.BytesIO(raw)).astype(np.float32)  # + up, row 0 = north
    return elevation


def sample(grid, west, north, step_lon, step_lat, lon, lat):
    """Bilinear sample of a north-up grid at arrays of lon/lat."""
    x = (lon - west) / step_lon - 0.5
    y = (north - lat) / step_lat - 0.5
    x0 = np.clip(np.floor(x).astype(int), 0, grid.shape[1] - 2)
    y0 = np.clip(np.floor(y).astype(int), 0, grid.shape[0] - 2)
    fx = np.clip(x - x0, 0, 1)
    fy = np.clip(y - y0, 0, 1)
    a = grid[y0, x0] * (1 - fx) + grid[y0, x0 + 1] * fx
    b = grid[y0 + 1, x0] * (1 - fx) + grid[y0 + 1, x0 + 1] * fx
    return a * (1 - fy) + b * fy


def land_polygons(west, south, east, north, elevation):
    print("Fetching coastline from OSM…")
    ways = overpass(f'[out:json][timeout:180];way["natural"="coastline"]({south},{west},{north},{east});out geom;')
    lines = [LineString([(p["lon"], p["lat"]) for p in w["geometry"]]) for w in ways if len(w.get("geometry", [])) > 1]
    print(f"  {len(lines)} coastline ways")
    frame = box(west, south, east, north)
    merged = linemerge(lines)
    merged = list(merged.geoms) if hasattr(merged, "geoms") else [merged]
    rings = [m for m in merged if m.is_ring]

    noded = unary_union([m.intersection(frame) for m in merged] + [frame.exterior])
    faces = list(polygonize(noded))
    print(f"  {len(faces)} faces, {len(rings)} closed islands")

    ring_set = {round(r.length, 9) for r in rings}
    land = []
    for face in faces:
        if round(face.exterior.length, 9) in ring_set:
            land.append(face)  # a whole island
            continue
        # Mainland / clipped pieces: ask EMODnet which side of the coast this is.
        points = [face.representative_point()]
        minx, miny, maxx, maxy = face.bounds
        rng = np.random.default_rng(0)
        for _ in range(60):
            px, py = rng.uniform(minx, maxx), rng.uniform(miny, maxy)
            if face.contains(box(px, py, px, py).centroid):
                points.append(box(px, py, px, py).centroid)
            if len(points) >= 25:
                break
        lon = np.array([p.x for p in points])
        lat = np.array([p.y for p in points])
        elev = sample(elevation, west, north, EMODNET_RES, EMODNET_RES, lon, lat)
        if np.median(elev) > 0:
            land.append(face)
    return land


def light_description(tags):
    """Chart-style light characteristic, e.g. 'Fl(2)R.5s 12m 6M'."""
    def tag(name):
        return tags.get(f"seamark:light:{name}") or tags.get(f"seamark:light:1:{name}")
    character = tag("character")
    if not character:
        return None
    group = tag("group")
    colours = (tag("colour") or "").split(";")
    abbrev = {"white": "W", "red": "R", "green": "G", "yellow": "Y", "blue": "Bu", "orange": "Or", "violet": "Vi"}
    colour = "".join(abbrev.get(c, "") for c in colours if c)
    text = character + (f"({group})" if group else "") + colour
    if (period := tag("period")):
        text += f".{period}s"
    if (height := tag("height")):
        text += f" {height}m"
    if (rng := tag("range")):
        text += f" {rng}M"
    return text


def seamarks(west, south, east, north):
    print("Fetching seamarks from OSM…")
    bbox = f"({south},{west},{north},{east})"
    elements = overpass(f'[out:json][timeout:180];(nwr["seamark:type"]{bbox};nwr["leisure"="marina"]{bbox};);out center tags;')
    keep = []
    skip = {"coastline", "cable_submarine", "pipeline_submarine", "separation_line", "separation_zone",
            "separation_boundary", "navigation_line", "recommended_track", "fairway", "seaplane_landing_area"}
    for e in elements:
        tags = e.get("tags", {})
        kind = tags.get("seamark:type") or ("harbour" if tags.get("leisure") == "marina" else None)
        if not kind or kind in skip:
            continue
        lat = e.get("lat") or e.get("center", {}).get("lat")
        lon = e.get("lon") or e.get("center", {}).get("lon")
        if lat is None:
            continue
        item = {"t": kind, "la": round(lat, 6), "lo": round(lon, 6)}
        if (name := tags.get("seamark:name") or tags.get("name")):
            item["n"] = name
        category = (tags.get(f"seamark:{kind}:category") or
                    ("marina" if tags.get("leisure") == "marina" else None))
        if category:
            item["c"] = category
        if (colour := tags.get(f"seamark:{kind}:colour")):
            item["col"] = colour
        if (light := light_description(tags)):
            item["l"] = light
        if (depth := tags.get("seamark:sounding:depth") or tags.get("depth")):
            item["d"] = depth
        keep.append(item)
    # Marinas are often mapped both as leisure=marina and seamark harbour; keep one.
    seen, unique = set(), []
    for item in keep:
        key = (item["t"], item.get("n"), round(item["la"], 3), round(item["lo"], 3))
        if key not in seen:
            seen.add(key)
            unique.append(item)
    print(f"  {len(unique)} seamarks")
    return unique


def main():
    region_id, name = sys.argv[1], sys.argv[2]
    west, south, east, north = map(float, sys.argv[3:7])
    out = Path(__file__).resolve().parent.parent / "Leeway" / "Charts"
    out.mkdir(parents=True, exist_ok=True)

    print("Fetching EMODnet bathymetry…")
    pad = 0.01
    elevation = emodnet(west - pad, south - pad, east + pad, north + pad)
    elevation = np.nan_to_num(elevation, nan=1.0)
    print(f"  {elevation.shape}")

    rows = int(round((north - south) / LAT_STEP))
    cols = int(round((east - west) / LON_STEP))
    lat = north - (np.arange(rows) + 0.5) * LAT_STEP
    lon = west + (np.arange(cols) + 0.5) * LON_STEP
    lon_grid, lat_grid = np.meshgrid(lon, lat)

    # Interpolate depth from sea cells only: blending in land heights makes whole coastal strips look dry.
    sea_source = elevation < -0.5
    nearest = ndimage.distance_transform_edt(~sea_source, return_distances=False, return_indices=True)
    sea_depth = -elevation[tuple(nearest)]
    depth = sample(sea_depth, west - pad, north + pad, EMODNET_RES, EMODNET_RES, lon_grid, lat_grid)

    land = land_polygons(west, south, east, north, elevation)
    mask = Image.new("L", (cols, rows), 0)
    draw = ImageDraw.Draw(mask)
    to_px = lambda x, y: ((x - west) / LON_STEP, (north - y) / LAT_STEP)
    for poly in land:
        draw.polygon([to_px(x, y) for x, y in poly.exterior.coords], fill=1)
    is_land = np.array(mask, dtype=bool)

    # Near the coast, never claim more water than a steep shelf would give (distance in metres from land).
    cell_m = np.sqrt((LAT_STEP * 111_320) * (LON_STEP * 111_320 * np.cos(np.radians((north + south) / 2))))
    shore_m = ndimage.distance_transform_edt(~is_land) * cell_m
    depth = np.minimum(np.clip(depth, 0, None), 1 + SHORE_SLOPE * shore_m)
    code = np.clip(np.round(depth * 2), 0, 250).astype(np.uint8)
    code[is_land] = LAND
    print(f"  grid {rows}×{cols}, {is_land.mean() * 100:.1f}% land")

    def deflate(data):
        compressor = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw deflate for Apple's Compression framework
        return compressor.compress(data) + compressor.flush()

    packed = deflate(code.tobytes())
    (out / f"{region_id}.depth").write_bytes(packed)

    # Land as vector rings (UInt32 ring count, then per ring UInt32 n + n × Float32 lon/lat), ~5 m tolerance.
    rings = []
    for poly in land:
        simple = poly.simplify(0.00004, preserve_topology=True)
        for part in getattr(simple, "geoms", [simple]):
            if part.is_empty or part.area < 1e-9:
                continue
            rings.append(np.asarray(part.exterior.coords, dtype=np.float32))
    blob = bytearray(np.uint32(len(rings)).tobytes())
    for ring in rings:
        blob += np.uint32(len(ring)).tobytes() + ring.tobytes()
    (out / f"{region_id}.land").write_bytes(deflate(bytes(blob)))
    print(f"  {len(rings)} land rings, {sum(len(r) for r in rings)} points")

    meta = {
        "id": region_id, "name": name,
        "west": west, "south": south, "east": east, "north": north,
        "rows": rows, "cols": cols, "latStep": LAT_STEP, "lonStep": LON_STEP,
        "attribution": "Depth: EMODnet Bathymetry (CC BY 4.0). Coastline & seamarks: © OpenStreetMap contributors (ODbL).",
        "seamarks": seamarks(west, south, east, north),
    }
    (out / f"{region_id}.json").write_text(json.dumps(meta, ensure_ascii=False, separators=(",", ":")))
    print(f"Wrote {out}/{region_id}.depth ({len(packed) / 1e6:.1f} MB) and {region_id}.json")

    preview = np.where(is_land, 200, np.clip(255 - code, 0, 255)).astype(np.uint8)
    Image.fromarray(preview).save(out.parent.parent / "tools" / f"{region_id}-preview.png")


if __name__ == "__main__":
    main()
