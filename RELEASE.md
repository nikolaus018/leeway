# Release checklist

What only a person can do or verify. Code, tests, CI and the server deploy are done; everything here needs a
device, an account, a boat or a decision.

## 1. Test on a real iPhone (the simulator can't)

- [ ] **GPS and background tracking:** record a track with the screen off for 30+ minutes; check the logbook.
- [ ] **Alarms in the background:** anchor alarm, collision alarm, shallow-water alarm and man overboard ring
      with the app backgrounded and the phone locked; the notification arrives. Note: `.defaultCritical`
      sounds need Apple's Critical Alerts entitlement, or they play as ordinary notifications.
- [ ] **Boat arrow:** points along the course when moving and along the compass when still (the simulator has
      no heading).
- [ ] **Double-tap-and-drag zoom:** dragging up zooms in. This replaces MapLibre's own gesture and I could not
      drive it in the simulator. If it misbehaves, remove the `quickZoom` code in `ChartMapView.swift`.
- [ ] **Rotation lock, measure tool, TSS arrows, sounding density** at a few zoom levels, in day and night
      palettes.
- [ ] **Offline:** download the chart pack, switch to airplane mode, pan and zoom, route, search a harbour.
- [ ] **Rain radar:** the server now serves the NEXRAD colour scheme (green to red); check it is visible on the
      chart and that old frames are gone.
- [ ] **Crashes:** two MapLibre worker-thread aborts were logged in the simulator (same stack), at the moments
      the app was force-terminated from the command line while tiles were loading. They look like shutdown
      artifacts, not something a user can hit, but watch TestFlight crash reports for the same stack.
- [ ] **Accessibility:** a VoiceOver pass, Reduce Motion, the largest Dynamic Type size, landscape.

## 2. Test with a real boat

- [ ] **NMEA 0183 gateway:** depth, wind and heading; reconnect after switching the gateway off and on; AIS
      from your own receiver, including Class B "CS" targets (names were mis-decoded before the fix).
- [ ] **Compare charts with reality or official charts:** the depths, a few buoys and lights, the TSS, and the
      cardinal marks (north/south were swapped before the fix). Open data is not surveyed to ECDIS standard.
- [ ] **Passage planning:** run a few routes you know and check the fastest-route result is sensible.

## 3. Licences and legal (needs your decision)

- [ ] **Commercial terms** of every upstream, as the README already flags: OpenFreeMap, OpenSeaMap tiles,
      RainViewer, Photon (the public instance is not for heavy use), Open-Meteo (a commercial plan is needed to
      charge for the app), aisstream.io, MeteoAlarm.
- [ ] **HHI data:** the catalogue says "no restrictions, cite the source". Read
      https://www.hhi.hr/dokumenti/uvjeti-pristupa-i-koristenja yourself, and keep the attribution (it is in the
      app's data sources and the server's `/v1/info`).
- [ ] **OpenStreetMap (ODbL):** the chart pack is a derived database. Decide how you will meet the share-alike
      and attribution terms (publishing the pack data and build scripts is the usual way).
- [ ] **The "not for navigation" disclaimer:** have its wording checked for your jurisdiction.
- [ ] **Privacy policy** published at a URL (App Store requires one). It should say: position is sent to your
      data server (forecast, search, AIS, sea level), not linked to identity, not used for tracking.

## 4. Apple

- [ ] **Developer account and signing:** team `C5MSK2XBMK`, bundle id `com.nikolausmarek.leeway` (and the widget
      target), certificates, provisioning profiles.
- [ ] **Capabilities** on the App ID: Background Modes (location), Live Activities, push for Live Activities.
- [ ] **App Store Connect:** privacy nutrition label (precise location, app functionality, not linked, no
      tracking), age rating, category (Navigation), description, keywords, support URL, screenshots (iPhone
      6.9" and 6.5" sizes at least), App Review notes explaining the app is a planning aid and how to test
      without a boat.
- [ ] **Icon:** `AppIcon.png` must be 1024×1024 with no transparency.
- [ ] **TestFlight** with a few sailors before submitting.
- [ ] Export compliance is answered in `Info.plist` (`ITSAppUsesNonExemptEncryption` is false: HTTPS only).

## 5. Server operations (Venvy, `seadata.ringtwo.win`)

- [ ] **Keys:** set `AISSTREAM_API_KEY` (AIS is off without it); `OPEN_METEO_API_KEY` if you go commercial.
- [ ] **`REQUIRE_CLIENT_HEADER=1`** if you want the server limited to the app (it is a weak check, not security).
- [ ] **Monitoring and backups:** watch `/metrics` and `/health`; decide what to back up (the tile cache can be
      rebuilt; the chart packs live in the repo).
- [ ] **Disk:** the cache is capped by `CACHE_MAX_GB` (default 8 GB); check the host has room.
- [ ] **Cloudflare:** confirm caching rules respect the origin's `Cache-Control`, and that rate limits are
      sensible behind the tunnel (limits are per client IP from `CF-Connecting-IP`).
- [ ] Redeploy any time with `python3 server/deploy/ship.py` (after `python3 scripts/ship.py login` if the
      Venvy session has expired).

## 6. Known gaps you may accept for 1.0

- Chart symbols follow INT 1 / S-52 in spirit, not to the letter: no safety-depth shoal highlighting, simplified
  buoy shapes, no drying heights or tidal datum, custom (not S-52) palettes.
- Depth data is about 115 m resolution (EMODnet); there is no free higher-resolution source for Croatia. A
  licence from the Croatian Hydrographic Institute would be the only route to better.
- The app covers Croatia only: the map stays inside it, and the server gathers AIS, wind, warnings and search for
  Croatia only (`config::CROATIA`, `ChartMapView.coverage`).
