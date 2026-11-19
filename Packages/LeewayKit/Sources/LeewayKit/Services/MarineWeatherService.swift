import CoreLocation

/// Wind, sea state and tidal stream at one place and time.
struct Conditions: Equatable {
    var windSpeed: Double      // kn
    var windFrom: Double       // ° true
    var gust: Double           // kn
    var waveHeight: Double?    // m
    var currentSpeed: Double   // kn
    var currentToward: Double  // ° true (direction the stream sets)

    static let calm = Conditions(windSpeed: 0, windFrom: 0, gust: 0, waveHeight: nil, currentSpeed: 0, currentToward: 0)

    /// The Adriatic name for a wind from this direction.
    var windName: String {
        switch Geo.normalize(windFrom) {
        case 20..<90: "Bura"        // NE: cold, gusty fall wind off the Velebit and Učka
        case 90..<110: "Levant"
        case 110..<170: "Jugo"      // SE: warm, steady, builds big seas
        case 170..<200: "Oštro"
        case 200..<250: "Lebić"
        case 250..<290: "Pulenat"
        case 290..<340: "Maestral"  // NW: the summer afternoon sea breeze
        default: "Tramontana"
        }
    }

    /// Only a real breeze gets a name; under 5 kn it's just light airs.
    var description: String { windSpeed < 5 ? "light airs" : windName.lowercased() }

    var isBura: Bool { windName == "Bura" && windSpeed >= 8 }
}

/// Weather models in order of preference; high-resolution ones resolve the gusty bura.
nonisolated enum WindModel: Int, CaseIterable, Sendable {
    case icon2I, iconD2, iconEU, global

    var apiName: String {
        switch self {
        case .icon2I: "italia_meteo_arpae_icon_2i"
        case .iconD2: "icon_d2"
        case .iconEU: "icon_eu"
        case .global: "best_match"
        }
    }

    var label: String {
        switch self {
        case .icon2I: "ICON-2I 2 km"
        case .iconD2: "ICON-D2 2 km"
        case .iconEU: "ICON-EU 7 km"
        case .global: "global model"
        }
    }

    /// The names the data server uses.
    init?(serverName: String) {
        switch serverName {
        case "icon2I": self = .icon2I
        case "iconD2": self = .iconD2
        case "iconEU": self = .iconEU
        case "global": self = .global
        default: return nil
        }
    }
}

/// Hourly forecast for one point on the route.
struct ForecastSeries {
    var coordinate: CLLocationCoordinate2D
    var distanceAlong: Double
    var times: [Date]
    var windSpeed: [Double?]
    var windFrom: [Double?]
    var gust: [Double?]
    var waveHeight: [Double?]
    var currentSpeed: [Double?]
    var currentToward: [Double?]
    /// Which model supplied the wind for each hour.
    var windModel: [WindModel?] = []
    // Extras from the data server, for the weather summary (empty when unavailable).
    var airTemp: [Double?] = []
    var seaTemp: [Double?] = []
    var pressure: [Double?] = []
    var wavePeriod: [Double?] = []
    var precipitation: [Double?] = []

