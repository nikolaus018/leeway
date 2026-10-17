import CoreLocation
import Observation

/// Own-ship position, speed and course, plus an optional recorded track.
@Observable
final class LocationTracker {
    private(set) var location: CLLocation?
    private(set) var isRecording = false
    private(set) var track: [CLLocationCoordinate2D] = []
    private(set) var trackDistance = 0.0
    private(set) var recordingStarted: Date?

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
            background?.invalidate()
            background = nil
        } else {
            track = location.map { [$0.coordinate] } ?? []
            trackDistance = 0
            recordingStarted = .now
            isRecording = true
            background = CLBackgroundActivitySession()
        }
    }

    func clearTrack() {
        guard !isRecording else { return }
        track = []
        trackDistance = 0
        recordingStarted = nil
    }

    private func receive(_ new: CLLocation) {
        location = new
        guard isRecording, new.horizontalAccuracy >= 0, new.horizontalAccuracy < 50 else { return }
        if let last = track.last {
            let moved = Geo.distanceNM(last, new.coordinate)
            guard moved > 0.005 else { return } // ~10 m, ignore GPS jitter
            trackDistance += moved
        }
        track.append(new.coordinate)
    }
}
