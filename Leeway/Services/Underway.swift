import AudioToolbox
import AVFoundation
import CoreLocation
import Observation
import UIKit
import UserNotifications

/// Everything that happens while the boat is moving or at anchor: following a route,
/// man-overboard, and the anchor watch. Fed by every GPS fix; survives relaunches.
@Observable
final class Underway {
    // MARK: Route following

    struct Navigation: Codable {
        var points: [Waypoint]
        var activeLeg: Int
        var started: Date
    }

    /// Live numbers for the panel, recomputed on every fix.
    struct Readout {
        var nextName: String
        var bearing: Double          // ° true to the next waypoint
        var distance: Double         // NM to the next waypoint
        var crossTrack: Double       // NM, + = right of track (steer port to come back)
        var remaining: Double        // NM to the destination along the route
        var sog: Double?
        var vmg: Double?             // speed made good towards the next waypoint
        var etaNext: Date?
        var etaFinish: Date?
        var offCourse: Bool
    }

    private(set) var navigation: Navigation? { didSet { persist() } }
    private(set) var readout: Readout?
    private(set) var arrived = false

    var isNavigating: Bool { navigation != nil }

    /// Within this distance of a waypoint, move on to the next leg.
    static let arrivalRadius = 0.04      // NM ≈ 75 m
    static let offCourseLimit = 0.1      // NM ≈ 185 m

    // MARK: MOB

    struct ManOverboard: Codable {
        var latitude: Double
        var longitude: Double
        var time: Date
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    private(set) var mob: ManOverboard? { didSet { persist() } }
    private(set) var mobBearing: Double?
    private(set) var mobDistance: Double?

    // MARK: Anchor watch

    struct AnchorWatch: Codable {
        var latitude: Double
        var longitude: Double
        var radius: Double           // metres
        var dropped: Date
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    private(set) var anchor: AnchorWatch? { didSet { persist() } }
    private(set) var anchorDistance: Double?          // metres, now
    private(set) var anchorMaxDistance = 0.0          // metres, since dropped
    private(set) var swing: [CLLocationCoordinate2D] = []
    private(set) var anchorAlarm = false
    private var outsideCount = 0
    /// After "Silence": stay quiet until the boat drags further or a while passes.
    private var snooze: (distance: Double, until: Date)?

    let alarm = AlarmPlayer()
    private var lastFix: CLLocation?

    init() {
        if let data = UserDefaults.standard.data(forKey: "underway"),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            navigation = saved.navigation
            mob = saved.mob
            anchor = saved.anchor
        }
    }

    var needsBackground: Bool { navigation != nil || mob != nil || anchor != nil }

    // MARK: Commands

    func startNavigation(along path: [CLLocationCoordinate2D], from location: CLLocation?) {
        guard path.count >= 2 else { return }
        var leg = 0
        // Joining a route part-way: pick the leg the boat is closest to.
        if let here = location?.coordinate, Geo.distanceNM(here, path[0]) > 0.5 {
            leg = zip(path, path.dropFirst()).enumerated().min { a, b in
                distanceToLeg(here, a.element) < distanceToLeg(here, b.element)
            }?.offset ?? 0
        }
        navigation = Navigation(points: path.map(Waypoint.init), activeLeg: leg, started: .now)
        arrived = false
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if let lastFix { update(with: lastFix) }
    }

    func stopNavigation() {
        navigation = nil
        readout = nil
        arrived = false
    }

    func skipWaypoint(by step: Int) {
        guard var nav = navigation else { return }
        nav.activeLeg = min(max(0, nav.activeLeg + step), nav.points.count - 2)
        navigation = nav
        if let lastFix { update(with: lastFix) }
    }

    func manOverboard() {
        guard let fix = lastFix else { return }
        mob = ManOverboard(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, time: .now)
        alarm.sound(.mob)
        update(with: fix)
    }

    func cancelMOB() {
        mob = nil
        mobBearing = nil
        mobDistance = nil
        alarm.stop()
    }

    func dropAnchor(radius: Double) {
        guard let fix = lastFix else { return }
        anchor = AnchorWatch(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, radius: radius, dropped: .now)
        anchorMaxDistance = 0
        swing = [fix.coordinate]
        anchorAlarm = false
        outsideCount = 0
        snooze = nil
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        update(with: fix)
    }

    func setAnchorRadius(_ radius: Double) {
        anchor?.radius = radius
        if let lastFix { update(with: lastFix) }
    }

    func silenceAnchorAlarm() {
        alarm.stop()
        if anchorAlarm { snooze = (anchorDistance ?? 0, Date.now.addingTimeInterval(300)) }
        anchorAlarm = false
    }

    func liftAnchor() {
        anchor = nil
        anchorDistance = nil
        swing = []
        silenceAnchorAlarm()
    }

    // MARK: Updates

