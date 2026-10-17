import CoreLocation
import Observation
import UIKit

@Observable
final class AppModel {
    enum ForecastState: Equatable { case idle, loading, loaded, failed(String) }

    enum RoutingState: Equatable {
        case idle
        case routing
        /// Automatic route found; indices of waypoints reached only through water shallower than the safety depth.
        case routed(shallowEnds: [Int])
        case manual
        case failed(String)
    }

    /// Something the user tapped on the chart.
    struct Inspection: Equatable {
        var coordinate: CLLocationCoordinate2D
        var seamark: Seamark?
        var sounding: ChartRegion.Sounding?
        /// Depth band from the vector chart where no pack grid covers the spot.
        var depthBand: ClosedRange<Double>?
        var zones: [ChartHit.Zone] = []
        var vessel: Vessel?
        var mark: UserMark?

        static func == (a: Inspection, b: Inspection) -> Bool {
            a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
                && a.seamark == b.seamark && a.vessel == b.vessel && a.mark == b.mark && a.zones == b.zones
        }
    }

    /// What the map is currently showing, for the scale bar, grid labels and compass.
    struct MapCamera: Equatable {
        struct Label: Equatable, Identifiable {
            var id: String { text }
            var position: Double
            var text: String
        }
        var metresPerPoint = 0.0
        /// Degrees true at the top of the screen.
        var heading = 0.0
        var center = CLLocationCoordinate2D(latitude: 45.2, longitude: 14.42)
        var zoom = 9.0
        var longitudeLabels: [Label] = []
        var latitudeLabels: [Label] = []

        static func == (a: MapCamera, b: MapCamera) -> Bool {
            a.metresPerPoint == b.metresPerPoint && a.heading == b.heading && a.zoom == b.zoom
                && a.center.latitude == b.center.latitude && a.center.longitude == b.center.longitude
                && a.longitudeLabels == b.longitudeLabels && a.latitudeLabels == b.latitudeLabels
        }
    }

    /// A request to centre the map somewhere (a search result, a mark).
    struct Focus: Equatable {
        var id: Int
        var coordinate: CLLocationCoordinate2D
        var zoom: Double

        static func == (a: Focus, b: Focus) -> Bool { a.id == b.id }
    }

    // MARK: Persisted

    var boat: BoatProfile {
        didSet {
            save(boat, as: "boat")
            if boat.safetyDepth != oldValue.safetyDepth || boat.airDraft != oldValue.airDraft { routeChanged() } else { recompute() }
        }
    }
    var savedRoutes: [Route] { didSet { save(savedRoutes, as: "routes") } }
    var mapBase: MapBase { didSet { save(mapBase, as: "mapBase") } }
    var showSeamarks: Bool { didSet { save(showSeamarks, as: "seamarks") } }
    var showSoundings: Bool { didSet { save(showSoundings, as: "soundings") } }
    var showGrid: Bool { didSet { save(showGrid, as: "grid") } }
    var paletteMode: PaletteMode { didSet { save(paletteMode, as: "palette"); updatePalette() } }
    var marks: [UserMark] { didSet { save(marks, as: "marks") } }
    /// Finished passages, newest first; kept in a file (they can be large).
    var logbook: [TrackLog] { didSet { Self.saveLogbook(logbook) } }
    /// A logbook track shown on the chart instead of the live one.
    var shownTrack: TrackLog?
    var showWind: Bool { didSet { save(showWind, as: "wind"); refreshWind() } }
    var showAIS: Bool { didSet { save(showAIS, as: "ais"); restartAIS() } }
    var alarms: AlarmSettings {
        didSet {
            save(alarms, as: "alarms")
            underway.offCourseLimit = alarms.crossTrack
        }
    }

    // MARK: Alarms

    /// When each ship last raised the collision alarm.
    private var collisionAlarmed: [Int: Date] = [:]
    private var lastShallowAlarm = Date.distantPast

    /// Sounds the alarm for a ship newly on a close course (again after ten minutes).
    private func checkCollisions() {
        guard alarms.aisAlarm, location.location != nil, showAIS || !nmea.vessels.isEmpty else { return }
        for vessel in vessels where isDangerous(vessel) {
            if let last = collisionAlarmed[vessel.mmsi], Date.now.timeIntervalSince(last) < 600 { continue }
            collisionAlarmed[vessel.mmsi] = .now
            let approach = approach(to: vessel)
            let text = approach.map { String(format: "%.2f NM in %d min", $0.distance, Int(($0.time * 60).rounded())) } ?? ""
            underway.alarm.sound(.collision, message: "\(vessel.displayName) will pass \(text).")
            if inspection == nil { inspection = Inspection(coordinate: vessel.coordinate, vessel: vessel) }
        }
    }

