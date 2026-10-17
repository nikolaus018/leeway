# Leeway

A native iOS chartplotter and passage planner in the spirit of savvy navvy and Garmin plotters: SwiftUI, MapLibre,
iOS 26 (Liquid Glass). One nautical chart for the whole world, with detailed offline charts for the **eastern Adriatic**
(the Slovenian coast, Istria, Kvarner, Dalmatia, Dubrovnik and the Bay of Kotor, 13.2–19.0°E, 42.2–45.57°N).

## Features

**Chart**
- One style everywhere: a paper-chart look for land and water worldwide (OpenMapTiles base map plus worldwide depth
  bands and contours from the data server), and the sharp version inside chart packs, in the same colours.
- Depth areas, contours (1, 2, 3, 5, 10 … 100 m in packs), a bold **safety contour** at the boat's safety depth, and spot
  soundings thinned by zoom.
- INT 1-style seamarks: lateral, cardinal, isolated danger, safe water and special marks, rocks by water level, wrecks,
  obstructions, light flares with characteristics (`Fl(2)R.5s 12m 6M`) and **light sectors**; harbours, marinas and
  anchorages; restricted areas, traffic separation, cables, pipelines, fish farms, seabed. OpenSeaMap symbols outside packs.
- **Day, dusk and night** palettes, automatic by the sun; night turns the whole app dark. **Satellite** base
  (Sentinel-2) with shallows, contours and seamarks on top.
- **Tap anything**: the object, its light, zones, the depth (pack grid or depth band), position, bearing and distance from
  the boat, the next tide; then route there, mark it, or measure from it.
- North up, heading up and **course up**, a compass when rotated, a capped nautical-mile scale bar, lat/lon grid.

**Routing**
- **Shortest**: the shortest path through water at least the safety depth deep (draft + under-keel clearance), clear of
  charted rocks, wrecks and obstructions, isolated-danger and cardinal marks, and bridges lower than the air draft + 1 m.
  Harbours are left through connected water.
- **Fastest** (weather routing): isochrones in the forecast wind with the boat's polar, tacking and gybing where it pays,
  with exactly the same safety checks. The planner says how much time it saves.
- **Manual**: straight legs; legs crossing land or shallows are drawn red.
- Every route is timed with the finest forecast wind per hour (ItaliaMeteo ICON-2I 2.2 km, then ICON-EU, then global),
  waves and tidal streams; a best-departure chart covers the next 3 days. Bura gusts are flagged.
- **Polars**: presets by boat type or import your own (tab/semicolon text, as designers and ORC certificates give them).
- GPX import and export of routes, tracks and waypoints.

**Underway**
- Navigation bar: next waypoint, bearing, distance, ETA, cross-track error; VMG and finish ETA; Live Activity.
- **Man overboard**, **anchor watch** with drag alarm, **collision alarm** from AIS (CPA/TCPA limits in settings), shallow
  water and off-track alarms; alarms sound with the phone on silent and notify in the background.
- AIS ships with 6-minute course vectors, a ship list sorted by closest approach, and the boat's own AIS receiver.
- **Boat instruments** over Wi-Fi: NMEA 0183 (TCP or UDP) depth, wind, heading and AIS from the boat's gateway.
- **Logbook**: recorded tracks with distance, time, average and top speed; show on the chart or export as GPX.
- Marks with symbols and notes; **range and bearing** tool.

**Weather and more**
- Wind now and the next 24 h, wind arrows over the chart with a time bar, **rain radar**, official **MeteoAlarm warnings**
  with their areas on the chart, **tide** curve with highs and lows, sun and twilight times.
- **Search** harbours, marinas, anchorages, bays, islands and towns (offline from the packs, online via the server).
- **Offline map**: saves the base map, depth and fonts around each chart pack, so the whole chart works without signal.

## Architecture

