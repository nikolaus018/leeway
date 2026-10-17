import CoreLocation
import Foundation

/// A charted object from OpenSeaMap/OSM: light, buoy, beacon, rock, wreck, harbour, anchorage…
nonisolated struct Seamark: Decodable, Sendable, Hashable {
    let type: String
    let name: String?
    let latitude: Double
    let longitude: Double
    let category: String?
    let colour: String?
    /// Chart-style light characteristic, e.g. "Fl(2)R.5s 12m 6M".
    let light: String?
    let depth: String?
    /// For rocks, wrecks, obstructions: dry, awash, covers, submerged…
    let waterLevel: String?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    enum CodingKeys: String, CodingKey {
        case type = "t", name = "n", latitude = "la", longitude = "lo", category = "c", colour = "col", light = "l", depth = "d"
        case waterLevel = "wl"
    }

    /// Charted depth over the object, if known.
    var depthMetres: Double? { depth.flatMap { Double($0.replacingOccurrences(of: ",", with: ".").split(separator: " ").first ?? "") } }

    /// Parsed light characteristic for flashing animation and color.
    var lightCharacteristic: LightCharacteristic? {
        light.flatMap { LightCharacteristic.parse($0, fallbackColour: colour) }
    }

    var isDanger: Bool { ["rock", "wreck", "obstruction"].contains(type) }

    /// Plain-language name of the object type.
    var kind: String {
        let base: String = switch type {
        case "light_major": "Lighthouse"
        case "light_minor": "Light"
        case "light_vessel": "Light vessel"
        case "harbour": category == "marina" ? "Marina" : "Harbour"
        case "small_craft_facility": "Small craft facility"
        case "anchorage": "Anchorage"
        case "mooring": "Mooring"
        case "rock": "Rock"
        case "wreck": "Wreck"
        case "obstruction": "Obstruction"
        case "buoy_lateral", "beacon_lateral": type.hasPrefix("buoy") ? "Lateral buoy" : "Lateral beacon"
        case "buoy_cardinal", "beacon_cardinal": type.hasPrefix("buoy") ? "Cardinal buoy" : "Cardinal beacon"
        case "buoy_isolated_danger", "beacon_isolated_danger": "Isolated danger mark"
        case "buoy_safe_water", "beacon_safe_water": "Safe water mark"
        case "buoy_special_purpose", "beacon_special_purpose": "Special mark"
        case "restricted_area": "Restricted area"
        case "landmark": "Landmark"
        default: type.replacingOccurrences(of: "_", with: " ").capitalized
        }
        guard let category, !["marina"].contains(category) else { return base }
        let detail = category.replacingOccurrences(of: "_", with: " ")
        return "\(base) · \(detail)"
    }

    var isHarbourLike: Bool { ["harbour", "anchorage", "small_craft_facility"].contains(type) }
}

/// A named feature a sea chart labels: bay, cape, strait, islet, island.
nonisolated struct PlaceName: Decodable, Sendable, Hashable {
    let type: String
    let name: String
    let latitude: Double
    let longitude: Double

    enum CodingKeys: String, CodingKey { case type = "t", name = "n", latitude = "la", longitude = "lo" }
}

/// A bridge over navigable water.
nonisolated struct Bridge: Decodable, Sendable, Hashable {
    let id: Int
    let name: String?
    /// Vertical clearance in metres, if charted.
    let clearance: Double?
    let category: String?
    let points: [[Double]]

    enum CodingKeys: String, CodingKey {
        case id, name = "n", clearance = "h", category = "c", points = "pts"
    }

    var coordinates: [CLLocationCoordinate2D] { points.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) } }
    var isOpening: Bool { ["swing", "lifting", "bascule", "opening", "draw", "transporter", "pontoon"].contains(category ?? "") }
    var displayName: String { name ?? (isOpening ? "Opening bridge" : "Bridge") }
}

