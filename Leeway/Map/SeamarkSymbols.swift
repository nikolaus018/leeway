import UIKit

/// Icons the chart style asks for by name: INT 1-style seamark symbols (keys made by
/// tools/build_vector.py), light flares, and the markers of the live layers. Drawn on demand when
/// the map first needs one, so there's no sprite sheet to keep in sync.
enum SeamarkSymbols {
    /// Canvas size in points; the charted position is the centre.
    private static let canvas: CGFloat = 44

    static func image(named name: String, palette: ChartPalette) -> UIImage? {
        let dark = palette == .night
        switch name {
        case "wind-arrow": return windArrow()
        case "tss-arrow": return trafficArrow(dark: dark)
        case "vessel-moving": return vessel(moving: true)
        case "vessel-stopped": return vessel(moving: false)
        case "inspect": return inspect()
        case "measure-end": return dot(.white, size: 12, ring: UIColor(white: 0.1, alpha: 0.9))
        case "anchor-mark": return badge("⚓︎", fill: .systemPurple, size: 30)
        case "anchor-alarm": return badge("⚓︎", fill: .systemRed, size: 30)
        case "mob-mark": return badge("MOB", fill: .systemRed, size: 40)
        default: break
        }
        if name.hasPrefix("flare-") { return flare(String(name.dropFirst(6)), dark: dark) }
        if name.hasPrefix("mark-") { return userMark(String(name.dropFirst(5))) }
        return render { context, c in drawSeamark(name, at: c, dark: dark, in: context) }
    }

