import CoreLocation
import Foundation

/// Client for the Leeway data server (`server/` in this repo). It pulls forecasts, seamark tiles,
/// chart packs and AIS from their sources, so the app talks to one place.
nonisolated struct Seadata: Sendable, Equatable {
    static let defaultURL = "https://seadata.ringtwo.win"
    static let defaultsKey = "serverURL"

    let base: URL

    /// Accepts "host", "host:port", or a full URL; nil if it can't be a server address.
    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil else { return nil }
        base = url
    }

    /// The server chosen in settings (the default one until the user picks another).
    static var current: Seadata {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Seadata.init) ?? Seadata(defaultURL)!
    }

    var displayName: String { base.host() ?? base.absoluteString }

    enum Failure: LocalizedError {
        case status(Int, String?)
        case noAIS

        var errorDescription: String? {
            switch self {
            case .status(let code, let message): "The data server answered \(code)\(message.map { ": \($0)" } ?? "")."
            case .noAIS: "AIS isn't set up on this data server."
            }
        }
    }

    // MARK: Endpoints

    struct Info: Decodable, Sendable {
        let name: String
        let version: String
        let features: [String]
        let attribution: [String]
    }

    func info() async throws -> Info {
        try await get("v1/info")
    }

    func forecast(at points: [CLLocationCoordinate2D]) async throws -> ServerForecast {
        let spec = points.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }.joined(separator: ";")
        return try await get("v1/forecast", [URLQueryItem(name: "points", value: spec)])
    }

    func windGrid(_ box: GeoBox) async throws -> WindGrid {
        try await get("v1/wind-grid", box.queryItems)
    }

    func vessels(in box: GeoBox) async throws -> [Vessel] {
        do {
            let response: VesselsResponse = try await get("v1/ais", box.queryItems)
            return response.vessels
        } catch Failure.status(501, _) {
            throw Failure.noAIS
        }
    }

    func charts() async throws -> [ChartPackInfo] {
        let response: ChartsResponse = try await get("v1/charts")
        return response.charts
    }

    /// A pack file; the version makes the URL unique, so caches may keep it for good.
    func chartFile(_ name: String, version: String? = nil) -> URL {
        let url = base.appending(path: "v1/charts/files").appending(path: name)
        return version.map { url.appending(queryItems: [URLQueryItem(name: "v", value: $0)]) } ?? url
    }

    func seaLevel(at c: CLLocationCoordinate2D) async throws -> SeaLevel {
        try await get("v1/sealevel", [URLQueryItem(name: "lat", value: String(format: "%.3f", c.latitude)),
                                      URLQueryItem(name: "lon", value: String(format: "%.3f", c.longitude))])
    }

    func warnings(in box: GeoBox) async throws -> [WeatherWarning] {
        let response: WarningsResponse = try await get("v1/warnings", box.queryItems)
        return response.warnings
    }

    func search(_ text: String, near c: CLLocationCoordinate2D?) async throws -> [PlaceResult] {
        var query = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "limit", value: "15")]
        if let c {
            query += [URLQueryItem(name: "lat", value: String(format: "%.2f", c.latitude)),
                      URLQueryItem(name: "lon", value: String(format: "%.2f", c.longitude))]
        }
        let response: SearchResponse = try await get("v1/search", query)
        return response.results
    }

    func radar() async throws -> [RadarFrame] {
        let response: RadarResponse = try await get("v1/radar")
        return response.frames
    }

    /// One session for the app: identifies the app to the server, and keeps what the server says
    /// may be kept (forecasts for minutes, tiles for days) so repeat views cost nothing.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["X-Leeway-Client": clientHeader]
        configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20,
                                          directory: URL.cachesDirectory.appending(path: "Seadata"))
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static var clientHeader: String {
        "Leeway/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") iOS"
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        let request = URLRequest(url: components.url!, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.status(status, (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

nonisolated private struct VesselsResponse: Decodable { let vessels: [Vessel] }
nonisolated private struct WarningsResponse: Decodable { let warnings: [WeatherWarning] }
nonisolated private struct SearchResponse: Decodable { let results: [PlaceResult] }
nonisolated private struct RadarResponse: Decodable { let frames: [RadarFrame] }

/// `/v1/sealevel`: tide plus surge, hourly.
nonisolated struct SeaLevel: Decodable, Sendable, Equatable {
    let lat: Double
    let lon: Double
    let times: [Double]
    let height: [Double?]

    /// (time, metres) pairs with data.
    var points: [(Date, Double)] {
        zip(times, height).compactMap { t, h in h.map { (Date(timeIntervalSince1970: t), $0) } }
    }

    /// Highs and lows: local extremes of the curve.
    var turningPoints: [(time: Date, height: Double, high: Bool)] {
        let p = points
        guard p.count >= 3 else { return [] }
        return (1..<(p.count - 1)).compactMap { i in
            let (a, b, c) = (p[i - 1].1, p[i].1, p[i + 1].1)
            if b > a && b >= c { return (p[i].0, b, true) }
            if b < a && b <= c { return (p[i].0, b, false) }
            return nil
        }
    }
}

/// An official weather warning (MeteoAlarm).
nonisolated struct WeatherWarning: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let country: String
    let areaName: String
    let event: String
    let severity: String
    let level: String?
    let kind: String?
    let onset: String
    let expires: String
    let headline: String
    let description: String?
    let instruction: String?
    /// The area's outline rings (lon, lat), when the server knows them.
    let polygon: [[[Double]]]?

    var title: String { "\(event) · \(areaName)" }

    /// Marine-relevant: wind, thunderstorms, coastal events, fog.
    var isMarine: Bool {
        let k = (kind ?? event).lowercased()
        return ["wind", "thunder", "coastal", "fog", "storm"].contains { k.contains($0) }
    }

    var onsetDate: Date? { ISO8601DateFormatter().date(from: onset) }
    var expiresDate: Date? { ISO8601DateFormatter().date(from: expires) }
}

/// A place from `/v1/search`.
nonisolated struct PlaceResult: Decodable, Sendable, Identifiable, Hashable {
    let name: String
    let kind: String
    let lat: Double
    let lon: Double
    let detail: String?

    var id: String { "\(name)|\(lat)|\(lon)" }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    var symbol: String {
        switch kind {
        case "marina": "sailboat.fill"
        case "harbour": "ferry.fill"
        case "anchorage", "mooring": "anchor"
        case "bay", "strait": "water.waves"
        case "island", "islet", "cape": "mountain.2.fill"
        case "city", "town", "village": "building.2.fill"
        case "fuel": "fuelpump.fill"
        default: "mappin"
        }
    }
}

/// A rain radar picture: its time and tile URL template.
nonisolated struct RadarFrame: Decodable, Sendable, Hashable {
    let time: Double
    let tiles: String
    var date: Date { Date(timeIntervalSince1970: time) }
}
nonisolated private struct ChartsResponse: Decodable { let charts: [ChartPackInfo] }
nonisolated private struct ErrorBody: Decodable { let error: String }

/// A lat/lon box, e.g. the visible part of the map.
nonisolated struct GeoBox: Equatable, Sendable {
    var west, south, east, north: Double

    var width: Double { east - west }
    var height: Double { north - south }

    func contains(_ other: GeoBox) -> Bool {
        other.west >= west && other.east <= east && other.south >= south && other.north <= north
    }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude >= south && c.latitude <= north && c.longitude >= west && c.longitude <= east
    }

    /// Grown by `fraction` of its size on every side, clamped to the globe.
    func expanded(by fraction: Double) -> GeoBox {
        let dx = width * fraction, dy = height * fraction
        return GeoBox(west: max(-180, west - dx), south: max(-85, south - dy),
                      east: min(180, east + dx), north: min(85, north + dy))
    }

    var queryItems: [URLQueryItem] {
        [("west", west), ("south", south), ("east", east), ("north", north)].map {
            URLQueryItem(name: $0.0, value: String(format: "%.4f", $0.1))
        }
    }
}

/// `/v1/forecast`: one merged hourly series per point.
nonisolated struct ServerForecast: Decodable, Sendable {
    struct Point: Decodable, Sendable {
        let lat: Double
        let lon: Double
        let times: [Double]
        let windSpeed: [Double?]
        let windFrom: [Double?]
        let gust: [Double?]
        let windModel: [String?]
        let waveHeight: [Double?]?
        let waveFrom: [Double?]?
        let wavePeriod: [Double?]?
        let swellHeight: [Double?]?
        let currentSpeed: [Double?]?
        let currentToward: [Double?]?
        let seaTemp: [Double?]?
        let airTemp: [Double?]?
        let pressure: [Double?]?
        let precipitation: [Double?]?
        let cloudCover: [Double?]?
        let visibility: [Double?]?
        let weatherCode: [Double?]?
    }
    let fetchedAt: Double
    let points: [Point]
}

/// `/v1/wind-grid`: wind on a regular grid, for arrows on the map.
nonisolated struct WindGrid: Decodable, Sendable {
    struct Point: Decodable, Sendable {
        let lat: Double
        let lon: Double
        let windSpeed: [Double?]
        let windFrom: [Double?]
        let gust: [Double?]
        let waveHeight: [Double?]?
    }
    let step: Double
    let times: [Double]
    let points: [Point]

    /// The hour closest to `date`, if the grid covers it.
    func hour(for date: Date) -> Int? {
        guard let first = times.first, let last = times.last else { return nil }
        let t = date.timeIntervalSince1970
        guard t >= first - 1800, t <= last + 1800 else { return nil }
        return times.indices.min { abs(times[$0] - t) < abs(times[$1] - t) }
    }

    var start: Date? { times.first.map(Date.init(timeIntervalSince1970:)) }
    var end: Date? { times.last.map(Date.init(timeIntervalSince1970:)) }
}

/// A chart pack the server offers for download.
nonisolated struct ChartPackInfo: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let west, south, east, north: Double
    let version: String
    let size: Int
    let files: [String]
    let attribution: String
}

