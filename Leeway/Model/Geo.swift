import CoreLocation

/// Spherical-earth navigation maths. Distances in nautical miles, angles in degrees true.
nonisolated enum Geo {
    static let earthRadiusNM = 3440.065

    static func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude.radians, φ2 = b.latitude.radians
        let dφ = φ2 - φ1, dλ = (b.longitude - a.longitude).radians
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadiusNM * asin(min(1, sqrt(h)))
    }

    /// Initial great-circle bearing from `a` to `b`, 0..<360.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude.radians, φ2 = b.latitude.radians
        let dλ = (b.longitude - a.longitude).radians
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return normalize(atan2(y, x).degrees)
    }

    /// Point a fraction of the way along the great circle from `a` to `b`.
    static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, fraction f: Double) -> CLLocationCoordinate2D {
        let δ = distanceNM(a, b) / earthRadiusNM
        guard δ > 1e-9 else { return a }
        let φ1 = a.latitude.radians, λ1 = a.longitude.radians
        let φ2 = b.latitude.radians, λ2 = b.longitude.radians
        let A = sin((1 - f) * δ) / sin(δ), B = sin(f * δ) / sin(δ)
        let x = A * cos(φ1) * cos(λ1) + B * cos(φ2) * cos(λ2)
        let y = A * cos(φ1) * sin(λ1) + B * cos(φ2) * sin(λ2)
        let z = A * sin(φ1) + B * sin(φ2)
        return CLLocationCoordinate2D(latitude: atan2(z, sqrt(x * x + y * y)).degrees, longitude: atan2(y, x).degrees)
    }

    /// Point at `distance` NM along a polyline (clamped to its ends).
    static func point(along path: [CLLocationCoordinate2D], distance: Double) -> CLLocationCoordinate2D? {
        guard var previous = path.first else { return nil }
        var remaining = max(0, distance)
        for next in path.dropFirst() {
            let leg = distanceNM(previous, next)
            if remaining <= leg, leg > 0 { return interpolate(previous, next, fraction: remaining / leg) }
            remaining -= leg
            previous = next
        }
        return previous
    }

    /// Point reached from `start` on an initial bearing after `distanceNM`.
    static func destination(from start: CLLocationCoordinate2D, bearing: Double, distanceNM: Double) -> CLLocationCoordinate2D {
        let δ = distanceNM / earthRadiusNM, θ = bearing.radians
        let φ1 = start.latitude.radians, λ1 = start.longitude.radians
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return CLLocationCoordinate2D(latitude: φ2.degrees, longitude: λ2.degrees)
    }

    static func length(of path: [CLLocationCoordinate2D]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + distanceNM($1.0, $1.1) }
    }

    static func normalize(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// Signed smallest difference `a - b`, in -180...180.
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    static func compassPoint(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return points[Int((normalize(degrees) / 22.5).rounded()) % 16]
    }
}

nonisolated extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
