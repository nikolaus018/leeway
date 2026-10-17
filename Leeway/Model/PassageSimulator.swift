import CoreLocation

struct LegResult: Identifiable {
    var id: Int { index }
    var index: Int
    var distance: Double
    var bearing: Double
    var departure: Date
    var arrival: Date
    var maxWind: Double
    var maxGust: Double
    var maxWave: Double?
    var meanTWA: Double
    var tacking: Bool
    var motoringFraction: Double
    /// Mean tidal stream component along the course; negative means foul tide.
    var meanCurrentAlong: Double

    var duration: TimeInterval { arrival.timeIntervalSince(departure) }
    var averageSOG: Double { distance / max(duration / 3600, 0.001) }
}

/// A point along the passage for drawing conditions on the chart.
struct PassageSample: Identifiable {
    var id: Int
    var coordinate: CLLocationCoordinate2D
    var time: Date
    var conditions: Conditions
}

struct PassagePlan {
    var departure: Date
    var arrival: Date
    var legs: [LegResult]
    var samples: [PassageSample]
    var usedForecast: Bool
    var beyondForecast: Bool

    var distance: Double { legs.reduce(0) { $0 + $1.distance } }
    var duration: TimeInterval { arrival.timeIntervalSince(departure) }
    var maxWind: Double { legs.map(\.maxWind).max() ?? 0 }
    var maxGust: Double { legs.map(\.maxGust).max() ?? 0 }
    var maxWave: Double? { legs.compactMap(\.maxWave).max() }
    var motoringFraction: Double {
        guard duration > 0 else { return 0 }
        return legs.reduce(0) { $0 + $1.motoringFraction * $1.duration } / duration
    }
}

struct DepartureOption: Identifiable {
    var id: Date { departure }
    var departure: Date
    var duration: TimeInterval
    var maxWind: Double
    var maxWave: Double?
    var motoringFraction: Double
    var rating: Rating

    enum Rating: String, CaseIterable, Comparable {
        case good = "Good", fair = "Fair", rough = "Rough"
        static func < (a: Rating, b: Rating) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    }
}

/// Steps the boat along the route in short increments, using the forecast wind and
/// tidal stream at each place and time to work out speed over the ground.
enum PassageSimulator {
    private static let stepNM = 0.5
    private static let minimumSOG = 0.3

    static func plan(route: [CLLocationCoordinate2D], boat: BoatProfile, forecast: RouteForecast?, departure: Date) -> PassagePlan? {
        guard route.count >= 2 else { return nil }
        var clock = departure
        var along = 0.0
        var legs: [LegResult] = []
        var samples: [PassageSample] = []
        let totalDistance = Geo.length(of: route)
        let sampleSpacing = max(totalDistance / 6, stepNM)
        var nextSample = 0.0

        for (index, (a, b)) in zip(route, route.dropFirst()).enumerated() {
            let legDistance = Geo.distanceNM(a, b)
            let legStart = clock
            var covered = 0.0
            var maxWind = 0.0, maxGust = 0.0, maxWave: Double?
            var twaSum = 0.0, currentSum = 0.0, stepCount = 0.0
            var motoringTime = 0.0
            var tacking = false

            while covered < legDistance - 1e-9 {
                let step = min(stepNM, legDistance - covered)
                let mid = Geo.interpolate(a, b, fraction: (covered + step / 2) / legDistance)
                let course = Geo.bearing(mid, b)
                let conditions = forecast?.conditions(alongNM: along + covered + step / 2, at: clock)
                let motion = speed(course: course, conditions: conditions, boat: boat)

                if along + covered >= nextSample, let conditions {
                    samples.append(PassageSample(id: samples.count, coordinate: mid, time: clock, conditions: conditions))
                    nextSample += sampleSpacing
                }

                let hours = step / motion.sog
                if motion.motoring { motoringTime += hours }
                tacking = tacking || motion.tacking
                if let c = conditions {
                    maxWind = max(maxWind, c.windSpeed)
                    maxGust = max(maxGust, c.gust)
                    if let w = c.waveHeight { maxWave = max(maxWave ?? 0, w) }
                }
                twaSum += motion.twa * step
                currentSum += motion.currentAlong * step
                stepCount += step
                covered += step
                clock += hours * 3600
            }

            let legHours = clock.timeIntervalSince(legStart) / 3600
            legs.append(LegResult(
                index: index,
                distance: legDistance,
                bearing: Geo.bearing(a, b),
                departure: legStart,
                arrival: clock,
                maxWind: maxWind,
                maxGust: maxGust,
                maxWave: maxWave,
                meanTWA: stepCount > 0 ? twaSum / stepCount : 0,
                tacking: tacking,
                motoringFraction: legHours > 0 ? min(1, motoringTime / legHours) : 0,
                meanCurrentAlong: stepCount > 0 ? currentSum / stepCount : 0
            ))
            along += legDistance
        }

        return PassagePlan(
            departure: departure,
            arrival: clock,
            legs: legs,
            samples: samples,
            usedForecast: forecast != nil,
            beyondForecast: forecast.map { clock > $0.validUntil } ?? false
        )
    }

