import CoreLocation

/// A charted danger the boat must keep clear of, as a no-go disc.
nonisolated struct Danger: Sendable {
    var center: CLLocationCoordinate2D
    /// Radius of the no-go disc in metres.
    var radius: Double
    var label: String

    /// Rocks, wrecks and obstructions that could touch the keel, plus the dangers that
    /// isolated-danger and cardinal marks point at.
    static func all(in region: ChartRegion, safetyDepth: Double) -> [Danger] {
        region.seamarks.compactMap { mark in
            switch mark.type {
            case "rock", "wreck", "obstruction":
                // Charted with enough water over it: no danger to this boat.
                if let depth = mark.depthMetres, depth >= safetyDepth + 1 { return nil }
                let level = mark.waterLevel.map { " (\($0.replacingOccurrences(of: "-", with: " ")))" } ?? ""
                return Danger(center: mark.coordinate, radius: mark.type == "rock" ? 60 : 50, label: "\(mark.type)\(level)")
            case "buoy_isolated_danger", "beacon_isolated_danger":
                return Danger(center: mark.coordinate, radius: 60, label: "isolated danger mark")
            case "buoy_cardinal", "beacon_cardinal":
                // A north cardinal says "pass to the north": the danger lies to its south, and so on.
                let toDanger: Double? = switch mark.category {
                case "north": 180
                case "east": 270
                case "south": 0
                case "west": 90
                default: nil
                }
                guard let toDanger else { return nil }
                return Danger(center: Geo.destination(from: mark.coordinate, bearing: toDanger, distanceNM: 70 / 1852),
                              radius: 60, label: "danger marked by a \(mark.category ?? "") cardinal")
            default:
                return nil
            }
        }
    }
}

/// The boat-specific limits a route is checked against.
nonisolated struct NavigationRules: Sendable {
    let region: ChartRegion
    let safetyDepth: Double
    let airDraft: Double
    let dangers: [Danger]

    init(region: ChartRegion, safetyDepth: Double, airDraft: Double) {
        self.region = region
        self.safetyDepth = safetyDepth
        self.airDraft = airDraft
        dangers = Danger.all(in: region, safetyDepth: safetyDepth)
    }
}

