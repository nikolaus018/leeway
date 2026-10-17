import CoreLocation
import Observation

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

    var boat: BoatProfile { didSet { save(boat, as: "boat"); if boat.safetyDepth != oldValue.safetyDepth { routeChanged() } else { recompute() } } }
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
    private(set) var routingState = RoutingState.idle
    private(set) var forecast: RouteForecast?
    private(set) var forecastState = ForecastState.idle
    private(set) var plan: PassagePlan?
    private(set) var departureOptions: [DepartureOption] = []
    var inspection: Inspection?
    var camera = MapCamera()

    let regions = ChartRegion.bundled()
    let location = LocationTracker()
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
        guard let region else {
            useStraightLegs(points, in: nil)
            routingState = .failed(Router.Failure.outsideChart.localizedDescription)
            planChanged()
            return
        }

        routingState = .routing
        if path.count < 2 { useStraightLegs(points, in: region) }
        let safetyDepth = boat.safetyDepth
        routeTask = Task {
            try? await Task.sleep(for: .milliseconds(120)) // coalesce drags
            guard !Task.isCancelled else { return }
            let grid = await routingGrid(for: region, safetyDepth: safetyDepth)
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Router.route(through: points, on: grid) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let routed):
                path = routed.path
                legHazards = []
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
        legHazards = zip(points, points.dropFirst()).map { a, b in
            region.flatMap { Router.hazard(from: a, to: b, region: $0, safetyDepth: boat.safetyDepth) }
        }
    }

    private func routingGrid(for region: ChartRegion, safetyDepth: Double) async -> RoutingGrid {
        let key = "\(region.id)@\(safetyDepth)"
        if let grid = grids[key] { return grid }
        let grid = await Task.detached(priority: .userInitiated) {
            RoutingGrid(region: region, safetyDepth: safetyDepth)
        }.value
        grids[key] = grid
        return grid
    }

    // MARK: Forecast & planning

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
