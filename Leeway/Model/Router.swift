import CoreLocation

/// Where the boat may go for a given safety depth, plus how far each cell is from danger.
nonisolated final class RoutingGrid: Sendable {
    /// Cells of clearance beyond which there's no penalty (~4 × 67 m).
    static let maxClearance: UInt8 = 4

    let region: ChartRegion
    let safetyDepth: Double
    /// Distance in cells to the nearest land or too-shallow cell, capped. 0 = not navigable.
    let clearance: [UInt8]
    /// Connected safe-water areas (4-connected); -1 = not navigable.
    let component: [Int32]
    /// The largest connected area — the open sea.
    let seaComponent: Int32

    init(region: ChartRegion, safetyDepth: Double) {
        self.region = region
        self.safetyDepth = safetyDepth
        let minimumCode = UInt8(min(250, (safetyDepth * 2).rounded(.up)))
        let rows = region.rows, cols = region.cols
        var d = region.grid.map { $0 == ChartRegion.landCode || $0 < minimumCode ? UInt8(0) : Self.maxClearance }
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

    /// Checks a straight leg for land and water shallower than the safety depth.
    static func hazard(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, region: ChartRegion, safetyDepth: Double) -> String? {
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
        guard known, minDepth < safetyDepth else { return nil }
        return String(format: "Shallows: %.1f m (safety depth %.1f m)", minDepth, safetyDepth)
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
                    guard parent[n] == nil, region.grid[n] != ChartRegion.landCode else { continue }
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
