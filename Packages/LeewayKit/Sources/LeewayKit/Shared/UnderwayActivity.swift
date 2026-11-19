import ActivityKit
import Foundation

/// The Live Activity shown on the lock screen and in the Dynamic Island while navigating,
/// at anchor or after a man-overboard. Shared by the app and the widget extension.
nonisolated struct UnderwayAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable { case navigation, anchor, mob }

        var kind: Kind

        // Navigation
        var nextName: String?
        var bearing: Double?          // ° true, also used for MOB
        var distance: Double?         // NM, also used for MOB
        var crossTrack: Double?       // NM, + = right of track
        var etaNext: Date?
        var remaining: Double?        // NM to finish
        var etaFinish: Date?
        var sog: Double?
        var arrived = false

        // Anchor watch
        var anchorDistance: Double?   // m
        var anchorRadius: Double?     // m
        var anchorMax: Double?        // m
        var anchorAlarm = false

        // MOB
        var mobTime: Date?
    }

    var boatName: String
}

nonisolated enum UnderwayFormat {
    /// NM, or metres when close.
    static func distance(_ nm: Double) -> String {
        nm < 0.3 ? "\(Int((nm * 1852).rounded())) m" : String(format: "%.1f NM", nm)
    }

    static func bearing(_ degrees: Double) -> String { String(format: "%03.0f°", degrees) }
}
