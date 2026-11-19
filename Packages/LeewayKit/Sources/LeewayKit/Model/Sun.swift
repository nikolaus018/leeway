import CoreLocation

/// Where the sun is, for the automatic day/dusk/night chart and sunrise and sunset times.
/// Low-precision formulas (about a minute of accuracy), plenty for a chart palette and a logbook.
nonisolated enum Sun {
    /// Degrees above the horizon (negative below), not corrected for refraction.
    static func elevation(at c: CLLocationCoordinate2D, date: Date) -> Double {
        let n = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
        let meanLongitude = Geo.normalize(280.460 + 0.9856474 * n)
        let anomaly = Geo.normalize(357.528 + 0.9856003 * n).radians
        let eclipticLongitude = (meanLongitude + 1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)).radians
        let obliquity = (23.439 - 0.0000004 * n).radians
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude)).degrees
        let siderealHours = (18.697374558 + 24.06570982441908 * n).truncatingRemainder(dividingBy: 24)
        let hourAngle = (siderealHours * 15 + c.longitude - rightAscension).radians
        let latitude = c.latitude.radians
        return asin(sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)).degrees
    }

    /// The palette for the light at that place and time: night below civil twilight.
    static func palette(at c: CLLocationCoordinate2D, date: Date = .now) -> ChartPalette {
        let e = elevation(at: c, date: date)
        return e > 0 ? .day : e > -6 ? .dusk : .night
    }

    struct Times: Equatable {
        var dawn: Date?
        var sunrise: Date?
        var sunset: Date?
        var dusk: Date?
    }

    /// Civil dawn, sunrise, sunset and civil dusk on the local day containing `date`.
    static func times(at c: CLLocationCoordinate2D, on date: Date, calendar: Calendar = .current) -> Times {
        let start = calendar.startOfDay(for: date)
        // Elevation every 5 minutes, then the crossings refined by interpolation.
        let step = 300.0
        var samples: [(Date, Double)] = []
        for i in 0...(86400 / Int(step)) {
            let t = start.addingTimeInterval(Double(i) * step)
            samples.append((t, elevation(at: c, date: t)))
        }
        func crossing(_ level: Double, rising: Bool) -> Date? {
            for (a, b) in zip(samples, samples.dropFirst()) where (a.1 < level) == rising && (b.1 >= level) == rising {
                let f = (level - a.1) / (b.1 - a.1)
                return a.0.addingTimeInterval(step * f)
            }
            return nil
        }
        // −0.833°: the upper limb on the horizon, with refraction.
        return Times(dawn: crossing(-6, rising: true), sunrise: crossing(-0.833, rising: true),
                     sunset: crossing(-0.833, rising: false), dusk: crossing(-6, rising: false))
    }
}