/// A ship from AIS.
nonisolated struct Vessel: Decodable, Sendable, Identifiable, Hashable {
    let mmsi: Int
    let name: String?
    let callSign: String?
    let destination: String?
    let shipType: Int?
    let length: Double?
    let beam: Double?
    let lat: Double
    let lon: Double
    let sog: Double?
    let cog: Double?
    let heading: Double?
    let navStatus: Int?
    let updated: Double

    var id: Int { mmsi }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var displayName: String { name ?? "MMSI \(mmsi)" }
    var lastHeard: Date { Date(timeIntervalSince1970: updated) }
    /// Where the bow points, else where it's going.
    var course: Double? { heading ?? cog }
    var isUnderway: Bool { (sog ?? 0) >= 0.5 && navStatus != 1 && navStatus != 5 }

    enum Category { case sailing, pleasure, passenger, cargo, tanker, fishing, highSpeed, service, other }

    var category: Category {
        switch shipType ?? 0 {
        case 36: .sailing
        case 37: .pleasure
        case 30: .fishing
        case 40...49: .highSpeed
        case 60...69: .passenger
        case 70...79: .cargo
        case 80...89: .tanker
        case 31...35, 50...59: .service
        default: .other
        }
    }

    var kind: String {
        switch category {
        case .sailing: "Sailing vessel"
        case .pleasure: "Pleasure craft"
        case .passenger: "Passenger ship"
        case .cargo: "Cargo ship"
        case .tanker: "Tanker"
        case .fishing: "Fishing vessel"
        case .highSpeed: "High-speed craft"
        case .service: shipType == 52 ? "Tug" : shipType == 51 ? "Search and rescue" : "Service vessel"
        case .other: "Vessel"
        }
    }

    var status: String? {
        switch navStatus {
        case 0: "Under way using engine"
        case 1: "At anchor"
        case 2: "Not under command"
        case 3: "Restricted manoeuvrability"
        case 4: "Constrained by draught"
        case 5: "Moored"
        case 6: "Aground"
        case 7: "Engaged in fishing"
        case 8: "Under way sailing"
        default: nil
        }
    }
}

/// Closest point of approach between two moving boats (flat earth, fine within a few miles).
nonisolated struct Approach: Equatable, Sendable {
    /// NM at the closest point.
    var distance: Double
    /// Hours until then (0 if it's now or past).
    var time: Double

    static func between(own: CLLocationCoordinate2D, ownSOG: Double, ownCOG: Double,
                        target: CLLocationCoordinate2D, targetSOG: Double, targetCOG: Double) -> Approach {
        let rx = (target.longitude - own.longitude) * 60 * cos(own.latitude.radians)
        let ry = (target.latitude - own.latitude) * 60
        let vx = targetSOG * sin(targetCOG.radians) - ownSOG * sin(ownCOG.radians)
        let vy = targetSOG * cos(targetCOG.radians) - ownSOG * cos(ownCOG.radians)
        let v2 = vx * vx + vy * vy
        let t = v2 < 1e-6 ? 0 : max(0, -(rx * vx + ry * vy) / v2)
        return Approach(distance: hypot(rx + vx * t, ry + vy * t), time: t)
    }

    /// Close and soon enough to keep an eye on.
    var isDangerous: Bool { distance < 0.5 && time < 1.0 / 3 }
}
