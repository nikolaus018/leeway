import CoreLocation

/// Forecast wind over an area and time, from the data server's wind grid, for weather routing.
nonisolated struct WindField: Sendable {
    private let lat0, lon0, step: Double
    private let rows, cols: Int
    private let times: [Double]
    /// Per hour, per grid node: the wind as an east/north vector of where it blows *from*, knots.
    private let u: [[Float]]
    private let v: [[Float]]

    init?(_ grid: WindGrid) {
        guard !grid.points.isEmpty, !grid.times.isEmpty, grid.step > 0 else { return nil }
        let lats = grid.points.map(\.lat), lons = grid.points.map(\.lon)
        lat0 = lats.min()!; lon0 = lons.min()!; step = grid.step
        rows = Int(((lats.max()! - lat0) / step).rounded()) + 1
        cols = Int(((lons.max()! - lon0) / step).rounded()) + 1
        // A corridor is small; refuse a grid so big that a wrong answer from the server could eat the memory.
        guard rows > 0, cols > 0, rows * cols * grid.times.count <= 4_000_000 else { return nil }
        times = grid.times
        var u = [[Float]](repeating: [Float](repeating: .nan, count: rows * cols), count: times.count)
        var v = u
        for p in grid.points {
            let r = Int(((p.lat - lat0) / step).rounded()), c = Int(((p.lon - lon0) / step).rounded())
            guard r >= 0, r < rows, c >= 0, c < cols else { continue }
            for h in times.indices where h < p.windSpeed.count && h < p.windFrom.count {
                guard let s = p.windSpeed[h], let from = p.windFrom[h] else { continue }
                u[h][r * cols + c] = Float(s * sin(from.radians))
                v[h][r * cols + c] = Float(s * cos(from.radians))
            }
        }
        self.u = u
        self.v = v
    }

    var end: Date { Date(timeIntervalSince1970: times.last ?? 0) }

    /// Wind speed (kn) and direction it blows from (°T), interpolated in space and time.
    func wind(at c: CLLocationCoordinate2D, time: Date) -> (speed: Double, from: Double)? {
        let t = time.timeIntervalSince1970
        let h1 = times.firstIndex { $0 >= t } ?? times.count - 1
        let h0 = max(0, h1 - 1)
        let f = h1 == h0 ? 0 : min(1, max(0, (t - times[h0]) / (times[h1] - times[h0])))
        guard let a = sample(h0, c), let b = sample(h1, c) else { return nil }
        let x = a.0 + (b.0 - a.0) * f, y = a.1 + (b.1 - a.1) * f
        return (hypot(x, y), Geo.normalize(atan2(x, y).degrees))
    }

    private func sample(_ h: Int, _ c: CLLocationCoordinate2D) -> (Double, Double)? {
        let y = min(max((c.latitude - lat0) / step, 0), Double(rows - 1))
        let x = min(max((c.longitude - lon0) / step, 0), Double(cols - 1))
        let r0 = Int(y), c0 = Int(x), r1 = min(r0 + 1, rows - 1), c1 = min(c0 + 1, cols - 1)
        let fy = y - Double(r0), fx = x - Double(c0)
        var su = 0.0, sv = 0.0, weight = 0.0
        for (r, cc, w) in [(r0, c0, (1 - fx) * (1 - fy)), (r0, c1, fx * (1 - fy)), (r1, c0, (1 - fx) * fy), (r1, c1, fx * fy)] {
            let i = r * cols + cc
            guard !u[h][i].isNaN, w > 0 else { continue }
            su += Double(u[h][i]) * w
            sv += Double(v[h][i]) * w
            weight += w
        }
        return weight > 0 ? (su / weight, sv / weight) : nil
    }
}