    /// Plans the passage for each hourly departure in the forecast window and rates them.
    static func departureOptions(route: [CLLocationCoordinate2D], boat: BoatProfile, forecast: RouteForecast, from start: Date) -> [DepartureOption] {
        let firstHour = Calendar.current.dateInterval(of: .hour, for: start)!.end
        return (0..<72).compactMap { offset in
            let departure = firstHour.addingTimeInterval(Double(offset) * 3600)
            guard let plan = plan(route: route, boat: boat, forecast: forecast, departure: departure),
                  plan.arrival <= forecast.validUntil else { return nil }
            let wave = plan.maxWave ?? 0
            let rating: DepartureOption.Rating =
                plan.maxWind > boat.maxWind || wave > boat.maxWave ? .rough :
                plan.maxWind > boat.maxWind * 0.8 || wave > boat.maxWave * 0.8 || plan.motoringFraction > 0.5 ? .fair : .good
            return DepartureOption(
                departure: departure,
                duration: plan.duration,
                maxWind: plan.maxWind,
                maxWave: plan.maxWave,
                motoringFraction: plan.motoringFraction,
                rating: rating
            )
        }
    }

    private struct Motion { var sog: Double; var twa: Double; var tacking: Bool; var motoring: Bool; var currentAlong: Double }

    private static func speed(course: Double, conditions: Conditions?, boat: BoatProfile) -> Motion {
        guard let c = conditions else {
            // No forecast: assume a typical average speed.
            let sog = boat.propulsion == .motor ? boat.motorSpeed : boat.sailSpeed * 0.75
            return Motion(sog: sog, twa: 90, tacking: false, motoring: boat.propulsion == .motor, currentAlong: 0)
        }

        let twa = abs(Geo.angleDiff(c.windFrom, course))
        var throughWater: Double
        var tacking = false
        var motoring = boat.propulsion == .motor
        if motoring {
            throughWater = boat.motorSpeed
        } else {
            let sailing = Polar.speedAlongCourse(twa: twa, tws: c.windSpeed, best: boat.sailSpeed)
            if sailing.speed < boat.motorThreshold {
                throughWater = boat.motorSpeed
                motoring = true
            } else {
                throughWater = sailing.speed
                tacking = sailing.tacking
            }
        }

        // Steer into the cross-stream to hold the course; the along-course stream adds or subtracts.
        let relative = Geo.angleDiff(c.currentToward, course).radians
        let along = c.currentSpeed * cos(relative)
        let cross = c.currentSpeed * sin(relative)
        let sog = throughWater > abs(cross)
            ? sqrt(throughWater * throughWater - cross * cross) + along
            : along
        return Motion(sog: max(sog, minimumSOG), twa: twa, tacking: tacking, motoring: motoring, currentAlong: along)
    }
}
