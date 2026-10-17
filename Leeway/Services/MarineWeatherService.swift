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

    var validUntil: Date { points.compactMap { $0.times.last }.min() ?? fetchedAt }

    func conditions(alongNM distance: Double, at date: Date) -> Conditions {
        guard let nearest = points.min(by: { abs($0.distanceAlong - distance) < abs($1.distanceAlong - distance) }) else { return .calm }
        return nearest.conditions(at: date)
    }
}

/// Free, keyless forecasts from Open-Meteo: wind from the weather API, waves and
/// currents (including tidal streams) from the marine API.
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
        let lats = samples.map { String(format: "%.4f", $0.0.latitude) }.joined(separator: ",")
        let lons = samples.map { String(format: "%.4f", $0.0.longitude) }.joined(separator: ",")

        async let wind = fetch(
            "https://api.open-meteo.com/v1/forecast",
            lats, lons,
            hourly: "wind_speed_10m,wind_direction_10m,wind_gusts_10m",
            extra: [URLQueryItem(name: "wind_speed_unit", value: "kn")]
        )
        async let marine = fetch(
            "https://marine-api.open-meteo.com/v1/marine",
            lats, lons,
            hourly: "wave_height,ocean_current_velocity,ocean_current_direction"
        )
        let (windData, marineData) = try await (wind, marine)
        let windSeries = try decode(windData)
        let marineSeries = try decode(marineData)
        guard windSeries.count == samples.count else { throw Failure.badResponse }

        let points = samples.enumerated().map { index, sample in
            let w = windSeries[index].hourly
            let m = index < marineSeries.count ? marineSeries[index].hourly : nil
            let times = w.time.map { Date(timeIntervalSince1970: $0) }
            // Marine data is keyed by timestamp so the two feeds line up even if their ranges differ.
            var marineByTime: [Double: Int] = [:]
            m?.time.enumerated().forEach { marineByTime[$1] = $0 }
            func marineValue(_ values: [Double?]?, factor: Double = 1) -> [Double?] {
                w.time.map { t in marineByTime[t].flatMap { values?[$0] }.map { $0 * factor } }
            }
            return ForecastSeries(
                coordinate: sample.0,
                distanceAlong: sample.1,
                times: times,
                windSpeed: w.windSpeed10m ?? [],
                windFrom: w.windDirection10m ?? [],
                gust: w.windGusts10m ?? [],
                waveHeight: marineValue(m?.waveHeight),
                currentSpeed: marineValue(m?.oceanCurrentVelocity, factor: 1 / 1.852), // km/h → kn
                currentToward: marineValue(m?.oceanCurrentDirection)
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
        var windSpeed10m: [Double?]?
        var windDirection10m: [Double?]?
        var windGusts10m: [Double?]?
        var waveHeight: [Double?]?
        var oceanCurrentVelocity: [Double?]?
        var oceanCurrentDirection: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time
            case windSpeed10m = "wind_speed_10m"
            case windDirection10m = "wind_direction_10m"
            case windGusts10m = "wind_gusts_10m"
            case waveHeight = "wave_height"
            case oceanCurrentVelocity = "ocean_current_velocity"
            case oceanCurrentDirection = "ocean_current_direction"
        }
    }
    var hourly: Hourly
}
