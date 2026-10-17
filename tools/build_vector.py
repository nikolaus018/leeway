#!/usr/bin/env python3
"""Builds the vector chart of an offline chart pack: Leeway/Charts/<id>.pmtiles.

The app draws it with MapLibre, styled like the worldwide depth from the data server, so a pack is
simply the sharp version of the same chart. It is made from the pack's own files (the depth grid,
the coastline rings and the seamarks in <id>.json), plus details only OpenStreetMap has (light
sectors, restricted areas, traffic separation, cables, pipelines, seabed) from local extracts:

    .venv/bin/python tools/build_vector.py adriatic --osm croatia.osm.pbf,slovenia.osm.pbf

Needs tippecanoe (brew install tippecanoe) and numpy, shapely, contourpy, scipy (+ osmium for --osm).
build_region.py runs this at the end. Layers (attribute names are what the app's style reads):

    land          coastline polygons
    depare        depth areas, min/max metres
    depcnt        depth contours, depth
    soundg        spot soundings, depth (thinned per zoom)
    seamark       t type, n name, c category, col colour, l light, d depth, wl water level,
                  sym symbol key, ls short light characteristic, lc light colour (R/G/W)
    lightsector   sector arcs and limits, col (R/G/W/Y), l light
    area          kind, n name, c category, res restriction
    names         t type, n name
    bridge        h clearance, n name
"""
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

import contourpy
import numpy as np
from scipy import ndimage

CHARTS = Path(__file__).resolve().parent.parent / "Leeway" / "Charts"
LAND = 255
BANDS = [0, 1, 2, 3, 5, 10, 15, 20, 30, 50, 100, 200]
CONTOURS = [1, 2, 3, 5, 10, 15, 20, 30, 50, 100]
# Grid blocks contoured separately, so polygons stay small for tippecanoe.
BLOCK = 600
MIN_ZOOM, MAX_ZOOM = 6, 14
FORMAT = 2


def inflate(data):
    return zlib.decompress(data, -15)


def load_pack(pack_id):
    meta = json.loads((CHARTS / f"{pack_id}.json").read_text())
    code = np.frombuffer(inflate((CHARTS / f"{pack_id}.depth").read_bytes()), dtype=np.uint8)
    code = code.reshape(meta["rows"], meta["cols"])
    rings = []
    land_file = CHARTS / f"{pack_id}.land"
    if land_file.exists():
        blob = inflate(land_file.read_bytes())
        count = int(np.frombuffer(blob, dtype=np.uint32, count=1)[0])
        offset = 4
        for _ in range(count):
            n = int(np.frombuffer(blob, dtype=np.uint32, count=1, offset=offset)[0])
            offset += 4
            ring = np.frombuffer(blob, dtype=np.float32, count=2 * n, offset=offset).reshape(n, 2)
            offset += 8 * n
            rings.append(ring.astype(np.float64))
    return meta, code, rings


def feature(geometry, properties=None, minzoom=None):
    props = dict(properties or {})
    out = {"type": "Feature", "geometry": geometry, "properties": props}
    if minzoom is not None:
        out["tippecanoe"] = {"minzoom": minzoom}
    return out


def r6(x):
    return round(float(x), 6)


def ring_coords(points):
    coords = [[r6(x), r6(y)] for x, y in points]
    if coords and coords[0] != coords[-1]:
        coords.append(coords[0])
    return coords


def depth_layers(meta, code):
    """Depth areas and contours from the grid, block by block."""
    west, north = meta["west"], meta["north"]
    lat_step, lon_step = meta["latStep"], meta["lonStep"]
    rows, cols = code.shape
    depth = code.astype(np.float32) / 2
    land = code == LAND
    # Under land the depth is 0, so the shallowest band reaches the coastline (drawn on top).
    depth[land] = 0
    # A little smoothing takes the stair-steps out of the 67 m grid; land stays put.
    smooth = ndimage.gaussian_filter(depth, sigma=0.8)
    smooth[land] = 0
    areas, contours = [], []
    for r0 in range(0, rows - 1, BLOCK):
        for c0 in range(0, cols - 1, BLOCK):
            r1, c1 = min(rows, r0 + BLOCK + 1), min(cols, c0 + BLOCK + 1)
            block = smooth[r0:r1, c0:c1]
            if land[r0:r1, c0:c1].all():
                continue
            # Cell centres in lon/lat.
            x = west + (np.arange(c0, c1) + 0.5) * lon_step
            y = north - (np.arange(r0, r1) + 0.5) * lat_step
            gen = contourpy.contour_generator(x, y, block, fill_type="OuterOffset", line_type="Separate")
            for lower, upper in zip(BANDS, BANDS[1:] + [12000]):
                if block.max() < lower or block.min() >= upper:
                    continue
                polygons, offsets = gen.filled(lower, upper)
                for points, offs in zip(polygons, offsets):
                    rings = [ring_coords(points[a:b]) for a, b in zip(offs[:-1], offs[1:])]
                    rings = [r for r in rings if len(r) >= 4]
                    if rings:
                        areas.append(feature({"type": "Polygon", "coordinates": rings}, {"min": lower, "max": upper}))
            for level in CONTOURS:
                if not (block.min() < level < block.max()):
                    continue
                lines = [[[r6(px), r6(py)] for px, py in line] for line in gen.lines(level) if len(line) >= 2]
                if lines:
                    contours.append(feature({"type": "MultiLineString", "coordinates": lines}, {"depth": level}))
    areas.sort(key=lambda f: f["properties"]["min"])
    return areas, contours


