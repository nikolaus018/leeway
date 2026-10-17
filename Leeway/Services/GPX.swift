import CoreLocation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

/// GPX 1.1, the format every plotter and navigation app reads and writes: routes, tracks and
/// waypoints in and out.
nonisolated enum GPX {
    struct Contents {
        var routes: [(name: String, points: [CLLocationCoordinate2D])] = []
        var tracks: [(name: String, points: [TrackPoint])] = []
        var waypoints: [(name: String, coordinate: CLLocationCoordinate2D)] = []

        var isEmpty: Bool { routes.isEmpty && tracks.isEmpty && waypoints.isEmpty }
    }

    static func export(routes: [(String, [CLLocationCoordinate2D])] = [], tracks: [(String, [TrackPoint])] = [],
                       waypoints: [(String, CLLocationCoordinate2D)] = []) -> String {
        let iso = ISO8601DateFormatter()
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func coordinate(_ c: CLLocationCoordinate2D) -> String {
            String(format: "lat=\"%.6f\" lon=\"%.6f\"", c.latitude, c.longitude)
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Leeway" xmlns="http://www.topografix.com/GPX/1/1">

        """
        for (name, c) in waypoints {
            xml += "  <wpt \(coordinate(c))><name>\(escape(name))</name></wpt>\n"
        }
        for (name, points) in routes {
            xml += "  <rte><name>\(escape(name))</name>\n"
            for (i, c) in points.enumerated() {
                xml += "    <rtept \(coordinate(c))><name>\(i == 0 ? "Start" : i == points.count - 1 ? "Finish" : "WP \(i)")</name></rtept>\n"
            }
            xml += "  </rte>\n"
        }
        for (name, points) in tracks {
            xml += "  <trk><name>\(escape(name))</name><trkseg>\n"
            for p in points {
                xml += "    <trkpt \(coordinate(p.coordinate))><time>\(iso.string(from: p.time))</time></trkpt>\n"
            }
            xml += "  </trkseg></trk>\n"
        }
        return xml + "</gpx>\n"
    }

    static func parse(_ data: Data) -> Contents {
        let parser = XMLParser(data: data)
        let delegate = Reader()
        parser.delegate = delegate
        parser.parse()
        return delegate.contents
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var contents = Contents()
        private var stack: [String] = []
        private var text = ""
        private var point: (CLLocationCoordinate2D, Date?)?
        private var pointName: String?
        private var name: String?
        private var routePoints: [CLLocationCoordinate2D] = []
        private var trackPoints: [TrackPoint] = []
        private let iso = ISO8601DateFormatter()

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let tag = element.lowercased()
            stack.append(tag)
            text = ""
            switch tag {
            case "wpt", "rtept", "trkpt":
                if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
                   abs(lat) <= 90, abs(lon) <= 180 {
                    point = (CLLocationCoordinate2D(latitude: lat, longitude: lon), nil)
                }
                pointName = nil
            case "rte", "trk":
                name = nil
                routePoints = []
                trackPoints = []
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let tag = element.lowercased()
            stack.removeLast()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = stack.last
            switch tag {
            case "name":
                if parent == "wpt" || parent == "rtept" || parent == "trkpt" { pointName = value } else if parent == "rte" || parent == "trk" { name = value }
            case "time" where parent == "trkpt":
                point?.1 = iso.date(from: value)
            case "wpt":
                if let point { contents.waypoints.append((pointName ?? "Waypoint", point.0)) }
                point = nil
            case "rtept":
                if let point { routePoints.append(point.0) }
                point = nil
            case "trkpt":
                if let point { trackPoints.append(TrackPoint(point.0, time: point.1 ?? .distantPast, sog: nil)) }
                point = nil
            case "rte":
                if routePoints.count >= 2 { contents.routes.append((name ?? "Imported route", routePoints)) }
            case "trk":
                if trackPoints.count >= 2 { contents.tracks.append((name ?? "Imported track", trackPoints)) }
            default:
                break
            }
            text = ""
        }
    }
}

/// A route or track as a .gpx file for the share sheet.
struct GPXFile: Transferable {
    var name: String
    var xml: String

    @MainActor init(route: Route, path: [CLLocationCoordinate2D]) {
        name = route.name
        // The planned track (automatic routes have more turns than waypoints).
        xml = GPX.export(routes: [(route.name, path.count >= 2 ? path : route.coordinates)])
    }

    init(track: TrackLog) {
        name = track.name
        xml = GPX.export(tracks: [(track.name, track.points)])
    }

    @MainActor init(marks: [UserMark]) {
        name = "Leeway marks"
        xml = GPX.export(waypoints: marks.map { ($0.name, $0.coordinate) })
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .gpx) { file in
            let safe = file.name.replacingOccurrences(of: "/", with: "-")
            let url = URL.temporaryDirectory.appending(path: "\(safe.isEmpty ? "Leeway" : safe).gpx")
            try file.xml.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
