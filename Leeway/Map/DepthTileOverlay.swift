import MapKit
import UIKit

/// Renders a chart region as paper-chart style tiles: depth bands, depth contours,
/// a bold safety contour, spot soundings, and (in chart mode) buff-coloured land.
nonisolated final class DepthTileOverlay: MKTileOverlay, @unchecked Sendable {
    struct Style: Hashable {
        var paintLand: Bool
        var dark: Bool
        var safetyDepth: Double
    }

    let region: ChartRegion
    let style: Style
    private static let pixels = 512
    private static let contours: [Float] = [2, 5, 10, 20, 50, 100]

    init(region: ChartRegion, style: Style) {
        self.region = region
        self.style = style
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 10 // overview zooms fall back to the base map
        maximumZ = 19
    }

    override var boundingMapRect: MKMapRect {
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: region.north, longitude: region.west))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: region.south, longitude: region.east))
        return MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            result(self.render(path), nil)
        }
    }

    // MARK: Palette

    private struct RGB { var r, g, b: UInt8 }

    private var land: RGB { style.dark ? RGB(r: 44, g: 40, b: 31) : RGB(r: 242, g: 229, b: 190) }
    private var coastline: UIColor { style.dark ? UIColor(red: 0.45, green: 0.42, blue: 0.33, alpha: 1) : UIColor(red: 0.45, green: 0.38, blue: 0.22, alpha: 1) }
    private var contourColour: RGB { style.dark ? RGB(r: 92, g: 120, b: 160) : RGB(r: 120, g: 150, b: 190) }
    private var safetyColour: RGB { style.dark ? RGB(r: 150, g: 175, b: 210) : RGB(r: 30, g: 70, b: 140) }

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

    // MARK: Rendering

    private func render(_ path: MKTileOverlayPath) -> Data? {
        let size = Self.pixels
        let n = Double(1 << path.z)
        // Web Mercator: longitude per column and latitude per row are separable.
        let lons = (0...size).map { (Double(path.x) + Double($0) / Double(size)) / n * 360 - 180 }
        let lats = (0...size).map { row -> Double in
            let y = (Double(path.y) + Double(row) / Double(size)) / n
            return atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
        }
        guard lats[0] > region.south, lats[size] < region.north, lons[size] > region.west, lons[0] < region.east else { return nil }

        // Sample depth/land at pixel corners so contours can be found by comparing neighbours.
        let stride = size + 1
        var depth = [Float](repeating: .nan, count: stride * stride)
        var isLand = [Bool](repeating: false, count: stride * stride)
        for row in 0...size {
            for col in 0...size {
                guard let s = region.smoothSample(longitude: lons[col], latitude: lats[row]) else { continue }
                let i = row * stride + col
                isLand[i] = s.land >= 0.5
                depth[i] = s.depth
            }
        }

        let vectorLand = !region.landRings.isEmpty
        let showContours = path.z >= 11
        let safety = Float(style.safetyDepth)
        func band(_ d: Float) -> Int { Self.contours.firstIndex { d < $0 } ?? Self.contours.count }

        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for row in 0..<size {
            for col in 0..<size {
                let i = row * stride + col
                let d = depth[i]
                guard !d.isNaN else { continue }
                var colour: RGB
                var alpha: UInt8 = 255
                if isLand[i] {
                    guard style.paintLand else { continue }
                    // With vector coastlines, the grid's land is only the fringe the polygons don't cover: drying/shallow water.
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
                // Premultiplied alpha.
                let a = UInt16(alpha)
                rgba[o] = UInt8(UInt16(colour.r) * a / 255)
                rgba[o + 1] = UInt8(UInt16(colour.g) * a / 255)
                rgba[o + 2] = UInt8(UInt16(colour.b) * a / 255)
                rgba[o + 3] = alpha
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return renderer.pngData { context in
            UIImage(cgImage: image).draw(at: .zero)
            if vectorLand { drawLand(lons: lons, lats: lats, in: context.cgContext) }
            if path.z >= 14 { drawSoundings(path: path, lons: lons, lats: lats, in: context.cgContext) }
        }
    }

    /// Coastline polygons, projected into the tile.
    private func drawLand(lons: [Double], lats: [Double], in context: CGContext) {
        let size = Double(Self.pixels)
        let west = Float(lons[0]), east = Float(lons[Self.pixels])
        let north = Float(lats[0]), south = Float(lats[Self.pixels])
        func merc(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }
        let mercTop = merc(lats[0]), mercBottom = merc(lats[Self.pixels])
        let lonScale = size / (lons[Self.pixels] - lons[0]), latScale = size / (mercTop - mercBottom)

        let shape = CGMutablePath()
        for (ring, b) in zip(region.landRings, region.ringBounds) {
            guard b.x <= east, b.z >= west, b.y <= north, b.w >= south, ring.count > 2 else { continue }
            var first = true
            for p in ring {
                let point = CGPoint(x: (Double(p.x) - lons[0]) * lonScale, y: (mercTop - merc(Double(p.y))) * latScale)
                if first { shape.move(to: point); first = false } else { shape.addLine(to: point) }
            }
            shape.closeSubpath()
        }
        guard !shape.isEmpty else { return }
        let fill = land
        context.addPath(shape)
        context.setFillColor(red: CGFloat(fill.r) / 255, green: CGFloat(fill.g) / 255, blue: CGFloat(fill.b) / 255, alpha: 1)
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(coastline.cgColor)
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.strokePath()
    }

    /// Spot depths on a fixed lattice of grid cells, so they line up across tiles.
    private func drawSoundings(path: MKTileOverlayPath, lons: [Double], lats: [Double], in context: CGContext) {
        let size = Double(Self.pixels)
        let pixelsPerCell = size / ((lons[Self.pixels] - lons[0]) / region.lonStep)
        let spacing = max(1, Int((130 / pixelsPerCell).rounded(.up)))
        let font = UIFont.italicSystemFont(ofSize: 20)
        let colour = style.dark ? UIColor(white: 0.75, alpha: 1) : UIColor(red: 0.2, green: 0.25, blue: 0.35, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]

        let margin = 2.0 * Double(spacing)
        let colLo = Int(((lons[0] - region.west) / region.lonStep - margin).rounded(.down))
        let colHi = Int(((lons[Self.pixels] - region.west) / region.lonStep + margin).rounded(.up))
        let rowLo = Int(((region.north - lats[0]) / region.latStep - margin).rounded(.down))
        let rowHi = Int(((region.north - lats[Self.pixels]) / region.latStep + margin).rounded(.up))
        let latTop = lats[0], latBottom = lats[Self.pixels]
        let mercTop = log(tan(.pi / 4 + latTop.radians / 2)), mercBottom = log(tan(.pi / 4 + latBottom.radians / 2))

        for row in max(0, rowLo)...min(region.rows - 1, max(0, rowHi)) where row % spacing == 0 {
            for col in max(0, colLo)...min(region.cols - 1, max(0, colHi)) where col % spacing == 0 {
                let code = region.grid[row * region.cols + col]
                // Skip land and the coast-tapered cells right next to it.
                guard code != ChartRegion.landCode, code >= 4 else { continue }
                let c = region.center(ofCell: row * region.cols + col)
                let x = (c.longitude - lons[0]) / (lons[Self.pixels] - lons[0]) * size
                let merc = log(tan(.pi / 4 + c.latitude.radians / 2))
                let y = (mercTop - merc) / (mercTop - mercBottom) * size
                let metres = Double(code) / 2
                let text = metres < 10 ? String(format: "%.1f", metres).replacingOccurrences(of: ".0", with: "") : "\(Int(metres))"
                let label = text as NSString
                let box = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: x - box.width / 2, y: y - box.height / 2), withAttributes: attributes)
            }
        }
    }
}

