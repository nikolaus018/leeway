import CoreLocation
import Observation

/// Own-ship position, speed and course, plus an optional recorded track.
@Observable
final class LocationTracker {
    private(set) var location: CLLocation?
    private(set) var isRecording = false
    private(set) var trackPoints: [TrackPoint] = []
    private(set) var trackDistance = 0.0
    private(set) var recordingStarted: Date?
    /// Called with the finished track when recording stops, for the logbook.
    var onTrackFinished: ((TrackLog) -> Void)?

    var track: [CLLocationCoordinate2D] { trackPoints.map(\.coordinate) }

    /// Speed over ground in knots, if the fix has one.
    var sog: Double? {
        guard let l = location, l.speed >= 0 else { return nil }
        return l.speed * 3600 / 1852
    }
    /// Course over ground, ° true.
    var cog: Double? {
        guard let l = location, l.course >= 0 else { return nil }
        return l.course
    }

    /// Called with every new fix (navigation, MOB and anchor watch listen here).
    var onUpdate: ((CLLocation) -> Void)?
    /// Keep receiving fixes with the screen off (navigation, anchor watch, MOB).
    var keepAlive = false { didSet { updateBackgroundSession() } }

    private var updates: Task<Void, Never>?
    private var session: CLServiceSession?
    private var background: CLBackgroundActivitySession?

    func start() {
        guard updates == nil else { return }
        session = CLServiceSession(authorization: .whenInUse)
        updates = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let location = update.location else { continue }
                    self?.receive(location)
                }
            } catch {}
        }
    }

    func toggleRecording() {
        if isRecording {
            isRecording = false
            if let started = recordingStarted, trackPoints.count >= 2 {
                onTrackFinished?(TrackLog(start: started, points: trackPoints, distance: trackDistance))
            }
        } else {
            trackPoints = location.map { [TrackPoint($0)] } ?? []
            trackDistance = 0
            recordingStarted = .now
            isRecording = true
        }
        updateBackgroundSession()
    }

    func startRecordingIfNeeded() {
        if !isRecording { toggleRecording() }
    }

    private func updateBackgroundSession() {
        let needed = isRecording || keepAlive
        if needed, background == nil { background = CLBackgroundActivitySession() }
        if !needed {
            background?.invalidate()
            background = nil
        }
    }

    func clearTrack() {
        guard !isRecording else { return }
        trackPoints = []
        trackDistance = 0
        recordingStarted = nil
    }

    private func receive(_ new: CLLocation) {
        location = new
        onUpdate?(new)
        guard isRecording, new.horizontalAccuracy >= 0, new.horizontalAccuracy < 50 else { return }
        if let last = trackPoints.last {
            let moved = Geo.distanceNM(last.coordinate, new.coordinate)
            guard moved > 0.005 else { return } // ~10 m, ignore GPS jitter
            trackDistance += moved
        }
        trackPoints.append(TrackPoint(new))
    }
}

/// One recorded position.
nonisolated struct TrackPoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var time: Date
    /// Knots, if the fix had a speed.
    var sog: Double?

    init(_ coordinate: CLLocationCoordinate2D, time: Date, sog: Double?) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.time = time
        self.sog = sog
    }

    init(_ location: CLLocation) {
        self.init(location.coordinate, time: location.timestamp, sog: location.speed >= 0 ? location.speed * 3600 / 1852 : nil)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// A finished passage in the logbook.
nonisolated struct TrackLog: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date
    var points: [TrackPoint]
    /// NM.
    var distance: Double

    init(name: String? = nil, start: Date, points: [TrackPoint], distance: Double? = nil) {
        self.start = start
        self.points = points
        end = points.last?.time ?? start
        self.distance = distance ?? Geo.length(of: points.map(\.coordinate))
        self.name = name ?? start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var maxSOG: Double? { points.compactMap(\.sog).max() }
    /// Distance over time under way.
    var averageSOG: Double? { duration > 60 ? distance / (duration / 3600) : nil }
}
