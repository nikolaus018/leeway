#!/usr/bin/env python3
"""Official ENC detail (Croatian Hydrographic Institute, via Aqua Map's vector tiles) for a chart pack.

PERSONAL USE ONLY. ENC data is licensed: a pack built with it must not be committed, published or deployed.
build_vector.py only uses this with --aquamap, marks the pack `"enc": true`, and server/deploy/ship.py refuses
to upload such a pack.

What it adds, and how it stays consistent with the rest of the pack:
- Vector bathymetry: builds a non-overlapping quadtree of the finest available ENC tiles (zoom 12 in harbours and
  approaches at ~1.7 m precision, zoom 11 along the coast at ~3.4 m, zoom 10 offshore), partitions the depth bands
  (subdividing with 1 m HD bathymetry where present, shallowest band winning where scales overlap) and derives
  seamless depth contours directly from the vector partition.
- Depth grid: the pack's routing/lookup grid (`adriatic.depth`) is clamped into the same ENC depth bands and spot
  soundings so route planning and the depth readout under the boat agree with the vector chart.
- Soundings: all measured spot depths from the finest ENC leaf tiles, thinned by zoom.
- Seamarks: ENC lights (characteristics, ranges, heights), cardinal / isolated-danger / lateral / safe-water /
  special-purpose marks, rocks, wrecks and obstructions are matched to the OSM marks or added where OSM has none.
- Light sectors: from the ENC, replacing OSM's for the same lights.

Tiles are cached in tools/.aquamap-cache (git-ignored).
"""

from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
import math
import time
import urllib.request
from pathlib import Path

from mapbox_vector_tile.decoder import TileData
import numpy as np
from PIL import Image, ImageDraw
from shapely.geometry import MultiPolygon, Polygon, box, shape
from shapely.ops import unary_union

CACHE_DIR = Path(__file__).resolve().parent / ".aquamap-cache"
URL = "https://open-maps.gec-it.com/pbf/aqua?z={z}&x={x}&y={y}"  # TMS y
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)"
BASE_ZOOM = 10

KEEP_LAYERS = {
    "depare_a", "3ddepare_a", "depcnt_l", "lndare_a", "soundg_p", "lights_p",
    "bcncar_p", "boycar_p", "bcnisd_p", "boyisd_p", "bcnlat_p", "boylat_p",
    "bcnspp_p", "boyspp_p", "boysaw_p", "uwtroc_p", "wrecks_p", "obstrn_p",
}
FINE_BANDS = [(0, 1), (1, 2), (2, 3), (3, 5), (5, 10), (10, 15), (15, 20), (20, 30), (30, 50)]
DEEP_BANDS = [(50, 100), (100, 200)]

# S-57 LITCHR (light characteristic) → chart abbreviation.
LITCHR = {1: "F", 2: "Fl", 3: "LFl", 4: "Q", 5: "VQ", 6: "UQ", 7: "Iso", 8: "Oc", 9: "IQ", 10: "IVQ", 11: "IUQ",
          12: "Mo", 13: "FFl", 14: "Fl+LFl", 15: "Oc+Fl", 16: "FLFl", 17: "Al.Oc", 18: "Al.LFl", 19: "Al.Fl",
          20: "Al.Gr", 25: "Q+LFl", 26: "VQ+LFl", 27: "UQ+LFl", 28: "Al", 29: "Al.FFl"}
# S-57 COLOUR → light letter.
LIGHT_LETTER = {"1": "W", "3": "R", "4": "G", "6": "Y", "11": "Y"}
# S-57 WATLEV → the app's water level words (see build_vector.symbol).
WATLEV = {1: "dry", 2: "dry", 3: "submerged", 4: "covers", 5: "awash"}


def r6(x):
    return round(float(x), 6)


def num(x):
    return f"{float(x):g}"


# MARK: Tiles & Quadtree

def deg2num(lat, lon, z):
    n = 2.0 ** z
    return (int((lon + 180.0) / 360.0 * n),
            int((1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n))


def to_lonlat(px, py, extent, z, x, y):
    """Tile pixel → lon, lat. Tiles are decoded with y_coord_down, so py grows southwards."""
    n = 2.0 ** z
    lon = (x + px / extent) / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi - 2.0 * math.pi * (y + py / extent) / n)))
    return lon, lat


def fetch(z, x, y):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = CACHE_DIR / f"{z}_{x}_{y}.pbf"
    if path.exists():
        return path.read_bytes()
    url = URL.format(z=z, x=x, y=(2 ** z - 1) - y)
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = resp.read()
            path.write_bytes(data)
            return data
        except urllib.error.HTTPError as e:
            if e.code == 404:
                path.write_bytes(b"")
                return b""
            time.sleep(0.5 * (attempt + 1))
        except Exception:
            time.sleep(0.5 * (attempt + 1))
    return None