def soundings(meta, code):
    """Spot depths on a fixed lattice that thins out as you zoom out, like a paper chart."""
    west, north = meta["west"], meta["north"]
    lat_step, lon_step = meta["latStep"], meta["lonStep"]
    rows, cols = code.shape
    # Not right on the shore (the coastline would sit on the figures), but close to it: that is where
    # a skipper reads depths.
    near_land = ndimage.binary_dilation(code == LAND, iterations=1)
    out = []
    taken = np.zeros_like(code, dtype=bool)
    # (spacing in grid cells, first zoom, deepest metres shown). The grid is about 67 m a cell, finer
    # than the source data (EMODnet, about 115 m), so 2 cells is as dense as the data can justify.
    # Deep water gets fewer figures (the grid stores up to 127 m): nobody steers by them, and the file stays small.
    for spacing, minzoom, deepest in ((32, 9, 127), (16, 10, 127), (8, 11, 60), (4, 12, 40), (3, 13, 35), (2, 14, 30)):
        rr, cc = np.mgrid[spacing // 2:rows:spacing, spacing // 2:cols:spacing]
        rr, cc = rr.ravel(), cc.ravel()
        values = code[rr, cc]
        keep = (values != LAND) & (values >= 2) & (values <= deepest * 2) & ~near_land[rr, cc] & ~taken[rr, cc]
        for r, c, v in zip(rr[keep], cc[keep], values[keep]):
            taken[r, c] = True
            lon = west + (c + 0.5) * lon_step
            lat = north - (r + 0.5) * lat_step
            out.append(feature({"type": "Point", "coordinates": [r6(lon), r6(lat)]}, {"depth": float(v) / 2}, minzoom))
    return out


def seamark_minzoom(mark):
    t = mark["t"]
    if t == "light_major":
        return 7
    if "l" in mark or t in ("rock", "wreck", "obstruction"):
        return 10
    if t in ("harbour", "small_craft_facility", "anchorage"):
        return 10
    return 11


LIGHT_CHARACTER = re.compile(r"^(Al\.)?(LFl|Fl|VQ|UQ|IQ|Q|Iso|Oc|Mo\([A-Z]+\)|F)(\([^)]*\))?")


def symbol(mark):
    """The app's icon for a seamark (see SeamarkSymbols.swift), or None for no icon."""
    t, category = mark["t"], mark.get("c") or ""
    colours = (mark.get("col") or "").split(";")
    kind = "beacon" if t.startswith("beacon") else "buoy"
    if t == "rock":
        level = mark.get("wl")
        return f"rock-{level if level in ('dry', 'awash', 'covers') else 'submerged'}"
    if t in ("wreck", "obstruction", "mooring", "anchorage", "landmark"):
        return t
    if t in ("harbour", "small_craft_facility"):
        return "marina" if category == "marina" or t == "small_craft_facility" else "harbour"
    if t.endswith("_lateral"):
        port = "port" in category or colours[0] == "red"
        return f"{kind}-{'port' if port else 'starboard'}"
    if t.endswith("_cardinal"):
        return f"{kind}-cardinal-{category if category in ('north', 'south', 'east') else 'west'}"
    if t.endswith("_isolated_danger"):
        return "isolated-danger"
    if t.endswith("_safe_water"):
        return "safe-water"
    if t.endswith("_special_purpose"):
        return "special"
    if t in ("light_major", "light_minor", "light_vessel"):
        return None  # just the flare
    if t.startswith(("buoy", "beacon")):
        return f"{kind}-generic"
    return None


def light_colour(light):
    rest = LIGHT_CHARACTER.sub("", light).lstrip(".")
    return "R" if rest.startswith("R") else "G" if rest.startswith("G") else "W"


def seamark_points(meta):
    out = []
    for mark in meta.get("seamarks", []):
        props = {k: mark[k] for k in ("t", "n", "c", "col", "l", "d", "wl") if k in mark}
        if (sym := symbol(mark)):
            props["sym"] = sym
        if (light := mark.get("l")):
            props["ls"] = light.split(" ")[0]
            props["lc"] = light_colour(light)
        out.append(feature({"type": "Point", "coordinates": [mark["lo"], mark["la"]]}, props, seamark_minzoom(mark)))
    return out


def name_points(meta):
    zoom = {"strait": 9, "bay": 10, "island": 10, "cape": 11, "islet": 12}
    return [feature({"type": "Point", "coordinates": [p["lo"], p["la"]]}, {"t": p["t"], "n": p["n"]}, zoom.get(p["t"], 11))
            for p in meta.get("names", [])]


def bridge_lines(meta):
    out = []
    for b in meta.get("bridges", []):
        props = {k: b[k] for k in ("n", "h", "c") if k in b}
        out.append(feature({"type": "LineString", "coordinates": b["pts"]}, props, 11))
    return out


def land_polygons(rings):
    return [feature({"type": "Polygon", "coordinates": [ring_coords(r)]}) for r in rings if len(r) >= 3]


# MARK: OpenStreetMap details

AREA_KINDS = {
    "restricted_area": "restricted",
    "military_area": "restricted",
    "anchorage": "anchorage",
    "anchor_berth": "anchorage",
    "mooring": "mooring",
    "separation_zone": "tss_separation",
    "separation_line": "tss_separation",
    "separation_boundary": "tss_lane",
    "separation_lane": "tss_lane",
    "inshore_traffic_zone": "tss_lane",
    "fairway": "fairway",
    "recommended_track": "fairway",
    "navigation_line": "fairway",
    "cable_submarine": "cable",
    "cable_area": "cable",
    "pipeline_submarine": "pipeline",
    "pipeline_area": "pipeline",
    "seabed_area": "seabed",
    "marine_farm": "marine_farm",
    "dumping_ground": "restricted",
    "production_area": "restricted",
}

COLOUR_LETTER = {"red": "R", "green": "G", "white": "W", "yellow": "Y", "orange": "Y", "blue": "B", "violet": "V"}


def destination(lon, lat, bearing, nm):
    """Point `nm` nautical miles from lon/lat on a true bearing (flat earth, fine for a few miles)."""
    d = nm / 60
    return (lon + d * math.sin(math.radians(bearing)) / math.cos(math.radians(lat)),
            lat + d * math.cos(math.radians(bearing)))


def sector_features(lon, lat, tags, light):
    """Arcs and limit lines for each sector of a light. Sector limits are charted as bearings from
    seaward towards the light, so the arc around the light spans those bearings plus 180°."""
    out = []
    n = 1
    while f"seamark:light:{n}:colour" in tags or f"seamark:light:{n}:sector_start" in tags:
        start, end = tags.get(f"seamark:light:{n}:sector_start"), tags.get(f"seamark:light:{n}:sector_end")
        colour = (tags.get(f"seamark:light:{n}:colour") or "white").split(";")[0]
        rng = tags.get(f"seamark:light:{n}:range") or tags.get("seamark:light:range")
        n += 1
        if start is None or end is None:
            continue
        try:
            a, b = float(start) % 360, float(end) % 360
            reach = float(str(rng).split()[0].replace(",", ".")) if rng else 3.0
        except ValueError:
            continue
        radius = min(max(reach * 0.12, 0.25), 1.2)
        span = (b - a) % 360 or 360
        steps = max(4, int(span / 4))
        arc = [destination(lon, lat, (a + 180 + span * i / steps) % 360, radius) for i in range(steps + 1)]
        props = {"col": COLOUR_LETTER.get(colour, "W")}
        if light:
            props["l"] = light
        out.append(feature({"type": "LineString", "coordinates": [[r6(x), r6(y)] for x, y in arc]}, {**props, "part": "arc"}, 11))
        for bearing in (a, b):
            tip = destination(lon, lat, (bearing + 180) % 360, radius * 1.6)
            out.append(feature({"type": "LineString", "coordinates": [[r6(lon), r6(lat)], [r6(tip[0]), r6(tip[1])]]},
                               {**props, "part": "limit"}, 12))
    return out


def osm_details(paths, west, south, east, north):
    import osmium
    from shapely import wkb

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from build_region import light_description

    inside = lambda lon, lat: west <= lon <= east and south <= lat <= north
    factory = osmium.geom.WKBFactory()
    sectors, areas = [], []
    seen = set()

    def area_props(tags, kind):
        props = {"kind": AREA_KINDS[kind]}
        if (name := tags.get("seamark:name") or tags.get("name")):
            props["n"] = name
        if (category := tags.get(f"seamark:{kind}:category")):
            props["c"] = category
        if (restriction := tags.get(f"seamark:{kind}:restriction")):
            props["res"] = restriction
        if kind == "seabed_area" and (surface := tags.get("seamark:seabed_area:surface")):
            props["c"] = surface
        return props

    class Handler(osmium.SimpleHandler):
        def node(self, n):
            t = n.tags
            if "seamark:light:1:sector_start" not in t and "seamark:light:sector_start" not in t:
                return
            if not n.location.valid() or not inside(n.location.lon, n.location.lat):
                return
            tags = dict(t)
            if "seamark:light:sector_start" in tags:  # single-sector lights without the :1: index
                for key in ("sector_start", "sector_end", "colour", "range"):
                    if f"seamark:light:{key}" in tags:
                        tags.setdefault(f"seamark:light:1:{key}", tags[f"seamark:light:{key}"])
            sectors.extend(sector_features(n.location.lon, n.location.lat, tags, light_description(tags)))

        def way(self, w):
            kind = w.tags.get("seamark:type")
            if kind not in AREA_KINDS or w.is_closed() and kind not in ("separation_line", "navigation_line",
                                                                         "recommended_track", "cable_submarine",
                                                                         "pipeline_submarine"):
                return  # closed ways become areas below
            try:
                line = wkb.loads(factory.create_linestring(w), hex=True)
            except Exception:
                return
            if not any(inside(x, y) for x, y in line.coords) or ("w", w.id) in seen:
                return
            seen.add(("w", w.id))
            coords = [[r6(x), r6(y)] for x, y in line.coords]
            areas.append(feature({"type": "LineString", "coordinates": coords}, area_props(dict(w.tags), kind), 10))

        def area(self, a):
            kind = a.tags.get("seamark:type")
            if kind not in AREA_KINDS:
                return
            try:
                shape = wkb.loads(factory.create_multipolygon(a), hex=True)
            except Exception:
                return
            minx, miny, maxx, maxy = shape.bounds
            if maxx < west or minx > east or maxy < south or miny > north:
                return
            key = ("a", a.orig_id(), a.from_way())
            if key in seen:
                return
            seen.add(key)
            for poly in getattr(shape, "geoms", [shape]):
                rings = [ring_coords(poly.exterior.coords)] + [ring_coords(i.coords) for i in poly.interiors]
                areas.append(feature({"type": "Polygon", "coordinates": rings}, area_props(dict(a.tags), kind), 9))

    for path in paths:
        print(f"Reading {Path(path).name} for sectors and areas…", flush=True)
        Handler().apply_file(path, locations=True, idx="flex_mem")
    print(f"  {len(sectors)} sector lines, {len(areas)} areas and lines", flush=True)
    return sectors, areas


def build(pack_id, osm_paths=()):
    if not shutil.which("tippecanoe"):
        sys.exit("tippecanoe not found: brew install tippecanoe")
    meta, code, rings = load_pack(pack_id)
    print(f"Vector chart for {meta['name']}: grid {code.shape[0]}×{code.shape[1]}", flush=True)
    areas, contours = depth_layers(meta, code)
    print(f"  {len(areas)} depth areas, {len(contours)} contour sets", flush=True)
    layers = {
        "land": land_polygons(rings),
        "depare": areas,
        "depcnt": contours,
        "soundg": soundings(meta, code),
        "seamark": seamark_points(meta),
        "names": name_points(meta),
        "bridge": bridge_lines(meta),
    }
    if osm_paths:
        layers["lightsector"], layers["area"] = osm_details(osm_paths, meta["west"], meta["south"], meta["east"], meta["north"])

    out = CHARTS / f"{pack_id}.pmtiles"
    with tempfile.TemporaryDirectory() as tmp:
        args = ["tippecanoe", "-o", str(out), "--force", f"-Z{MIN_ZOOM}", f"-z{MAX_ZOOM}",
                "--name", meta["name"], "--attribution", meta.get("attribution", ""),
                "--detect-shared-borders", "--no-feature-limit", "--no-tile-size-limit",
                "--simplification=4", "--buffer=8", "--quiet"]
        for name, features in layers.items():
            path = Path(tmp) / f"{name}.geojson"
            with path.open("w") as f:
                json.dump({"type": "FeatureCollection", "features": features}, f, separators=(",", ":"))
            args += ["-L", json.dumps({"file": str(path), "layer": name})]
            print(f"  {name}: {len(features)} features", flush=True)
        subprocess.run(args, check=True)
    print(f"Wrote {out} ({out.stat().st_size / 1e6:.1f} MB)")

    meta["vector"] = out.name
    meta["format"] = FORMAT
    (CHARTS / f"{pack_id}.json").write_text(json.dumps(meta, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    args = sys.argv[1:]
    paths = []
    if "--osm" in args:
        i = args.index("--osm")
        paths = args[i + 1].split(",")
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit(__doc__)
    build(args[0], paths)
