import CoreLocation
import Foundation
import Testing
@testable import Leeway

struct GPXTests {
    @Test func roundTripsRoutesTracksAndWaypoints() throws {
        let route = [CLLocationCoordinate2D(latitude: 45.3, longitude: 14.4), CLLocationCoordinate2D(latitude: 45.0, longitude: 14.5)]
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let track = [TrackPoint(route[0], time: t0, sog: 5), TrackPoint(route[1], time: t0.addingTimeInterval(3600), sog: 6)]
        let xml = GPX.export(routes: [("Rijeka & Cres <test>", route)], tracks: [("Sunday", track)],
                             waypoints: [("Anchorage", route[1])])
        let parsed = GPX.parse(Data(xml.utf8))
        #expect(parsed.routes.count == 1)
        #expect(parsed.routes[0].name == "Rijeka & Cres <test>")
        #expect(parsed.routes[0].points.count == 2)
        #expect(abs(parsed.routes[0].points[1].latitude - 45.0) < 1e-6)
        #expect(parsed.tracks.first?.points.last?.time == t0.addingTimeInterval(3600))
        #expect(parsed.waypoints.first?.name == "Anchorage")
    }

    @Test func ignoresBrokenPoints() {
        let xml = #"<gpx><wpt lat="95" lon="14"><name>bad</name></wpt><rte><rtept lat="45" lon="14"/></rte></gpx>"#
        let parsed = GPX.parse(Data(xml.utf8))
        #expect(parsed.waypoints.isEmpty)
        #expect(parsed.routes.isEmpty, "a one-point route is no route")
    }
}

@MainActor
struct ParsingRegressionTests {
    @Test func gpxReadsFractionalSecondTimes() {
        let xml = "<gpx><trk><trkseg><trkpt lat=\"45\" lon=\"14\"><time>2025-06-01T10:00:00.250Z</time></trkpt><trkpt lat=\"45.1\" lon=\"14\"><time>2025-06-01T10:05:00Z</time></trkpt></trkseg></trk></gpx>"
        let track = GPX.parse(Data(xml.utf8)).tracks.first
        #expect(track?.points.first?.time != .distantPast)
        #expect(track?.points.last?.time != .distantPast)
    }

    @Test func polarReadsDecimalCommas() {
        let text = "TWA\\TWS;6;10\n40;3,5;5,5\n90;5,0;7,5\n150;4,5;6,5\n"
        let table = PolarTable.parse(text, name: "t")
        #expect(table?.windSpeeds == [6, 10])
        #expect(table?.speeds[1] == [5.0, 7.5])
    }

    @Test func magneticHeadingFollowsAtFullRate() {
        let nmea = NMEAClient()
        nmea.parse("$HCHDM,100.0,M*28")
        nmea.parse("$HCHDM,101.0,M*29")
        #expect(nmea.heading == 101)
    }
}

struct NMEATests {
    @Test func readsDepthWindAndHeading() {
        let nmea = NMEAClient()
        nmea.parse(sentence("IIDPT,4.2,0.5"))
        nmea.parse(sentence("WIMWV,045.0,R,12.4,N,A"))
        nmea.parse(sentence("HCHDT,182.5,T"))
        nmea.parse("$IIDBT,0.0,f,9.9,M,0.0,F*00") // bad checksum: ignored
        #expect(nmea.depth == 4.7)
        #expect(nmea.wind == NMEAClient.Wind(angle: 45, speed: 12.4, relative: true))
        #expect(nmea.heading == 182.5)
    }

    @Test func convertsWindUnits() {
        let nmea = NMEAClient()
        nmea.parse(sentence("WIMWV,200,T,10.0,M,A"))
        #expect(abs((nmea.wind?.speed ?? 0) - 19.438) < 0.01)
        #expect(nmea.wind?.relative == false)
    }

    @Test func decodesAISPositionAndName() {
        let nmea = NMEAClient()
        // Type 1: MMSI 238123456, under way, 12.3 kn, 45.33 N 14.42 E, COG 210.5, heading 211.
        var bits = Bits()
        bits.add(1, 6); bits.add(0, 2); bits.add(238_123_456, 30); bits.add(0, 4); bits.add(0, 8)
        bits.add(123, 10); bits.add(0, 1); bits.add(Int(14.42 * 600_000), 28); bits.add(Int(45.33 * 600_000), 27)
        bits.add(2105, 12); bits.add(211, 9); bits.add(0, 60)
        nmea.parse(sentence("AIVDM,1,1,,A,\(bits.payload),0"))
        // Type 24 part A: the name.
        var name = Bits()
        name.add(24, 6); name.add(0, 2); name.add(238_123_456, 30); name.add(0, 2); name.addText("MARKO POLO", 20)
        nmea.parse(sentence("AIVDM,1,1,,A,\(name.payload),0"))
        let v = nmea.vessels[238_123_456]
        #expect(v?.name == "MARKO POLO")
        #expect(abs((v?.lat ?? 0) - 45.33) < 1e-5)
        #expect(abs((v?.lon ?? 0) - 14.42) < 1e-5)
        #expect(v?.sog == 12.3)
        #expect(v?.cog == 210.5)
        #expect(v?.heading == 211)
    }