def decode_tile(path):
    td = TileData(path.read_bytes(), default_options={"y_coord_down": True})
    for i in range(len(td.tile.layers) - 1, -1, -1):
        if td.tile.layers[i].name not in KEEP_LAYERS:
            del td.tile.layers[i]
    return td.get_message()


def build_quadtree_leaves(west, south, east, north):
    """Ensure base zoom-10 tiles exist, then build a non-overlapping quadtree of (z, x, y, path, (fx0, fy0, fx1, fy1))
    using cached zoom-11 and zoom-12 coastal/harbour tiles where available."""
    x0, y1 = deg2num(south, west, BASE_ZOOM)
    x1, y0 = deg2num(north, east, BASE_ZOOM)
    keys10 = [(BASE_ZOOM, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda k: fetch(*k), keys10))

    def non_empty(z, x, y):
        p = CACHE_DIR / f"{z}_{x}_{y}.pbf"
        return p if p.exists() and p.stat().st_size > 0 else None

    leaves = []
    for _, x10, y10 in keys10:
        p10 = non_empty(10, x10, y10)
        if not p10:
            continue
        has11 = any(non_empty(11, x10 * 2 + dx, y10 * 2 + dy) for dx in (0, 1) for dy in (0, 1))
        if not has11:
            leaves.append((10, x10, y10, p10, (0.0, 0.0, 1.0, 1.0)))
            continue
        for dx in (0, 1):
            for dy in (0, 1):
                x11, y11 = x10 * 2 + dx, y10 * 2 + dy
                p11 = non_empty(11, x11, y11)
                has12 = any(non_empty(12, x11 * 2 + sdx, y11 * 2 + sdy) for sdx in (0, 1) for sdy in (0, 1))
                if has12:
                    for sdx in (0, 1):
                        for sdy in (0, 1):
                            x12, y12 = x11 * 2 + sdx, y11 * 2 + sdy
                            if (p12 := non_empty(12, x12, y12)):
                                leaves.append((12, x12, y12, p12, (0.0, 0.0, 1.0, 1.0)))
                            elif p11:
                                leaves.append((11, x11, y11, p11, (sdx * 0.5, sdy * 0.5, (sdx + 1) * 0.5, (sdy + 1) * 0.5)))
                            else:
                                leaves.append((10, x10, y10, p10,
                                               ((dx * 2 + sdx) * 0.25, (dy * 2 + sdy) * 0.25,
                                                (dx * 2 + sdx + 1) * 0.25, (dy * 2 + sdy + 1) * 0.25)))
                elif p11:
                    leaves.append((11, x11, y11, p11, (0.0, 0.0, 1.0, 1.0)))
                else:
                    leaves.append((10, x10, y10, p10, (dx * 0.5, dy * 0.5, (dx + 1) * 0.5, (dy + 1) * 0.5)))
    return leaves


def leaf_points(leaves, decoded, layer, bounds):
    """(lon, lat, properties) of a point layer from the quadtree leaves, clipped to each leaf's fractional box."""
    west, south, east, north = bounds
    for z, x, y, path, (fx0, fy0, fx1, fy1) in leaves:
        dec = decoded[path]
        if layer not in dec:
            continue
        ext = dec[layer].get("extent", 4096)
        x_min, y_min, x_max, y_max = fx0 * ext, fy0 * ext, fx1 * ext, fy1 * ext
        for f in dec[layer]["features"]:
            g = f["geometry"]
            if g["type"] != "Point":
                continue
            px, py = g["coordinates"]
            if not (x_min <= px < x_max and y_min <= py < y_max):
                continue
            lon, lat = to_lonlat(px, py, ext, z, x, y)
            if west <= lon <= east and south <= lat <= north:
                yield lon, lat, f["properties"]


# MARK: Vector Bathymetry (Planar Partition & Seamless Contours)

def only_polys(g):
    if g is None or g.is_empty:
        return Polygon()
    if g.geom_type == "Polygon":
        return g
    if hasattr(g, "geoms"):
        ps = [q for p in g.geoms
              for q in ([p] if p.geom_type == "Polygon" else list(p.geoms) if p.geom_type == "MultiPolygon" else [])
              if not q.is_empty and q.area > 0]
        return MultiPolygon(ps) if len(ps) > 1 else (ps[0] if ps else Polygon())
    return Polygon()


