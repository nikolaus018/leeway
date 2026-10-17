import MapKit
import UIKit

/// How the chart is drawn; a change means every tile is redrawn.
nonisolated struct ChartStyle: Hashable, Sendable {
    var paintLand: Bool
    var dark: Bool
    var safetyDepth: Double
    var seamarks: Bool
}

/// Draws one Web-Mercator tile of a chart region the way a paper chart looks: depth bands,
/// contours, a bold safety contour, buff land from the coastline polygons, spot soundings,
/// and the seamarks (lights, buoys, beacons, rocks, wrecks) with their labels.
nonisolated struct ChartPainter: Sendable {
    let region: ChartRegion
    let style: ChartStyle

    private static let contours: [Float] = [2, 5, 10, 20, 50, 100]

    /// Lon/lat bounds of tile z/x/y.
    static func bounds(z: Int, x: Int, y: Int) -> (west: Double, east: Double, north: Double, south: Double) {
        let n = Double(1 << z)
        func lat(_ t: Double) -> Double { atan(sinh(.pi * (1 - 2 * t / n))) * 180 / .pi }
        return (Double(x) / n * 360 - 180, Double(x + 1) / n * 360 - 180, lat(Double(y)), lat(Double(y + 1)))
    }

    func intersects(z: Int, x: Int, y: Int) -> Bool {
        let b = Self.bounds(z: z, x: x, y: y)
        return b.north > region.south && b.south < region.north && b.east > region.west && b.west < region.east
    }

    /// Renders the tile at `pixels` × `pixels`; `detailed` adds soundings, seamarks and labels.
    func image(z: Int, x: Int, y: Int, pixels size: Int, detailed: Bool) -> CGImage? {
        guard intersects(z: z, x: x, y: y) else { return nil }
        let n = Double(1 << z)
        // Web Mercator: longitude per column and latitude per row are separable.
        let lons = (0...size).map { (Double(x) + Double($0) / Double(size)) / n * 360 - 180 }
        let lats = (0...size).map { row -> Double in
            atan(sinh(.pi * (1 - 2 * (Double(y) + Double(row) / Double(size)) / n))) * 180 / .pi
        }
        let projection = Projection(lons: lons, lats: lats, size: Double(size))

        guard let raster = depthRaster(lons: lons, lats: lats, size: size, contours: z >= 11) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let image = renderer.image { context in
            UIImage(cgImage: raster).draw(at: .zero)
            if !region.landRings.isEmpty { drawLand(projection, in: context.cgContext) }
            guard detailed else { return }
            // Points → pixels: a tile is shown 256 points wide.
            let k = Double(size) / 256
            if z >= 14 { drawSoundings(projection, k: k) }
            if style.seamarks && z >= 11 { drawSeamarks(projection, z: z, k: k) }
        }
        return image.cgImage
    }

    // MARK: - Palette

    private struct RGB { var r, g, b: UInt8 }

    private var land: RGB { style.dark ? RGB(r: 44, g: 40, b: 31) : RGB(r: 242, g: 229, b: 190) }
    private var coastline: UIColor { style.dark ? UIColor(red: 0.45, green: 0.42, blue: 0.33, alpha: 1) : UIColor(red: 0.45, green: 0.38, blue: 0.22, alpha: 1) }
    private var contourColour: RGB { style.dark ? RGB(r: 92, g: 120, b: 160) : RGB(r: 120, g: 150, b: 190) }
    private var safetyColour: RGB { style.dark ? RGB(r: 150, g: 175, b: 210) : RGB(r: 30, g: 70, b: 140) }
    private var ink: UIColor { style.dark ? UIColor(white: 0.85, alpha: 1) : UIColor(red: 0.12, green: 0.14, blue: 0.2, alpha: 1) }
    private var magenta: UIColor { style.dark ? UIColor(red: 0.95, green: 0.45, blue: 0.9, alpha: 1) : UIColor(red: 0.75, green: 0.1, blue: 0.6, alpha: 1) }

    /// Shallow water darker, deep water pale — like a paper chart.
    private func water(_ depth: Float) -> RGB {
        let safety = Float(style.safetyDepth)
        if style.dark {
            switch depth {
            case ..<safety: return RGB(r: 26, g: 64, b: 120)
            case ..<10: return RGB(r: 20, g: 46, b: 88)
            case ..<20: return RGB(r: 15, g: 34, b: 66)
            default: return RGB(r: 10, g: 22, b: 44)
            }
        }
        switch depth {
        case ..<safety: return RGB(r: 128, g: 178, b: 226)
        case ..<10: return RGB(r: 172, g: 208, b: 238)
        case ..<20: return RGB(r: 206, g: 229, b: 247)
        default: return RGB(r: 246, g: 250, b: 254)
        }
    }

    // MARK: - Depth raster

    private func depthRaster(lons: [Double], lats: [Double], size: Int, contours showContours: Bool) -> CGImage? {
        // Sample depth/land at pixel corners so contours can be found by comparing neighbours.
        let stride = size + 1
        var depth = [Float](repeating: .nan, count: stride * stride)
        var isLand = [Bool](repeating: false, count: stride * stride)
        var any = false
        for row in 0...size {
            for col in 0...size {
                guard let s = region.smoothSample(longitude: lons[col], latitude: lats[row]) else { continue }
                let i = row * stride + col
                isLand[i] = s.land >= 0.5
                depth[i] = s.depth
                any = true
            }
        }
        guard any else { return nil }

        let vectorLand = !region.landRings.isEmpty
        let safety = Float(style.safetyDepth)
        // Contour lines get thicker with the tile's resolution so they read the same at any size.
        func band(_ d: Float) -> Int { Self.contours.firstIndex { d < $0 } ?? Self.contours.count }

        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        rgba.withUnsafeMutableBufferPointer { out in
            for row in 0..<size {
                for col in 0..<size {
                    let i = row * stride + col
                    let d = depth[i]
                    guard !d.isNaN else { continue }
                    var colour: RGB
                    var alpha: UInt16 = 255
                    if isLand[i] {
                        guard style.paintLand else { continue }
                        // With vector coastlines, grid land is only the fringe the polygons don't cover.
                        colour = vectorLand ? water(0) : land
                    } else {
                        colour = water(d)
                        if !style.paintLand { alpha = 150 }
                        if showContours, !isLand[i + 1], !isLand[i + stride] {
                            let right = depth[i + 1], below = depth[i + stride]
                            if (d < safety) != (right < safety) || (d < safety) != (below < safety) {
                                colour = safetyColour; alpha = 255
                            } else if band(d) != band(right) || band(d) != band(below) {
                                colour = contourColour; alpha = 255
                            }
                        }
                    }
                    let o = (row * size + col) * 4
                    out[o] = UInt8(UInt16(colour.r) * alpha / 255)
                    out[o + 1] = UInt8(UInt16(colour.g) * alpha / 255)
                    out[o + 2] = UInt8(UInt16(colour.b) * alpha / 255)
                    out[o + 3] = UInt8(alpha)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Land

    private func drawLand(_ p: Projection, in context: CGContext) {
        let west = Float(p.west), east = Float(p.east), north = Float(p.north), south = Float(p.south)
        let shape = CGMutablePath()
        for (ring, b) in zip(region.landRings, region.ringBounds) {
            guard b.x <= east, b.z >= west, b.y <= north, b.w >= south, ring.count > 2 else { continue }
            shape.move(to: p.point(Double(ring[0].x), Double(ring[0].y)))
            for q in ring.dropFirst() { shape.addLine(to: p.point(Double(q.x), Double(q.y))) }
            shape.closeSubpath()
        }
        guard !shape.isEmpty else { return }
        let fill = land
        context.addPath(shape)
        context.setFillColor(red: CGFloat(fill.r) / 255, green: CGFloat(fill.g) / 255, blue: CGFloat(fill.b) / 255, alpha: 1)
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(coastline.cgColor)
        context.setLineWidth(p.size / 256)
        context.setLineJoin(.round)
        context.strokePath()
    }

    // MARK: - Soundings

    /// Spot depths on a fixed lattice of grid cells, so they line up across tiles; sparse, like a chart.
    private func drawSoundings(_ p: Projection, k: Double) {
        let pixelsPerCell = p.size / ((p.east - p.west) / region.lonStep)
        let spacing = max(1, Int((150 * k / pixelsPerCell).rounded(.up)))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.italicSystemFont(ofSize: 9.5 * k),
            .foregroundColor: style.dark ? UIColor(white: 0.7, alpha: 1) : UIColor(red: 0.25, green: 0.3, blue: 0.4, alpha: 1),
        ]
        let margin = 2.0 * Double(spacing)
        let colLo = Int(((p.west - region.west) / region.lonStep - margin).rounded(.down))
        let colHi = Int(((p.east - region.west) / region.lonStep + margin).rounded(.up))
        let rowLo = Int(((region.north - p.north) / region.latStep - margin).rounded(.down))
        let rowHi = Int(((region.north - p.south) / region.latStep + margin).rounded(.up))
        guard colHi >= 0, rowHi >= 0, colLo < region.cols, rowLo < region.rows else { return }

        for row in max(0, rowLo)...min(region.rows - 1, rowHi) where row % spacing == spacing / 2 {
            for col in max(0, colLo)...min(region.cols - 1, colHi) where col % spacing == spacing / 2 {
                let code = region.grid[row * region.cols + col]
                // Skip land and the coast-tapered cells right next to it.
                guard code != ChartRegion.landCode, code >= 4 else { continue }
                let c = region.center(ofCell: row * region.cols + col)
                let point = p.point(c.longitude, c.latitude)
                let metres = Double(code) / 2
                let text = (metres < 10 ? String(format: "%.1f", metres).replacingOccurrences(of: ".0", with: "") : "\(Int(metres))") as NSString
                let box = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: point.x - box.width / 2, y: point.y - box.height / 2), withAttributes: attributes)
            }
        }
    }

    // MARK: - Seamarks

    private func drawSeamarks(_ p: Projection, z: Int, k: Double) {
        let marginLon = (p.east - p.west) * 0.25, marginLat = (p.north - p.south) * 0.25
        var labels: [CGRect] = []
        let marks = region.seamarks.filter {
            $0.longitude > p.west - marginLon && $0.longitude < p.east + marginLon &&
                $0.latitude > p.south - marginLat && $0.latitude < p.north + marginLat
        }
        // Dangers first, lights last so their flares sit on top.
        let ordered = marks.sorted { order($0) < order($1) }
        for mark in ordered {
            let at = p.point(mark.longitude, mark.latitude)
            guard draws(mark, z: z) else { continue }
            drawSymbol(mark, at: at, k: k)
            if let text = label(for: mark, z: z) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 8.5 * k, weight: .semibold),
                    .foregroundColor: mark.light != nil ? magenta : ink,
                ]
                let ns = text as NSString
                let size = ns.size(withAttributes: attributes)
                var frame = CGRect(x: at.x + 7 * k, y: at.y - size.height / 2, width: size.width, height: size.height)
                if labels.contains(where: { $0.intersects(frame) }) {
                    frame.origin.y += size.height
                    if labels.contains(where: { $0.intersects(frame) }) { continue }
                }
                labels.append(frame)
                let halo: [NSAttributedString.Key: Any] = [
                    .font: attributes[.font]!, .strokeWidth: 6.0,
                    .strokeColor: style.dark ? UIColor(white: 0, alpha: 0.6) : UIColor(white: 1, alpha: 0.85),
                ]
                ns.draw(at: frame.origin, withAttributes: halo)
                ns.draw(at: frame.origin, withAttributes: attributes)
            }
        }
    }

    private func order(_ mark: Seamark) -> Int {
        if mark.light != nil { return 3 }
        return mark.isDanger ? 0 : 1
    }

    private func draws(_ mark: Seamark, z: Int) -> Bool {
        switch mark.type {
        case "light_major": return true
        case "harbour", "small_craft_facility", "landmark", "notice", "building", "radio_station", "restricted_area":
            return false
        default: return z >= 12 || mark.light != nil && z >= 11
        }
    }

    private func label(for mark: Seamark, z: Int) -> String? {
        var parts: [String] = []
        if let light = mark.light, z >= (mark.type == "light_major" ? 11 : 13) {
            // Drop height and range until zoomed right in.
            parts.append(z >= 15 ? light : light.split(separator: " ").first.map(String.init) ?? light)
        }
        if let name = mark.name, z >= 14, !mark.isHarbourLike { parts.append(name) }
        if mark.isDanger, z >= 14, let level = mark.waterLevel, mark.type != "rock" { parts.append(level) }
        if mark.isDanger, z >= 14, let depth = mark.depthMetres { parts.append(String(format: "%.1f m", depth)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func colour(_ name: Substring) -> UIColor {
        switch name {
        case "red": UIColor(red: 0.86, green: 0.1, blue: 0.12, alpha: 1)
        case "green": UIColor(red: 0.0, green: 0.62, blue: 0.3, alpha: 1)
        case "yellow": UIColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1)
        case "black": UIColor(white: 0.05, alpha: 1)
        case "white": .white
        case "orange": .orange
        default: .gray
        }
    }

    private func drawSymbol(_ mark: Seamark, at c: CGPoint, k: Double) {
        let outline = style.dark ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.1, alpha: 1)
        let colours = (mark.colour ?? "").split(separator: ";").map(colour)
        let main = colours.first ?? (mark.category == "port" ? colour("red") : mark.category == "starboard" ? colour("green") : .gray)
        let buoy = mark.type.hasPrefix("buoy")
        let beacon = mark.type.hasPrefix("beacon")

        func stroke(_ path: UIBezierPath, fill: UIColor?, width: Double = 1) {
            if let fill { fill.setFill(); path.fill() }
            outline.setStroke()
            path.lineWidth = width * k
            path.stroke()
        }
        func rect(_ w: Double, _ h: Double, dy: Double = 0) -> CGRect {
            CGRect(x: c.x - w * k / 2, y: c.y - h * k + dy * k, width: w * k, height: h * k)
        }
        func triangle(up: Bool, centre: CGPoint, size s: Double) -> UIBezierPath {
            let p = UIBezierPath()
            let h = s * k
            if up {
                p.move(to: CGPoint(x: centre.x, y: centre.y - h / 2))
                p.addLine(to: CGPoint(x: centre.x + h / 2, y: centre.y + h / 2))
                p.addLine(to: CGPoint(x: centre.x - h / 2, y: centre.y + h / 2))
            } else {
                p.move(to: CGPoint(x: centre.x, y: centre.y + h / 2))
                p.addLine(to: CGPoint(x: centre.x + h / 2, y: centre.y - h / 2))
                p.addLine(to: CGPoint(x: centre.x - h / 2, y: centre.y - h / 2))
            }
            p.close()
            return p
        }

        switch mark.type {
        case "rock":
            // Chart symbols: dry rock = blob, awash = asterisk, covers/submerged = cross.
            let r = 3.2 * k
            switch mark.waterLevel {
            case "dry":
                stroke(UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), fill: outline, width: 0.5)
            case "awash":
                let p = UIBezierPath()
                for angle in stride(from: 0.0, to: 180, by: 45) {
                    let a = angle.radians
                    p.move(to: CGPoint(x: c.x - cos(a) * r * 1.3, y: c.y - sin(a) * r * 1.3))
                    p.addLine(to: CGPoint(x: c.x + cos(a) * r * 1.3, y: c.y + sin(a) * r * 1.3))
                }
                stroke(p, fill: nil, width: 1.1)
            default:
                let p = UIBezierPath()
                p.move(to: CGPoint(x: c.x - r * 1.3, y: c.y)); p.addLine(to: CGPoint(x: c.x + r * 1.3, y: c.y))
                p.move(to: CGPoint(x: c.x, y: c.y - r * 1.3)); p.addLine(to: CGPoint(x: c.x, y: c.y + r * 1.3))
                stroke(p, fill: nil, width: 1.1)
                if mark.waterLevel == "covers" {
                    for (dx, dy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
                        let dot = CGRect(x: c.x + dx * r * 0.7 - 0.7 * k, y: c.y + dy * r * 0.7 - 0.7 * k, width: 1.4 * k, height: 1.4 * k)
                        outline.setFill(); UIBezierPath(ovalIn: dot).fill()
                    }
                }
            }
            dangerRing(at: c, k: k)
        case "wreck":
            let p = UIBezierPath()
            p.move(to: CGPoint(x: c.x - 5 * k, y: c.y)); p.addLine(to: CGPoint(x: c.x + 5 * k, y: c.y))
            for dx in [-2.5, 0, 2.5] {
                p.move(to: CGPoint(x: c.x + dx * k, y: c.y - 2.5 * k)); p.addLine(to: CGPoint(x: c.x + dx * k, y: c.y + 2.5 * k))
            }
            stroke(p, fill: nil, width: 1.1)
            dangerRing(at: c, k: k)
        case "obstruction":
            dangerRing(at: c, k: k, radius: 5)
        case "buoy_lateral", "beacon_lateral":
            let port = mark.category?.contains("port") == true || main == colour("red")
            if beacon {
                stroke(UIBezierPath(rect: rect(1.6, 11)), fill: main, width: 0.6)
                let top = CGPoint(x: c.x, y: c.y - 12.5 * k)
                stroke(port ? UIBezierPath(rect: CGRect(x: top.x - 2.5 * k, y: top.y - 2.5 * k, width: 5 * k, height: 5 * k))
                            : triangle(up: true, centre: top, size: 5.5), fill: main, width: 0.6)
            } else if port {
                stroke(UIBezierPath(roundedRect: rect(6, 8), cornerRadius: 1 * k), fill: main, width: 0.8)
            } else {
                stroke(triangle(up: true, centre: CGPoint(x: c.x, y: c.y - 4.5 * k), size: 9), fill: main, width: 0.8)
            }
        case "buoy_cardinal", "beacon_cardinal":
            stroke(UIBezierPath(rect: rect(5, 9)), fill: colour("yellow"), width: 0.7)
            colour("black").setFill()
            let band = mark.category == "north" ? rect(5, 4.5) : mark.category == "south" ? rect(5, 4.5, dy: -4.5) : rect(5, 3, dy: -3)
            UIBezierPath(rect: band).fill()
            let t1 = CGPoint(x: c.x, y: c.y - 12 * k), t2 = CGPoint(x: c.x, y: c.y - 16.5 * k)
            let (up1, up2): (Bool, Bool) = switch mark.category {
            case "north": (true, true)
            case "south": (false, false)
            case "east": (false, true)
            default: (true, false)
            }
            stroke(triangle(up: up1, centre: t1, size: 4.5), fill: colour("black"), width: 0.4)
            stroke(triangle(up: up2, centre: t2, size: 4.5), fill: colour("black"), width: 0.4)
        case "buoy_isolated_danger", "beacon_isolated_danger":
            stroke(UIBezierPath(rect: rect(4.5, 9)), fill: colour("black"), width: 0.6)
            colour("red").setFill(); UIBezierPath(rect: rect(4.5, 3, dy: -3)).fill()
            for dy in [12.0, 16.0] {
                stroke(UIBezierPath(ovalIn: CGRect(x: c.x - 1.8 * k, y: c.y - dy * k - 1.8 * k, width: 3.6 * k, height: 3.6 * k)),
                       fill: colour("black"), width: 0.3)
            }
        case "buoy_safe_water", "beacon_safe_water":
            stroke(UIBezierPath(ovalIn: CGRect(x: c.x - 4 * k, y: c.y - 8 * k, width: 8 * k, height: 8 * k)), fill: .white, width: 0.8)
            colour("red").setFill()
            UIBezierPath(rect: CGRect(x: c.x - 1.2 * k, y: c.y - 8 * k, width: 2.4 * k, height: 8 * k)).fill()
        case "buoy_special_purpose", "beacon_special_purpose":
            stroke(UIBezierPath(rect: rect(5, 8)), fill: colour("yellow"), width: 0.7)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: c.x - 2.5 * k, y: c.y - 13 * k)); p.addLine(to: CGPoint(x: c.x + 2.5 * k, y: c.y - 9 * k))
            p.move(to: CGPoint(x: c.x + 2.5 * k, y: c.y - 13 * k)); p.addLine(to: CGPoint(x: c.x - 2.5 * k, y: c.y - 9 * k))
            stroke(p, fill: nil, width: 1)
        case "mooring":
            stroke(UIBezierPath(ovalIn: CGRect(x: c.x - 2.5 * k, y: c.y - 2.5 * k, width: 5 * k, height: 5 * k)), fill: magenta, width: 0.5)
        case "anchorage":
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13 * k, weight: .bold), .foregroundColor: magenta]
            let glyph = "⚓︎" as NSString
            let s = glyph.size(withAttributes: attributes)
            glyph.draw(at: CGPoint(x: c.x - s.width / 2, y: c.y - s.height / 2), withAttributes: attributes)
        default:
            if mark.light == nil, buoy || beacon {
                stroke(UIBezierPath(ovalIn: CGRect(x: c.x - 3 * k, y: c.y - 6 * k, width: 6 * k, height: 6 * k)), fill: main, width: 0.7)
            }
        }

        if mark.light != nil { drawLightFlare(mark, at: c, k: k) }
    }

    /// The classic teardrop flare for a light, in the light's colour.
    private func drawLightFlare(_ mark: Seamark, at c: CGPoint, k: Double) {
        // "Fl(2)R.5s 12m 6M": the colour letters follow the character and group.
        let text = mark.light ?? ""
        let rest = text.replacingOccurrences(of: #"^(Al\.)?(LFl|Fl|VQ|UQ|IQ|Q|Iso|Oc|Mo\([A-Z]+\)|F)(\([^)]*\))?"#, with: "", options: .regularExpression)
        let lightColour: UIColor = rest.hasPrefix("R") ? colour("red") : rest.hasPrefix("G") ? colour("green") : magenta
        let length = (mark.type == "light_major" ? 20.0 : 14.0) * k
        let width = length * 0.36
        let angle = 45.0.radians // pointing up-right, away from the symbol
        let tip = CGPoint(x: c.x + cos(angle) * length, y: c.y - sin(angle) * length)
        let side = CGPoint(x: -sin(angle) * width / 2, y: -cos(angle) * width / 2)
        let base = CGPoint(x: c.x + cos(angle) * length * 0.22, y: c.y - sin(angle) * length * 0.22)
        let flare = UIBezierPath()
        flare.move(to: base)
        flare.addQuadCurve(to: tip, controlPoint: CGPoint(x: base.x + side.x * 2 + (tip.x - base.x) * 0.5, y: base.y + side.y * 2 + (tip.y - base.y) * 0.5))
        flare.addQuadCurve(to: base, controlPoint: CGPoint(x: base.x - side.x * 2 + (tip.x - base.x) * 0.5, y: base.y - side.y * 2 + (tip.y - base.y) * 0.5))
        lightColour.withAlphaComponent(0.9).setFill()
        flare.fill()
        // Position dot.
        let dot = UIBezierPath(ovalIn: CGRect(x: c.x - 1.6 * k, y: c.y - 1.6 * k, width: 3.2 * k, height: 3.2 * k))
        (style.dark ? UIColor.white : UIColor.black).setFill()
        dot.fill()
    }

    private func dangerRing(at c: CGPoint, k: Double, radius: Double = 7) {
        let ring = UIBezierPath(ovalIn: CGRect(x: c.x - radius * k, y: c.y - radius * k, width: 2 * radius * k, height: 2 * radius * k))
        ring.lineWidth = 0.9 * k
        ring.setLineDash([1.2 * k, 1.6 * k], count: 2, phase: 0)
        (style.dark ? UIColor(white: 0.85, alpha: 0.9) : UIColor(white: 0.1, alpha: 0.8)).setStroke()
        ring.stroke()
    }
}

/// Lon/lat → tile pixel conversion for one tile.
nonisolated struct Projection {
    let west, east, north, south: Double
    let size: Double
    private let mercTop, mercBottom: Double

    init(lons: [Double], lats: [Double], size: Double) {
        west = lons.first!; east = lons.last!; north = lats.first!; south = lats.last!
        self.size = size
        mercTop = Self.merc(north); mercBottom = Self.merc(south)
    }

    static func merc(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }

    func point(_ lon: Double, _ lat: Double) -> CGPoint {
        CGPoint(x: (lon - west) / (east - west) * size, y: (mercTop - Self.merc(lat)) / (mercTop - mercBottom) * size)
    }
}