    func update(with fix: CLLocation) {
        lastFix = fix
        let here = fix.coordinate
        let sog = fix.speed >= 0 ? fix.speed * 3600 / 1852 : nil
        let cog = fix.course >= 0 ? fix.course : nil

        if let mob {
            mobBearing = Geo.bearing(here, mob.coordinate)
            mobDistance = Geo.distanceNM(here, mob.coordinate)
        }

        if let anchor, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy < 30 {
            let metres = Geo.distanceNM(anchor.coordinate, here) * 1852
            anchorDistance = metres
            anchorMaxDistance = max(anchorMaxDistance, metres)
            if swing.last.map({ Geo.distanceNM($0, here) * 1852 > 3 }) ?? true {
                swing.append(here)
                if swing.count > 2000 { swing.removeFirst(swing.count - 2000) }
            }
            // Three fixes in a row outside the circle, so a single GPS jump doesn't wake the crew.
            outsideCount = metres > anchor.radius ? outsideCount + 1 : 0
            if outsideCount == 0 { snooze = nil }
            let snoozed = snooze.map { metres < $0.distance + 20 && Date.now < $0.until } ?? false
            if outsideCount >= 3 && !anchorAlarm && !snoozed {
                anchorAlarm = true
                alarm.sound(.anchor, message: "Anchor dragging: \(Int(metres)) m from the anchor (circle \(Int(anchor.radius)) m).")
            }
        }

        guard var nav = navigation else { return }
        let points = nav.points.map(\.coordinate)
        var leg = nav.activeLeg
        // Move on when inside the arrival circle or past the end of the leg.
        while leg < points.count - 1 {
            let target = points[leg + 1]
            let along = Geo.crossTrack(from: points[leg], to: target, point: here).along
            let passed = along > Geo.distanceNM(points[leg], target)
            let inside = Geo.distanceNM(here, target) < Self.arrivalRadius
            guard passed || inside else { break }
            if leg == points.count - 2 {
                if inside && !arrived {
                    arrived = true
                    alarm.sound(.arrival, message: "Arrived at your destination.")
                }
                break
            }
            leg += 1
        }
        if leg != nav.activeLeg {
            nav.activeLeg = leg
            navigation = nav
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }

        let a = points[leg], b = points[leg + 1]
        let bearing = Geo.bearing(here, b)
        let distance = Geo.distanceNM(here, b)
        let xte = Geo.crossTrack(from: a, to: b, point: here).cross
        let remaining = distance + Geo.length(of: Array(points[(leg + 1)...]))
        var vmg: Double?
        if let sog, let cog { vmg = sog * cos(Geo.angleDiff(cog, bearing).radians) }
        // ETA from speed made good, falling back to speed over ground when VMG is meaningless.
        let speed: Double? = if let vmg, vmg > 0.5 { vmg } else if let sog, sog > 0.5 { sog } else { nil }
        let wasOff = readout?.offCourse ?? false
        let offCourse = abs(xte) > Self.offCourseLimit
        if offCourse && !wasOff { alarm.nudge() }
        readout = Readout(
            nextName: leg + 1 == points.count - 1 ? "Finish" : "WP \(leg + 1)",
            bearing: bearing, distance: distance, crossTrack: xte, remaining: remaining,
            sog: sog, vmg: vmg,
            etaNext: speed.map { Date.now.addingTimeInterval(distance / $0 * 3600) },
            etaFinish: sog.flatMap { $0 > 0.5 ? Date.now.addingTimeInterval(remaining / $0 * 3600) : nil },
            offCourse: offCourse
        )
    }

    /// Waypoints after the active leg's end, for drawing the rest of the route.
    var pointsAhead: [CLLocationCoordinate2D] {
        guard let nav = navigation, nav.activeLeg + 1 < nav.points.count else { return [] }
        return nav.points[(nav.activeLeg + 1)...].map(\.coordinate)
    }

    /// The leg the boat is on, for drawing (start, end).
    var activeLegPoints: (CLLocationCoordinate2D, CLLocationCoordinate2D)? {
        guard let nav = navigation, nav.activeLeg + 1 < nav.points.count else { return nil }
        return (nav.points[nav.activeLeg].coordinate, nav.points[nav.activeLeg + 1].coordinate)
    }

    private func distanceToLeg(_ p: CLLocationCoordinate2D, _ leg: (CLLocationCoordinate2D, CLLocationCoordinate2D)) -> Double {
        let t = Geo.crossTrack(from: leg.0, to: leg.1, point: p)
        let length = Geo.distanceNM(leg.0, leg.1)
        if t.along < 0 { return Geo.distanceNM(p, leg.0) }
        if t.along > length { return Geo.distanceNM(p, leg.1) }
        return abs(t.cross)
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var navigation: Navigation?
        var mob: ManOverboard?
        var anchor: AnchorWatch?
    }

    private func persist() {
        let saved = Saved(navigation: navigation, mob: mob, anchor: anchor)
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "underway")
    }
}

/// Loud, repeated alarms that work with the phone on silent, plus a notification when the app is in the background.
final class AlarmPlayer {
    enum Kind { case mob, anchor, arrival }

    private var timer: Timer?

    func sound(_ kind: Kind, message: String? = nil) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let repeating = kind != .arrival
        let play = {
            AudioServicesPlayAlertSound(SystemSoundID(kind == .arrival ? 1025 : 1005))
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        play()
        if repeating {
            // The anchor alarm rings until silenced; MOB rings a few times, then lets the crew work.
            var remaining = kind == .mob ? 4 : Int.max
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                remaining -= 1
                if remaining < 0 { self?.stop() } else { play() }
            }
        }
        if let message, UIApplication.shared.applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = kind == .anchor ? "Anchor alarm" : kind == .mob ? "Man overboard" : "Leeway"
            content.body = message
            content.sound = .defaultCritical
            content.interruptionLevel = .timeSensitive
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// A short buzz, e.g. when drifting off course.
    func nudge() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
