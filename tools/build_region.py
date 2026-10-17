#!/usr/bin/env python3
"""Builds an offline chart region for Leeway.

Combines EMODnet Bathymetry (depth, ~115 m) with the OpenStreetMap coastline
(crisp land mask) into a depth grid, and collects OpenSeaMap seamarks,
harbours and marinas from OSM.

    python3 -m venv .venv && .venv/bin/pip install numpy scipy shapely pillow tifffile
    .venv/bin/python tools/build_region.py adriatic "Eastern Adriatic" 13.2 42.2 19.0 45.57 \
        --osm croatia.osm.pbf,slovenia.osm.pbf,bosnia-herzegovina.osm.pbf,montenegro.osm.pbf

With --osm (Geofabrik country extracts, needs `pip install osmium`) everything OSM is read locally;
without it the Overpass API is queried tile by tile. Coast not covered by the extracts (e.g. Italy across
the Adriatic) is taken from EMODnet's land heights.

Outputs Leeway/Charts/<id>.depth (raw-deflate UInt8 grid, row 0 = north, used for routing),
Leeway/Charts/<id>.land (raw-deflate coastline polygons), Leeway/Charts/<id>.json (grid metadata +
seamarks), and Leeway/Charts/<id>.pmtiles, the vector chart the app draws (see build_vector.py; needs
tippecanoe).

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
# Mirrors, fastest first; each query falls through to the next on errors.
OVERPASS = ["https://overpass.kumi.systems/api/interpreter", "https://overpass-api.de/api/interpreter"]
CACHE = Path(__file__).resolve().parent / ".overpass-cache"
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
    """Runs an Overpass query, caching the answer on disk so re-runs are quick."""
    import hashlib
    CACHE.mkdir(exist_ok=True)
    cached = CACHE / (hashlib.sha1(query.encode()).hexdigest() + ".json")
    if cached.exists():
        return json.loads(cached.read_text())["elements"]
    body = urllib.parse.urlencode({"data": query}).encode()
    for attempt in range(6):
        endpoint = OVERPASS[attempt % len(OVERPASS)]
        try:
            req = urllib.request.Request(endpoint, data=body, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=300) as r:
                raw = r.read()
            elements = json.loads(raw)["elements"]
            cached.write_bytes(raw)
            return elements
        except Exception as e:
            print(f"  {endpoint.split('/')[2]} failed ({e}); retrying", flush=True)
            time.sleep(5 * (attempt + 1))
    raise RuntimeError("Overpass unavailable")


# Set from --osm: OSM data read from local extracts instead of Overpass.
OSM = None

HIGHWAYS = {"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified"}


class OsmExtract:
    """Collects coastline, seamarks, bridges and names from .osm.pbf files, in Overpass-like dicts."""

    def __init__(self, paths, west, south, east, north):
        import osmium

        bbox = (west, south, east, north)
        inside = lambda lon, lat: bbox[0] <= lon <= bbox[2] and bbox[1] <= lat <= bbox[3]
        self.coastline, self.seamarks, self.bridges, self.names = [], [], [], []
        seen = set()

        def is_name(t):
            return "name" in t and (t.get("natural") in ("bay", "cape", "strait") or t.get("place") in ("island", "islet"))

        outer = self

        class Handler(osmium.SimpleHandler):
            def node(self, n):
                t = n.tags
                if not ("seamark:type" in t or t.get("leisure") == "marina" or is_name(t)):
                    return
                if not n.location.valid() or not inside(n.location.lon, n.location.lat) or ("n", n.id) in seen:
                    return
                seen.add(("n", n.id))
                el = {"type": "node", "id": n.id, "lat": n.location.lat, "lon": n.location.lon, "tags": dict(t)}
                if is_name(t):
                    outer.names.append(el)
                else:
                    outer.seamarks.append(el)

            def way(self, w):
                t = w.tags
                coast = t.get("natural") == "coastline"
                mark = "seamark:type" in t or t.get("leisure") == "marina"
                bridge = "bridge" in t and t.get("highway") in HIGHWAYS
                name = is_name(t)
                if not (coast or mark or bridge or name) or ("w", w.id) in seen:
                    return
                try:
                    geometry = [{"lat": nd.location.lat, "lon": nd.location.lon} for nd in w.nodes]
                except osmium.InvalidLocationError:
                    return
                if len(geometry) < 2 or not any(inside(g["lon"], g["lat"]) for g in geometry):
                    return
                seen.add(("w", w.id))
                center = {"lat": sum(g["lat"] for g in geometry) / len(geometry), "lon": sum(g["lon"] for g in geometry) / len(geometry)}
                el = {"type": "way", "id": w.id, "tags": dict(t), "geometry": geometry, "center": center}
                if coast:
                    outer.coastline.append(el)
                if mark:
                    outer.seamarks.append(el)
                if bridge or t.get("seamark:type") == "bridge":
                    outer.bridges.append(el)
                if name:
                    outer.names.append(el)

        for path in paths:
            print(f"Reading {Path(path).name}…", flush=True)
            Handler().apply_file(path, locations=True, idx="flex_mem")
        print(f"  {len(self.coastline)} coastline ways, {len(self.seamarks)} seamarks, "
              f"{len(self.bridges)} bridges, {len(self.names)} names", flush=True)


def chunks(west, south, east, north, step=1.0):
    """1° tiles covering the bbox, so big areas don't time out the APIs."""
    lat = south
    while lat < north - 1e-9:
        lon = west
        while lon < east - 1e-9:
            yield lon, lat, min(lon + step, east), min(lat + step, north)
            lon += step
        lat += step


