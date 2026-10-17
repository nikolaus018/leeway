import CoreLocation
import SwiftUI

/// Wind at one grid point at the chosen hour.
struct WindArrow: Equatable {
    var latitude: Double
    var longitude: Double
    var speed: Double
    var from: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// A ship on the map; `danger` when it will pass close to us soon.
struct VesselMarker: Equatable {
    var vessel: Vessel
    var danger: Bool

    /// Hull colour by kind of ship, as on a plotter's AIS layer.
    var colour: String {
        switch vessel.category {
        case .sailing, .pleasure: "#8E44D9"
        case .passenger, .highSpeed: "#1E6FD9"
        case .cargo: "#2E9E4F"
        case .tanker: "#9A6A3A"
        case .fishing: "#F08A1C"
        case .service: "#1FA3A3"
        case .other: "#7A7F8A"
        }
    }
}

/// Course and distance of a leg, shown at its midpoint.
struct LegAnnotationData: Equatable {
    var text: String
    var latitude: Double
    var longitude: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// What the map draws for underway mode, compared each update so sources only change when needed.
struct UnderwayMapState: Equatable {
    struct Point: Equatable {
        var latitude: Double
        var longitude: Double
        init(_ c: CLLocationCoordinate2D) { latitude = c.latitude; longitude = c.longitude }
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }
    var boat: Point?
    var cog: Double?
    var sog: Double?
    var activeLeg: [Point] = []
    /// The rest of the route after the active leg.
    var ahead: [Point] = []
    var next: Point?
    var mob: Point?
    var anchor: Point?
    var anchorRadius = 0.0
    var anchorAlarm = false
    var swing: [Point] = []
}

enum WindScale {
    static func color(_ knots: Double) -> Color { Color(uiColor: uiColor(knots)) }

    static func uiColor(_ knots: Double) -> UIColor {
        switch knots {
        case ..<6: .systemTeal
        case ..<12: .systemGreen
        case ..<18: .systemYellow
        case ..<24: .systemOrange
        case ..<30: .systemRed
        default: .systemPurple
        }
    }
}

/// Latitude/longitude grid spacing and labels.
nonisolated enum Graticule {
    /// Grid spacing in minutes of arc giving lines roughly 150+ points apart.
    static func step(pointsPerDegree: Double) -> Double {
        [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300].first { pointsPerDegree * $0 / 60 > 150 } ?? 300
    }

    static func format(_ value: Double, positive: String, negative: String, step minutes: Double) -> String {
        let v = abs(value)
        var degrees = Int(v.rounded(.down))
        var mins = (v - Double(degrees)) * 60
        if mins > 59.95 { degrees += 1; mins = 0 }
        let minuteText = minutes < 1 ? String(format: "%04.1f", mins) : String(format: "%02.0f", mins.rounded())
        return "\(degrees)°\(minuteText)′\(value >= 0 ? positive : negative)"
    }
}
