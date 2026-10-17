import MapKit
import UIKit

/// The offline chart of one region, drawn by `ChartRenderer`.
nonisolated final class ChartOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let painter: ChartPainter
    let boundingMapRect: MKMapRect

    var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }

    init(region: ChartRegion, style: ChartStyle) {
        painter = ChartPainter(region: region, style: style)
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: region.north, longitude: region.west))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: region.south, longitude: region.east))
        boundingMapRect = MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
    }
}

/// Draws chart tiles without ever leaving a hole while you pan and zoom: tiles are cached,
/// a tile that isn't ready yet is stood in for by its cached parent (or children, or a quick
/// low-resolution render), and the sharp version is swapped in as soon as it's painted.
nonisolated final class ChartRenderer: MKOverlayRenderer, @unchecked Sendable {
    private let painter: ChartPainter
    private let cache = NSCache<NSNumber, TileImage>()
    private let lock = NSLock()
    private var pending: Set<Int64> = []
    private var latestZoom = 0
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private static let pixels = 512
    private static let quickPixels = 128
    private static let zoomRange = 8...19

    private final class TileImage {
        let image: UIImage
        init(_ image: CGImage) { self.image = UIImage(cgImage: image) }
    }

    init(chart: ChartOverlay) {
        painter = chart.painter
        super.init(overlay: chart)
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    deinit { queue.cancelAllOperations() }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let z = Self.tileZoom(for: zoomScale)
        guard Self.zoomRange.contains(z) else { return }
        lock.withLock { latestZoom = z }

        let span = MKMapSize.world.width / Double(1 << z)
        let x0 = Int(mapRect.minX / span), x1 = Int((mapRect.maxX - 1e-6) / span)
        let y0 = Int(mapRect.minY / span), y1 = Int((mapRect.maxY - 1e-6) / span)

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        for x in x0...max(x0, x1) {
            for y in y0...max(y0, y1) {
                guard painter.intersects(z: z, x: x, y: y) else { continue }
                let tileRect = rect(for: Self.mapRect(z: z, x: x, y: y))
                if let tile = cached(z, x, y) {
                    tile.image.draw(in: tileRect)
                    continue
                }
                request(z, x, y)
                context.saveGState()
                context.clip(to: tileRect)
                drawStandIn(z, x, y, in: tileRect)
                context.restoreGState()
            }
        }
    }

    // MARK: Stand-ins

    private func drawStandIn(_ z: Int, _ x: Int, _ y: Int, in tileRect: CGRect) {
        // A cached ancestor, scaled up.
        for up in 1...4 where z - up >= Self.zoomRange.lowerBound {
            let az = z - up, ax = x >> up, ay = y >> up
            if let tile = cached(az, ax, ay) {
                tile.image.draw(in: rect(for: Self.mapRect(z: az, x: ax, y: ay)))
                return
            }
        }
        // All four children (zooming out).
        if z + 1 <= Self.zoomRange.upperBound {
            let children = (0..<4).map { (2 * x + $0 % 2, 2 * y + $0 / 2) }
            let tiles = children.map { cached(z + 1, $0.0, $0.1) }
            if tiles.allSatisfy({ $0 != nil }) {
                for (child, tile) in zip(children, tiles) {
                    tile?.image.draw(in: rect(for: Self.mapRect(z: z + 1, x: child.0, y: child.1)))
                }
                return
            }
        }
        // Nothing cached nearby: a quick, plain render now.
        let key = Self.key(z, x, y, quick: true)
        if let tile = cache.object(forKey: key) {
            tile.image.draw(in: tileRect)
        } else if let image = painter.image(z: z, x: x, y: y, pixels: Self.quickPixels, detailed: false) {
            let tile = TileImage(image)
            cache.setObject(tile, forKey: key, cost: Self.quickPixels * Self.quickPixels * 4)
            tile.image.draw(in: tileRect)
        }
    }

    // MARK: Painting

    private func request(_ z: Int, _ x: Int, _ y: Int) {
        let id = Self.id(z, x, y)
        let isNew = lock.withLock { pending.insert(id).inserted }
        guard isNew else { return }
        queue.addOperation { [weak self] in
            guard let self else { return }
            // Skip zoom levels the user has already zoomed past.
            let latest = self.lock.withLock { self.latestZoom }
            guard abs(latest - z) <= 1 else {
                self.lock.withLock { _ = self.pending.remove(id) }
                return
            }
            let image = self.painter.image(z: z, x: x, y: y, pixels: Self.pixels, detailed: true)
            if let image {
                self.cache.setObject(TileImage(image), forKey: Self.key(z, x, y, quick: false), cost: Self.pixels * Self.pixels * 4)
            }
            self.lock.withLock { _ = self.pending.remove(id) }
            guard image != nil else { return }
            let tileRect = Self.mapRect(z: z, x: x, y: y)
            DispatchQueue.main.async { self.setNeedsDisplay(tileRect) }
        }
    }

    private func cached(_ z: Int, _ x: Int, _ y: Int) -> TileImage? {
        cache.object(forKey: Self.key(z, x, y, quick: false))
    }

    // MARK: Tile maths

    /// The tile level whose 256-point tiles match the current zoom.
    private static func tileZoom(for zoomScale: MKZoomScale) -> Int {
        Int(log2(MKMapSize.world.width * Double(zoomScale) / 256).rounded())
    }

    private static func mapRect(z: Int, x: Int, y: Int) -> MKMapRect {
        let span = MKMapSize.world.width / Double(1 << z)
        return MKMapRect(x: Double(x) * span, y: Double(y) * span, width: span, height: span)
    }

    private static func id(_ z: Int, _ x: Int, _ y: Int) -> Int64 {
        Int64(z) << 50 | Int64(x) << 25 | Int64(y)
    }

    private static func key(_ z: Int, _ x: Int, _ y: Int, quick: Bool) -> NSNumber {
        NSNumber(value: id(z, x, y) | (quick ? Int64(1) << 60 : 0))
    }
}