def overpass_chunked(query, west, south, east, north):
    """Runs `query` (with {bbox}) per tile and merges the results, de-duplicated by element."""
    seen, elements = set(), []
    tiles = list(chunks(west, south, east, north))
    for i, (w, s, e, n) in enumerate(tiles):
        for el in overpass(query.format(bbox=f"({s},{w},{n},{e})")):
            key = (el["type"], el["id"])
            if key not in seen:
                seen.add(key)
                elements.append(el)
        print(f"    tile {i + 1}/{len(tiles)}: {len(elements)} so far", flush=True)
        time.sleep(1)
    return elements


def emodnet(west, south, east, north):
    """EMODnet elevation (+ up, row 0 = north) on its native 1/960° grid, fetched in tiles."""
    rows = int(round((north - south) / EMODNET_RES))
    cols = int(round((east - west) / EMODNET_RES))
    mosaic = np.full((rows, cols), np.nan, dtype=np.float32)
    for w, s, e, n in chunks(west, south, east, north):
        params = {
            "service": "wcs", "version": "1.0.0", "request": "getcoverage",
            "coverage": "emodnet:mean", "crs": "EPSG:4326",
            "bbox": f"{w},{s},{e},{n}", "format": "image/tiff",
            "resx": EMODNET_RES, "resy": EMODNET_RES,
        }
        tile = tifffile.imread(io.BytesIO(fetch(EMODNET + "?" + urllib.parse.urlencode(params)))).astype(np.float32)
        r0 = int(round((north - n) / EMODNET_RES))
        c0 = int(round((w - west) / EMODNET_RES))
        h, wd = min(tile.shape[0], rows - r0), min(tile.shape[1], cols - c0)
        mosaic[r0:r0 + h, c0:c0 + wd] = tile[:h, :wd]
        print(f"    depth tile {w:.1f},{s:.1f}", flush=True)
    return mosaic


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


def land_polygons(west, south, east, north, elevation, origin):
    print("Fetching coastline from OSM…")
    ways = OSM.coastline if OSM else overpass_chunked('[out:json][timeout:240];way["natural"="coastline"]{bbox};out geom;', west, south, east, north)
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
        elev = sample(elevation, origin[0], origin[1], EMODNET_RES, EMODNET_RES, lon, lat)
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
    elements = OSM.seamarks if OSM else overpass_chunked(
        '[out:json][timeout:240];(nwr["seamark:type"]{bbox};nwr["leisure"="marina"]{bbox};);out center tags;', west, south, east, north)
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
        if (depth := (tags.get(f"seamark:{kind}:depth") or tags.get(f"seamark:{kind}:value_of_sounding")
                      or tags.get("seamark:sounding:depth") or tags.get("depth"))):
            item["d"] = depth
        if (level := tags.get(f"seamark:{kind}:water_level")):
            item["wl"] = level
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


def place_names(west, south, east, north):
    """Names a sea chart shows: bays, coves, capes, straits, islets."""
    print("Fetching bay, cape and islet names from OSM…")
    elements = OSM.names if OSM else overpass_chunked(
        '[out:json][timeout:240];(nwr["natural"~"^(bay|cape|strait)$"]["name"]{bbox};'
        'nwr["place"~"^(island|islet)$"]["name"]{bbox};);out center tags;', west, south, east, north)
    names = []
    for e in elements:
        tags = e.get("tags", {})
        lat = e.get("lat") or e.get("center", {}).get("lat")
        lon = e.get("lon") or e.get("center", {}).get("lon")
        if lat is None:
            continue
        kind = tags.get("natural") or tags.get("place")
        names.append({"t": kind, "n": tags["name"], "la": round(lat, 5), "lo": round(lon, 5)})
    print(f"  {len(names)} names")
    return names


# Clearances (m) for bridges whose OSM data lacks them, keyed by OSM way id. Only add values from an official chart.
CLEARANCE_OVERRIDES: dict[int, float] = {}