/// The fastest route by sail, by isochrones: from the start, fan out headings every time step,
/// sail each with the polar in the forecast wind, keep the furthest point in each direction, and
/// repeat until the finish is within reach. Steps that would cross land, shallows or a charted
/// danger are dropped, so the result is as safe as the shortest route.
nonisolated enum WeatherRouter {
    struct Result: Sendable {
        var path: [CLLocationCoordinate2D]
        var arrival: Date
        var tacks: Int
    }

    enum Failure: LocalizedError {
        case noWind, noWay

        var errorDescription: String? {
            switch self {
            case .noWind: "No wind forecast for this passage."
            case .noWay: "No faster way found within the forecast."
            }
        }
    }

    private struct Node {
        var coordinate: CLLocationCoordinate2D
        var time: Date
        var parent: Int
        var heading: Double
    }

    /// Routes from `start` to `goal`, both in navigable water on `grid`.
    static func route(from start: CLLocationCoordinate2D, to goal: CLLocationCoordinate2D, departure: Date,
                      boat: BoatProfile, wind: WindField, grid: RoutingGrid) throws -> Result {
        let direct = Geo.distanceNM(start, goal)
        guard direct > 0.05 else { return Result(path: [start, goal], arrival: departure, tacks: 0) }
        // About 30 steps for the passage, between 6 minutes and an hour each.
        let typical = boat.propulsion == .motor ? boat.motorSpeed : max(3, boat.sailSpeed * 0.7)
        let dt = min(1, max(0.1, direct / typical / 30))
        let headings = stride(from: 0.0, to: 360, by: 5).map { $0 }
        let sectors = 180

        var nodes = [Node(coordinate: start, time: departure, parent: -1, heading: 0)]
        var front = [0]
        var best: (node: Int, arrival: Date)?
        let horizon = departure.addingTimeInterval(min(direct / 1.5, 120) * 3600)

        for _ in 0..<400 {
            // Can the finish be reached from here within one step?
            for i in front {
                let node = nodes[i]
                let distance = Geo.distanceNM(node.coordinate, goal)
                let speed = boatSpeed(heading: Geo.bearing(node.coordinate, goal),
                                      wind: wind.wind(at: node.coordinate, time: node.time), boat: boat)
                guard speed > 0.1, distance <= speed * dt * 1.0001, grid.isClear(node.coordinate, goal) else { continue }
                let arrival = node.time.addingTimeInterval(distance / speed * 3600)
                if best.map({ arrival < $0.arrival }) ?? true { best = (i, arrival) }
            }
            if best != nil { break }

            // Expand the front, keep the furthest point per direction from the start.
            var keep = [Int: (node: Node, reach: Double)]()
            for i in front {
                let node = nodes[i]
                // The wind is the same on every heading from here: look it up once.
                let here = wind.wind(at: node.coordinate, time: node.time)
                for heading in headings {
                    let speed = boatSpeed(heading: heading, wind: here, boat: boat)
                    guard speed > 0.1 else { continue }
                    let next = Geo.destination(from: node.coordinate, bearing: heading, distanceNM: speed * dt)
                    // Don't fan out far beyond the finish.
                    guard Geo.distanceNM(next, goal) < direct * 1.3 + 2, grid.isClear(node.coordinate, next) else { continue }
                    let reach = Geo.distanceNM(start, next) - 0.3 * Geo.distanceNM(next, goal)
                    let sector = Int(Geo.bearing(start, next) / 360 * Double(sectors)) % sectors
                    if keep[sector].map({ reach > $0.reach }) ?? true {
                        keep[sector] = (Node(coordinate: next, time: node.time.addingTimeInterval(dt * 3600), parent: i, heading: heading), reach)
                    }
                }
            }
            guard !keep.isEmpty else { throw Failure.noWay }
            front = keep.values.map { candidate in
                nodes.append(candidate.node)
                return nodes.count - 1
            }
            if let time = nodes.last?.time, time > horizon { throw Failure.noWay }
        }
        guard let best else { throw Failure.noWay }

        var path = [goal]
        var i = best.node
        while i >= 0 {
            path.append(nodes[i].coordinate)
            i = nodes[i].parent
        }
        path.reverse()
        let simplified = simplify(path, grid: grid)
        return Result(path: simplified, arrival: best.arrival, tacks: tacks(in: simplified))
    }

    /// Boat speed on a heading from a node: under sail by the polar, or motoring when that's faster
    /// than the engine threshold allows.
    private static func boatSpeed(heading: Double, wind w: (speed: Double, from: Double)?, boat: BoatProfile) -> Double {
        if boat.propulsion == .motor { return boat.motorSpeed }
        guard let w else { return boat.motorSpeed }
        let twa = abs(Geo.angleDiff(w.from, heading))
        // Motor when sailing the course (tacking included) is too slow, as the passage simulator does.
        // Otherwise the heading is sailed as is: 0 inside the no-go zone, so the router must tack.
        let along = Polar.speedAlongCourse(twa: twa, tws: w.speed, boat: boat).speed
        return along < boat.motorThreshold ? boat.motorSpeed : Polar.speed(twa: twa, tws: w.speed, boat: boat)
    }

    /// Merges runs of nearly the same heading into one leg, where the straight line stays clear.
    private static func simplify(_ path: [CLLocationCoordinate2D], grid: RoutingGrid) -> [CLLocationCoordinate2D] {
        guard path.count > 2 else { return path }
        var out = [path[0]]
        var anchor = 0
        for i in 1..<(path.count - 1) {
            let legHeading = Geo.bearing(path[anchor], path[i])
            let nextHeading = Geo.bearing(path[i], path[i + 1])
            if abs(Geo.angleDiff(legHeading, nextHeading)) > 8 || !grid.isClear(path[anchor], path[i + 1]) {
                out.append(path[i])
                anchor = i
            }
        }
        out.append(path[path.count - 1])
        return out
    }

    /// Turns through the wind: legs whose courses differ by more than 60°.
    private static func tacks(in path: [CLLocationCoordinate2D]) -> Int {
        guard path.count > 2 else { return 0 }
        return (1..<(path.count - 1)).filter { i in
            abs(Geo.angleDiff(Geo.bearing(path[i - 1], path[i]), Geo.bearing(path[i], path[i + 1]))) > 60
        }.count
    }
}

nonisolated extension RoutingGrid {
    /// The straight line between two points stays in navigable water (deep enough, clear of
    /// charted dangers), checked every half cell.
    func isClear(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        let pa = gridPoint(a), pb = gridPoint(b)
        let cells = max(abs(pb.x - pa.x), abs(pb.y - pa.y))
        let steps = max(1, Int((cells * 2).rounded(.up)))
        for k in 0...steps {
            let f = Double(k) / Double(steps)
            let p = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                           longitude: a.longitude + (b.longitude - a.longitude) * f)
            guard let i = index(of: p), isNavigable(i) else { return false }
        }
        return true
    }
}