/// Where the boat may go for a given safety depth and air draft, plus how far each cell is from danger.
nonisolated final class RoutingGrid: Sendable {
    /// Cells of clearance beyond which there's no penalty (~4 × 67 m).
    static let maxClearance: UInt8 = 4
    /// Extra headroom wanted under a bridge, metres.
    static let bridgeMargin = 1.0

    let rules: NavigationRules
    var region: ChartRegion { rules.region }
    /// Water cells closed by a charted danger or a bridge that's too low.
    let blocked: [Bool]
    /// Distance in cells to the nearest land or too-shallow cell, capped. 0 = not navigable.
    let clearance: [UInt8]
    /// Connected safe-water areas (4-connected); -1 = not navigable.
    let component: [Int32]
    /// The largest connected area — the open sea.
    let seaComponent: Int32

    init(rules: NavigationRules) {
        self.rules = rules
        let region = rules.region, safetyDepth = rules.safetyDepth, airDraft = rules.airDraft
        let minimumCode = UInt8(min(250, (safetyDepth * 2).rounded(.up)))
        let rows = region.rows, cols = region.cols

        var closed = [Bool](repeating: false, count: rows * cols)
        for danger in rules.dangers {
            let p = region.gridPoint(danger.center)
            let rx = danger.radius / (region.cellNM.dx * 1852), ry = danger.radius / (region.cellNM.dy * 1852)
            for r in max(0, Int(p.y - ry))...min(rows - 1, Int(p.y + ry)) {
                for c in max(0, Int(p.x - rx))...min(cols - 1, Int(p.x + rx)) {
                    let nx = (Double(c) + 0.5 - p.x) / rx, ny = (Double(r) + 0.5 - p.y) / ry
                    if nx * nx + ny * ny <= 1 || (r == Int(p.y) && c == Int(p.x)) { closed[r * cols + c] = true }
                }
            }
        }
        for bridge in region.bridges {
            guard let height = bridge.clearance, height < airDraft + Self.bridgeMargin else { continue }
            for (a, b) in zip(bridge.coordinates, bridge.coordinates.dropFirst()) {
                let p = region.gridPoint(a), q = region.gridPoint(b)
                let steps = max(1, Int((hypot(q.x - p.x, q.y - p.y) / 0.25).rounded(.up)))
                for s in 0...steps {
                    let t = Double(s) / Double(steps)
                    let x = Int(p.x + (q.x - p.x) * t), y = Int(p.y + (q.y - p.y) * t)
                    if x >= 0, y >= 0, x < cols, y < rows { closed[y * cols + x] = true }
                }
            }
        }
        blocked = closed

        var d = [UInt8](repeating: 0, count: rows * cols)
        for i in 0..<(rows * cols) {
            let code = region.grid[i]
            d[i] = code == ChartRegion.landCode || code < minimumCode || closed[i] ? 0 : Self.maxClearance
        }
        // Two-pass chamfer distance (chessboard metric).
        d.withUnsafeMutableBufferPointer { d in
            for r in 0..<rows {
                for c in 0..<cols {
                    let i = r * cols + c
                    var v = d[i]
                    if v == 0 { continue }
                    if c > 0 { v = min(v, d[i - 1] &+ 1) }
                    if r > 0 {
                        v = min(v, d[i - cols] &+ 1)
                        if c > 0 { v = min(v, d[i - cols - 1] &+ 1) }
                        if c < cols - 1 { v = min(v, d[i - cols + 1] &+ 1) }
                    }
                    d[i] = v
                }
            }
            for r in stride(from: rows - 1, through: 0, by: -1) {
                for c in stride(from: cols - 1, through: 0, by: -1) {
                    let i = r * cols + c
                    var v = d[i]
                    if v == 0 { continue }
                    if c < cols - 1 { v = min(v, d[i + 1] &+ 1) }
                    if r < rows - 1 {
                        v = min(v, d[i + cols] &+ 1)
                        if c < cols - 1 { v = min(v, d[i + cols + 1] &+ 1) }
                        if c > 0 { v = min(v, d[i + cols - 1] &+ 1) }
                    }
                    d[i] = v
                }
            }
        }
        clearance = d

        var labels = [Int32](repeating: -1, count: rows * cols)
        var sizes: [Int] = []
        var stack: [Int] = []
        for seed in 0..<(rows * cols) where d[seed] > 0 && labels[seed] < 0 {
            let label = Int32(sizes.count)
            var size = 0
            labels[seed] = label
            stack.append(seed)
            while let i = stack.popLast() {
                size += 1
                let r = i / cols, c = i % cols
                for n in [r > 0 ? i - cols : -1, r < rows - 1 ? i + cols : -1, c > 0 ? i - 1 : -1, c < cols - 1 ? i + 1 : -1]
                where n >= 0 && d[n] > 0 && labels[n] < 0 {
                    labels[n] = label
                    stack.append(n)
                }
            }
            sizes.append(size)
        }
        component = labels
        seaComponent = Int32(sizes.indices.max { sizes[$0] < sizes[$1] } ?? 0)
    }

    func isNavigable(_ i: Int) -> Bool { clearance[i] > 0 }
    /// Water the boat can creep through at low speed (shallow is allowed, dangers and low bridges aren't).
    func isPassable(_ i: Int) -> Bool { region.grid[i] != ChartRegion.landCode && !blocked[i] }
    func isOpenWater(_ i: Int) -> Bool { component[i] == seaComponent }
}