def bridges(west, south, east, north, code):
    """Bridges spanning real water: nautical-tagged ones plus road bridges over cells deeper than 2 m."""
    print("Fetching bridges from OSM…")
    bbox = f"({south},{west},{north},{east})"
    ways = OSM.bridges if OSM else overpass_chunked(
        '[out:json][timeout:240];(way["seamark:type"="bridge"]{bbox};'
        'way["bridge"]["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified)$"]{bbox};);out tags geom;',
        west, south, east, north)
    rows, cols = code.shape
    result = []
    for w in ways:
        tags, geometry = w.get("tags", {}), w.get("geometry", [])
        if len(geometry) < 2:
            continue
        line = LineString([(p["lon"], p["lat"]) for p in geometry])
        nautical = tags.get("seamark:type") == "bridge"
        if not nautical:
            # Keep only bridges with water at least 2 m deep somewhere under them.
            spans_water = False
            steps = max(2, int(line.length / 0.0002))
            for k in range(steps + 1):
                p = line.interpolate(k / steps, normalized=True)
                r, c = int((north - p.y) / LAT_STEP), int((p.x - west) / LON_STEP)
                if 0 <= r < rows and 0 <= c < cols and code[r, c] != LAND and code[r, c] >= 4:
                    spans_water = True
                    break
            if not spans_water:
                continue
        clearance = CLEARANCE_OVERRIDES.get(w["id"])
        for key in ("seamark:bridge:clearance_height", "seamark:bridge:vertical_clearance",
                    "seamark:bridge:clearance_height_closed", "seamark:bridge:vertical_clearance_closed"):
            if clearance is None and tags.get(key):
                try:
                    clearance = float(tags[key].split()[0].replace(",", "."))
                except ValueError:
                    pass
        item = {"id": w["id"], "pts": [[round(p["lon"], 6), round(p["lat"], 6)] for p in geometry]}
        if (bridge_name := tags.get("seamark:name") or tags.get("bridge:name") or tags.get("name")):
            item["n"] = bridge_name
        if clearance is not None:
            item["h"] = clearance
        if (category := tags.get("seamark:bridge:category")):
            item["c"] = category
        result.append(item)
    print(f"  {len(result)} bridges over water ({sum('h' in b for b in result)} with charted clearance)")
    return result


def main():
    global OSM
    args = sys.argv[1:]
    osm_paths = []
    if "--osm" in args:
        i = args.index("--osm")
        osm_paths = args[i + 1].split(",")
        del args[i:i + 2]
    region_id, name = args[0], args[1]
    west, south, east, north = map(float, args[2:6])
    if osm_paths:
        OSM = OsmExtract(osm_paths, west, south, east, north)
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

    # Interpolate depth from sea cells only: blending in land heights makes whole coastal strips look dry.
    sea_source = elevation < -0.5
    nearest = ndimage.distance_transform_edt(~sea_source, return_distances=False, return_indices=True)
    sea_depth = -elevation[tuple(nearest)]
    del nearest
    depth = np.empty((rows, cols), dtype=np.float32)
    emodnet_land = np.empty((rows, cols), dtype=bool)
    for r0 in range(0, rows, 400):
        lon_grid, lat_grid = np.meshgrid(lon, lat[r0:r0 + 400])
        depth[r0:r0 + 400] = sample(sea_depth, west - pad, north + pad, EMODNET_RES, EMODNET_RES, lon_grid, lat_grid)
        emodnet_land[r0:r0 + 400] = sample(elevation, west - pad, north + pad, EMODNET_RES, EMODNET_RES, lon_grid, lat_grid) > 0

    land = land_polygons(west, south, east, north, elevation, (west - pad, north + pad))
    mask = Image.new("L", (cols, rows), 0)
    draw = ImageDraw.Draw(mask)
    to_px = lambda x, y: ((x - west) / LON_STEP, (north - y) / LAT_STEP)
    for poly in land:
        draw.polygon([to_px(x, y) for x, y in poly.exterior.coords], fill=1)
    is_land = np.array(mask, dtype=bool)

    # Coast the OSM data doesn't cover (e.g. Italy across the Adriatic): EMODnet's land, if far from any OSM coastline.
    coast = Image.new("L", (cols, rows), 0)
    coast_draw = ImageDraw.Draw(coast)
    for way in (OSM.coastline if OSM else []):
        coast_draw.line([to_px(g["lon"], g["lat"]) for g in way["geometry"]], fill=1, width=1)
    if OSM:
        cell_km = LAT_STEP * 111.32
        far = ndimage.distance_transform_edt(~np.array(coast, dtype=bool)) * cell_km > 20
        is_land |= far & emodnet_land
    del emodnet_land

    # Near the coast, never claim more water than a steep shelf would give (distance in metres from land).
    cell_m = np.sqrt((LAT_STEP * 111_320) * (LON_STEP * 111_320 * np.cos(np.radians((north + south) / 2))))
    shore_m = ndimage.distance_transform_edt(~is_land).astype(np.float32) * cell_m
    depth = np.minimum(np.clip(depth, 0, None), 1 + SHORE_SLOPE * shore_m)
    del shore_m
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
        "bridges": bridges(west, south, east, north, code),
        "names": place_names(west, south, east, north),
    }
    (out / f"{region_id}.json").write_text(json.dumps(meta, ensure_ascii=False, separators=(",", ":")))
    print(f"Wrote {out}/{region_id}.depth ({len(packed) / 1e6:.1f} MB) and {region_id}.json")

    preview = np.where(is_land, 200, np.clip(255 - code, 0, 255)).astype(np.uint8)[::4, ::4]
    Image.fromarray(preview).save(out.parent.parent / "tools" / f"{region_id}-preview.png")

    from build_vector import build
    build(region_id, osm_paths)


if __name__ == "__main__":
    main()
