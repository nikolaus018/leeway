# Leeway

A native iOS passage planner in the spirit of savvy navvy: SwiftUI + MapKit, iOS 26 (Liquid Glass).
The bundled offline chart covers **Kvarner and Istria** (Rijeka, Opatija, Cres, Lošinj, Krk, Rab, Pula, Rovinj).

## Features

**Chart**
- Paper-chart look in the chart area: buff land drawn from the OSM coastline, depth bands shaded darker in shallow water,
  depth contours (2/5/10/20/50/100 m), a bold **safety contour** at your boat's safety depth, and spot soundings when zoomed in.
  There is a night palette for dark mode.
- OpenSeaMap seamark symbols on top (lights, buoys, beacons, traffic separation, ferry lanes, harbours).
- Harbour, marina and anchorage markers when zoomed in.
- **Tap anything** to see what it is (name, type, light characteristic such as `Fl(2)R.5s 12m 6M`, colours), the depth there,
  and its position in degrees and minutes. "Route here" plans a route from your GPS position.
- Nautical-mile scale bar and an optional lat/lon grid with edge labels.
- Base map: Chart, Standard or Satellite. Overlays can be toggled from the layers button.

**Routing**
- **Automatic** (default): the shortest path through water at least your *safety depth* (draft + under-keel clearance),
  kept off rocks and shores, then straightened into a few courses to steer. Marinas and harbours behind breakwaters are left
  through connected water, for example out of Rijeka port via its western entrance. If an end point sits in water shallower
  than the safety depth, the app says so.
- Keeps about 60 m clear of charted **rocks, wrecks and obstructions** (unless they're charted deeper than the safety depth
  plus 1 m), isolated-danger marks, and the danger side of cardinal marks.
- **Bridges**: blocked when their charted clearance is less than your **air draft** + 1 m. If the clearance isn't charted
  (OSM has none in Kvarner yet, including the Krk bridge), the route still passes and you get a "check your air draft" note.
  Opening bridges such as Osor's get a "check opening times" note. Clearances from an official chart can be added in
  `CLEARANCE_OVERRIDES` in `tools/build_region.py`.
- **Manual**: straight legs between your own waypoints. Legs that cross land or shallows are drawn red and dashed, and
  flagged in the leg list.
- Wind comes from the finest model available for each hour: ItaliaMeteo **ICON-2I** (2.2 km, ~72 h, built for the
  Adriatic), then DWD ICON-D2 (2.2 km), ICON-EU (7 km), then the global models. The planner shows which one is in use.
  Winds get their Adriatic names (bura, jugo, maestral…). **Bura** gusts of 25 kn or more are flagged per leg, and the max-gusts
  comfort limit counts toward the departure rating.
- Either mode is timed with forecast wind (Open-Meteo), tidal streams and waves (Open-Meteo marine), and a sailing
  performance curve. A best-departure chart covers the next 3 days.

**Underway**: SOG/COG readout, GPS track recording (also in the background), and saved routes.

## Build

```bash
brew install xcodegen   # once
xcodegen generate
open Leeway.xcodeproj
```

Debug builds are compiled with `-O` because routing and tile rendering process millions of grid cells.

Simulator testing (Debug only): launch arguments preload a route and a map position.

```bash
xcrun simctl launch booted com.nikolausmarek.leeway -debugRoute "45.3245,14.4385;44.5335,14.4660" -debugCenter "45.0,14.45,0.5"
```

Add `-debugMode manual` for a straight-leg route.

## Chart packs

`tools/build_region.py` builds an offline region from:
- **EMODnet Bathymetry** (~115 m depth grid, CC BY 4.0),
- **OpenStreetMap** coastline and seamarks via Overpass (ODbL).

It writes `Leeway/Charts/<id>.depth` (a 67 m UInt8 depth/land grid), `<id>.land` (vector coastline) and `<id>.json`
(metadata and seamarks). The app loads every pack in that folder.

```bash
python3 -m venv .venv && .venv/bin/pip install numpy scipy shapely pillow tifffile
.venv/bin/python tools/build_region.py kvarner "Kvarner & Istria" 13.45 44.30 15.10 45.60
```

Near the coast, the script never reports more depth than a steep shelf would allow (`SHORE_SLOPE`), because the survey
data is coarser than the grid there.

## Code map

| Area | File |
| --- | --- |
| Chart pack loading, depth lookup | `Leeway/Model/ChartRegion.swift` |
| Safe-water grid, A* routing, leg hazard checks | `Leeway/Model/Router.swift` |
| Chart tile rendering, lat/lon grid | `Leeway/Map/DepthTileOverlay.swift` |
| Map wrapper, overlays, taps | `Leeway/Map/ChartMapView.swift`, `Annotations.swift` |
| Passage timing, departure ranking | `Leeway/Model/PassageSimulator.swift`, `Polar.swift` |
| Forecasts | `Leeway/Services/MarineWeatherService.swift` |
| App state | `Leeway/AppModel.swift` |
| UI | `Leeway/Views/*` |

## Known limits

- **Not for navigation.** The depth data is a ~115 m survey grid. It doesn't show isolated rocks, shoals or wrecks smaller
  than that, and narrow passages (such as the Osor canal) are closed. The router avoids only the rocks and wrecks mapped in OSM.
- Only the bundled region has depths and automatic routing. Elsewhere you get the base map, OpenSeaMap symbols and manual routes.
- Routing picks the shortest safe path. It doesn't yet optimise for wind or tide the way savvy navvy does.
- The Open-Meteo current data (~8 km) misses small-scale tidal effects close inshore. Tides are small in the Adriatic anyway.
- For release, OpenSeaMap tiles and Open-Meteo need their usage and commercial terms checked. Official ENC data (for example
  from the Croatian Hydrographic Institute) would need licensing.

## Next steps

Avoid charted rocks and wrecks when routing; add weather-optimised (isochrone) routing; download chart packs in the app;
show light sectors, restricted areas and nature of seabed; import GPX files and real polars; AIS; anchor alarm.
