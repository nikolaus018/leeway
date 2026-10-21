#!/usr/bin/env python3
"""Builds the vector chart of an offline chart pack: Leeway/Charts/<id>.pmtiles.

The app draws it with MapLibre, styled like the worldwide depth from the data server, so a pack is
simply the sharp version of the same chart. It is made from the pack's own files (the depth grid,
the coastline rings and the seamarks in <id>.json), plus details only OpenStreetMap has (light
sectors, restricted areas, traffic separation, cables, pipelines, seabed) from local extracts:

    .venv/bin/python tools/build_vector.py adriatic --osm croatia.osm.pbf,slovenia.osm.pbf

--aquamap adds official ENC depth, soundings, lights, sectors and dangers (tools/aquamap.py). That data is licensed:
such a pack is for your own device only; it is marked "enc" and server/deploy/ship.py won't upload it.

Needs tippecanoe (brew install tippecanoe) and numpy, shapely, contourpy, scipy (+ osmium for --osm).
build_region.py runs this at the end. Layers (attribute names are what the app's style reads):

    land          coastline polygons
    depare        depth areas, min/max metres
    depcnt        depth contours, depth
    soundg        spot soundings, depth (thinned per zoom)
    seamark       t type, n name, c category, col colour, l light, d depth, wl water level,
                  sym symbol key, ls short light characteristic, lc light colour (R/G/W)
    lightsector   sector arcs and limits, col (R/G/W/Y), l light
    area          kind, n name, c category, res restriction (traffic separation, cables, pipelines and
                  platforms from HHI's open data when tools/fetch_hhi.py has been run, else OSM's)
    names         t type, n name (t=sea, lvl: named seas from HHI)
    coastline     official coastline (HHI)
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
from shapely.geometry import Point, shape
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


def soundings(meta, code, skip=None):
    """Spot depths on a fixed lattice that thins out as you zoom out, like a paper chart. No figures in the cells
    `skip` marks (where measured soundings are drawn instead)."""
    west, north = meta["west"], meta["north"]
    lat_step, lon_step = meta["latStep"], meta["lonStep"]
    rows, cols = code.shape
    # Not right on the shore (the coastline would sit on the figures), but close to it: that is where
    # a skipper reads depths.
    near_land = ndimage.binary_dilation(code == LAND, iterations=1)
    out = []
    taken = np.zeros_like(code, dtype=bool) if skip is None else skip.copy()
    # (spacing in grid cells, first zoom, deepest metres shown). The grid is about 67 m a cell, finer
    # than the source data (EMODnet, about 115 m), so 2 cells is as dense as the data can justify.
    # Sparse when zoomed out, so the chart stays readable; the dense lattice only at the closest zoom and
    # only in shallow water, where a skipper reads depths.
    for spacing, minzoom, deepest in ((48, 11, 127), (24, 12, 127), (10, 13, 50), (4, 14, 30)):
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
    if t == "wreck":
        # Only a wreck charted as non-dangerous loses the danger ring: when unsure, assume it is.
        return "wreck-safe" if category == "non-dangerous" else "wreck"
    if t == "obstruction":
        return "boom" if category == "boom" else "obstruction"
    if t in ("mooring", "anchorage", "landmark"):
        return t
    if t in ("harbour", "small_craft_facility"):
        return "marina" if category == "marina" or t == "small_craft_facility" else "harbour"
    if t.endswith("_lateral"):
        port = "port" in category or colours[0] == "red"
        return f"{kind}-{'port' if port else 'starboard'}"
    if t.endswith("_cardinal"):
        # Only the four real categories: guessing "west" would draw a wrong mark.
        return f"{kind}-cardinal-{category}" if category in ("north", "south", "east", "west") else f"{kind}-generic"
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
    zoom = {"strait": 9, "island": 10, "bay": 12, "cape": 12, "islet": 13}
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


# MARK: Croatian Hydrographic Institute (HHI) open data, see fetch_hhi.py

HHI_CACHE = Path(__file__).resolve().parent / ".hhi-cache"
# What the OSM seamark data says about these, HHI's official layers replace.
HHI_REPLACES = {"tss_separation", "tss_lane", "cable", "pipeline"}
HHI_TSS_KIND = {
    "Traffic separation zone": "tss_separation",
    "Traffic separation scheme lane part": "tss_lane",
    "Precautionary area": "tss_lane",
    "Inshore traffic zone": "tss_lane",
}
# Sea area levels, from the big named seas to single bays: when their names appear.
HHI_SEA_ZOOM = {"regija": 7, "podregija": 9, "mikroregija": 11}


def hhi_features(name):
    path = HHI_CACHE / f"{name}.geojson"
    return json.loads(path.read_text())["features"] if path.exists() else []


def round_coords(value):
    return [round_coords(v) for v in value] if isinstance(value[0], list) else [r6(v) for v in value]


def title_case(text):
    """'ZALJEV VALUN' -> 'Zaljev Valun'."""
    return " ".join(w[:1] + w[1:].lower() for w in text.split())


def hhi_layers():
    """Official traffic separation, cables, pipelines and platforms (replacing OSM's), sea area
    names, and the coastline, or three empty lists when fetch_hhi.py hasn't been run."""
    areas, names, coast = [], [], []
    for f in hhi_features("tss"):
        p = f["properties"]
        kind = HHI_TSS_KIND.get(p.get("Vrsta"))
        if kind and f.get("geometry"):
            props = {"kind": kind, "n": p.get("Naziv", "").strip() or p["Vrsta"]}
            areas.append(feature({**f["geometry"], "coordinates": round_coords(f["geometry"]["coordinates"])}, props, 8))
    # Direction-of-traffic arrows along each lane (the polygon's ORIENT attribute is the flow, true).
    for f in hhi_features("tss"):
        p = f["properties"]
        if p.get("Vrsta") != "Traffic separation scheme lane part" or not p.get("orientat") or not f.get("geometry"):
            continue
        poly = shape(f["geometry"]).buffer(0)
        centre, angle = poly.centroid, math.radians(p["orientat"])
        step = 6 / 60  # degrees of latitude: about 6 NM between arrows
        for k in range(-60, 61):
            x = centre.x + k * step * math.sin(angle) / math.cos(math.radians(centre.y))
            y = centre.y + k * step * math.cos(angle)
            if poly.contains(Point(x, y)):
                areas.append(feature({"type": "Point", "coordinates": [r6(x), r6(y)]},
                                     {"kind": "tss_arrow", "rot": float(p["orientat"])}, 8))
    for group, kind, minzoom in (("cable_power", "cable", 10), ("cable_telecom", "cable", 10), ("pipe_gas", "pipeline", 10),
                                 ("pipe_oil", "pipeline", 10), ("pipe_water", "pipeline", 11), ("pipe_outfall", "pipeline", 12)):
        for f in hhi_features(group):
            if f.get("geometry"):
                props = {"kind": kind}
                if (name := (f["properties"].get("Naziv") or "").strip()):
                    props["n"] = name
                areas.append(feature({**f["geometry"], "coordinates": round_coords(f["geometry"]["coordinates"])}, props, minzoom))
    for f in hhi_features("platform"):
        if f.get("geometry"):
            props = {"kind": "platform", "n": (f["properties"].get("Naziv") or "").strip()}
            areas.append(feature({**f["geometry"], "coordinates": round_coords(f["geometry"]["coordinates"])}, props, 9))
    for f in hhi_features("sea"):
        p = f["properties"]
        zoom = HHI_SEA_ZOOM.get((p.get("podjela") or "").strip())
        if zoom is None or not f.get("geometry") or not (p.get("Naziv") or "").strip():
            continue
        point = shape(f["geometry"]).representative_point()
        names.append(feature({"type": "Point", "coordinates": [r6(point.x), r6(point.y)]},
                             {"t": "sea", "n": title_case(p["Naziv"].strip()), "lvl": p["podjela"].strip()}, zoom))
    for path in sorted(HHI_CACHE.glob("coast_*.geojson")):
        for f in hhi_features(path.stem):
            if f.get("geometry"):
                coast.append(feature({**f["geometry"], "coordinates": round_coords(f["geometry"]["coordinates"])}))
    return areas, names, coast


# MARK: Official aids to navigation (Plovput), added where OpenSeaMap has none

PLOVPUT_LIGHT_RHYTHM = {"Bl": "Fl", "DBl": "LFl", "K": "Q", "VK": "VQ", "Izo": "Iso", "Pr": "Oc", "Mo": "Mo"}
PLOVPUT_COLOUR = {"B": "W", "C": "R", "Z": "G", "Ž": "Y", "P": "B"}


def plovput_light(text, height, range_nm):
    """'Z Bl 3s (0,5+2,5)s' -> 'FlG.3s 9m 4M', in the notation the app parses; None when it isn't a light."""
    if not text or "stalno" in text and not re.search(r"\d+s", text):
        return "F" + PLOVPUT_COLOUR.get(text.strip()[:1], "W") if text and "stalno" in text else None
    m = re.match(r"\s*([BCZŽP]+)\s+(Bl|DBl|K|VK|Izo|Pr|Mo)(\([^)]*\))?\s*(\d+(?:,\d+)?)s", text)
    if not m:
        return None
    colour = PLOVPUT_COLOUR.get(m.group(1)[0], "W")
    period = m.group(4).replace(",", ".")
    out = f"{PLOVPUT_LIGHT_RHYTHM[m.group(2)]}{m.group(3) or ''}{colour}.{period}s"
    if height:
        out += f" {height:g}m"
    if range_nm:
        out += f" {range_nm}M"
    return out


def plovput_kind(tip, description, colour, topmark):
    """(t, category, colour) for a register entry, from its type code and the words describing it."""
    words = " ".join(filter(None, [description, colour, topmark])).lower()
    shape = {12: "beacon", 13: "beacon", 14: "buoy", 15: "buoy"}.get(tip)
    if shape is None:
        return None
    # A cardinal mark is told by its colours and by its topmark: when the two disagree, don't guess a side
    # (routing keeps clear of the danger the category points at).
    by_colour = ("south" if "žuta iznad crne" in words else "north" if "crna iznad žute" in words
                 else "east" if "crna sa širokim žutim pojasom" in words
                 else "west" if "žuta sa širokim crnim pojasom" in words else None)
    by_topmark = None
    if "dva crna stošca" in words:
        by_topmark = ("north" if "vrhom prema gore" in words else "south" if "vrhom prema dolje" in words
                      else "east" if "bazom prema bazi" in words else "west" if "vrhom prema vrhu" in words else None)
    if by_colour or by_topmark:
        if by_colour and by_topmark and by_colour != by_topmark:
            return shape, None, None
        side = by_colour or by_topmark
        colours = {"north": "black;yellow", "south": "yellow;black", "east": "black;yellow;black", "west": "yellow;black;yellow"}
        return f"{shape}_cardinal", side, colours[side]
    if "crna" in words and ("crven" in words or "dvije crne kugle" in words):
        return f"{shape}_isolated_danger", None, "black;red;black"
    if "crvene i bijele" in words or "crveno-bijel" in words:
        return f"{shape}_safe_water", None, "red;white"
    if "zelen" in words:
        return f"{shape}_lateral", "starboard", "green"
    if "crven" in words:
        return f"{shape}_lateral", "port", "red"
    if "žut" in words:
        return f"{shape}_special_purpose", None, "yellow"
    return shape, None, None


def merge_plovput(meta):
    """Adds the register's active aids that have no OpenSeaMap mark within 100 m. Earlier additions (src pv)
    are dropped first, so rebuilding doesn't pile them up."""
    path = HHI_CACHE / "plovput.geojson"
    marks = [m for m in meta["seamarks"] if m.get("src") != "pv"]
    if not path.exists():
        meta["seamarks"] = marks
        return 0
    index = {}
    for m in marks:
        if m["t"] in ("rock", "wreck", "obstruction", "mooring", "anchorage", "harbour", "small_craft_facility", "notice",
                      "marine_farm", "restricted_area"):
            continue
        index.setdefault((round(m["la"] * 100), round(m["lo"] * 100)), []).append(m)

    def has_mark(lat, lon):
        c = math.cos(math.radians(lat))
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for m in index.get((round(lat * 100) + dy, round(lon * 100) + dx), []):
                    if math.hypot((m["la"] - lat) * 111320, (m["lo"] - lon) * 111320 * c) < 100:
                        return True
        return False

    added = 0
    for f in json.loads(path.read_text())["features"]:
        p, g = f["properties"], f.get("geometry")
        if not g or p.get("status_objekta") != "Aktivan":
            continue
        lon, lat = g["coordinates"][:2]
        if not (meta["west"] < lon < meta["east"] and meta["south"] < lat < meta["north"]) or has_mark(lat, lon):
            continue
        tip = p.get("tip_objekta")
        light = plovput_light(p.get("kar_svjetla"), p.get("visina_srm"), p.get("domet_svjetla"))
        mark = {"la": round(lat, 6), "lo": round(lon, 6), "src": "pv"}
        if name := (p.get("naziv_objekta") or "").strip():
            mark["n"] = name
        if tip in (9, 10, 17):
            mark["t"] = "light_major"
        elif tip in (11, 16, 22):
            mark["t"] = "light_minor"
        elif (kind := plovput_kind(tip, p.get("opis_objekta"), p.get("boja_plutace"), p.get("oblik_boja_vrh"))):
            mark["t"] = kind[0]
            if kind[1]:
                mark["c"] = kind[1]
            if kind[2]:
                mark["col"] = kind[2]
        else:
            continue
        if light:
            mark["l"] = light
        elif mark["t"].startswith("light"):
            continue  # a light that doesn't show one isn't worth a symbol
        marks.append(mark)
        added += 1
    meta["seamarks"] = marks
    return added


# MARK: Protected areas (Croatian Agency for the Environment and Nature, via Bioportal)

DATA = Path(__file__).resolve().parent / "data"
PROTECTED_NOTE = {
    "Nacionalni park": "National park: entry rules and fees apply",
    "Park prirode": "Nature park: entry rules and fees apply",
    "Posebni rezervat": "Special reserve: restricted, check the rules",
    "Strogi rezervat": "Strict reserve: no entry",
}


# Parks whose zoning the national dataset doesn't hold (the park authorities do): only the outline is known.
NO_ZONE_DATA = {"KORNATI", "TELAŠĆICA"}


def title_name(text):
    return title_case(text) if text.isupper() else text


def protected_features():
    """National and nature parks, nature reserves, and the strict-protection sea zones inside parks, as
    `area` features (kind protected / protected_zone / protected_strict). The data in tools/data was
    fetched from the Bioportal WFS and simplified to about 50 m (that service only answers browsers)."""
    out = []
    areas, zones = DATA / "protected_areas.json", DATA / "protected_zones.json"
    if areas.exists():
        for name, category, polygons in json.loads(areas.read_text()):
            note = PROTECTED_NOTE.get(category, category)
            if name in NO_ZONE_DATA:
                note += "; its strict zones are not drawn here: get the park's map"
            props = {"kind": "protected", "n": title_name(name), "c": note}
            out.append(feature({"type": "MultiPolygon", "coordinates": polygons}, props, 7))
    if zones.exists():
        for park, zone, level, polygons in json.loads(zones.read_text()):
            kind = "protected_strict" if level == 1 else "protected_zone"
            note = "strictest protection zone: no entry" if level == 1 else "strict protection zone: restricted"
            out.append(feature({"type": "MultiPolygon", "coordinates": polygons}, {"kind": kind, "n": park, "c": note}, 9))
    return out


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


def osm_details(paths, west, south, east, north, skip_lights=frozenset()):
    """Light sectors and seamark areas from OSM extracts. Sectors of lights in `skip_lights` ((lat, lon) rounded to
    3 decimals) are left out: the ENC draws those."""
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
            la, lo = round(n.location.lat, 3), round(n.location.lon, 3)
            if any((round(la + dy, 3), round(lo + dx, 3)) in skip_lights
                   for dy in (-0.001, 0, 0.001) for dx in (-0.001, 0, 0.001)):
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


def restore_open_data(pack_id, enc):
    """A pack built with --aquamap has ENC data in its grid and seamarks. The open-data originals are kept in
    tools/.aquamap-cache/orig: every build starts from them, so builds don't pile up and a plain build is clean."""
    orig = Path(__file__).resolve().parent / ".aquamap-cache" / "orig"
    names = [f"{pack_id}.json", f"{pack_id}.depth"]
    current = json.loads((CHARTS / names[0]).read_text())
    if current.get("enc") and all((orig / n).exists() for n in names):
        for n in names:
            shutil.copyfile(orig / n, CHARTS / n)
    elif current.get("enc"):
        sys.exit(f"{pack_id} has ENC data but no open-data originals in {orig}: rebuild it with build_region.py")
    elif enc:
        orig.mkdir(parents=True, exist_ok=True)
        for n in names:
            shutil.copyfile(CHARTS / n, orig / n)


def build(pack_id, osm_paths=(), enc=False):
    if not shutil.which("tippecanoe"):
        sys.exit("tippecanoe not found: brew install tippecanoe")
    restore_open_data(pack_id, enc)
    meta, code, rings = load_pack(pack_id)
    print(f"  {merge_plovput(meta)} official aids to navigation added", flush=True)
    print(f"Vector chart for {meta['name']}: grid {code.shape[0]}×{code.shape[1]}", flush=True)
    if enc:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import aquamap
        print("ENC detail from Aqua Map (personal use only)…", flush=True)
        code, enc_covered, enc_areas, enc_contours, enc_soundings, enc_sectors, enc_sector_lights, summary = aquamap.enrich(meta, code)
        print(f"  {summary}", flush=True)
        # Routing and the depth under the boat read the same grid the chart is drawn from.
        packer = zlib.compressobj(9, zlib.DEFLATED, -15)
        (CHARTS / f"{pack_id}.depth").write_bytes(packer.compress(code.tobytes()) + packer.flush())
        meta["enc"] = True
        areas, contours = enc_areas, enc_contours
    else:
        meta.pop("enc", None)
        areas, contours = depth_layers(meta, code)
    print(f"  {len(areas)} depth areas, {len(contours)} contour sets", flush=True)
    layers = {
        "land": land_polygons(rings),
        "depare": areas,
        "depcnt": contours,
        "soundg": soundings(meta, code, skip=enc_covered) + enc_soundings if enc else soundings(meta, code),
        "seamark": seamark_points(meta),
        "names": name_points(meta),
        "bridge": bridge_lines(meta),
    }
    if enc:
        layers["lightsector"] = enc_sectors
    if osm_paths:
        osm_sectors, layers["area"] = osm_details(osm_paths, meta["west"], meta["south"], meta["east"], meta["north"],
                                                  skip_lights=enc_sector_lights if enc else set())
        layers["lightsector"] = layers.get("lightsector", []) + osm_sectors
    layers["area"] = layers.get("area", []) + protected_features()
    hhi_areas, hhi_names, hhi_coast = hhi_layers()
    if hhi_areas:
        # HHI's official layers replace OSM's for the same things.
        layers["area"] = [a for a in layers.get("area", []) if a["properties"].get("kind") not in HHI_REPLACES] + hhi_areas
        layers["names"] = layers["names"] + hhi_names
        layers["coastline"] = hhi_coast
        print(f"  HHI: {len(hhi_areas)} area features, {len(hhi_names)} sea names, {len(hhi_coast)} coastline parts", flush=True)

    out = CHARTS / f"{pack_id}.pmtiles"
    with tempfile.TemporaryDirectory() as tmp:
        args = ["tippecanoe", "-o", str(out), "--force", f"-Z{MIN_ZOOM}", f"-z{MAX_ZOOM}",
                "--name", meta["name"], "--attribution", meta.get("attribution", ""),
                "--detect-shared-borders", "--no-feature-limit", "--no-tile-size-limit",
                "--no-tiny-polygon-reduction", "--simplify-only-low-zooms",
                "--simplification=2", "--buffer=8", "--quiet"]
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
    enc = "--aquamap" in args
    if enc:
        args.remove("--aquamap")
    if len(args) != 1:
        sys.exit(__doc__)
    build(args[0], paths, enc)