/// An offline chart area: a depth/land grid plus seamarks, built by tools/build_region.py.
nonisolated final class ChartRegion: Sendable {
    static let landCode: UInt8 = 255

    let id: String
    let name: String
    let west, south, east, north: Double
    let latStep, lonStep: Double
    let rows, cols: Int
    /// Row-major, row 0 = north. 0...250 = depth in half metres, 255 = land.
    let grid: [UInt8]
    let seamarks: [Seamark]
    let bridges: [Bridge]
    let names: [PlaceName]
    /// Coastline polygons (lon/lat), for drawing crisp land; the grid is too coarse at harbour scale.
    let landRings: [[SIMD2<Float>]]
    /// Bounding box per ring: west, south, east, north.
    let ringBounds: [SIMD4<Float>]
    let attribution: String
    /// The pack's vector chart (`<id>.pmtiles`), which the map draws; older packs have none.
    let vectorFile: URL?
    /// Cell size in nautical miles.
    let cellNM: (dx: Double, dy: Double)

    private struct Meta: Decodable {
        let id, name, attribution: String
        let west, south, east, north, latStep, lonStep: Double
        let rows, cols: Int
        let seamarks: [Seamark]
        let bridges: [Bridge]?
        let names: [PlaceName]?
    }

    init(metadata: URL, depth: URL, land: URL? = nil, vector: URL? = nil) throws {
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metadata))
        let packed = try Data(contentsOf: depth) as NSData
        let raw = try packed.decompressed(using: .zlib) as Data
        guard raw.count == meta.rows * meta.cols else { throw CocoaError(.fileReadCorruptFile) }
        id = meta.id; name = meta.name; attribution = meta.attribution
        west = meta.west; south = meta.south; east = meta.east; north = meta.north
        latStep = meta.latStep; lonStep = meta.lonStep
        rows = meta.rows; cols = meta.cols
        grid = [UInt8](raw)
        seamarks = meta.seamarks
        bridges = meta.bridges ?? []
        names = meta.names ?? []
        var rings: [[SIMD2<Float>]] = []
        if let land, let packedLand = try? Data(contentsOf: land) as NSData,
           let blob = try? packedLand.decompressed(using: .zlib) as Data {
            rings = Self.decodeRings(blob)
        }
        landRings = rings
        ringBounds = rings.map { ring in
            var b = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
            for p in ring { b = SIMD4(min(b.x, p.x), min(b.y, p.y), max(b.z, p.x), max(b.w, p.y)) }
            return b
        }
        let midLat = (north + south) / 2
        cellNM = (lonStep * 60 * cos(midLat.radians), latStep * 60)
        vectorFile = vector.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Chart packs downloaded from the data server.
    static let downloadDirectory = URL.applicationSupportDirectory.appending(path: "Charts", directoryHint: .isDirectory)

    /// Downloaded packs, plus the ones shipped in the app bundle that no download replaces.
    static func all(bundle: Bundle = .main) -> [ChartRegion] {
        let downloaded = ((try? FileManager.default.contentsOfDirectory(at: downloadDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        let replaced = Set(downloaded.map { $0.deletingPathExtension().lastPathComponent })
        let bundled = (bundle.urls(forResourcesWithExtension: "json", subdirectory: "Charts") ?? [])
            .filter { !replaced.contains($0.deletingPathExtension().lastPathComponent) }
        return load(downloaded + bundled)
    }

    private static func load(_ metas: [URL]) -> [ChartRegion] {
        metas.compactMap { meta in
            let base = meta.deletingPathExtension()
            return try? ChartRegion(metadata: meta, depth: base.appendingPathExtension("depth"),
                                    land: base.appendingPathExtension("land"), vector: base.appendingPathExtension("pmtiles"))
        }
    }

    private static func decodeRings(_ data: Data) -> [[SIMD2<Float>]] {
        data.withUnsafeBytes { raw -> [[SIMD2<Float>]] in
            var offset = 0
            func u32() -> Int {
                defer { offset += 4 }
                return Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            guard raw.count >= 4 else { return [] }
            let count = u32()
            var rings: [[SIMD2<Float>]] = []
            rings.reserveCapacity(count)
            for _ in 0..<count {
                guard offset + 4 <= raw.count else { break }
                let n = u32()
                guard offset + n * 8 <= raw.count else { break }
                var ring = [SIMD2<Float>](repeating: .zero, count: n)
                for k in 0..<n {
                    ring[k] = SIMD2(raw.loadUnaligned(fromByteOffset: offset, as: Float.self),
                                    raw.loadUnaligned(fromByteOffset: offset + 4, as: Float.self))
                    offset += 8
                }
                rings.append(ring)
            }
            return rings
        }
    }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude > south && c.latitude < north && c.longitude > west && c.longitude < east
    }

    // MARK: Grid addressing

    /// Fractional grid position (column, row) of a coordinate; cell centres are at .5.
    func gridPoint(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        ((c.longitude - west) / lonStep, (north - c.latitude) / latStep)
    }

    func cell(_ c: CLLocationCoordinate2D) -> Int? {
        let p = gridPoint(c)
        let col = Int(p.x), row = Int(p.y)
        guard p.x >= 0, p.y >= 0, col < cols, row < rows else { return nil }
        return row * cols + col
    }

    /// Row or column of a latitude/longitude, clamped to the grid.
    func cell(row latitude: Double) -> Int { min(rows - 1, max(0, Int((north - latitude) / latStep))) }
    func cell(col longitude: Double) -> Int { min(cols - 1, max(0, Int((longitude - west) / lonStep))) }

    func center(ofCell index: Int) -> CLLocationCoordinate2D {
        let row = index / cols, col = index % cols
        return CLLocationCoordinate2D(latitude: north - (Double(row) + 0.5) * latStep,
                                      longitude: west + (Double(col) + 0.5) * lonStep)
    }

    enum Sounding: Equatable {
        case land
        case depth(Double)
    }

    func sounding(at c: CLLocationCoordinate2D) -> Sounding? {
        guard let i = cell(c) else { return nil }
        let code = grid[i]
        return code == Self.landCode ? .land : .depth(Double(code) / 2)
    }

    /// Smooth depth for rendering: bilinear over water cells, plus how much of the
    /// neighbourhood is land (0...1) so coastlines can be anti-aliased.
    func smoothSample(longitude: Double, latitude: Double) -> (depth: Float, land: Float)? {
        let x = (longitude - west) / lonStep - 0.5
        let y = (north - latitude) / latStep - 0.5
        guard x > -0.5, y > -0.5, x < Double(cols) - 0.5, y < Double(rows) - 0.5 else { return nil }
        let x0 = min(max(Int(x.rounded(.down)), 0), cols - 2)
        let y0 = min(max(Int(y.rounded(.down)), 0), rows - 2)
        let fx = Float(min(max(x - Double(x0), 0), 1)), fy = Float(min(max(y - Double(y0), 0), 1))
        let i = y0 * cols + x0
        let codes = (grid[i], grid[i + 1], grid[i + cols], grid[i + cols + 1])
        let weights = ((1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy)
        var land: Float = 0, depth: Float = 0, water: Float = 0
        func add(_ code: UInt8, _ w: Float) {
            if code == Self.landCode { land += w } else { depth += Float(code) / 2 * w; water += w }
        }
        add(codes.0, weights.0); add(codes.1, weights.1); add(codes.2, weights.2); add(codes.3, weights.3)
        return (water > 0 ? depth / water : 0, land)
    }
}

// MARK: - Light Characteristic Engine

/// Marine light characteristic (e.g. "Fl(2)R.5s 12m 6M") parsing and timing engine.
nonisolated struct LightCharacteristic: Sendable, Hashable {
    enum Rhythm: Sendable, Hashable {
        case fixed
        case flashing
        case longFlashing
        case quick
        case veryQuick
        case isophase
        case occulting
        case morse(String)
    }

    enum LightColor: String, Sendable, Hashable {
        case white, red, green, yellow, blue
    }

    var rhythm: Rhythm
    var group: Int
    var color: LightColor
    var period: Double

    /// Is the light emitting beam at this time?
    func isOn(at date: Date) -> Bool {
        let t = date.timeIntervalSinceReferenceDate
        guard period > 0 else { return true }
        let phase = t.truncatingRemainder(dividingBy: period)
        let normalizedPhase = phase >= 0 ? phase : phase + period

        switch rhythm {
        case .fixed:
            return true

        case .isophase:
            return normalizedPhase < (period / 2.0)

        case .occulting:
            // Light mostly on, broken by `group` one-second eclipses, a second of light between them.
            let span = Double(max(group, 1) * 2 - 1)
            if normalizedPhase >= span { return true }
            return Int(normalizedPhase) % 2 == 1

        case .flashing, .longFlashing, .quick, .veryQuick:
            let (flashDuration, flashInterval): (Double, Double) = switch rhythm {
            case .veryQuick: (0.2, 0.4)
            case .quick: (0.3, 0.8)
            case .longFlashing: (2.0, 3.0)
            default: (0.6, 1.2)
            }

            let groupSpan = Double(group - 1) * flashInterval + flashDuration
            if normalizedPhase >= groupSpan {
                return false
            }
            let flashIndex = Int(normalizedPhase / flashInterval)
            if flashIndex < group {
                let offsetInFlash = normalizedPhase - Double(flashIndex) * flashInterval
                return offsetInFlash <= flashDuration
            }
            return false

        case .morse(let code):
            let dot = 0.4
            let dash = 1.2
            let gap = 0.4
            var cur = 0.0
            for char in code {
                let len = (char == "-" || char == "T" || char == "M" || char == "A") ? dash : dot
                if normalizedPhase >= cur && normalizedPhase < cur + len {
                    return true
                }
                cur += len + gap
            }
            return false
        }
    }

    static func parse(_ raw: String, fallbackColour: String? = nil) -> LightCharacteristic? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let token = trimmed.components(separatedBy: " ").first ?? trimmed
        let upper = token.uppercased()

        let rhythm: Rhythm
        let group: Int

        if upper.contains("VQ") {
            rhythm = .veryQuick
            group = extractGroup(from: upper) ?? 1
        } else if upper.contains("IQ") {
            rhythm = .quick
            group = extractGroup(from: upper) ?? 9
        } else if upper.contains("Q") {
            rhythm = .quick
            group = extractGroup(from: upper) ?? 1
        } else if upper.contains("LFL") {
            rhythm = .longFlashing
            group = extractGroup(from: upper) ?? 1
        } else if upper.contains("FL") {
            rhythm = .flashing
            group = extractGroup(from: upper) ?? 1
        } else if upper.contains("ISO") {
            rhythm = .isophase
            group = 1
        } else if upper.contains("OC") {
            rhythm = .occulting
            group = extractGroup(from: upper) ?? 1
        } else if upper.contains("MO(") {
            let code = extractBetween(upper, prefix: "MO(", suffix: ")") ?? "A"
            rhythm = .morse(code)
            group = 1
        } else if upper.hasPrefix("F") {
            rhythm = .fixed
            group = 1
        } else {
            return nil
        }

        var period = extractPeriod(from: trimmed)
        if period == nil || period == 0 {
            period = defaultPeriod(for: rhythm, group: group)
        }

        let color = extractColor(from: token) ?? fallbackColor(from: fallbackColour)

        return LightCharacteristic(rhythm: rhythm, group: group, color: color, period: period ?? 4.0)
    }

    private static func extractGroup(from s: String) -> Int? {
        guard let start = s.firstIndex(of: "("), let end = s.firstIndex(of: ")"), start < end else { return nil }
        let sub = s[s.index(after: start)..<end]
        return Int(sub)
    }

    private static func extractBetween(_ s: String, prefix: String, suffix: String) -> String? {
        guard let r1 = s.range(of: prefix), let r2 = s.range(of: suffix, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound])
    }

    private static func extractPeriod(from s: String) -> Double? {
        guard let pattern = try? NSRegularExpression(pattern: #"(?:^|[ .])(\d+(?:\.\d+)?)s\b"#, options: .caseInsensitive) else {
            return nil
        }
        let ns = s as NSString
        if let match = pattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 {
            let r = match.range(at: 1)
            return Double(ns.substring(with: r))
        }
        return nil
    }

    private static func defaultPeriod(for rhythm: Rhythm, group: Int) -> Double {
        switch rhythm {
        case .fixed: return 1.0
        case .veryQuick: return max(Double(group) * 0.5, 1.0)
        case .quick: return max(Double(group) * 1.0, 1.5)
        case .longFlashing: return max(Double(group) * 3.0, 5.0)
        case .flashing: return max(Double(group) * 2.0, 4.0)
        case .isophase, .occulting: return 4.0
        case .morse: return 6.0
        }
    }

    private static func extractColor(from s: String) -> LightColor? {
        var cleaned = s
        for p in ["VERYQUICK", "QUICK", "LFL", "FL", "ISO", "OC", "VQ", "IQ", "Q", "F"] {
            if let r = cleaned.range(of: p) {
                cleaned.removeSubrange(r)
                break
            }
        }
        if let paren = cleaned.firstIndex(of: "("), let endParen = cleaned.firstIndex(of: ")") {
            cleaned.removeSubrange(paren...endParen)
        }
        if let dot = cleaned.firstIndex(of: ".") {
            cleaned = String(cleaned[..<dot])
        }
        for ch in cleaned {
            switch ch {
            case "R": return .red
            case "G": return .green
            case "Y": return .yellow
            case "W": return .white
            case "B": return .blue
            default: break
            }
        }
        return nil
    }

    private static func fallbackColor(from colour: String?) -> LightColor {
        guard let c = colour?.lowercased() else { return .white }
        if c.contains("red") { return .red }
        if c.contains("green") { return .green }
        if c.contains("yellow") { return .yellow }
        if c.contains("blue") { return .blue }
        return .white
    }
}