```
Leeway app (SwiftUI + MapLibre Native)            seadata server (Rust/axum, Venvy)
 ChartStyle → MapLibre style JSON                  /v1/tiles/base, /v1/fonts      OpenFreeMap vector tiles + glyphs
  ├ base       vector  ─────────────────────────── /v1/tiles/bathy                worldwide depth (AWS Terrain → MVT)
  ├ bathy      vector  ───────────────────────────
  ├ chart-<id> pmtiles://  (pack on the phone)
  ├ satellite / openseamap / radar  raster  ────── /v1/tiles/satellite, seamark, radar
  └ live-*     GeoJSON (route, track, AIS, wind,   /v1/forecast, /v1/wind-grid    Open-Meteo, merged and cached
               underway, warnings, marks, measure) /v1/sealevel, /v1/warnings, /v1/search, /v1/ais, /v1/charts
```

Chart packs keep a `.depth` grid (routing, depth under the boat) next to the `.pmtiles` vector chart (drawing).

## Data server

Everything external comes through `server/` ("seadata"). Every user shares one cache: concurrent requests for the same
data make one upstream call, forecasts persist on disk and are served while a fresh copy is fetched, tiles live in a
size-capped disk cache and are served stale when a source is down, and responses carry ETags and Cache-Control for the
app and Cloudflare. Per-client rate limits protect the shared upstream quotas.

| Endpoint | What |
| --- | --- |
| `GET /v1/forecast?points=lat,lon;…` | Hourly wind (finest model per hour), gusts, waves, swell, currents, sea/air temperature, pressure, rain |
| `GET /v1/wind-grid?west&south&east&north` | Wind and waves on a grid (map arrows, weather routing); the sailing area is kept warm |
| `GET /v1/sealevel?lat&lon` | Sea level (tide + surge), hourly |
| `GET /v1/warnings?west&south&east&north` | MeteoAlarm warnings with their area outlines |
| `GET /v1/search?q&lat&lon` | Harbours, marinas, anchorages and names from the packs, then Photon |
| `GET /v1/radar`, `/v1/tiles/radar/{t}/{z}/{x}/{y}.png` | Rain radar frames (RainViewer) |
| `GET /v1/tiles/base.json`, `/v1/tiles/base/{z}/{x}/{y}.pbf`, `/v1/fonts/…` | Worldwide vector base map and label fonts |
| `GET /v1/tiles/bathy/{z}/{x}/{y}.pbf` | Worldwide depth areas (`depare`) and contours (`depcnt`) |
| `GET /v1/tiles/satellite/{z}/{x}/{y}.jpg` | Sentinel-2 cloudless 2016 |
| `GET /v1/tiles/seamark/{z}/{x}/{y}.png?skip=…` | OpenSeaMap seamarks, transparent inside the given pack boxes |
| `GET /v1/charts`, `/v1/charts/files/{name}?v=…` | Offline chart packs |
| `GET /v1/ais?west&south&east&north` | Live vessels (needs `AISSTREAM_API_KEY`) |
| `GET /v1/info`, `/health`, `/metrics` | Capabilities, liveness, Prometheus counters (cache hits, upstream calls) |

```bash
cd server
cargo test && cargo clippy --all-targets -- -D warnings
cargo run          # http://localhost:8790, serves the charts in Leeway/Charts
```

Settings are environment variables: `PORT`, `CHARTS_DIR`, `CACHE_DIR`, `CACHE_MAX_GB` (default 8), `PUBLIC_URL`,
`AISSTREAM_API_KEY`, `AIS_BBOX` (south,west,north,east), `OPEN_METEO_API_KEY` (commercial plan; the free API is
non-commercial), `REQUIRE_CLIENT_HEADER=1`, `LOG_FORMAT=json`, and the upstream URLs (`TERRAIN_URL`, `SATELLITE_URL`, …).
It builds with Rust 1.85 (the Venvy host); `.cargo/config.toml` keeps the lockfile resolvable there.

**Deploy** to Venvy (published at `https://seadata.ringtwo.win` through the Cloudflare tunnel):

```bash
python3 server/deploy/ship.py login   # once; keeps a 30-day session in ~/.config/venvy/
python3 server/deploy/ship.py
```

It uploads the code, styles and chart packs, removes files deleted locally, configures the port and environment, restarts,
publishes the hostname and waits until the new process answers.

## Build and test

