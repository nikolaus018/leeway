import Foundation

/// A generic cruising-yacht polar, scaled by the boat's best sailing speed.
/// Good enough for passage timing; swap for a real polar table later.
nonisolated enum Polar {
    /// Smallest true wind angle the boat can point at.
    static let noGoAngle = 42.0
    private static let beatAngle = 45.0

    private static let angles: [Double] = [0, 30, 42, 52, 60, 75, 90, 110, 120, 135, 150, 165, 180]
    private static let ratios: [Double] = [0, 0, 0.62, 0.76, 0.83, 0.91, 0.96, 1.0, 0.98, 0.92, 0.83, 0.75, 0.70]

    /// Boat speed through the water at a true wind angle (0...180) and true wind speed in knots.
    static func speed(twa: Double, tws: Double, best: Double) -> Double {
        guard tws > 0.5 else { return 0 }
        let windFactor = min(1, pow(tws / 16, 0.55))
        let reef = tws > 25 ? max(0.75, 1 - (tws - 25) * 0.02) : 1
        return best * interpolate(abs(twa)) * windFactor * reef
    }

    /// Speed made good along a course that lies `twa` off the wind, tacking if it's inside the no-go zone.
    static func speedAlongCourse(twa: Double, tws: Double, best: Double) -> (speed: Double, tacking: Bool) {
        let angle = abs(twa)
        guard angle < noGoAngle else { return (speed(twa: angle, tws: tws, best: best), false) }
        // Alternating tacks at ±45° to the wind: progress = V·cos45 / cos(twa).
        let v = speed(twa: beatAngle, tws: tws, best: best)
        return (v * cos(beatAngle.radians) / cos(angle.radians), true)
    }

    /// The boat's speed: its own polar when it has one.
    static func speed(twa: Double, tws: Double, boat: BoatProfile) -> Double {
        if let table = boat.polar { return table.speed(twa: twa, tws: tws) }
        return speed(twa: twa, tws: tws, best: boat.sailSpeed)
    }

    /// Progress along a course `twa` off the wind, tacking upwind (and gybing downwind with a real
    /// polar) when sailing straight at it is slower.
    static func speedAlongCourse(twa: Double, tws: Double, boat: BoatProfile) -> (speed: Double, tacking: Bool) {
        guard let table = boat.polar else { return speedAlongCourse(twa: twa, tws: tws, best: boat.sailSpeed) }
        let angle = abs(twa)
        let beat = table.bestBeat(tws: tws)
        if angle < beat.angle {
            return (beat.speed * cos(beat.angle.radians) / max(cos(angle.radians), 0.05), true)
        }
        let run = table.bestRun(tws: tws)
        if angle > run.angle {
            return (run.speed * cos((180 - run.angle).radians) / max(cos((180 - angle).radians), 0.05), true)
        }
        return (table.speed(twa: angle, tws: tws), false)
    }

    static func pointOfSail(twa: Double) -> String {
        switch abs(twa) {
        case ..<noGoAngle: "Beating"
        case ..<60: "Close-hauled"
        case ..<80: "Close reach"
        case ..<110: "Beam reach"
        case ..<150: "Broad reach"
        default: "Running"
        }
    }

    private static func interpolate(_ angle: Double) -> Double {
        for i in 1..<angles.count where angle <= angles[i] {
            let t = (angle - angles[i - 1]) / (angles[i] - angles[i - 1])
            return ratios[i - 1] + t * (ratios[i] - ratios[i - 1])
        }
        return ratios.last!
    }
}