    /// `$`/`!` + body + checksum.
    private func sentence(_ body: String) -> String {
        let checksum = body.utf8.reduce(0, ^)
        return (body.hasPrefix("AI") ? "!" : "$") + body + String(format: "*%02X", checksum)
    }

    /// Builds AIS payloads bit by bit.
    private struct Bits {
        var bits: [Bool] = []
        mutating func add(_ value: Int, _ n: Int) {
            for i in (0..<n).reversed() { bits.append((value >> i) & 1 == 1) }
        }
        mutating func addText(_ text: String, _ length: Int) {
            for ch in text.padding(toLength: length, withPad: "@", startingAt: 0).unicodeScalars {
                let v = Int(ch.value)
                add(v >= 64 ? v - 64 : v, 6)
            }
        }
        var payload: String {
            var out = ""
            var padded = bits
            while padded.count % 6 != 0 { padded.append(false) }
            for i in stride(from: 0, to: padded.count, by: 6) {
                var v = 0
                for b in padded[i..<(i + 6)] { v = v << 1 | (b ? 1 : 0) }
                let c = v < 40 ? v + 48 : v + 56
                out.append(Character(UnicodeScalar(UInt8(c))))
            }
            return out
        }
    }
}

struct NavigationMathTests {
    @Test func closestPointOfApproach() {
        let own = CLLocationCoordinate2D(latitude: 45, longitude: 14)
        // A ship 2 NM north heading south at 10 kn, while we sit still: passes through us in 12 minutes.
        let target = Geo.destination(from: own, bearing: 0, distanceNM: 2)
        let a = Approach.between(own: own, ownSOG: 0, ownCOG: 0, target: target, targetSOG: 10, targetCOG: 180)
        #expect(a.distance < 0.01)
        #expect(abs(a.time - 0.2) < 0.001)
        // Same ship heading away: closest is now.
        let away = Approach.between(own: own, ownSOG: 0, ownCOG: 0, target: target, targetSOG: 10, targetCOG: 0)
        #expect(away.time == 0)
    }

    @Test func sunTimesInRijeka() throws {
        // 21 June in Rijeka: solar noon 13:04 CEST, day length 15 h 40 min: sunrise 05:15, sunset 20:54.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zagreb")!
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12)))
        let times = Sun.times(at: CLLocationCoordinate2D(latitude: 45.33, longitude: 14.44), on: day, calendar: calendar)
        let sunrise = try #require(times.sunrise), sunset = try #require(times.sunset)
        let rise = calendar.dateComponents([.hour, .minute], from: sunrise), set = calendar.dateComponents([.hour, .minute], from: sunset)
        #expect(abs((rise.hour! * 60 + rise.minute!) - (5 * 60 + 15)) <= 4)
        #expect(abs((set.hour! * 60 + set.minute!) - (20 * 60 + 54)) <= 4)
        #expect(Sun.palette(at: CLLocationCoordinate2D(latitude: 45.33, longitude: 14.44), date: day) == .day)
    }

    @Test func seaLevelTurningPoints() {
        let times = (0..<13).map { Double($0) * 3600 }
        let heights: [Double?] = times.map { sin($0 / 3600 / 12 * 2 * .pi) * 0.3 }
        let level = SeaLevel(lat: 45, lon: 14, times: times, height: heights)
        let turns = level.turningPoints
        #expect(turns.count == 2)
        #expect(turns[0].high && !turns[1].high)
    }
}

