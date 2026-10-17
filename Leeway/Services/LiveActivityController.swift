import ActivityKit
import Foundation

/// Keeps one Live Activity in step with the underway state: started when navigation,
/// anchor watch or MOB begins, updated as the boat moves, ended when all of them stop.
final class LiveActivityController {
    private var activity: Activity<UnderwayAttributes>?
    private var lastSent: UnderwayAttributes.ContentState?
    private var lastSentAt = Date.distantPast
    private var pending: Task<Void, Never>?

    /// Updates more often than this only for big changes (alarm, MOB, switching mode).
    private static let minimumInterval: TimeInterval = 5

    init() {
        // Adopt the activity left from before a relaunch; drop any extras.
        let existing = Activity<UnderwayAttributes>.activities
        activity = existing.first
        for extra in existing.dropFirst() {
            Self.end(id: extra.id)
        }
    }

    func sync(_ state: UnderwayAttributes.ContentState?, boatName: String) {
        guard let state else {
            end()
            return
        }
        let urgent = lastSent.map { $0.kind != state.kind || $0.anchorAlarm != state.anchorAlarm || $0.arrived != state.arrived } ?? true
        guard state != lastSent, urgent || Date.now.timeIntervalSince(lastSentAt) >= Self.minimumInterval else { return }
        lastSent = state
        lastSentAt = .now
        // Shown as "No GPS update" if the app stops updating it.
        let content = ActivityContent(state: state, staleDate: Date.now.addingTimeInterval(180),
                                      relevanceScore: state.kind == .navigation ? 50 : 100)

        // Anything not ended is still ours (a just-requested activity can be pending for a moment).
        if let activity, activity.activityState != .ended && activity.activityState != .dismissed {
            let id = activity.id
            pending = Task { await Self.update(id: id, content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for stray in Activity<UnderwayAttributes>.activities { Self.end(id: stray.id) }
        activity = try? Activity.request(attributes: UnderwayAttributes(boatName: boatName), content: content)
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        lastSent = nil
        pending?.cancel()
        Self.end(id: activity.id)
    }

    private static func end(id: String) {
        Task { await finish(id: id) }
    }

    // Activity isn't Sendable, so these look it up by id off the main actor instead of passing it across.
    nonisolated private static func update(id: String, _ content: ActivityContent<UnderwayAttributes.ContentState>) async {
        await Activity<UnderwayAttributes>.activities.first { $0.id == id }?.update(content)
    }

    nonisolated private static func finish(id: String) async {
        await Activity<UnderwayAttributes>.activities.first { $0.id == id }?.end(nil, dismissalPolicy: .immediate)
    }
}
