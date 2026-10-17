import CoreLocation
import Foundation
import Testing
@testable import Leeway

/// The Adriatic chart pack shipped with the app, loaded once (it's a 40 MB grid).
private let adriatic: ChartRegion? = ChartRegion.all(bundle: .main).first { $0.id == "adriatic" }

private func coordinate(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

/// A uniform wind over the Kvarner for four days.
private func steadyWind(from direction: Double, knots: Double) -> WindField {
    let start = (Date.now.timeIntervalSince1970 / 3600).rounded(.down) * 3600
    let times = (0..<96).map { start + Double($0) * 3600 }
    var points: [WindGrid.Point] = []
    for lat in stride(from: 44.0, through: 46.0, by: 0.25) {
        for lon in stride(from: 13.5, through: 15.5, by: 0.25) {
            points.append(WindGrid.Point(lat: lat, lon: lon, windSpeed: times.map { _ in knots },
                                         windFrom: times.map { _ in direction }, gust: times.map { _ in knots * 1.3 }, waveHeight: nil))
        }
    }
    return WindField(WindGrid(step: 0.25, times: times, points: points))!
}

@Suite(.serialized) struct RoutingTests {
    let rules: NavigationRules
    /// A pure sailing boat: no engine to motor straight into the wind.
    let boat: BoatProfile = {
        var boat = BoatProfile()
        boat.motorThreshold = 0
        return boat
    }()

    init() throws {
        let region = try #require(adriatic)
        rules = NavigationRules(region: region, safetyDepth: boat.safetyDepth, airDraft: boat.airDraft)
    }

    @Test func shortestRouteStaysInSafeWater() throws {
        // Rijeka to Cres town, round the north of Cres.
        let points = [coordinate(45.315, 14.43), coordinate(44.96, 14.405)]
        let grid = RoutingGrid(rules: rules, around: points)
        let routed = try Router.route(through: points, on: grid)
        #expect(routed.path.count >= 3, "goes round the island, not through it")
        // The ends may cross shallows to reach a quay; everything between is safe water.
        let legs = Array(zip(routed.path, routed.path.dropFirst())).dropFirst().dropLast()
        for (a, b) in legs {
            #expect(Router.hazard(from: a, to: b, rules: rules) == nil, "\(a) → \(b)")
        }
    }

    @Test func warnsWhenARouteLeavesTheChart() {
        let inside = [coordinate(45.2, 14.4), coordinate(45.0, 14.4)]
        #expect(Router.notes(for: inside, rules: rules).allSatisfy { !$0.contains("outside the detailed chart") })
        // Far east of the Adriatic pack.
        let outside = [coordinate(45.2, 14.4), coordinate(45.2, 19.6)]
        #expect(Router.notes(for: outside, rules: rules).contains { $0.contains("outside the detailed chart") })
    }

    @Test func fastestRouteTacksUpwindAndStaysClear() throws {
        // Open water south of Rijeka, finish dead upwind in a northerly.
        let start = coordinate(45.20, 14.38), goal = coordinate(45.29, 14.38)
        let grid = RoutingGrid(rules: rules, around: [start, goal])
        let wind = steadyWind(from: 0, knots: 14)
        let result = try WeatherRouter.route(from: start, to: goal, departure: .now, boat: boat, wind: wind, grid: grid)
        #expect(result.tacks >= 1, "can't sail straight into the wind")
        #expect(result.path.first.map { Geo.distanceNM($0, start) } ?? 1 < 0.01)
        #expect(result.path.last.map { Geo.distanceNM($0, goal) } ?? 1 < 0.01)
        for (a, b) in zip(result.path, result.path.dropFirst()) {
            #expect(grid.isClear(a, b), "every leg in navigable water")
        }
        // Beating takes longer than the straight distance at full speed.
        let hours = result.arrival.timeIntervalSinceNow / 3600
        #expect(hours > Geo.distanceNM(start, goal) / boat.sailSpeed)
    }

    @Test func fastestRouteReachesStraight() throws {
        let start = coordinate(45.20, 14.36), goal = coordinate(45.20, 14.47)
        let grid = RoutingGrid(rules: rules, around: [start, goal])
        let result = try WeatherRouter.route(from: start, to: goal, departure: .now, boat: boat,
                                             wind: steadyWind(from: 0, knots: 14), grid: grid)
        #expect(result.tacks == 0, "a beam reach needs no tacks")
        #expect(Geo.length(of: result.path) < Geo.distanceNM(start, goal) * 1.1)
    }

    @Test func windFieldInterpolates() throws {
        let wind = steadyWind(from: 270, knots: 10)
        let w = try #require(wind.wind(at: coordinate(45.13, 14.61), time: .now.addingTimeInterval(1800)))
        #expect(abs(w.speed - 10) < 0.01)
        #expect(abs(Geo.angleDiff(w.from, 270)) < 0.5)
    }
}

struct PolarTests {
    @Test func interpolatesAndClamps() {
        let polar = PolarTable(name: "test", windSpeeds: [6, 12], angles: [45, 90, 180], speeds: [[4, 6], [5, 8], [3, 6]])
        #expect(polar.speed(twa: 90, tws: 12) == 8)
        #expect(abs(polar.speed(twa: 90, tws: 9) - 6.5) < 1e-9)
        #expect(abs(polar.speed(twa: 67.5, tws: 6) - 4.5) < 1e-9)
        #expect(polar.speed(twa: 30, tws: 12) == 0, "inside the no-go zone")
        #expect(polar.speed(twa: 90, tws: 30) == 8, "holds the strongest column")
        #expect(abs(polar.speed(twa: 90, tws: 3) - 2.5) < 1e-9, "scales down in light air")
    }

    @Test func roundTripsTextFormat() throws {
        let preset = PolarTable.presets[1]
        let parsed = try #require(PolarTable.parse(preset.export(), name: preset.name))
        #expect(parsed.windSpeeds == preset.windSpeeds)
        #expect(parsed.angles == preset.angles)
        #expect(abs(parsed.speed(twa: 100, tws: 13) - preset.speed(twa: 100, tws: 13)) < 0.01)
    }

    @Test func parsesSemicolonFiles() throws {
        let text = "twa/tws;6;10;14\n52;4.5;6.1;6.8\n90;5.6;7.2;7.7\n150;4.0;6.0;7.1\n"
        let polar = try #require(PolarTable.parse(text, name: "x"))
        #expect(polar.speed(twa: 90, tws: 10) == 7.2)
    }

    @Test func presetsLookLikeBoats() {
        for preset in PolarTable.presets {
            let beam = preset.speed(twa: 100, tws: 16), beat = preset.speed(twa: 45, tws: 16), run = preset.speed(twa: 180, tws: 16)
            #expect(beam > beat && beam > run, "\(preset.name): fastest reaching")
            #expect(preset.speed(twa: 100, tws: 8) < beam, "\(preset.name): slower in light air")
        }
    }
}
