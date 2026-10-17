import Foundation

/// A boat's polar: speed through the water by true wind angle and true wind speed, as sailmakers
/// and designers publish it (and as plotters import it, tab-separated: `twa/tws` header row of wind
/// speeds, then one row per angle).
nonisolated struct PolarTable: Codable, Equatable, Sendable {
    var name: String
    /// True wind speeds, knots, ascending.
    var windSpeeds: [Double]
    /// True wind angles, degrees, ascending (0…180).
    var angles: [Double]
    /// `speeds[angle][wind]`, knots.
    var speeds: [[Double]]

    /// Boat speed at a true wind angle and speed, interpolated in both; 0 inside the smallest angle.
    func speed(twa: Double, tws: Double) -> Double {
        let angle = min(180, abs(twa))
        guard let firstAngle = angles.first, angle >= firstAngle, !windSpeeds.isEmpty else { return 0 }
        let (a0, a1, ta) = Self.bracket(angles, angle)
        // Beyond the strongest tabulated wind, hold the last column (crews reef rather than go faster).
        let (w0, w1, tw) = tws <= windSpeeds[0]
            ? (0, 0, 0.0)
            : Self.bracket(windSpeeds, min(tws, windSpeeds[windSpeeds.count - 1]))
        func at(_ a: Int, _ w: Int) -> Double { speeds[a][w] }
        let low = at(a0, w0) + (at(a0, w1) - at(a0, w0)) * tw
        let high = at(a1, w0) + (at(a1, w1) - at(a1, w0)) * tw
        var v = low + (high - low) * ta
        // Lighter than the first column: scale down towards no wind.
        if tws < windSpeeds[0] { v *= max(0, tws / windSpeeds[0]) }
        return max(0, v)
    }

    /// The angle that makes most progress to windward at this wind speed (for tacking).
    func bestBeat(tws: Double) -> (angle: Double, speed: Double) {
        stride(from: 30.0, through: 70, by: 1).map { a in (a, speed(twa: a, tws: tws)) }
            .max { $0.1 * cos($0.0.radians) < $1.1 * cos($1.0.radians) } ?? (45, speed(twa: 45, tws: tws))
    }

    /// The angle that makes most progress downwind (for gybing).
    func bestRun(tws: Double) -> (angle: Double, speed: Double) {
        stride(from: 120.0, through: 180, by: 1).map { a in (a, speed(twa: a, tws: tws)) }
            .max { -$0.1 * cos($0.0.radians) < -$1.1 * cos($1.0.radians) } ?? (180, speed(twa: 180, tws: tws))
    }

    private static func bracket(_ values: [Double], _ x: Double) -> (Int, Int, Double) {
        guard values.count > 1 else { return (0, 0, 0) }
        for i in 1..<values.count where x <= values[i] {
            let t = (x - values[i - 1]) / max(values[i] - values[i - 1], 1e-9)
            return (i - 1, i, min(max(t, 0), 1))
        }
        return (values.count - 1, values.count - 1, 0)
    }

    // MARK: Files

    /// Reads the common plain-text polar formats: tab, semicolon or space separated, first row
    /// `TWA\TWS` (or similar) then the wind speeds, then rows of angle followed by speeds.
    static func parse(_ text: String, name: String) -> PolarTable? {
        let rows = text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: { $0 == "\t" || $0 == ";" || $0 == " " || $0 == "," }).map(String.init) }
            .filter { !$0.isEmpty }
        guard let header = rows.first else { return nil }
        let winds = header.compactMap { Double($0) }
        guard winds.count >= 2 else { return nil }
        var angles: [Double] = [], speeds: [[Double]] = []
        for row in rows.dropFirst() {
            let numbers = row.compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            guard numbers.count >= winds.count + 1, (0...180).contains(numbers[0]) else { continue }
            angles.append(numbers[0])
            speeds.append(Array(numbers[1...winds.count]))
        }
        guard angles.count >= 3 else { return nil }
        let order = angles.indices.sorted { angles[$0] < angles[$1] }
        return PolarTable(name: name, windSpeeds: winds, angles: order.map { angles[$0] }, speeds: order.map { speeds[$0] })
    }

    func export() -> String {
        var lines = ["TWA\\TWS\t" + windSpeeds.map { String(format: "%g", $0) }.joined(separator: "\t")]
        for (a, row) in zip(angles, speeds) {
            lines.append(String(format: "%g", a) + "\t" + row.map { String(format: "%.2f", $0) }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Presets

    /// Typical polars by boat type, from published designs, scaled to the hull speed.
    static let presets: [PolarTable] = [
        .typical(name: "Cruiser 30–34 ft", hull: 6.8, upwind: 0.80, light: 0.55),
        .typical(name: "Cruiser 35–40 ft", hull: 7.6, upwind: 0.82, light: 0.6),
        .typical(name: "Cruiser 41–46 ft", hull: 8.3, upwind: 0.83, light: 0.62),
        .typical(name: "Performance cruiser 38–42 ft", hull: 8.6, upwind: 0.87, light: 0.72),
        .typical(name: "Cruising catamaran 40–45 ft", hull: 9.5, upwind: 0.72, light: 0.6),
    ]

    /// A smooth, realistic polar shape: slow close-hauled, fastest on a beam to broad reach, and
    /// light-air performance as a fraction of full speed at 6 kn of wind.
    static func typical(name: String, hull: Double, upwind: Double, light: Double) -> PolarTable {
        let winds: [Double] = [6, 8, 10, 12, 14, 16, 20, 25]
        let angles: [Double] = [40, 45, 52, 60, 75, 90, 110, 120, 135, 150, 165, 180]
        let shape: [Double] = [0.66, 0.74, 0.80, 0.86, 0.93, 0.97, 1.0, 0.99, 0.94, 0.86, 0.79, 0.74]
        let speeds = zip(angles, shape).map { angle, s in
            winds.map { tws in
                // Rises with wind towards hull speed, sooner off the wind; upwind capped lower.
                let ramp = light + (1 - light) * min(1, (tws - 6) / (angle < 70 ? 12 : 9))
                let cap = angle < 70 ? upwind + (1 - upwind) * (angle - 40) / 30 : 1.0
                return (hull * s * ramp * cap * 100).rounded() / 100
            }
        }
        return PolarTable(name: name, windSpeeds: winds, angles: angles, speeds: speeds)
    }
}