def drop_border_segments(coords, cx0, cy0, cx1, cy1, eps=0.5):
    lines, cur = [], []
    for i in range(len(coords) - 1):
        a, b = coords[i], coords[i + 1]
        on_edge = ((abs(a[0] - cx0) <= eps and abs(b[0] - cx0) <= eps) or
                   (abs(a[0] - cx1) <= eps and abs(b[0] - cx1) <= eps) or
                   (abs(a[1] - cy0) <= eps and abs(b[1] - cy0) <= eps) or
                   (abs(a[1] - cy1) <= eps and abs(b[1] - cy1) <= eps))
        if on_edge:
            if len(cur) >= 2:
                lines.append(cur)
            cur = []
        else:
            if not cur:
                cur.append(a)
            cur.append(b)
    if len(cur) >= 2:
        lines.append(cur)
    return lines


def _ring_lonlat(coords, ext, z, x, y):
    pts = [[r6(lon), r6(lat)] for px, py in coords for lon, lat in (to_lonlat(px, py, ext, z, x, y),)]
    if pts and pts[0] != pts[-1]:
        pts.append(pts[0])
    return pts


def _poly_features(geom, d1, d2, ext, z, x, y):
    out = []
    for poly in ([geom] if geom.geom_type == "Polygon" else getattr(geom, "geoms", [])):
        if poly.is_empty:
            continue
        rings = [_ring_lonlat(poly.exterior.coords, ext, z, x, y)]
        rings += [_ring_lonlat(h.coords, ext, z, x, y) for h in poly.interiors]
        rings = [r for r in rings if len(r) >= 4]
        if rings:
            out.append({"type": "Feature", "geometry": {"type": "Polygon", "coordinates": rings},
                        "properties": {"min": d1, "max": d2}})
    return out


