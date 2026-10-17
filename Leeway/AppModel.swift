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

        static func == (a: Inspection, b: Inspection) -> Bool {
            a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.seamark == b.seamark
        }
    }

    /// What the map is currently showing, for the scale bar and grid labels.
    struct MapCamera: Equatable {
        struct Label: Equatable, Identifiable {
            var id: String { text }
            var position: Double
            var text: String
        }
        var metresPerPoint = 0.0
        var longitudeLabels: [Label] = []
        var latitudeLabels: [Label] = []
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
    var showDepth: Bool { didSet { save(showDepth, as: "depth") } }
    var showGrid: Bool { didSet { save(showGrid, as: "grid") } }

    // MARK: Session

    var route = Route()
    var isEditing = false
    var departure = Date.now { didSet { recompute(options: false) } }
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
    var camera = MapCamera()
    /// Forecast at the boat's position (or Rijeka before the first GPS fix).
    private(set) var localForecast: RouteForecast?
    private var localForecastFetched: (coordinate: CLLocationCoordinate2D, at: Date)?

    /// Offline charts; loaded in the background at launch (the Adriatic grid is ~40 MB).
    private(set) var regions: [ChartRegion] = []
    private var chartsLoaded = false
    let location = LocationTracker()
    let underway = Underway()
    /// Bumped to ask the map to frame the route.
    private(set) var fitRouteRequest = 0
    var tracking = UserTracking.none

    enum UserTracking { case none, follow, heading }

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
        showDepth = Self.load("depth") ?? true
        showGrid = Self.load("grid") ?? false
        Task {
            regions = await Task.detached(priority: .userInitiated) { ChartRegion.bundled() }.value
            chartsLoaded = true
            routeChanged()
        }
        location.onUpdate = { [weak self] fix in self?.underway.update(with: fix) }
        underway.boatName = boat.name
        syncUnderway()
        // Picking up where we left off (navigating, at anchor, MOB): show the boat.
        if underway.needsBackground { tracking = .follow }
        #if DEBUG
        loadDebugRoute()
        #endif
    }

    #if DEBUG
    /// `-debugRoute "lat,lon;lat,lon;…"` as a launch argument opens that route (for simulator testing).
    private func loadDebugRoute() {
        guard let spec = UserDefaults.standard.string(forKey: "debugRoute") else { return }
        var debug = Route()
        debug.name = "Debug route"
        debug.waypoints = spec.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return parts.count == 2 ? Waypoint(CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])) : nil
        }
        if UserDefaults.standard.string(forKey: "debugMode") == "manual" { debug.mode = .manual }
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

    func region(containing points: [CLLocationCoordinate2D]) -> ChartRegion? {
        regions.first { region in points.allSatisfy(region.contains) }
    }

    func inspect(_ coordinate: CLLocationCoordinate2D, seamark: Seamark?) {
        let point = seamark?.coordinate ?? coordinate
        inspection = Inspection(coordinate: point, seamark: seamark,
                                sounding: region(containing: [point])?.sounding(at: point))
    }

    private func inspectionTitle(for coordinate: CLLocationCoordinate2D) -> String {
        if let mark = inspection?.seamark, let name = mark.name { return name }
        return coordinate.formatted
    }

    // MARK: Routing

    private func routeChanged() {
        routeTask?.cancel()
        let points = route.coordinates
        let region = region(containing: points)

        guard route.mode == .automatic, points.count >= 2 else {
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
        routeTask = Task {
            try? await Task.sleep(for: .milliseconds(120)) // coalesce drags
            guard !Task.isCancelled else { return }
            let grid = await routingGrid(for: region, safetyDepth: safetyDepth, airDraft: airDraft, around: points)
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Router.route(through: points, on: grid) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let routed):
                path = routed.path
                legHazards = []
                routeNotes = Router.notes(for: routed.path, rules: grid.rules)
                routingState = .routed(shallowEnds: routed.shallowConnections)
            case .failure(let error):
                useStraightLegs(points, in: region)
                routingState = .failed(error.localizedDescription)
            }
            planChanged()
        }
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
        if fitPending, routingState != .routing, UserDefaults.standard.string(forKey: "debugCenter") == nil {
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

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, as key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