    /// Shallow water under way: the sounder (over NMEA) or else the chart, against the draft.
    private func checkDepth(_ fix: CLLocation) {
        guard alarms.shallowAlarm, (location.sog ?? 0) > 1.5, Date.now.timeIntervalSince(lastShallowAlarm) > 120 else { return }
        let depth: Double? = nmea.depth ?? {
            if case .depth(let d)? = region(containing: [fix.coordinate])?.sounding(at: fix.coordinate) { return d }
            return nil
        }()
        guard let depth, depth < boat.draft + 0.5 else { return }
        lastShallowAlarm = .now
        underway.alarm.sound(.shallow, message: String(format: "Shallow water: %.1f m.", depth))
    }
    /// The data server everything external comes through.
    var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: Seadata.defaultsKey)
            serverChanged()
        }
    }

    // MARK: Session

    /// The open route; kept across launches.
    var route = Route() { didSet { save(route, as: "currentRoute") } }
    var isEditing = false
    var departure = Date.now {
        didSet {
            // The fastest route depends on when you leave.
            if route.mode == .weather { routeChanged() } else { recompute(options: false) }
        }
    }
    /// Fastest route: time saved against the shortest one, and how many tacks or gybes it takes.
    private(set) var weatherRouting: (saved: TimeInterval, tacks: Int)?
    /// The track actually planned: the automatic route, or straight legs in manual mode.
    private(set) var path: [CLLocationCoordinate2D] = []
    /// Manual mode: a warning per leg if it crosses land or shallows.
    private(set) var legHazards: [String?] = []
    /// Things to know about the planned path, such as bridges with uncharted clearance.
    private(set) var routeNotes: [String] = []
    private(set) var routingState = RoutingState.idle
    private(set) var forecast: RouteForecast?
    private(set) var forecastState = ForecastState.idle
    private(set) var plan: PassagePlan?
    private(set) var departureOptions: [DepartureOption] = []
    var inspection: Inspection?
    var camera = MapCamera() { didSet { if Int(camera.center.latitude * 10) != Int(oldValue.center.latitude * 10) { updatePalette() } } }
    private(set) var focus: Focus?
    /// The chart's colours now: the setting, or the light at the map's centre.
    private(set) var palette = ChartPalette.day
    /// Range and bearing tool: on, and the points tapped so far.
    var isMeasuring = false { didSet { if !isMeasuring { measurePoints = [] } } }
    private(set) var measurePoints: [CLLocationCoordinate2D] = []
    /// Forecast at the boat's position (or Rijeka before the first GPS fix).
    private(set) var localForecast: RouteForecast?
    private var localForecastFetched: (coordinate: CLLocationCoordinate2D, at: Date)?

    /// Offline charts; loaded in the background at launch (the Adriatic grid is ~40 MB).
    private(set) var regions: [ChartRegion] = []
    private var chartsLoaded = false
    let charts = ChartStore()
    let location = LocationTracker()
    let underway = Underway()
    /// Bumped to ask the map to frame the route.
    private(set) var fitRouteRequest = 0
    /// Bumped to turn the map north up.
    private(set) var northRequest = 0
    /// Bumped to show the route sheet (after "Route here", or opening a saved route from elsewhere).
    private(set) var routeOpenedRequest = 0
    var tracking = UserTracking.none
    /// Instruments and AIS from the boat's own network (NMEA 0183 over Wi-Fi).
    let nmea = NMEAClient()
    /// Base map and depth saved for chart areas, for use without signal.
    let offline = OfflineMaps()

    /// North up, follow the boat north up, heading up (compass), course up (GPS track).
    enum UserTracking { case none, follow, heading, course }

    private let weather = MarineWeatherService()
    private var forecastTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var grids: [String: RoutingGrid] = [:]
    /// Frame the route on the map once its path is known.
    private var fitPending = false

    init() {
        boat = Self.load("boat") ?? BoatProfile()
        savedRoutes = Self.load("routes") ?? []
        mapBase = Self.load("mapBase") ?? .chart
        showSeamarks = Self.load("seamarks") ?? true
        showSoundings = Self.load("soundings") ?? true
        showGrid = Self.load("grid") ?? false
        paletteMode = Self.load("palette") ?? .auto
        marks = Self.load("marks") ?? []
        logbook = Self.loadLogbook()
        route = Self.load("currentRoute") ?? Route()
        showWind = Self.load("wind") ?? false
        showAIS = Self.load("ais") ?? false
        showRadar = Self.load("radar") ?? false
        alarms = Self.load("alarms") ?? AlarmSettings()
        serverURL = UserDefaults.standard.string(forKey: Seadata.defaultsKey) ?? Seadata.defaultURL
        reloadCharts()
        location.onUpdate = { [weak self] fix in
            self?.underway.update(with: fix)
            self?.checkDepth(fix)
        }
        location.onTrackFinished = { [weak self] track in self?.logbook.insert(track, at: 0) }
        charts.onChange = { [weak self] in self?.reloadCharts() }
        underway.boatName = boat.name
        syncUnderway()
        updatePalette()
        underway.offCourseLimit = alarms.crossTrack
        // The automatic palette follows the sun.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.updatePalette()
            }
        }
        // Collision watch: ships that will pass close, every few seconds.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.checkCollisions()
            }
        }
        // Picking up where we left off (navigating, at anchor, MOB): show the boat.
        if underway.needsBackground { tracking = .follow }
        #if DEBUG
        loadDebugRoute()
        #endif
    }

    /// A `-name value` launch argument, read raw (the defaults system can't parse "45.0,14.4,0.5").
    static func debugArgument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-\(name)"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    #if DEBUG
    /// `-debugRoute "lat,lon;lat,lon;…"` as a launch argument opens that route (for simulator testing).
    private func loadDebugRoute() {
        guard let spec = Self.debugArgument("debugRoute") else { return }
        var debug = Route()
        debug.name = "Debug route"
        debug.waypoints = spec.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return parts.count == 2 ? Waypoint(CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])) : nil
        }
        if let mode = Self.debugArgument("debugMode").flatMap(RoutingMode.init(rawValue:)) { debug.mode = mode }
        open(debug)
    }
    #endif

    // MARK: Route editing

    var routingMode: RoutingMode {
        get { route.mode }
        set { route.mode = newValue; routeChanged() }
    }

    func startNewRoute() {
        route = Route()
        isEditing = true
        inspection = nil
        routeChanged()
    }

    func addWaypoint(at coordinate: CLLocationCoordinate2D) {
        if !isEditing && route.waypoints.isEmpty { route = Route() }
        isEditing = true
        inspection = nil
        route.waypoints.append(Waypoint(coordinate))
        routeChanged()
    }

    /// Plans a route from the boat's position to a point on the chart.
    func routeHere(_ coordinate: CLLocationCoordinate2D) {
        inspection = nil
        guard let here = location.location?.coordinate else {
            addWaypoint(at: coordinate)
            return
        }
        route = Route()
        route.name = "To \(inspectionTitle(for: coordinate))"
        route.waypoints = [Waypoint(here), Waypoint(coordinate)]
        isEditing = false
        departure = .now
        fitPending = true
        routeChanged()
        routeOpenedRequest += 1
    }

    func moveWaypoint(_ id: Waypoint.ID, to coordinate: CLLocationCoordinate2D) {
        guard let i = route.waypoints.firstIndex(where: { $0.id == id }) else { return }
        route.waypoints[i].coordinate = coordinate
        routeChanged()
    }

    func removeWaypoint(_ id: Waypoint.ID) {
        route.waypoints.removeAll { $0.id == id }
        routeChanged()
    }

    func undoLastWaypoint() {
        guard !route.waypoints.isEmpty else { return }
        route.waypoints.removeLast()
        routeChanged()
    }

    func reverseRoute() {
        route.waypoints.reverse()
        routeChanged()
    }

    func closeRoute() {
        route = Route()
        isEditing = false
        routeChanged()
    }

    func finishEditing() {
        isEditing = false
        if route.waypoints.count >= 2 { fitPending = true; planChanged() }
    }

    func northUp() {
        if tracking == .heading || tracking == .course { tracking = .follow }
        northRequest += 1
    }

    func saveRoute() {
        route.updatedAt = .now
        if let i = savedRoutes.firstIndex(where: { $0.id == route.id }) {
            savedRoutes[i] = route
        } else {
            savedRoutes.insert(route, at: 0)
        }
    }

    func open(_ saved: Route) {
        route = saved
        isEditing = false
        departure = .now
        fitPending = true
        routeChanged()
    }

    func deleteRoutes(at offsets: IndexSet) {
        savedRoutes.remove(atOffsets: offsets)
    }

    var isRouteSaved: Bool { savedRoutes.contains { $0 == route } }

    // MARK: Underway

    func startNavigation() {
        guard path.count >= 2 else { return }
        isEditing = false
        inspection = nil
        underway.startNavigation(along: path, from: location.location)
        location.startRecordingIfNeeded()
        tracking = .follow
        syncUnderway()
    }

    func stopNavigation() {
        underway.stopNavigation()
        syncUnderway()
    }

    func manOverboard() {
        underway.manOverboard()
        tracking = .follow
        syncUnderway()
    }

    func cancelMOB() {
        underway.cancelMOB()
        syncUnderway()
    }

    func dropAnchor(radius: Double) {
        underway.dropAnchor(radius: radius)
        syncUnderway()
    }

    func liftAnchor() {
        underway.liftAnchor()
        syncUnderway()
    }

    /// Background location and an always-on screen while navigating, at anchor or after a MOB.
    private func syncUnderway() {
        location.keepAlive = underway.needsBackground
        UIApplication.shared.isIdleTimerDisabled = underway.isNavigating || underway.mob != nil
    }

    // MARK: Chart

    /// Loads the offline charts (bundled and downloaded) in the background, then re-plans.
    func reloadCharts() {
        Task {
            regions = await Task.detached(priority: .userInitiated) { ChartRegion.all() }.value
            chartsLoaded = true
            grids = [:]
            routeChanged()
        }
    }

    func region(containing points: [CLLocationCoordinate2D]) -> ChartRegion? {
        regions.first { region in points.allSatisfy(region.contains) }
    }

    /// Shows what was tapped: a ship, a mark, a charted object, zones, and the depth there.
    func inspect(_ hit: ChartHit) {
        if let mmsi = hit.mmsi, let vessel = vessels.first(where: { $0.mmsi == mmsi }) {
            inspection = Inspection(coordinate: vessel.coordinate, vessel: vessel)
            return
        }
        if let id = hit.markID, let mark = marks.first(where: { $0.id == id }) {
            inspection = Inspection(coordinate: mark.coordinate, mark: mark)
            return
        }
        let point = hit.seamark?.coordinate ?? hit.coordinate
        inspection = Inspection(coordinate: point, seamark: hit.seamark,
                                sounding: region(containing: [point])?.sounding(at: point),
                                depthBand: hit.depthBand, zones: hit.zones)
    }

    // MARK: Map tools

    func centre(on coordinate: CLLocationCoordinate2D, zoom: Double = 13) {
        focus = Focus(id: (focus?.id ?? 0) + 1, coordinate: coordinate, zoom: zoom)
    }

    func addMeasurePoint(_ coordinate: CLLocationCoordinate2D) {
        // A third tap starts a new measurement.
        measurePoints = measurePoints.count >= 2 ? [coordinate] : measurePoints + [coordinate]
    }

    /// From the boat: the first point is the boat's position.
    func measureFromBoat() {
        isMeasuring = true
        measurePoints = location.location.map { [$0.coordinate] } ?? []
    }

    func addMark(at coordinate: CLLocationCoordinate2D, name: String? = nil, symbol: String = "mappin") {
        let mark = UserMark(name: name ?? "Mark \(marks.count + 1)", symbol: symbol, coordinate: coordinate)
        marks.append(mark)
        inspection = Inspection(coordinate: coordinate, mark: mark)
    }

    func markHere() {
        guard let here = location.location?.coordinate else { return }
        addMark(at: here, name: "Mark \(Date.now.formatted(date: .omitted, time: .shortened))", symbol: "flag.fill")
    }

    func updateMark(_ mark: UserMark) {
        guard let i = marks.firstIndex(where: { $0.id == mark.id }) else { return }
        marks[i] = mark
        if inspection?.mark?.id == mark.id { inspection?.mark = mark }
    }

    func deleteMark(_ mark: UserMark) {
        marks.removeAll { $0.id == mark.id }
        if inspection?.mark?.id == mark.id { inspection = nil }
    }

    private func updatePalette() {
        let resolved: ChartPalette = switch paletteMode {
        case .auto: Sun.palette(at: location.location?.coordinate ?? camera.center)
        case .day: .day
        case .dusk: .dusk
        case .night: .night
        }
        if resolved != palette { palette = resolved }
    }

    /// The chart as drawn now.
    var chartStyle: ChartStyle {
        let server = (Seadata(serverURL) ?? Seadata.current).base
        let packs = regions.compactMap { r in
            r.vectorFile.map { ChartStyle.Pack(id: r.id, file: $0, west: r.west, south: r.south, east: r.east, north: r.north) }
        }
        return ChartStyle(palette: palette, base: mapBase, server: server, packs: packs, safetyDepth: boat.safetyDepth,
                          showSeamarks: showSeamarks, showSoundings: showSoundings)
    }

    /// Close and soon, while either boat is moving: drawn red and alarmed.
    func isDangerous(_ vessel: Vessel) -> Bool {
        let moving = (location.sog ?? 0) >= 0.5
        guard moving || vessel.isUnderway, let approach = approach(to: vessel) else { return false }
        return approach.distance < alarms.cpaDistance && approach.time < alarms.cpaMinutes / 60
    }

    /// Where a ship will pass us, from both boats' course and speed (the ship dead-reckoned from its last report).
    func approach(to vessel: Vessel) -> Approach? {
        guard let fix = location.location, let sog = vessel.sog, let cog = vessel.cog ?? vessel.heading else { return nil }
        let age = max(0, Date.now.timeIntervalSince(vessel.lastHeard))
        let now = Geo.destination(from: vessel.coordinate, bearing: cog, distanceNM: sog * age / 3600)
        return Approach.between(own: fix.coordinate, ownSOG: location.sog ?? 0, ownCOG: location.cog ?? 0,
                                target: now, targetSOG: sog, targetCOG: cog)
    }

    private func inspectionTitle(for coordinate: CLLocationCoordinate2D) -> String {
        if let mark = inspection?.seamark, let name = mark.name { return name }
        if let vessel = inspection?.vessel { return vessel.displayName }
        return coordinate.formatted
    }

    // MARK: Routing

    private func routeChanged() {
        routeTask?.cancel()
        let points = route.coordinates
        let region = region(containing: points)

        guard route.mode != .manual, points.count >= 2 else {
            useStraightLegs(points, in: region)
            routingState = points.count >= 2 ? .manual : .idle
            planChanged()
            return
        }
        guard chartsLoaded else {
            // Charts still loading: plan once they're in.
            useStraightLegs(points, in: nil)
            routingState = .routing
            return
        }
        guard let region else {
            useStraightLegs(points, in: nil)
            routingState = .failed(Router.Failure.outsideChart.localizedDescription)
            planChanged()
            return
        }

        routingState = .routing
        if path.count < 2 { useStraightLegs(points, in: region) }
        let safetyDepth = boat.safetyDepth, airDraft = boat.airDraft
        let mode = route.mode, boat = boat, departure = departure
        routeTask = Task {
            try? await Task.sleep(for: .milliseconds(mode == .weather ? 400 : 120)) // coalesce drags
            guard !Task.isCancelled else { return }
            let grid = await routingGrid(for: region, safetyDepth: safetyDepth, airDraft: airDraft, around: points)
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Router.route(through: points, on: grid) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let routed):
                var final = routed.path
                weatherRouting = nil
                if mode == .weather, let fastest = await fastestRoute(points: points, shortest: routed.path, grid: grid,
                                                                       boat: boat, departure: departure) {
                    guard !Task.isCancelled else { return }
                    final = fastest.path
                    weatherRouting = (fastest.saved, fastest.tacks)
                }
                path = final
                legHazards = []
                routeNotes = Router.notes(for: final, rules: grid.rules)
                routingState = .routed(shallowEnds: routed.shallowConnections)
            case .failure(let error):
                useStraightLegs(points, in: region)
                routingState = .failed(error.localizedDescription)
            }
            planChanged()
        }
    }

    /// The fastest route under sail: isochrones between the safe-water ends of each leg of the
    /// shortest route (which still brings the boat out of and into harbour), in the forecast wind.
    private func fastestRoute(points: [CLLocationCoordinate2D], shortest: [CLLocationCoordinate2D], grid: RoutingGrid,
                              boat: BoatProfile, departure: Date) async -> (path: [CLLocationCoordinate2D], saved: TimeInterval, tacks: Int)? {
        guard boat.propulsion == .sail else { return nil }
        let lats = shortest.map(\.latitude), lons = shortest.map(\.longitude)
        guard let s = lats.min(), let n = lats.max(), let w = lons.min(), let e = lons.max() else { return nil }
        let box = GeoBox(west: w, south: s, east: e, north: n).expanded(by: 0.3)
        let pad = 0.1
        let corridor = GeoBox(west: box.west - pad, south: box.south - pad, east: box.east + pad, north: box.north + pad)
        guard let windGrid = try? await Seadata.current.windGrid(corridor), let field = WindField(windGrid) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> (path: [CLLocationCoordinate2D], saved: TimeInterval, tacks: Int)? in
            // Where the shortest route first and last reaches navigable water: harbour exits stay as planned.
            let navigable = shortest.indices.filter { i in grid.index(of: shortest[i]).map(grid.isNavigable) ?? false }
            guard let first = navigable.first, let last = navigable.last, last > first else { return nil }
            guard let result = try? WeatherRouter.route(from: shortest[first], to: shortest[last], departure: departure,
                                                       boat: boat, wind: field, grid: grid) else { return nil }
            let combined = Array(shortest[...first]) + result.path.dropFirst().dropLast() + Array(shortest[last...])
            // Compare like with like: the same wind, the shortest route sailed through it.
            let shortestTime = Self.sailingTime(Array(shortest[first...last]), departure: departure, boat: boat, wind: field)
            let fastestTime = result.arrival.timeIntervalSince(departure)
            // Not worth it: keep the shortest route.
            guard shortestTime - fastestTime > 60 else { return nil }
            return (combined, shortestTime - fastestTime, result.tacks)
        }.value
    }

    /// Time to sail a path in a wind field (tacking where needed), for comparing routes.
    nonisolated private static func sailingTime(_ path: [CLLocationCoordinate2D], departure: Date, boat: BoatProfile, wind: WindField) -> TimeInterval {
        var clock = departure
        for (a, b) in zip(path, path.dropFirst()) {
            let length = Geo.distanceNM(a, b)
            var covered = 0.0
            while covered < length - 1e-9 {
                let step = min(0.5, length - covered)
                let here = Geo.interpolate(a, b, fraction: (covered + step / 2) / max(length, 1e-9))
                var speed = boat.motorSpeed
                if let w = wind.wind(at: here, time: clock) {
                    let sailing = Polar.speedAlongCourse(twa: abs(Geo.angleDiff(w.from, Geo.bearing(here, b))), tws: w.speed, boat: boat).speed
                    if sailing >= boat.motorThreshold { speed = sailing }
                }
                clock += step / max(speed, 0.3) * 3600
                covered += step
            }
        }
        return clock.timeIntervalSince(departure)
    }

    private func useStraightLegs(_ points: [CLLocationCoordinate2D], in region: ChartRegion?) {
        path = points
        let rules = region.map { NavigationRules(region: $0, safetyDepth: boat.safetyDepth, airDraft: boat.airDraft) }
        legHazards = zip(points, points.dropFirst()).map { a, b in
            rules.flatMap { Router.hazard(from: a, to: b, rules: $0) }
        }
        routeNotes = rules.map { Router.notes(for: points, rules: $0) } ?? []
    }

    /// The routing grid around the route; reused while waypoints stay inside the same window.
    private func routingGrid(for region: ChartRegion, safetyDepth: Double, airDraft: Double,
                             around points: [CLLocationCoordinate2D]) async -> RoutingGrid {
        let key = "\(region.id)@\(safetyDepth)@\(airDraft)"
        if let grid = grids[key], points.allSatisfy({ grid.index(of: $0) != nil }), !grid.isTooLoose(for: points) {
            return grid
        }
        let grid = await Task.detached(priority: .userInitiated) {
            RoutingGrid(rules: NavigationRules(region: region, safetyDepth: safetyDepth, airDraft: airDraft), around: points)
        }.value
        grids = [key: grid]
        return grid
    }

    // MARK: Forecast & planning

    func refreshLocalWeather() {
        let here = location.location?.coordinate ?? CLLocationCoordinate2D(latitude: 45.3245, longitude: 14.4385)
        if let last = localForecastFetched, Geo.distanceNM(last.coordinate, here) < 5, Date.now.timeIntervalSince(last.at) < 1800 { return }
        localForecastFetched = (here, .now)
        Task {
            if let forecast = try? await weather.forecast(along: [here, here]) { localForecast = forecast }
            else { localForecastFetched = nil }
        }
    }

    func refreshForecast() {
        forecastTask?.cancel()
        let coordinates = path
        guard coordinates.count >= 2 else {
            forecast = nil
            forecastState = .idle
            return
        }
        forecastState = .loading
        forecastTask = Task {
            // Wait for the user to stop dragging waypoints around.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do {
                let result = try await weather.forecast(along: coordinates)
                guard !Task.isCancelled else { return }
                forecast = result
                forecastState = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                forecastState = .failed(error.localizedDescription)
            }
            recompute()
        }
    }

    private func planChanged() {
        recompute()
        refreshForecast()
        if fitPending, routingState != .routing, Self.debugArgument("debugCenter") == nil {
            fitPending = false
            fitRouteRequest += 1
        }
    }

    private func recompute(options: Bool = true) {
        plan = PassageSimulator.plan(route: path, boat: boat, forecast: forecast, departure: departure)
        guard options else { return }
        if let forecast, path.count >= 2 {
            departureOptions = PassageSimulator.departureOptions(route: path, boat: boat, forecast: forecast, from: .now)
        } else {
            departureOptions = []
        }
    }

    var bestDeparture: DepartureOption? {
        departureOptions.min { a, b in
            a.rating != b.rating ? a.rating < b.rating : a.duration < b.duration
        }
    }

    // MARK: Data server & live layers

    enum LayerState: Equatable { case idle, loading, zoomIn, failed(String) }

    private(set) var windGrid: WindGrid?
    private(set) var windState = LayerState.idle
    /// The hour the wind arrows show.
    var windTime = Date.now
    /// Ships from the data server's AIS feed.
    private(set) var serverVessels: [Vessel] = []
    private(set) var aisState = LayerState.idle

    /// All ships: the boat's own AIS receiver (NMEA) first, it's live and works offline; then the server's.
    var vessels: [Vessel] {
        let cutoff = Date.now.timeIntervalSince1970 - 1800
        let own = nmea.vessels.values.filter { $0.updated > cutoff && ($0.lat != 0 || $0.lon != 0) }
        guard !own.isEmpty else { return serverVessels }
        let ownIDs = Set(own.map(\.mmsi))
        let box = visibleBox
        return own.filter { box?.expanded(by: 0.2).contains($0.coordinate) ?? true } + serverVessels.filter { !ownIDs.contains($0.mmsi) }
    }
    /// Visible part of the map, for the live layers.
    private(set) var visibleBox: GeoBox?
    /// Foreground only: no AIS polling in the background.
    var isActive = true { didSet { if isActive != oldValue { restartAIS() } } }
    private var windTask: Task<Void, Never>?
    private var aisTask: Task<Void, Never>?
    private var windFetched: (box: GeoBox, at: Date)?

    func mapMoved(to box: GeoBox) {
        visibleBox = box
        refreshWind()
        restartAIS()
        refreshWarnings()
    }

    /// Steps the wind arrows by three hours, or the radar by one frame.
    func stepTime(by steps: Int) {
        if showWind {
            var next = windTime.addingTimeInterval(Double(steps * 3) * 3600)
            if let grid = windGrid, let start = grid.start, let end = grid.end { next = min(max(next, start), end) }
            windTime = next
        } else if let frame = radarFrame, let i = radarFrames.firstIndex(of: frame) {
            radarFrame = radarFrames[min(max(0, i + steps), radarFrames.count - 1)]
        }
    }

    func resetTime() {
        windTime = .now
        radarFrame = radarFrames.last
    }

    // MARK: Rain radar

    var showRadar: Bool { didSet { save(showRadar, as: "radar"); refreshRadar() } }
    private(set) var radarFrames: [RadarFrame] = []
    var radarFrame: RadarFrame?
    private var radarFetched: Date?

    func refreshRadar() {
        guard showRadar else {
            radarFrame = nil
            return
        }
        if let radarFetched, Date.now.timeIntervalSince(radarFetched) < 300, radarFrame != nil { return }
        let server = Seadata.current
        Task {
            guard let frames = try? await server.radar(), !frames.isEmpty else { return }
            radarFrames = frames
            radarFetched = .now
            if showRadar { radarFrame = frames.last }
        }
    }

    // MARK: Warnings

    private(set) var warnings: [WeatherWarning] = []
    private var warningsFetched: (box: GeoBox, at: Date)?

    /// The most severe current marine warning for where the map is.
    var activeWarning: WeatherWarning? {
        warnings.first { $0.isMarine && ($0.expiresDate ?? .distantFuture) > .now && ($0.onsetDate ?? .distantPast) < .now.addingTimeInterval(12 * 3600) }
    }

    private func refreshWarnings() {
        guard let box = visibleBox, box.width < 15 else { return }
        if let last = warningsFetched, last.box.contains(box), Date.now.timeIntervalSince(last.at) < 900 { return }
        let wanted = box.expanded(by: 0.5)
        warningsFetched = (wanted, .now)
        let server = Seadata.current
        Task {
            if let found = try? await server.warnings(in: wanted) { warnings = found } else { warningsFetched = nil }
        }
    }

    private func serverChanged() {
        localForecastFetched = nil
        refreshLocalWeather()
        refreshForecast()
        windGrid = nil
        windFetched = nil
        serverVessels = []
        refreshWind()
        restartAIS()
    }

    private func refreshWind() {
        guard showWind, let box = visibleBox else {
            windTask?.cancel()
            return
        }
        // The last grid still covers this view at a fitting spacing, and isn't stale.
        if let last = windFetched, last.box.contains(box), box.width > last.box.width / 4,
           Date.now.timeIntervalSince(last.at) < 1800 { return }
        windTask?.cancel()
        let server = Seadata.current
        let wanted = box.expanded(by: 0.3)
        windTask = Task {
            try? await Task.sleep(for: .milliseconds(350)) // let the map settle
            guard !Task.isCancelled else { return }
            windState = .loading
            do {
                let grid = try await server.windGrid(wanted)
                guard !Task.isCancelled else { return }
                windGrid = grid
                windFetched = (wanted, .now)
                windState = .idle
                if grid.hour(for: windTime) == nil { windTime = .now }
            } catch {
                guard !Task.isCancelled else { return }
                windState = .failed(error.localizedDescription)
            }
        }
    }

    /// Polls AIS for the visible area every 15 s while the layer is on and the app is in front.
    private func restartAIS() {
        aisTask?.cancel()
        guard showAIS, isActive, visibleBox != nil else { return }
        let server = Seadata.current
        aisTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                guard let box = visibleBox else { return }
                // Zoomed far out there would be thousands of ships.
                guard box.width < 4 else {
                    serverVessels = []
                    aisState = .zoomIn
                    return
                }
                do {
                    let found = try await server.vessels(in: box.expanded(by: 0.2))
                    guard !Task.isCancelled else { return }
                    serverVessels = found
                    aisState = .idle
                    if let shown = inspection?.vessel, let fresh = found.first(where: { $0.mmsi == shown.mmsi }) {
                        inspection = Inspection(coordinate: fresh.coordinate, vessel: fresh)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    aisState = .failed(error.localizedDescription)
                    if let failure = error as? Seadata.Failure, case .noAIS = failure { return }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Shows a logbook track on the chart and frames it.
    func show(_ track: TrackLog) {
        shownTrack = track
        if let first = track.points.first { centre(on: first.coordinate, zoom: 11) }
    }

    // MARK: GPX

    /// Routes become saved routes, tracks go into the logbook, waypoints become marks.
    func importGPX(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let contents = GPX.parse(data)
        for imported in contents.routes {
            var route = Route()
            route.name = imported.name
            route.waypoints = imported.points.map(Waypoint.init)
            // Many points means a track to follow as drawn, not a few turns to route between.
            route.mode = imported.points.count > 12 ? .manual : .automatic
            savedRoutes.insert(route, at: 0)
        }
        for track in contents.tracks {
            logbook.insert(TrackLog(name: track.name, start: track.points.first?.time ?? .now, points: track.points), at: 0)
        }
        for waypoint in contents.waypoints {
            marks.append(UserMark(name: waypoint.name, symbol: "mappin", coordinate: waypoint.coordinate))
        }
        if let first = contents.routes.first, let saved = savedRoutes.first(where: { $0.name == first.name }) { open(saved) }
    }

    // MARK: Persistence

    nonisolated private static var logbookFile: URL { URL.applicationSupportDirectory.appending(path: "logbook.json") }

    private static func loadLogbook() -> [TrackLog] {
        (try? Data(contentsOf: logbookFile)).flatMap { try? JSONDecoder().decode([TrackLog].self, from: $0) } ?? []
    }

    private static func saveLogbook(_ logbook: [TrackLog]) {
        let data = try? JSONEncoder().encode(logbook)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try? data?.write(to: logbookFile, options: .atomic)
        }
    }

    private func save<T: Encodable>(_ value: T, as key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