    /// One of the extra series, interpolated at `date`.
    func value(_ values: [Double?], at date: Date) -> Double? {
        guard let first = times.first, times.count > 1, values.count == times.count else { return nil }
        let step = times[1].timeIntervalSince(first)
        let position = min(max(date.timeIntervalSince(first) / step, 0), Double(times.count - 1))
        let i = min(Int(position), times.count - 2)
        let t = position - Double(i)
        switch (values[i], values[i + 1]) {
        case let (a?, b?): return a + (b - a) * t
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    func conditions(at date: Date) -> Conditions {
        guard let first = times.first, let last = times.last, times.count > 1 else { return .calm }
        let clamped = min(max(date, first), last)
        let step = times[1].timeIntervalSince(first)
        let position = clamped.timeIntervalSince(first) / step
        let i = min(Int(position), times.count - 2)
        let t = position - Double(i)

        func value(_ values: [Double?], _ k: Int) -> Double? { k < values.count ? values[k] : nil }
        func scalar(_ values: [Double?]) -> Double? {
            switch (value(values, i), value(values, i + 1)) {
            case let (a?, b?): a + (b - a) * t
            case let (a?, nil): a
            case let (nil, b?): b
            default: nil
            }
        }
        /// Interpolates a speed/direction pair as a vector so 350° → 10° doesn't swing through south.
        func vector(_ speeds: [Double?], _ directions: [Double?]) -> (Double, Double) {
            func uv(_ k: Int) -> (Double, Double)? {
                guard let s = value(speeds, k), let d = value(directions, k) else { return nil }
                return (s * sin(d.radians), s * cos(d.radians))
            }
            let a = uv(i) ?? uv(i + 1) ?? (0, 0), b = uv(i + 1) ?? a
            let u = a.0 + (b.0 - a.0) * t, v = a.1 + (b.1 - a.1) * t
            return (hypot(u, v), Geo.normalize(atan2(u, v).degrees))
        }

        let wind = vector(windSpeed, windFrom)
        let current = vector(currentSpeed, currentToward)
        return Conditions(
            windSpeed: wind.0, windFrom: wind.1,
            gust: scalar(gust) ?? wind.0,
            waveHeight: scalar(waveHeight),
            currentSpeed: current.0, currentToward: current.1
        )
    }
}

/// Forecast sampled at points along a route; looked up by distance along the route.
struct RouteForecast {
    var points: [ForecastSeries]
    var fetchedAt: Date
    /// Where it came from, e.g. "seadata.ringtwo.win".
    var source = ""

    var validUntil: Date { points.compactMap { $0.times.last }.min() ?? fetchedAt }

    /// The wind models used over a time span, e.g. [(ICON-2I, until Mon 08:00), (ICON-EU, until Wed 00:00)].
    func windModels(from start: Date, to end: Date) -> [(model: WindModel, until: Date)] {
        guard let series = points.first else { return [] }
        var runs: [(WindModel, Date)] = []
        for (time, model) in zip(series.times, series.windModel) where time >= start.addingTimeInterval(-3600) && time <= end.addingTimeInterval(3600) {
            guard let model else { continue }
            if runs.last?.0 == model { runs[runs.count - 1].1 = time } else { runs.append((model, time)) }
        }
        return runs.map { (model: $0.0, until: $0.1) }
    }

    func conditions(alongNM distance: Double, at date: Date) -> Conditions {
        guard let nearest = points.min(by: { abs($0.distanceAlong - distance) < abs($1.distanceAlong - distance) }) else { return .calm }
        return nearest.conditions(at: date)
    }
}

/// Forecasts along a route: from the data server (wind from the finest model per hour, waves,
/// currents including tidal streams, weather), or straight from Open-Meteo if the server can't be reached.
struct MarineWeatherService {
    enum Failure: LocalizedError {
        case badResponse
        var errorDescription: String? { "The forecast service returned an unexpected response." }
    }

    func forecast(along route: [CLLocationCoordinate2D]) async throws -> RouteForecast {
        let total = Geo.length(of: route)
        let count = min(14, max(2, Int(total / 4) + 2))
        let samples: [(CLLocationCoordinate2D, Double)] = (0..<count).compactMap { i in
            let d = total * Double(i) / Double(count - 1)
            return Geo.point(along: route, distance: d).map { ($0, d) }
        }
        let server = Seadata.current
        do {
            return try await fromServer(server, samples)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            var forecast = try await direct(samples)
            forecast.source = "Open-Meteo direct (\(server.displayName) unreachable)"
            return forecast
        }
    }

    private func fromServer(_ server: Seadata, _ samples: [(CLLocationCoordinate2D, Double)]) async throws -> RouteForecast {
        let response = try await server.forecast(at: samples.map { $0.0 })
        guard response.points.count == samples.count else { throw Failure.badResponse }
        let points = zip(samples, response.points).map { sample, p in
            ForecastSeries(
                coordinate: sample.0,
                distanceAlong: sample.1,
                times: p.times.map { Date(timeIntervalSince1970: $0) },
                windSpeed: p.windSpeed,
                windFrom: p.windFrom,
                gust: p.gust,
                waveHeight: p.waveHeight ?? [],
                currentSpeed: p.currentSpeed ?? [],
                currentToward: p.currentToward ?? [],
                windModel: p.windModel.map { $0.flatMap(WindModel.init(serverName:)) },
                airTemp: p.airTemp ?? [],
                seaTemp: p.seaTemp ?? [],
                pressure: p.pressure ?? [],
                wavePeriod: p.wavePeriod ?? [],
                precipitation: p.precipitation ?? []
            )
        }
        return RouteForecast(points: points, fetchedAt: .now, source: server.displayName)
    }

    /// Open-Meteo without the data server: wind from the weather API, waves and currents from the marine API.
    private func direct(_ samples: [(CLLocationCoordinate2D, Double)]) async throws -> RouteForecast {
        let lats = samples.map { String(format: "%.4f", $0.0.latitude) }.joined(separator: ",")
        let lons = samples.map { String(format: "%.4f", $0.0.longitude) }.joined(separator: ",")

        async let wind = fetch(
            "https://api.open-meteo.com/v1/forecast",
            lats, lons,
            hourly: "wind_speed_10m,wind_direction_10m,wind_gusts_10m",
            extra: [URLQueryItem(name: "wind_speed_unit", value: "kn"),
                    URLQueryItem(name: "models", value: WindModel.allCases.map(\.apiName).joined(separator: ","))]
        )
        async let marine = fetch(
            "https://marine-api.open-meteo.com/v1/marine",
            lats, lons,
            hourly: "wave_height,ocean_current_velocity,ocean_current_direction"
        )
        let (windData, marineData) = try await (wind, marine)
        let windSeries = try decodeModels(windData)
        let marineSeries = try decode(marineData)
        guard windSeries.count == samples.count else { throw Failure.badResponse }

        let points = samples.enumerated().map { index, sample in
            let w = windSeries[index]
            let m = index < marineSeries.count ? marineSeries[index].hourly : nil
            let wTimes = (w["time"] ?? []).map { $0 ?? 0 }
            let times = wTimes.map { Date(timeIntervalSince1970: $0) }
            // Per hour, take the wind from the finest model that has it.
            var speed: [Double?] = [], from: [Double?] = [], gust: [Double?] = [], source: [WindModel?] = []
            for i in wTimes.indices {
                func value(_ variable: String, _ model: WindModel) -> Double? {
                    w["\(variable)_\(model.apiName)"].flatMap { i < $0.count ? $0[i] : nil }
                }
                let model = WindModel.allCases.first { value("wind_speed_10m", $0) != nil && value("wind_direction_10m", $0) != nil }
                speed.append(model.flatMap { value("wind_speed_10m", $0) })
                from.append(model.flatMap { value("wind_direction_10m", $0) })
                gust.append(model.flatMap { value("wind_gusts_10m", $0) })
                source.append(model)
            }
            // Marine data is keyed by timestamp so the two feeds line up even if their ranges differ.
            var marineByTime: [Double: Int] = [:]
            m?.time.enumerated().forEach { marineByTime[$1] = $0 }
            func marineValue(_ values: [Double?]?, factor: Double = 1) -> [Double?] {
                wTimes.map { t in marineByTime[t].flatMap { values?[$0] }.map { $0 * factor } }
            }
            return ForecastSeries(
                coordinate: sample.0,
                distanceAlong: sample.1,
                times: times,
                windSpeed: speed,
                windFrom: from,
                gust: gust,
                waveHeight: marineValue(m?.waveHeight),
                currentSpeed: marineValue(m?.oceanCurrentVelocity, factor: 1 / 1.852), // km/h → kn
                currentToward: marineValue(m?.oceanCurrentDirection),
                windModel: source
            )
        }
        return RouteForecast(points: points, fetchedAt: .now)
    }

    private func fetch(_ base: String, _ lats: String, _ lons: String, hourly: String, extra: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(string: base)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: lats),
            URLQueryItem(name: "longitude", value: lons),
            URLQueryItem(name: "hourly", value: hourly),
            URLQueryItem(name: "forecast_days", value: "4"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "cell_selection", value: "sea"),
        ] + extra
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        return data
    }

    /// Multi-model responses suffix each variable with the model name, so read `hourly` as a dictionary.
    private func decodeModels(_ data: Data) throws -> [[String: [Double?]]] {
        struct Response: Decodable { var hourly: [String: [Double?]] }
        let decoder = JSONDecoder()
        if let many = try? decoder.decode([Response].self, from: data) { return many.map(\.hourly) }
        return [try decoder.decode(Response.self, from: data).hourly]
    }

    private func decode(_ data: Data) throws -> [OpenMeteoResponse] {
        let decoder = JSONDecoder()
        // One location comes back as an object, several as an array.
        if let many = try? decoder.decode([OpenMeteoResponse].self, from: data) { return many }
        return [try decoder.decode(OpenMeteoResponse.self, from: data)]
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Hourly: Decodable {
        var time: [Double]
        var waveHeight: [Double?]?
        var oceanCurrentVelocity: [Double?]?
        var oceanCurrentDirection: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time
            case waveHeight = "wave_height"
            case oceanCurrentVelocity = "ocean_current_velocity"
            case oceanCurrentDirection = "ocean_current_direction"
        }
    }
    var hourly: Hourly
}