struct ChartStyleTests {
    @Test func everyPaletteAndBaseBuildsAStyle() throws {
        for palette in ChartPalette.allCases {
            for base in MapBase.allCases {
                let style = ChartStyle(palette: palette, base: base, server: URL(string: "https://example.org")!,
                                       packs: [.init(id: "adriatic", file: URL(fileURLWithPath: "/tmp/a.pmtiles"), west: 13, south: 42, east: 19, north: 45.6)],
                                       safetyDepth: 2.8, showSeamarks: true, showSoundings: true)
                let json = style.json()
                let layers = try #require(json["layers"] as? [[String: Any]])
                let ids = layers.compactMap { $0["id"] as? String }
                #expect(Set(ids).count == ids.count, "layer ids are unique")
                for live in ChartStyle.Live.allCases {
                    #expect((json["sources"] as? [String: Any])?["live-\(live.rawValue)"] != nil)
                }
                // Dash patterns can't vary per feature in MapLibre: always plain arrays.
                for layer in layers {
                    if let dash = (layer["paint"] as? [String: Any])?["line-dasharray"] {
                        #expect(dash is [Double] || dash is [Int], "\(layer["id"] ?? "")")
                    }
                }
                #expect(try JSONSerialization.data(withJSONObject: json).count > 10_000)
            }
        }
    }

    @Test func safetyContourIsTheNextDeeper() {
        #expect(ChartStyle.safetyContour(2.8, in: ChartStyle.packContours) == 3)
        #expect(ChartStyle.safetyContour(2.8, in: ChartStyle.bathyContours) == 5)
        #expect(ChartStyle.safetyContour(500, in: ChartStyle.packContours) == 100)
    }
}

struct LightCharacteristicTests {
    @Test func parsesStandardDescriptions() {
        // Fl(2)R.5s 12m 6M
        let fl2r = LightCharacteristic.parse("Fl(2)R.5s 12m 6M")
        #expect(fl2r != nil)
        #expect(fl2r?.rhythm == .flashing)
        #expect(fl2r?.group == 2)
        #expect(fl2r?.color == .red)
        #expect(fl2r?.period == 5.0)

        // Iso.4s
        let iso = LightCharacteristic.parse("Iso.4s")
        #expect(iso?.rhythm == .isophase)
        #expect(iso?.period == 4.0)
        #expect(iso?.color == .white)

        // Q(9)W.15s
        let q9 = LightCharacteristic.parse("Q(9)W.15s")
        #expect(q9?.rhythm == .quick)
        #expect(q9?.group == 9)
        #expect(q9?.period == 15.0)
        #expect(q9?.color == .white)

        // FG
        let fg = LightCharacteristic.parse("FG")
        #expect(fg?.rhythm == .fixed)
        #expect(fg?.color == .green)
        #expect(fg?.period == 1.0)

        // Oc(3)Y.10s
        let oc3y = LightCharacteristic.parse("Oc(3)Y.10s")
        #expect(oc3y?.rhythm == .occulting)
        #expect(oc3y?.group == 3)
        #expect(oc3y?.color == .yellow)
        #expect(oc3y?.period == 10.0)

        // Mo(A)W.6s
        let moA = LightCharacteristic.parse("Mo(A)W.6s")
        if case .morse(let code) = moA?.rhythm {
            #expect(code == "A")
        } else {
            Issue.record("Expected morse rhythm")
        }
    }

    @Test func computesAccurateIsOnTiming() {
        guard let fl = LightCharacteristic.parse("Fl.5s") else {
            Issue.record("Failed to parse Fl.5s")
            return
        }

        // Flashing rhythm has flash at start of cycle (t = 0..0.6s)
        let t0 = Date(timeIntervalSinceReferenceDate: 0.1)
        let tDark = Date(timeIntervalSinceReferenceDate: 2.5)
        #expect(fl.isOn(at: t0) == true)
        #expect(fl.isOn(at: tDark) == false)

        // Fixed light is always on
        guard let fixed = LightCharacteristic.parse("FR") else {
            Issue.record("Failed to parse FR")
            return
        }
        #expect(fixed.isOn(at: t0) == true)
        #expect(fixed.isOn(at: tDark) == true)
    }

    @Test func parsesAdriaticSeamarksDataset() throws {
        struct FileMeta: Decodable {
            let seamarks: [Seamark]
        }
        let fileURL = URL(fileURLWithPath: "Leeway/Charts/adriatic.json")
        if let data = try? Data(contentsOf: fileURL),
           let meta = try? JSONDecoder().decode(FileMeta.self, from: data) {
            var parsedCount = 0
            for mark in meta.seamarks where mark.light != nil {
                if let light = mark.lightCharacteristic {
                    parsedCount += 1
                    #expect(light.period > 0)
                }
            }
            #expect(parsedCount > 400, "Should parse majority of the 512 seamarks with light characteristics")
        }
    }
}