```bash
brew install xcodegen   # once
xcodegen generate
open Leeway.xcodeproj
xcodebuild test -project Leeway.xcodeproj -scheme Leeway -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Debug builds use `-O` because routing processes millions of grid cells. CI builds and tests the app and the server on
every push and pull request. Simulator launch arguments (Debug only): `-debugRoute "45.32,14.44;44.53,14.47"`,
`-debugMode manual` (or `weather`), `-debugCenter "45.0,14.45,0.5"`.

## Chart packs

`tools/build_region.py` builds an offline region from **EMODnet Bathymetry** (~115 m, CC BY 4.0) and
**OpenStreetMap** coastline and seamarks (ODbL), then `tools/build_vector.py` turns it into the vector chart with
tippecanoe (layers: `land`, `depare`, `depcnt`, `soundg`, `seamark`, `lightsector`, `area`, `names`, `bridge`).

```bash
brew install tippecanoe
python3 -m venv .venv && .venv/bin/pip install numpy scipy shapely pillow tifffile osmium contourpy
# OSM country extracts from download.geofabrik.de, e.g. into tools/.osm-cache/
.venv/bin/python tools/build_region.py adriatic "Eastern Adriatic" 13.2 42.2 19.0 45.57 \
    --osm croatia.osm.pbf,slovenia.osm.pbf,bosnia-herzegovina.osm.pbf,montenegro.osm.pbf
# Only the vector chart, from an existing pack:
.venv/bin/python tools/build_vector.py adriatic --osm croatia.osm.pbf,…
```

## Code map

| Area | File |
| --- | --- |
| Chart style (colours, layers, palettes) | `Leeway/Map/ChartStyle.swift` |
| Map view, live layers, taps | `Leeway/Map/ChartMapView.swift` |
| Seamark and marker icons | `Leeway/Map/SeamarkSymbols.swift` |
| Chart packs, depth lookup | `Leeway/Model/ChartRegion.swift`, `Leeway/Services/ChartStore.swift` |
| Shortest route (A*), hazard checks | `Leeway/Model/Router.swift` |
| Fastest route (isochrones), wind field | `Leeway/Model/WeatherRouter.swift` |
| Polars | `Leeway/Model/Polar.swift`, `PolarTable.swift` |
| Passage timing, departures | `Leeway/Model/PassageSimulator.swift` |
| Sun and twilight | `Leeway/Model/Sun.swift` |
| Data server client | `Leeway/Services/Seadata.swift`, `MarineWeatherService.swift` |
| Navigation, MOB, anchor watch, alarms | `Leeway/Services/Underway.swift`, `LiveActivityController.swift` |
| Boat instruments (NMEA 0183, AIS) | `Leeway/Services/NMEA.swift` |
| GPX, logbook, offline map | `Leeway/Services/GPX.swift`, `LocationTracker.swift`, `OfflineMaps.swift` |
| App state | `Leeway/AppModel.swift` |
| UI | `Leeway/Views/*` (map chrome, sheets, cards) |
| Data server | `server/src/*` |
| Tests | `LeewayTests/*`, `server/src/tests.rs` |

## Known limits

- **Not for navigation.** The depth data is a ~115 m survey grid. It doesn't show isolated rocks, shoals or wrecks smaller
  than that, and narrow passages (such as the Osor canal) are closed. The router avoids only the rocks and wrecks mapped in
  OSM. Outside packs, worldwide depth is coarse and automatic routing isn't available.
- Fastest routing uses the server's wind grid (0.1–0.5°) and ignores currents; passage timing then uses the full forecast.
- AIS comes from aisstream.io's volunteer receivers (gaps, positions up to a minute old) or the boat's own receiver.
- MeteoAlarm areas are matched by outline; a few countries' feeds cover land regions only.
- For a commercial release, the terms of OpenFreeMap, OpenSeaMap tiles, RainViewer, Photon and Open-Meteo (commercial plan)
  need checking; official ENC data would need licensing.

## Next steps

More chart packs (Ionian, Tyrrhenian), currents in weather routing, a tide station database, AIS target trails, Apple Watch
companion, CarPlay.