    private static func render(size: CGFloat = canvas, _ draw: (CGContext, CGPoint) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            draw(context.cgContext, CGPoint(x: size / 2, y: size / 2))
        }
    }

    // MARK: Seamarks

    private static func colour(_ name: String) -> UIColor {
        switch name {
        case "red": UIColor(red: 0.86, green: 0.1, blue: 0.12, alpha: 1)
        case "green": UIColor(red: 0.0, green: 0.62, blue: 0.3, alpha: 1)
        case "yellow": UIColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1)
        case "black": UIColor(white: 0.05, alpha: 1)
        case "white": .white
        default: .gray
        }
    }

    private static func drawSeamark(_ name: String, at c: CGPoint, dark: Bool, in context: CGContext) {
        let outline = dark ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.1, alpha: 1)
        let magenta = dark ? UIColor(red: 0.95, green: 0.45, blue: 0.9, alpha: 1) : UIColor(red: 0.75, green: 0.1, blue: 0.6, alpha: 1)
        let k = 1.0
        let beacon = name.hasPrefix("beacon")

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
        func dangerRing(radius: Double = 7) {
            let ring = UIBezierPath(ovalIn: CGRect(x: c.x - radius * k, y: c.y - radius * k, width: 2 * radius * k, height: 2 * radius * k))
            ring.lineWidth = 0.9 * k
            ring.setLineDash([1.2 * k, 1.6 * k], count: 2, phase: 0)
            (dark ? UIColor(white: 0.85, alpha: 0.9) : UIColor(white: 0.1, alpha: 0.8)).setStroke()
            ring.stroke()
        }
        func glyph(_ text: String, size: Double, colour: UIColor) {
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: colour]
            let s = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: c.x - s.width / 2, y: c.y - s.height / 2), withAttributes: attributes)
        }

        switch name {
        case "rock-dry", "rock-awash", "rock-covers", "rock-submerged":
            // Chart symbols: dry rock = blob, awash = asterisk, covers/submerged = cross.
            let r = 3.2 * k
            switch name {
            case "rock-dry":
                stroke(UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), fill: outline, width: 0.5)
            case "rock-awash":
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
                if name == "rock-covers" {
                    for (dx, dy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
                        let dot = CGRect(x: c.x + dx * r * 0.7 - 0.7 * k, y: c.y + dy * r * 0.7 - 0.7 * k, width: 1.4 * k, height: 1.4 * k)
                        outline.setFill(); UIBezierPath(ovalIn: dot).fill()
                    }
                }
            }
            dangerRing()
        case "wreck", "wreck-safe":
            let p = UIBezierPath()
            p.move(to: CGPoint(x: c.x - 5 * k, y: c.y)); p.addLine(to: CGPoint(x: c.x + 5 * k, y: c.y))
            for dx in [-2.5, 0, 2.5] {
                p.move(to: CGPoint(x: c.x + dx * k, y: c.y - 2.5 * k)); p.addLine(to: CGPoint(x: c.x + dx * k, y: c.y + 2.5 * k))
            }
            stroke(p, fill: nil, width: 1.1)
            // S-52: only a dangerous wreck gets the dotted danger ring.
            if name == "wreck" { dangerRing() }
        case "boom":
            // A floating barrier (swimming area, marina): a small open square, no danger ring.
            stroke(UIBezierPath(rect: CGRect(x: c.x - 3 * k, y: c.y - 3 * k, width: 6 * k, height: 6 * k)), fill: nil, width: 1)
        case "obstruction":
            dangerRing(radius: 5)
        case "buoy-port", "buoy-starboard", "beacon-port", "beacon-starboard":
            let port = name.hasSuffix("port")
            let main = colour(port ? "red" : "green")
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
        case _ where name.contains("cardinal"):
            let quadrant = name.split(separator: "-").last.map(String.init) ?? "north"
            // IALA: north black over yellow, south yellow over black, east black with a yellow band,
            // west yellow with a black band. (rect(w, h, dy:) grows upwards from the position.)
            let body: UIColor = quadrant == "east" ? colour("black") : colour("yellow")
            let band: UIColor = quadrant == "east" ? colour("yellow") : colour("black")
            stroke(UIBezierPath(rect: rect(5, 9)), fill: body, width: 0.7)
            band.setFill()
            switch quadrant {
            case "north": UIBezierPath(rect: rect(5, 4.5, dy: -4.5)).fill()   // upper half
            case "south": UIBezierPath(rect: rect(5, 4.5)).fill()             // lower half
            default: UIBezierPath(rect: rect(5, 3, dy: -3)).fill()            // middle third
            }
            stroke(UIBezierPath(rect: rect(5, 9)), fill: nil, width: 0.7)
            let t1 = CGPoint(x: c.x, y: c.y - 12 * k), t2 = CGPoint(x: c.x, y: c.y - 16.5 * k)
            let (up1, up2): (Bool, Bool) = switch quadrant {
            case "north": (true, true)
            case "south": (false, false)
            case "east": (false, true)
            default: (true, false)
            }
            stroke(triangle(up: up1, centre: t1, size: 4.5), fill: colour("black"), width: 0.4)
            stroke(triangle(up: up2, centre: t2, size: 4.5), fill: colour("black"), width: 0.4)
        case "isolated-danger":
            stroke(UIBezierPath(rect: rect(4.5, 9)), fill: colour("black"), width: 0.6)
            colour("red").setFill(); UIBezierPath(rect: rect(4.5, 3, dy: -3)).fill()
            for dy in [12.0, 16.0] {
                stroke(UIBezierPath(ovalIn: CGRect(x: c.x - 1.8 * k, y: c.y - dy * k - 1.8 * k, width: 3.6 * k, height: 3.6 * k)),
                       fill: colour("black"), width: 0.3)
            }
        case "safe-water":
            stroke(UIBezierPath(ovalIn: CGRect(x: c.x - 4 * k, y: c.y - 8 * k, width: 8 * k, height: 8 * k)), fill: .white, width: 0.8)
            colour("red").setFill()
            UIBezierPath(rect: CGRect(x: c.x - 1.2 * k, y: c.y - 8 * k, width: 2.4 * k, height: 8 * k)).fill()
        case "special":
            stroke(UIBezierPath(rect: rect(5, 8)), fill: colour("yellow"), width: 0.7)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: c.x - 2.5 * k, y: c.y - 13 * k)); p.addLine(to: CGPoint(x: c.x + 2.5 * k, y: c.y - 9 * k))
            p.move(to: CGPoint(x: c.x + 2.5 * k, y: c.y - 13 * k)); p.addLine(to: CGPoint(x: c.x - 2.5 * k, y: c.y - 9 * k))
            stroke(p, fill: nil, width: 1)
        case "mooring":
            stroke(UIBezierPath(ovalIn: CGRect(x: c.x - 2.5 * k, y: c.y - 2.5 * k, width: 5 * k, height: 5 * k)), fill: magenta, width: 0.5)
        case "anchorage":
            glyph("⚓︎", size: 14, colour: magenta)
        case "harbour", "marina":
            // A round badge, as plotters show harbours and marinas.
            let r = 9.0
            let badge = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            (dark ? UIColor(white: 0.15, alpha: 0.95) : UIColor(white: 1, alpha: 0.95)).setFill()
            badge.fill()
            magenta.setStroke()
            badge.lineWidth = 1.5
            badge.stroke()
            let symbol = UIImage(systemName: name == "marina" ? "sailboat.fill" : "ferry.fill",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))?
                .withTintColor(magenta, renderingMode: .alwaysOriginal)
            symbol?.draw(at: CGPoint(x: c.x - (symbol?.size.width ?? 0) / 2, y: c.y - (symbol?.size.height ?? 0) / 2))
        case "landmark":
            let p = UIBezierPath(ovalIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            stroke(p, fill: nil, width: 1)
            outline.setFill(); UIBezierPath(ovalIn: CGRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2)).fill()
        case "buoy-generic", "beacon-generic":
            stroke(UIBezierPath(ovalIn: CGRect(x: c.x - 3 * k, y: c.y - 6 * k, width: 6 * k, height: 6 * k)), fill: .gray, width: 0.7)
        default:
            outline.setFill()
            UIBezierPath(ovalIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)).fill()
        }
    }

    /// The teardrop flare of a light, pointing up-right from the position (bottom-left of the image).
    private static func flare(_ letter: String, dark: Bool) -> UIImage {
        let size: CGFloat = 22
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let colour: UIColor = switch letter {
            case "R": colour("red")
            case "G": colour("green")
            default: dark ? UIColor(red: 0.95, green: 0.45, blue: 0.9, alpha: 1) : UIColor(red: 0.75, green: 0.1, blue: 0.6, alpha: 1)
            }
            let c = CGPoint(x: 2, y: size - 2)
            let length = 18.0, width = length * 0.36
            let angle = 45.0.radians
            let tip = CGPoint(x: c.x + cos(angle) * length, y: c.y - sin(angle) * length)
            let side = CGPoint(x: -sin(angle) * width / 2, y: -cos(angle) * width / 2)
            let base = CGPoint(x: c.x + cos(angle) * length * 0.22, y: c.y - sin(angle) * length * 0.22)
            let path = UIBezierPath()
            path.move(to: base)
            path.addQuadCurve(to: tip, controlPoint: CGPoint(x: base.x + side.x * 2 + (tip.x - base.x) * 0.5, y: base.y + side.y * 2 + (tip.y - base.y) * 0.5))
            path.addQuadCurve(to: base, controlPoint: CGPoint(x: base.x - side.x * 2 + (tip.x - base.x) * 0.5, y: base.y - side.y * 2 + (tip.y - base.y) * 0.5))
            colour.withAlphaComponent(0.9).setFill()
            path.fill()
            (dark ? UIColor.white : UIColor.black).setFill()
            UIBezierPath(ovalIn: CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)).fill()
        }
    }

    // MARK: Live layers

    /// White arrow pointing up (north), tinted by the style: `icon-color` needs a template image.
    private static func windArrow() -> UIImage {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 22, height: 26)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 11, y: 1))
            p.addLine(to: CGPoint(x: 20, y: 13))
            p.addLine(to: CGPoint(x: 14, y: 12))
            p.addLine(to: CGPoint(x: 14, y: 25))
            p.addLine(to: CGPoint(x: 8, y: 25))
            p.addLine(to: CGPoint(x: 8, y: 12))
            p.addLine(to: CGPoint(x: 2, y: 13))
            p.close()
            UIColor.white.setFill()
            p.fill()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// The large open arrow of a traffic separation lane, pointing north (the style rotates it).
    private static func trafficArrow(dark: Bool) -> UIImage {
        let magenta = dark ? UIColor(red: 0.95, green: 0.45, blue: 0.9, alpha: 1) : UIColor(red: 0.75, green: 0.1, blue: 0.6, alpha: 1)
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 44)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 12, y: 2))
            p.addLine(to: CGPoint(x: 22, y: 18))
            p.addLine(to: CGPoint(x: 15, y: 18))
            p.addLine(to: CGPoint(x: 15, y: 42))
            p.addLine(to: CGPoint(x: 9, y: 42))
            p.addLine(to: CGPoint(x: 9, y: 18))
            p.addLine(to: CGPoint(x: 2, y: 18))
            p.close()
            magenta.setStroke()
            p.lineWidth = 1.6
            p.lineJoinStyle = .round
            p.stroke()
        }
    }

    private static func vessel(moving: Bool) -> UIImage {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26)).image { _ in
            let path: UIBezierPath
            if moving {
                path = UIBezierPath()
                path.move(to: CGPoint(x: 13, y: 2))
                path.addLine(to: CGPoint(x: 20, y: 23))
                path.addLine(to: CGPoint(x: 13, y: 19))
                path.addLine(to: CGPoint(x: 6, y: 23))
                path.close()
            } else {
                path = UIBezierPath(ovalIn: CGRect(x: 7, y: 7, width: 12, height: 12))
            }
            UIColor.white.setFill()
            path.fill()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private static func inspect() -> UIImage {
        let symbol = UIImage(systemName: "plus.viewfinder", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .medium))
        return symbol?.withTintColor(.systemRed, renderingMode: .alwaysOriginal) ?? dot(.systemRed, size: 10)
    }

    private static func dot(_ colour: UIColor, size: CGFloat, ring: UIColor = .white) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size + 4, height: size + 4)).image { _ in
            let p = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: size, height: size))
            colour.setFill()
            p.fill()
            ring.setStroke()
            p.lineWidth = 2
            p.stroke()
        }
    }

    private static func badge(_ text: String, fill: UIColor, size: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let p = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: size - 2, height: size - 2))
            fill.setFill()
            p.fill()
            UIColor.white.setStroke()
            p.lineWidth = 2
            p.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size * 0.42, weight: .heavy), .foregroundColor: UIColor.white]
            let s = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: (size - s.width) / 2, y: (size - s.height) / 2), withAttributes: attributes)
        }
    }

    /// A user's mark: an SF Symbol on a coloured pin head.
    private static func userMark(_ symbolName: String) -> UIImage {
        let size: CGFloat = 30
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let p = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: size - 4, height: size - 4))
            UIColor.systemOrange.setFill()
            p.fill()
            UIColor.white.setStroke()
            p.lineWidth = 2
            p.stroke()
            let symbol = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            if let symbol { symbol.draw(at: CGPoint(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2)) }
        }
    }
}