def _process_leaf_chunk(chunk):
    """Worker for ProcessPoolExecutor: decodes and partitions a batch of quadtree leaves."""
    areas, contours = [], []
    cache = {}
    for z, x, y, path_str, (fx0, fy0, fx1, fy1), bounds in chunk:
        west, south, east, north = bounds
        # Skip tiles completely outside pack bounds
        lon0, lat0 = to_lonlat(fx0 * 4096, fy1 * 4096, 4096, z, x, y)
        lon1, lat1 = to_lonlat(fx1 * 4096, fy0 * 4096, 4096, z, x, y)
        if lon1 < west or lon0 > east or lat1 < south or lat0 > north:
            continue
        if path_str not in cache:
            cache[path_str] = decode_tile(Path(path_str))
        d = cache[path_str]
        if "depare_a" not in d:
            continue
        ext = d["depare_a"].get("extent", 4096)
        cx0, cy0, cx1, cy1 = fx0 * ext, fy0 * ext, fx1 * ext, fy1 * ext
        clip = box(cx0, cy0, cx1, cy1)

        has_shallow = any(float(f["properties"].get("drval1") or 0) < 50 for f in d["depare_a"]["features"])
        if not has_shallow:
            for f in d["depare_a"]["features"]:
                pr = f["properties"]
                d1 = max(float(pr.get("drval1") or 0), 0.0)
                d2 = float(pr["drval2"]) if pr.get("drval2") is not None else 12000.0
                b_lo, b_hi = (100, 200) if d1 >= 100 else (50, 100)
                g = only_polys(shape(f["geometry"]).buffer(0).intersection(clip))
                if not g.is_empty:
                    areas.extend(_poly_features(g, b_lo, b_hi, ext, z, x, y))
            for f in d.get("depcnt_l", {}).get("features", []):
                val = f["properties"].get("valdco")
                if val == 100:
                    g = shape(f["geometry"]).intersection(clip)
                    raw = [g] if g.geom_type == "LineString" else [l for l in getattr(g, "geoms", []) if l.geom_type == "LineString"]
                    lines = [[[r6(lon), r6(lat)] for px, py in l.coords for lon, lat in (to_lonlat(px, py, ext, z, x, y),)]
                             for l in raw if len(l.coords) >= 2]
                    if lines:
                        contours.append({"type": "Feature", "geometry": {"type": "MultiLineString", "coordinates": lines},
                                         "properties": {"depth": 100}})
            continue

        ge3d = {}
        if "3ddepare_a" in d:
            for f in d["3ddepare_a"]["features"]:
                d1 = float(f["properties"].get("drval1") or 0)
                if d1 in (1, 2, 3, 5, 15, 30):
                    g = only_polys(shape(f["geometry"]).buffer(0).intersection(clip))
                    if not g.is_empty:
                        ge3d.setdefault(d1, []).append(g)
            ge3d = {k: only_polys(unary_union(v)) for k, v in ge3d.items()}

        def split_by_3d(poly, d_lo, d_mid, d_hi, dest):
            if poly.is_empty:
                return
            if d_mid in ge3d:
                dest[(d_lo, d_mid)].append(only_polys(poly.difference(ge3d[d_mid])))
                dest[(d_mid, d_hi)].append(only_polys(poly.intersection(ge3d[d_mid])))
            else:
                dest[(d_mid, d_hi)].append(poly)

        specific = {b: [] for b in FINE_BANDS}
        deep_polys = {(50, 100): [], (100, 200): []}
        coarse = {(0, 5): [], (0, 10): [], (20, 50): []}
        for f in d["depare_a"]["features"]:
            pr = f["properties"]
            d1 = max(float(pr.get("drval1") or 0), 0.0)
            d2 = float(pr["drval2"]) if pr.get("drval2") is not None else 12000.0
            g = only_polys(shape(f["geometry"]).buffer(0).intersection(clip))
            if g.is_empty:
                continue
            if d1 >= 100:
                deep_polys[(100, 200)].append(g)
            elif d1 >= 50:
                deep_polys[(50, 100)].append(g)
            elif d2 <= 2:
                split_by_3d(g, 0, 1, 2, specific)
            elif (d1, d2) == (2, 5):
                split_by_3d(g, 2, 3, 5, specific)
            elif (d1, d2) == (5, 10):
                specific[(5, 10)].append(g)
            elif (d1, d2) == (10, 20):
                split_by_3d(g, 10, 15, 20, specific)
            elif (d1, d2) in specific:
                specific[(d1, d2)].append(g)
            elif (d1, d2) in coarse:
                coarse[(d1, d2)].append(g)
            elif d2 <= 20:
                split_by_3d(g, 10, 15, 20, specific)
            elif d2 <= 50:
                coarse[(20, 50)].append(g)
            else:
                deep_polys[(50, 100)].append(g)

        u_spec = {b: only_polys(unary_union(specific[b])) if specific[b] else Polygon() for b in FINE_BANDS}
        fine_0_10 = only_polys(unary_union([u_spec[(0, 1)], u_spec[(1, 2)], u_spec[(2, 3)], u_spec[(3, 5)], u_spec[(5, 10)]]))
        fine_20_50 = only_polys(unary_union([u_spec[(20, 30)], u_spec[(30, 50)]]))

        if coarse[(0, 5)]:
            c05 = only_polys(unary_union(coarse[(0, 5)]).difference(fine_0_10))
            if 2 in ge3d:
                c02, c25 = only_polys(c05.difference(ge3d[2])), only_polys(c05.intersection(ge3d[2]))
                split_by_3d(c02, 0, 1, 2, specific)
                split_by_3d(c25, 2, 3, 5, specific)
                for b in ((0, 1), (1, 2), (2, 3), (3, 5)):
                    u_spec[b] = only_polys(unary_union(specific[b])) if specific[b] else Polygon()
            else:
                u_spec[(3, 5)] = only_polys(unary_union([u_spec[(3, 5)], c05]))
            fine_0_10 = only_polys(unary_union([fine_0_10, c05]))

        if coarse[(0, 10)]:
            c010 = only_polys(unary_union(coarse[(0, 10)]).difference(fine_0_10))
            if 2 in ge3d and 5 in ge3d:
                c02 = only_polys(c010.difference(ge3d[2]))
                c25 = only_polys(c010.intersection(ge3d[2]).difference(ge3d[5]))
                c510 = only_polys(c010.intersection(ge3d[5]))
                split_by_3d(c02, 0, 1, 2, specific)
                split_by_3d(c25, 2, 3, 5, specific)
                for b in ((0, 1), (1, 2), (2, 3), (3, 5)):
                    u_spec[b] = only_polys(unary_union(specific[b])) if specific[b] else Polygon()
                u_spec[(5, 10)] = only_polys(unary_union([u_spec[(5, 10)], c510]))
            else:
                u_spec[(5, 10)] = only_polys(unary_union([u_spec[(5, 10)], c010]))

        if coarse[(20, 50)]:
            c2050 = only_polys(unary_union(coarse[(20, 50)]).difference(fine_20_50))
            if 30 in ge3d:
                u_spec[(20, 30)] = only_polys(unary_union([u_spec[(20, 30)], c2050.difference(ge3d[30])]))
                u_spec[(30, 50)] = only_polys(unary_union([u_spec[(30, 50)], c2050.intersection(ge3d[30])]))
            else:
                u_spec[(30, 50)] = only_polys(unary_union([u_spec[(30, 50)], c2050]))

        covered = Polygon()
        partition = {}
        for b in FINE_BANDS:
            g = only_polys(u_spec[b].difference(covered))
            if not g.is_empty:
                partition[b] = g
                covered = only_polys(unary_union([covered, g]))
                areas.extend(_poly_features(g, b[0], b[1], ext, z, x, y))

        for b in DEEP_BANDS:
            if deep_polys[b]:
                g = only_polys(unary_union(deep_polys[b]).difference(covered))
                if not g.is_empty:
                    covered = only_polys(unary_union([covered, g]))
                    areas.extend(_poly_features(g, b[0], b[1], ext, z, x, y))

        land_feats = d.get("lndare_a", {}).get("features", [])
        land = only_polys(unary_union([shape(f["geometry"]).buffer(0).intersection(clip) for f in land_feats])) if land_feats else Polygon()
        drawn = land.buffer(1.5)
        shallow_union = land
        for (d1, d2) in FINE_BANDS:
            if (d1, d2) in partition:
                shallow_union = only_polys(unary_union([shallow_union, partition[(d1, d2)]]))
            if shallow_union.is_empty:
                continue
            bndry = shallow_union.boundary
            cnt = bndry.difference(drawn)
            if not cnt.is_empty:
                drawn = unary_union([drawn, bndry.buffer(0.5)])
                raw = [cnt] if cnt.geom_type == "LineString" else [l for l in getattr(cnt, "geoms", []) if l.geom_type == "LineString"]
                lines = []
                for rl in raw:
                    for seg in drop_border_segments(list(rl.coords), cx0, cy0, cx1, cy1):
                        lines.append([[r6(lon), r6(lat)] for px, py in seg for lon, lat in (to_lonlat(px, py, ext, z, x, y),)])
                if lines:
                    contours.append({"type": "Feature", "geometry": {"type": "MultiLineString", "coordinates": lines},
                                     "properties": {"depth": d2}})

        for f in d.get("depcnt_l", {}).get("features", []):
            if f["properties"].get("valdco") == 100:
                g = shape(f["geometry"]).intersection(clip)
                raw = [g] if g.geom_type == "LineString" else [l for l in getattr(g, "geoms", []) if l.geom_type == "LineString"]
                lines = [[[r6(lon), r6(lat)] for px, py in l.coords for lon, lat in (to_lonlat(px, py, ext, z, x, y),)]
                         for l in raw if len(l.coords) >= 2]
                if lines:
                    contours.append({"type": "Feature", "geometry": {"type": "MultiLineString", "coordinates": lines},
                                     "properties": {"depth": 100}})
    return areas, contours