/// OpenSeaMap seamark tiles (through the data server, which caches them) with a disk cache,
/// skipped where an offline chart draws its own seamarks.
nonisolated final class SeamarkTileOverlay: MKTileOverlay, @unchecked Sendable {
    private let regions: [ChartRegion]
    private static let openSeaMap = "https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png"
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024,
                                          directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                                              .appendingPathComponent("SeamarkTiles"))
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    init(regions: [ChartRegion], server: Seadata) {
        self.regions = regions
        super.init(urlTemplate: server.seamarkTileTemplate)
        canReplaceMapContent = false
        minimumZ = 6
        maximumZ = 18
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let b = ChartPainter.bounds(z: path.z, x: path.x, y: path.y)
        let insideChart = regions.contains { r in
            b.west >= r.west && b.east <= r.east && b.south >= r.south && b.north <= r.north
        }
        guard !insideChart else { return result(nil, nil) }
        Self.fetch(url(forTilePath: path)) { data, ok in
            if ok { return result(data, nil) }
            // Data server unreachable: go to OpenSeaMap directly.
            let direct = Self.openSeaMap.replacingOccurrences(of: "{z}", with: "\(path.z)")
                .replacingOccurrences(of: "{x}", with: "\(path.x)").replacingOccurrences(of: "{y}", with: "\(path.y)")
            guard let url = URL(string: direct) else { return result(nil, nil) }
            Self.fetch(url) { data, _ in result(data, nil) }
        }
    }

    /// PNG data, or nil for an empty tile; `ok` is false when the source failed.
    private static func fetch(_ url: URL, completion: @escaping (Data?, Bool) -> Void) {
        session.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: completion(data, true)
            case 204, 404: completion(nil, true)
            default: completion(nil, error == nil && status < 500 && status != 0)
            }
        }.resume()
    }
}

/// Latitude/longitude grid lines at a spacing that suits the zoom level.
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