/// Latitude/longitude grid lines with labels, at a spacing that suits the zoom level.
nonisolated final class GraticuleOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

nonisolated final class GraticuleRenderer: MKOverlayRenderer, @unchecked Sendable {
    var dark = false

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let step = Graticule.step(pointsPerDegree: MKMapPointsPerMeterAtLatitude(0) * 111_320 * Double(zoomScale)) / 60
        let nw = mapRect.origin.coordinate
        let se = MKMapPoint(x: mapRect.maxX, y: mapRect.maxY).coordinate
        let colour = dark ? UIColor(white: 1, alpha: 0.25) : UIColor(red: 0.25, green: 0.3, blue: 0.4, alpha: 0.35)
        context.setStrokeColor(colour.cgColor)
        context.setLineWidth(1 / zoomScale)
        let top = point(for: mapRect.origin), bottom = point(for: MKMapPoint(x: mapRect.maxX, y: mapRect.maxY))

        var lon = (nw.longitude / step).rounded(.down) * step
        while lon <= se.longitude {
            let x = point(for: MKMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: lon))).x
            context.move(to: CGPoint(x: x, y: top.y))
            context.addLine(to: CGPoint(x: x, y: bottom.y))
            lon += step
        }
        var lat = (se.latitude / step).rounded(.down) * step
        while lat <= nw.latitude + step {
            let y = point(for: MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: 0))).y
            context.move(to: CGPoint(x: top.x, y: y))
            context.addLine(to: CGPoint(x: bottom.x, y: y))
            lat += step
        }
        context.strokePath()
    }
}

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