def vector_bathymetry(leaves, bounds):
    items = [(z, x, y, str(path), frac, bounds) for z, x, y, path, frac in leaves]
    workers = 8
    chunks = [items[i::workers] for i in range(workers)]
    areas, contours = [], []
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for a, c in pool.map(_process_leaf_chunk, chunks):
            areas.extend(a)
            contours.extend(c)
    areas.sort(key=lambda f: f["properties"]["min"])
    return areas, contours


# MARK: Depth grid (for routing & depth readout under the boat)

def clamp_depth_grid(leaves, decoded, meta, code, land_code=255):
    """The pack's depth codes (half metres, 255 land) clamped into the ENC depth bands and spot soundings."""
    west, north = meta["west"], meta["north"]
    lat_step, lon_step = meta["latStep"], meta["lonStep"]
    rows, cols = code.shape
    lo = np.full(code.shape, 1e9, dtype=np.float32)
    hi = np.zeros(code.shape, dtype=np.float32)

    for z, x, y, path, _ in leaves:
        if z != 10 and (10, x >> (z - 10), y >> (z - 10)) != (z, x, y):
            pass
        dec = decoded[path]
        if "depare_a" not in dec:
            continue
        ext = dec["depare_a"].get("extent", 4096)
        for f in dec["depare_a"]["features"]:
            p, g = f["properties"], f["geometry"]
            d1 = max(float(p.get("drval1") or 0), 0.0)
            d2 = float(p["drval2"]) if p.get("drval2") is not None else 12000.0
            polygons = [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"] if g["type"] == "MultiPolygon" else []
            for rings in polygons:
                pix = []
                for ring in rings:
                    pts = [((lon - west) / lon_step - 0.5, (north - lat) / lat_step - 0.5)
                           for px, py in ring for lon, lat in (to_lonlat(px, py, ext, z, x, y),)]
                    pix.append(pts)
                xs = [p_[0] for p_ in pix[0]]
                ys = [p_[1] for p_ in pix[0]]
                c0, c1 = max(int(math.floor(min(xs))), 0), min(int(math.ceil(max(xs))) + 1, cols)
                r0, r1 = max(int(math.floor(min(ys))), 0), min(int(math.ceil(max(ys))) + 1, rows)
                if c0 >= c1 or r0 >= r1:
                    continue
                mask = Image.new("1", (c1 - c0, r1 - r0), 0)
                draw = ImageDraw.Draw(mask)
                draw.polygon([(a - c0, b - r0) for a, b in pix[0]], fill=1)
                for hole in pix[1:]:
                    if len(hole) >= 3:
                        draw.polygon([(a - c0, b - r0) for a, b in hole], fill=0)
                m = np.array(mask, dtype=bool)
                if not m.any():
                    continue
                lo_c, hi_c = lo[r0:r1, c0:c1], hi[r0:r1, c0:c1]
                sel = m & (d1 < lo_c)
                lo_c[sel] = d1
                hi_c[sel] = d2

    covered = lo < 1e9
    depth = code.astype(np.float32) / 2
    land = code == land_code
    out = code.copy()
    water = covered & ~land
    clamped = np.clip(depth[water], lo[water], np.minimum(hi[water], 127.0))
    out[water] = np.clip(np.round(clamped * 2), 0, 254).astype(np.uint8)
    opened = covered & land & (lo >= 2)
    out[opened] = np.clip(np.round(np.minimum(lo[opened], 127.0) * 2), 0, 254).astype(np.uint8)
    return out, covered, int(opened.sum())


# MARK: Soundings

def soundings(leaves, decoded, bounds):
    """Measured spot depths from all quadtree leaves, thinned like a paper chart: shallowest kept per cell."""
    raw = [(lon, lat, float(p["valsou"]))
           for lon, lat, p in leaf_points(leaves, decoded, "soundg_p", bounds)
           if p.get("valsou") is not None]
    raw.sort(key=lambda s: s[2])
    taken = set()
    out = []
    # (cell size in degrees of latitude, first zoom): ~1.5 km, 750 m, 350 m, 150 m.
    for cell, minzoom in ((0.0135, 11), (0.0068, 12), (0.0032, 13), (0.0011, 14)):
        used = set()
        for i, (lon, lat, d) in enumerate(raw):
            if i in taken:
                continue
            key = (round(lat / cell), round(lon * math.cos(math.radians(lat)) / cell))
            if key in used:
                continue
            used.add(key)
            taken.add(i)
            out.append((lon, lat, round(d, 1), minzoom))
    return out


# MARK: Lights and sectors

def light_text(p, colours=None):
    base = LITCHR.get(p.get("litchr"))
    if not base:
        return None
    group = (p.get("siggrp") or "").strip()
    if group in ("(1)", "()", "(U)") and base != "Mo":
        group = ""
    if "+" in base and group:  # Q(6)+LFl
        head, tail = base.split("+", 1)
        text = f"{head}{group.split(')')[0]})+{tail}"
    else:
        text = base + group
    text += colours if colours is not None else LIGHT_LETTER.get(str(p.get("colour", "1")).split(",")[0], "W")
    if p.get("sigper"):
        text += f".{num(p['sigper'])}s"
    if p.get("height"):
        text += f" {num(p['height'])}m"
    if p.get("valnmr"):
        text += f" {num(p['valnmr'])}M"
    return text


def destination(lon, lat, bearing, nm):
    d = nm / 60
    return (lon + d * math.sin(math.radians(bearing)) / math.cos(math.radians(lat)),
            lat + d * math.cos(math.radians(bearing)))


def lights(leaves, decoded, bounds):
    """(lights, sectors): one light per position (colours combined, the main light's characteristic) and the
    sector arcs and limits as `lightsector` features."""
    by_position = {}
    seen = set()
    sectors = []
    for lon, lat, p in leaf_points(leaves, decoded, "lights_p", bounds):
        key = (round(lat, 5), round(lon, 5))
        record = (key, p.get("sectr1"), p.get("sectr2"), p.get("colour"), p.get("litchr"), p.get("valnmr"))
        if record in seen:
            continue
        seen.add(record)
        by_position.setdefault(key, []).append((lon, lat, p))
        s1, s2 = p.get("sectr1"), p.get("sectr2")
        if s1 is None or s2 is None or float(s1) % 360 == float(s2) % 360:
            continue
        a, b = float(s1) % 360, float(s2) % 360
        radius = min(max(float(p.get("valnmr") or 3) * 0.12, 0.25), 1.2)
        span = (b - a) % 360 or 360
        steps = max(4, int(span / 4))
        arc = [destination(lon, lat, (a + 180 + span * i / steps) % 360, radius) for i in range(steps + 1)]
        props = {"col": LIGHT_LETTER.get(str(p.get("colour", "1")).split(",")[0], "W")}
        if (text := light_text(p)):
            props["l"] = text
        sectors.append({"type": "Feature", "properties": {**props, "part": "arc"}, "tippecanoe": {"minzoom": 11},
                        "geometry": {"type": "LineString", "coordinates": [[r6(x), r6(y)] for x, y in arc]}})
        for bearing in (a, b):
            tip = destination(lon, lat, (bearing + 180) % 360, radius * 1.6)
            sectors.append({"type": "Feature", "properties": {**props, "part": "limit"}, "tippecanoe": {"minzoom": 12},
                            "geometry": {"type": "LineString", "coordinates": [[r6(lon), r6(lat)], [r6(tip[0]), r6(tip[1])]]}})

    out = []
    for records in by_position.values():
        main = max(records, key=lambda r: float(r[2].get("valnmr") or 0))
        lon, lat, p = main
        same = [r[2] for r in records if r[2].get("litchr") == p.get("litchr") and r[2].get("sigper") == p.get("sigper")]
        letters = []
        for q in same:
            letter = LIGHT_LETTER.get(str(q.get("colour", "1")).split(",")[0], "W")
            if letter not in letters:
                letters.append(letter)
        letters.sort(key="WRGY".index)
        text = light_text(p, "".join(letters))
        if not text:
            continue
        mark = {"t": "light_major" if float(p.get("valnmr") or 0) >= 15 else "light_minor",
                "la": r6(lat), "lo": r6(lon), "l": text}
        if (name := (p.get("objnam") or "").strip()):
            mark["n"] = name
        out.append(mark)
    return out, sectors


# MARK: Other seamarks

CARDINAL_COLOURS = {"2,6": "north", "6,2": "south", "2,6,2": "east", "6,2,6": "west"}
CARDINAL_PATTERN = {"north": "black;yellow", "south": "yellow;black", "east": "black;yellow;black", "west": "yellow;black;yellow"}


def structures(leaves, decoded, bounds):
    out = []
    for layer, kind in (("bcncar_p", "beacon"), ("boycar_p", "buoy")):
        for lon, lat, p in leaf_points(leaves, decoded, layer, bounds):
            side = CARDINAL_COLOURS.get(str(p.get("colour", "")).replace(";", ","))
            mark = {"t": f"{kind}_cardinal", "la": r6(lat), "lo": r6(lon)}
            if side:
                mark["c"], mark["col"] = side, CARDINAL_PATTERN[side]
            if (name := (p.get("objnam") or "").strip()):
                mark["n"] = name
            out.append(mark)
    for layer, kind in (("bcnisd_p", "beacon"), ("boyisd_p", "buoy")):
        for lon, lat, p in leaf_points(leaves, decoded, layer, bounds):
            mark = {"t": f"{kind}_isolated_danger", "la": r6(lat), "lo": r6(lon), "col": "black;red;black"}
            if (name := (p.get("objnam") or "").strip()):
                mark["n"] = name
            out.append(mark)
    for layer, kind in (("bcnlat_p", "beacon"), ("boylat_p", "buoy")):
        for lon, lat, p in leaf_points(leaves, decoded, layer, bounds):
            cat = str(p.get("catlam", ""))
            col = str(p.get("colour", "")).split(",")[0]
            port = cat == "1" or col == "3"
            mark = {"t": f"{kind}_lateral", "la": r6(lat), "lo": r6(lon),
                    "c": "port" if port else "starboard", "col": "red" if port else "green"}
            if (name := (p.get("objnam") or "").strip()):
                mark["n"] = name
            out.append(mark)
    for layer, kind in (("bcnspp_p", "beacon"), ("boyspp_p", "buoy")):
        for lon, lat, p in leaf_points(leaves, decoded, layer, bounds):
            mark = {"t": f"{kind}_special_purpose", "la": r6(lat), "lo": r6(lon), "col": "yellow"}
            if (name := (p.get("objnam") or "").strip()):
                mark["n"] = name
            out.append(mark)
    for lon, lat, p in leaf_points(leaves, decoded, "boysaw_p", bounds):
        mark = {"t": "buoy_safe_water", "la": r6(lat), "lo": r6(lon), "col": "red;white"}
        if (name := (p.get("objnam") or "").strip()):
            mark["n"] = name
        out.append(mark)
    return out


def hazards(leaves, decoded, bounds):
    out = []
    for lon, lat, p in leaf_points(leaves, decoded, "uwtroc_p", bounds):
        if p.get("valsou") is not None and float(p["valsou"]) > 10:
            continue
        mark = {"t": "rock", "la": r6(lat), "lo": r6(lon), "wl": WATLEV.get(p.get("watlev"), "submerged")}
        if p.get("valsou") is not None:
            mark["d"] = num(round(float(p["valsou"]), 1))
        if (name := (p.get("objnam") or "").strip()):
            mark["n"] = name
        out.append(mark)
    for lon, lat, p in leaf_points(leaves, decoded, "wrecks_p", bounds):
        mark = {"t": "wreck", "la": r6(lat), "lo": r6(lon), "c": "non-dangerous" if p.get("catwrk") == 1 else "dangerous"}
        if p.get("valsou") is not None:
            mark["d"] = num(round(float(p["valsou"]), 1))
        out.append(mark)
    for lon, lat, p in leaf_points(leaves, decoded, "obstrn_p", bounds):
        if p.get("valsou") is not None and float(p["valsou"]) > 10:
            continue
        mark = {"t": "obstruction", "la": r6(lat), "lo": r6(lon), "wl": WATLEV.get(p.get("watlev"), "submerged")}
        if p.get("valsou") is not None:
            mark["d"] = num(round(float(p["valsou"]), 1))
        if (name := (p.get("objnam") or "").strip()):
            mark["n"] = name
        out.append(mark)
    return out


# MARK: Merge

class Index:
    def __init__(self, marks):
        self.cells = {}
        for m in marks:
            self.add(m)

    def add(self, m):
        self.cells.setdefault((round(m["la"] * 200), round(m["lo"] * 200)), []).append(m)

    def nearest(self, lat, lon, radius_m, accept):
        c = math.cos(math.radians(lat))
        best, best_d = None, radius_m
        k = (round(lat * 200), round(lon * 200))
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for m in self.cells.get((k[0] + dy, k[1] + dx), []):
                    if not accept(m["t"]):
                        continue
                    d = math.hypot((m["la"] - lat) * 111320, (m["lo"] - lon) * 111320 * c)
                    if d < best_d:
                        best, best_d = m, d
        return best


def is_aid(t):
    return t.startswith(("light", "beacon", "buoy"))


def merge_seamarks(marks, enc_lights, enc_structures, enc_hazards):
    """ENC marks onto the pack's marks (in place). Returns (corrected, added)."""
    index = Index(marks)
    corrected = added = 0

    def add(m):
        nonlocal added
        m["src"] = "enc"
        marks.append(m)
        index.add(m)
        added += 1

    for e in enc_structures:
        family = e["t"].split("_", 1)[1]
        match = index.nearest(e["la"], e["lo"], 60, lambda t: t.startswith(("beacon", "buoy")) and t.endswith(family))
        if match:
            match["la"], match["lo"] = e["la"], e["lo"]
            if "c" in e:
                match["c"] = e["c"]
            if "col" in e:
                match["col"] = e["col"]
            corrected += 1
        else:
            add(e)
    for e in enc_lights:
        match = index.nearest(e["la"], e["lo"], 50, is_aid)
        if match:
            match["l"] = e["l"]
            if match["t"].startswith("light"):
                match["la"], match["lo"] = e["la"], e["lo"]
                if e["t"] == "light_major":
                    match["t"] = "light_major"
            if e.get("n") and not match.get("n"):
                match["n"] = e["n"]
            corrected += 1
        else:
            add(e)
    for e in enc_hazards:
        kinds = ("rock", "obstruction") if e["t"] in ("rock", "obstruction") else ("wreck", "obstruction")
        match = index.nearest(e["la"], e["lo"], 50, lambda t: t in kinds)
        if match:
            if match["t"] == e["t"]:
                match["la"], match["lo"] = e["la"], e["lo"]
                for k in ("wl", "d", "c"):
                    if k in e:
                        match[k] = e[k]
            corrected += 1
        else:
            add(e)
    return corrected, added


def enrich(meta, code):
    """Everything above for one pack. Returns (code, covered, enc_areas, enc_contours, sounding features,
    sector features, sector light positions, summary)."""
    bounds = (meta["west"], meta["south"], meta["east"], meta["north"])
    leaves = build_quadtree_leaves(*bounds)
    unique_paths = sorted({path for *_, path, _ in leaves})
    with ThreadPoolExecutor(max_workers=8) as pool:
        decoded = dict(zip(unique_paths, pool.map(decode_tile, unique_paths)))

    enc_areas, enc_contours = vector_bathymetry(leaves, bounds)
    new_code, covered, opened = clamp_depth_grid(leaves, decoded, meta, code)
    snd = [{"type": "Feature", "geometry": {"type": "Point", "coordinates": [r6(lon), r6(lat)]},
            "properties": {"depth": d}, "tippecanoe": {"minzoom": z}}
           for lon, lat, d, z in soundings(leaves, decoded, bounds)]
    enc_lights, sectors = lights(leaves, decoded, bounds)
    corrected, added = merge_seamarks(meta["seamarks"], enc_lights,
                                      structures(leaves, decoded, bounds),
                                      hazards(leaves, decoded, bounds))
    sector_lights = {(round(s["geometry"]["coordinates"][0][1], 3), round(s["geometry"]["coordinates"][0][0], 3))
                     for s in sectors if s["properties"]["part"] == "limit"}
    changed = int(((new_code != code) & covered).sum())
    summary = (f"ENC ({len(leaves)} quadtree tiles z10–z12): {len(enc_areas)} vector depth polygons, "
               f"{len(enc_contours)} contour sets; {covered.mean() * 100:.0f}% grid covered ({changed} cells clamped, "
               f"{opened} opened); {len(snd)} soundings, {len(sectors)} sector lines; "
               f"seamarks {corrected} corrected, {added} added")
    return new_code, covered, enc_areas, enc_contours, snd, sectors, sector_lights, summary