/// Automatic routing: shortest safe-water path between waypoints (A* on the depth grid,
/// biased away from land and shallows), then straightened into a few courses to steer.
nonisolated enum Router {
    enum Failure: LocalizedError {
        case outsideChart
        case noSafeWater(near: Int)
        case noPassage(leg: Int)

        var errorDescription: String? {
            switch self {
            case .outsideChart: "Automatic routing only works inside a downloaded chart area."
            case .noSafeWater(let i): "No water deep enough near waypoint \(i + 1)."
            case .noPassage(let leg): "No safe passage found for leg \(leg + 1) at this draft."
            }
        }
    }

    struct Result: Sendable {
        var path: [CLLocationCoordinate2D]
        /// Waypoints that had to be connected through water shallower than the safety depth (e.g. inside a marina).
        var shallowConnections: [Int]
    }

    static func route(through waypoints: [CLLocationCoordinate2D], on grid: RoutingGrid) throws -> Result {
        let region = grid.region
        guard waypoints.allSatisfy(region.contains) else { throw Failure.outsideChart }

        // Connect each waypoint to safe water, following the water rather than crossing land.
        var anchors: [(cell: Int, approach: [Int])] = []
        var shallow: [Int] = []
        for (index, point) in waypoints.enumerated() {
            guard let access = safeWaterAccess(from: point, on: grid) else { throw Failure.noSafeWater(near: index) }
            if !access.approach.isEmpty { shallow.append(index) }
            anchors.append(access)
        }

        var path: [CLLocationCoordinate2D] = [waypoints[0]]
        for leg in 0..<(waypoints.count - 1) {
            let from = anchors[leg], to = anchors[leg + 1]
            guard let cells = aStar(from: from.cell, to: to.cell, on: grid) else { throw Failure.noPassage(leg: leg) }
            let straight = smooth(cells, on: grid)
            let cellsOut = from.approach + straight + to.approach.reversed()
            path += cellsOut.map(region.center(ofCell:))
            path.append(waypoints[leg + 1])
        }
        return Result(path: dedupe(path), shallowConnections: shallow)
    }

    /// Checks a straight leg for land, shallows, charted dangers and low bridges.
    static func hazard(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, rules: NavigationRules) -> String? {
        let region = rules.region
        let p = region.gridPoint(a), q = region.gridPoint(b)
        let steps = max(1, Int((hypot(q.x - p.x, q.y - p.y) / 0.3).rounded(.up)))
        var minDepth = Double.infinity
        var known = false
        for s in 0...steps {
            let t = Double(s) / Double(steps)
            let x = Int(p.x + (q.x - p.x) * t), y = Int(p.y + (q.y - p.y) * t)
            guard x >= 0, y >= 0, x < region.cols, y < region.rows else { continue }
            known = true
            let code = region.grid[y * region.cols + x]
            if code == ChartRegion.landCode { return "Crosses land" }
            minDepth = min(minDepth, Double(code) / 2)
        }
        for bridge in region.bridges where crosses(a, b, bridge.coordinates) {
            if let height = bridge.clearance, height < rules.airDraft + RoutingGrid.bridgeMargin {
                return String(format: "%@ too low: %.0f m clearance, air draft %.0f m", bridge.displayName, height, rules.airDraft)
            }
        }
        if let (danger, distance) = closestDanger(to: a, b, in: rules.dangers), distance < danger.radius {
            return "Passes \(Int(distance.rounded())) m from a \(danger.label)"
        }
        guard known, minDepth < rules.safetyDepth else { return nil }
        return String(format: "Shallows: %.1f m (safety depth %.1f m)", minDepth, rules.safetyDepth)
    }

    /// Things the skipper should know about a planned path, e.g. bridges whose clearance isn't charted.
    static func notes(for path: [CLLocationCoordinate2D], rules: NavigationRules) -> [String] {
        var notes: [String] = []
        for bridge in rules.region.bridges {
            guard zip(path, path.dropFirst()).contains(where: { crosses($0.0, $0.1, bridge.coordinates) }) else { continue }
            let air = String(format: "%.0f m", rules.airDraft)
            if bridge.isOpening {
                notes.append("Passes \(bridge.displayName): opening bridge, check opening times.")
            } else if let height = bridge.clearance {
                notes.append(String(format: "Passes under %@: %.0f m clearance (air draft %@).", bridge.displayName, height, air))
            } else {
                notes.append("Passes under \(bridge.displayName): clearance not charted. Check it against your air draft (\(air)).")
            }
        }
        // Waypoints placed right on a danger (the router keeps the legs clear but can't move your waypoints).
        for point in path.prefix(1) + path.suffix(1) {
            if let (danger, distance) = closestDanger(to: point, point, in: rules.dangers), distance < danger.radius {
                notes.append("A waypoint is \(Int(distance.rounded())) m from a \(danger.label).")
            }
        }
        return notes
    }

    private static func crosses(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ line: [CLLocationCoordinate2D]) -> Bool {
        func orient(_ p: CLLocationCoordinate2D, _ q: CLLocationCoordinate2D, _ r: CLLocationCoordinate2D) -> Double {
            (q.longitude - p.longitude) * (r.latitude - p.latitude) - (q.latitude - p.latitude) * (r.longitude - p.longitude)
        }
        for (c, d) in zip(line, line.dropFirst()) {
            if orient(a, b, c) * orient(a, b, d) < 0 && orient(c, d, a) * orient(c, d, b) < 0 { return true }
        }
        return false
    }

    /// Nearest danger to segment a–b and its distance in metres.
    private static func closestDanger(to a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, in dangers: [Danger]) -> (Danger, Double)? {
        let metresPerDegLat = 111_320.0, metresPerDegLon = 111_320.0 * cos(a.latitude.radians)
        let bx = (b.longitude - a.longitude) * metresPerDegLon, by = (b.latitude - a.latitude) * metresPerDegLat
        let lengthSquared = bx * bx + by * by
        var best: (Danger, Double)?
        for danger in dangers {
            let px = (danger.center.longitude - a.longitude) * metresPerDegLon
            let py = (danger.center.latitude - a.latitude) * metresPerDegLat
            let t = lengthSquared > 0 ? min(1, max(0, (px * bx + py * by) / lengthSquared)) : 0
            let distance = hypot(px - t * bx, py - t * by)
            if distance < (best?.1 ?? .infinity) { best = (danger, distance) }
        }
        return best
    }

    // MARK: - Search

    private static func aStar(from start: Int, to goal: Int, on grid: RoutingGrid) -> [Int]? {
        if start == goal { return [start] }
        let region = grid.region
        let rows = region.rows, cols = region.cols, count = rows * cols
        let dx = Float(region.cellNM.dx), dy = Float(region.cellNM.dy)
        let diagonal = (dx * dx + dy * dy).squareRoot()
        let goalRow = goal / cols, goalCol = goal % cols

        var cost = [Float](repeating: .infinity, count: count)
        var parent = [Int32](repeating: -1, count: count)
        var heap = MinHeap()
        cost[start] = 0
        heap.push(0, Int32(start))

        let moves: [(dr: Int, dc: Int, length: Float)] = [
            (-1, 0, dy), (1, 0, dy), (0, -1, dx), (0, 1, dx),
            (-1, -1, diagonal), (-1, 1, diagonal), (1, -1, diagonal), (1, 1, diagonal),
        ]
        // Extra cost per NM for sailing close to danger; keeps routes off the rocks but allows narrow channels.
        let penalty: [Float] = [.infinity, 2.0, 1.0, 0.4, 0]

        return grid.clearance.withUnsafeBufferPointer { clear -> [Int]? in
            while let (f, node) = heap.pop() {
                let i = Int(node)
                if i == goal { break }
                let r = i / cols, c = i % cols
                let g = cost[i]
                // Stale heap entry?
                let h0 = heuristic(r, c, goalRow, goalCol, dx, dy)
                if f > g + h0 + 1e-4 { continue }
                for m in moves {
                    let nr = r + m.dr, nc = c + m.dc
                    guard nr >= 0, nc >= 0, nr < rows, nc < cols else { continue }
                    let n = nr * cols + nc
                    let cl = clear[n]
                    guard cl > 0 else { continue }
                    // Don't cut corners of land diagonally.
                    if m.dr != 0 && m.dc != 0 && (clear[r * cols + nc] == 0 || clear[nr * cols + c] == 0) { continue }
                    let step = m.length * (1 + penalty[Int(min(cl, RoutingGrid.maxClearance))])
                    let candidate = g + step
                    if candidate < cost[n] {
                        cost[n] = candidate
                        parent[n] = Int32(i)
                        heap.push(candidate + heuristic(nr, nc, goalRow, goalCol, dx, dy), Int32(n))
                    }
                }
            }
            guard parent[goal] >= 0 else { return nil }
            var cells = [goal]
            var i = goal
            while i != start {
                i = Int(parent[i])
                cells.append(i)
            }
            return cells.reversed()
        }
    }

    private static func heuristic(_ r: Int, _ c: Int, _ gr: Int, _ gc: Int, _ dx: Float, _ dy: Float) -> Float {
        let a = Float(r - gr) * dy, b = Float(c - gc) * dx
        return (a * a + b * b).squareRoot()
    }

    /// Greedy string pulling: jump to the furthest later cell that's still in clear line of sight.
    private static func smooth(_ cells: [Int], on grid: RoutingGrid) -> [Int] {
        guard cells.count > 2 else { return cells }
        var result = [cells[0]]
        var i = 0
        while i < cells.count - 1 {
            var best = i + 1
            var pathClearance = min(grid.clearance[cells[i]], grid.clearance[cells[i + 1]])
            var j = i + 1
            while j < cells.count {
                pathClearance = min(pathClearance, grid.clearance[cells[j]])
                // Never get closer to danger than the searched path did (up to 2 cells ≈ 130 m).
                let needed = max(1, min(pathClearance, 2))
                if lineOfSight(cells[i], cells[j], needed: needed, on: grid) {
                    best = j
                } else if j - best > 60 {
                    break
                }
                j += 1
            }
            result.append(cells[best])
            i = best
        }
        return result
    }

    private static func lineOfSight(_ a: Int, _ b: Int, needed: UInt8, on grid: RoutingGrid) -> Bool {
        let cols = grid.region.cols
        let ax = Double(a % cols) + 0.5, ay = Double(a / cols) + 0.5
        let bx = Double(b % cols) + 0.5, by = Double(b / cols) + 0.5
        let steps = max(1, Int((hypot(bx - ax, by - ay) / 0.3).rounded(.up)))
        for s in 0...steps {
            let t = Double(s) / Double(steps)
            let i = Int(ay + (by - ay) * t) * cols + Int(ax + (bx - ax) * t)
            if grid.clearance[i] < needed { return false }
        }
        return true
    }

    /// Finds the nearest safe-water cell reachable through water from a point.
    /// Returns the cell and the shallow-water cells leading to it (empty if the point is already in safe water).
    private static func safeWaterAccess(from point: CLLocationCoordinate2D, on grid: RoutingGrid) -> (cell: Int, approach: [Int])? {
        let region = grid.region
        guard var start = region.cell(point) else { return nil }
        if grid.isOpenWater(start) { return (start, []) }

        let cols = region.cols, rows = region.rows
        // Points on land (e.g. a quay the coarse grid calls land): hop to the nearest water cell first.
        if region.grid[start] == ChartRegion.landCode {
            guard let water = nearest(to: start, within: 15, on: region, where: { region.grid[$0] != ChartRegion.landCode }) else { return nil }
            start = water
        }

        var parent: [Int: Int] = [start: start]
        var queue = [start]
        var head = 0
        while head < queue.count, queue.count < 40_000 {
            let i = queue[head]; head += 1
            if grid.isOpenWater(i) {
                var path = [Int]()
                var k = i
                while k != start { k = parent[k]!; path.append(k) }
                return (i, path.reversed())
            }
            let r = i / cols, c = i % cols
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nc >= 0, nr < rows, nc < cols else { continue }
                    let n = nr * cols + nc
                    guard parent[n] == nil, grid.isPassable(n) else { continue }
                    parent[n] = i
                    queue.append(n)
                }
            }
        }
        // Enclosed in the grid (e.g. a basin the coarse data closes off): take the nearest safe cell outright.
        guard let cell = nearest(to: start, within: 60, on: region, where: grid.isOpenWater) else { return nil }
        return (cell, [])
    }

    private static func nearest(to index: Int, within radius: Int, on region: ChartRegion, where accept: (Int) -> Bool) -> Int? {
        let cols = region.cols, rows = region.rows
        let r0 = index / cols, c0 = index % cols
        var best: (Int, Double)?
        for r in max(0, r0 - radius)...min(rows - 1, r0 + radius) {
            for c in max(0, c0 - radius)...min(cols - 1, c0 + radius) {
                let i = r * cols + c
                guard accept(i) else { continue }
                let d = hypot(Double(r - r0) * region.cellNM.dy, Double(c - c0) * region.cellNM.dx)
                if best == nil || d < best!.1 { best = (i, d) }
            }
        }
        return best?.0
    }

    private static func dedupe(_ path: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for p in path where out.last.map({ Geo.distanceNM($0, p) > 0.005 }) ?? true {
            out.append(p)
        }
        return out
    }
}

/// Binary min-heap of (priority, node).
nonisolated private struct MinHeap {
    private var keys: [Float] = []
    private var values: [Int32] = []

    mutating func push(_ key: Float, _ value: Int32) {
        keys.append(key); values.append(value)
        var i = keys.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard keys[p] > keys[i] else { break }
            keys.swapAt(p, i); values.swapAt(p, i)
            i = p
        }
    }

    mutating func pop() -> (Float, Int32)? {
        guard let top = keys.first else { return nil }
        let value = values[0]
        let lastKey = keys.removeLast(), lastValue = values.removeLast()
        if !keys.isEmpty {
            keys[0] = lastKey; values[0] = lastValue
            var i = 0
            let n = keys.count
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < n && keys[l] < keys[m] { m = l }
                if r < n && keys[r] < keys[m] { m = r }
                if m == i { break }
                keys.swapAt(m, i); values.swapAt(m, i)
                i = m
            }
        }
        return (top, value)
    }
}
