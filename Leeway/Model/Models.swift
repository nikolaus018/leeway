import CoreLocation

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case chart
    case routes
    case weather
    case log
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chart: "Chart"
        case .routes: "Routes"
        case .weather: "Weather"
        case .log: "Log"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chart: "map"
        case .routes: "point.topleft.down.to.point.bottomright.curvepath"
        case .weather: "cloud.sun"
        case .log: "book.closed"
        case .settings: "gearshape"
        }
    }
}

struct Waypoint: Identifiable, Codable, Hashable {
    var id = UUID()
    var latitude: Double
    var longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set { latitude = newValue.latitude; longitude = newValue.longitude }
    }
}

enum RoutingMode: String, Codable, CaseIterable, Identifiable {
    /// Shortest path through water deep enough for the boat.
    case automatic
    /// Fastest path under sail in the forecast wind (isochrones), just as safe.
    case weather
    /// Straight legs between the user's waypoints.
    case manual
    var id: Self { self }
    var label: String {
        switch self {
        case .automatic: "Shortest"
        case .weather: "Fastest"
        case .manual: "Manual"
        }
    }
}

struct Route: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "New route"
    var waypoints: [Waypoint] = []
    var mode = RoutingMode.automatic
    var updatedAt = Date()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        waypoints = try c.decode([Waypoint].self, forKey: .waypoints)
        mode = try c.decodeIfPresent(RoutingMode.self, forKey: .mode) ?? .automatic
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }

    var coordinates: [CLLocationCoordinate2D] { waypoints.map(\.coordinate) }
    var distanceNM: Double { Geo.length(of: coordinates) }
}

enum Propulsion: String, Codable, CaseIterable, Identifiable {
    case sail, motor
    var id: Self { self }
    var label: String { self == .sail ? "Sailing yacht" : "Motor boat" }
}

struct BoatProfile: Codable, Equatable {
    var name = "My Boat"
    var propulsion = Propulsion.sail
    /// Best boat speed through the water under sail in ~16 kn of breeze.
    var sailSpeed = 6.5
    /// Cruising speed under engine.
    var motorSpeed = 5.5
    /// Below this sailing speed the engine goes on.
    var motorThreshold = 3.0
    var draft = 1.8
    /// Extra water wanted under the keel; draft + clearance is the safety depth for routing.
    var underKeelClearance = 1.0
    /// Height above the waterline of the highest point (mast top, antennas), for bridges.
    var airDraft = 16.0
    /// Comfort limits used to rank departure times.
    var maxWind = 22.0
    var maxGust = 30.0
    var maxWave = 1.5
    /// The boat's own polar (a preset or imported); nil uses a generic one scaled by `sailSpeed`.
    var polar: PolarTable?

    var safetyDepth: Double { draft + underKeelClearance }

    init() {}

    // Tolerates profiles saved by older versions that lack newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BoatProfile()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        propulsion = try c.decodeIfPresent(Propulsion.self, forKey: .propulsion) ?? d.propulsion
        sailSpeed = try c.decodeIfPresent(Double.self, forKey: .sailSpeed) ?? d.sailSpeed
        motorSpeed = try c.decodeIfPresent(Double.self, forKey: .motorSpeed) ?? d.motorSpeed
        motorThreshold = try c.decodeIfPresent(Double.self, forKey: .motorThreshold) ?? d.motorThreshold
        draft = try c.decodeIfPresent(Double.self, forKey: .draft) ?? d.draft
        underKeelClearance = try c.decodeIfPresent(Double.self, forKey: .underKeelClearance) ?? d.underKeelClearance
        airDraft = try c.decodeIfPresent(Double.self, forKey: .airDraft) ?? d.airDraft
        maxWind = try c.decodeIfPresent(Double.self, forKey: .maxWind) ?? d.maxWind
        maxGust = try c.decodeIfPresent(Double.self, forKey: .maxGust) ?? d.maxGust
        maxWave = try c.decodeIfPresent(Double.self, forKey: .maxWave) ?? d.maxWave
        polar = try c.decodeIfPresent(PolarTable.self, forKey: .polar)
    }
}

enum MapBase: String, CaseIterable, Identifiable, Codable {
    /// The nautical chart, everywhere.
    case chart
    /// Satellite imagery with depth contours, shallows, soundings and seamarks on top.
    case satellite
    var id: Self { self }
    var label: String { self == .chart ? "Chart" : "Satellite" }
    var symbol: String { self == .chart ? "map" : "globe.europe.africa.fill" }
}

/// How the chart's colours are chosen.
enum PaletteMode: String, CaseIterable, Identifiable, Codable {
    /// By the sun: day, dusk at civil twilight, night after dark.
    case auto, day, dusk, night
    var id: Self { self }
    var label: String { self == .auto ? "Automatic" : rawValue.capitalized }
}

/// A place the user marked: a good anchorage, a fishing spot, a rock that isn't charted.
struct UserMark: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// SF Symbol name.
    var symbol: String
    var latitude: Double
    var longitude: Double
    var notes = ""
    var created = Date()

    init(name: String, symbol: String, coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.symbol = symbol
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set { latitude = newValue.latitude; longitude = newValue.longitude }
    }

    static let symbols = ["mappin", "flag.fill", "star.fill", "anchor", "fish.fill", "exclamationmark.triangle.fill", "fuelpump.fill", "fork.knife", "beach.umbrella.fill", "camera.fill"]
}

/// When the app raises an alarm.
struct AlarmSettings: Codable, Equatable {
    /// AIS: a ship passing closer than this (NM)…
    var cpaDistance = 0.5
    /// …within this many minutes.
    var cpaMinutes = 20.0
    var aisAlarm = true
    /// Navigation: off track by more than this (NM).
    var crossTrack = 0.1
    /// Depth below the keel (m) for the shallow-water alarm from the chart or sounder.
    var shallowAlarm = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlarmSettings()
        cpaDistance = try c.decodeIfPresent(Double.self, forKey: .cpaDistance) ?? d.cpaDistance
        cpaMinutes = try c.decodeIfPresent(Double.self, forKey: .cpaMinutes) ?? d.cpaMinutes
        aisAlarm = try c.decodeIfPresent(Bool.self, forKey: .aisAlarm) ?? d.aisAlarm
        crossTrack = try c.decodeIfPresent(Double.self, forKey: .crossTrack) ?? d.crossTrack
        shallowAlarm = try c.decodeIfPresent(Bool.self, forKey: .shallowAlarm) ?? d.shallowAlarm
    }
}
