import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LeewayWidgets: WidgetBundle {
    var body: some Widget {
        UnderwayLiveActivity()
    }
}

struct UnderwayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UnderwayAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(context.state.isAlarm ? Color.red : nil)
                .activitySystemActionForegroundColor(context.state.isAlarm ? .white : .accentColor)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(state.title, systemImage: state.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(state.isAlarm ? .red : .cyan)
                        Text(state.primary)
                            .font(.title2.weight(.bold).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state.secondaryCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        Text(state.secondary)
                            .font(.title2.weight(.bold).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DetailLine(state: state, compact: true)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } compactLeading: {
                Label {
                    Text(state.compactLeading).monospacedDigit()
                } icon: {
                    Image(systemName: state.symbol)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(state.isAlarm ? .red : .cyan)
            } compactTrailing: {
                Text(state.compactTrailing)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(state.isAlarm ? .red : .primary)
            } minimal: {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.isAlarm ? .red : .cyan)
            }
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    var state: UnderwayAttributes.ContentState
    var stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(state.title, systemImage: state.symbol)
                    .font(.headline.weight(state.isAlarm ? .heavy : .semibold))
                Spacer()
                if state.kind == .mob, let time = state.mobTime {
                    Text(time, style: .timer)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                } else if stale {
                    Label("No GPS update", systemImage: "location.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(state.isAlarm ? .white : .primary)

            switch state.kind {
            case .navigation:
                if state.arrived {
                    Text("Arrived").font(.title.weight(.bold))
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Figure(caption: "BTW", value: state.bearing.map(UnderwayFormat.bearing) ?? "–")
                        Figure(caption: "DTW", value: state.distance.map(UnderwayFormat.distance) ?? "–")
                        Figure(caption: "ETA", value: state.etaNext.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–")
                    }
                    DetailLine(state: state)
                        .font(.footnote.weight(.medium))
                }
            case .anchor:
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Figure(caption: "FROM ANCHOR", value: "\(Int(state.anchorDistance ?? 0)) m")
                    Figure(caption: "CIRCLE", value: "\(Int(state.anchorRadius ?? 0)) m")
                    Figure(caption: "MAX", value: "\(Int(state.anchorMax ?? 0)) m")
                }
                .foregroundStyle(state.anchorAlarm ? .white : .primary)
                ProgressView(value: min(state.anchorDistance ?? 0, state.anchorRadius ?? 1), total: max(state.anchorRadius ?? 1, 1))
                    .tint(state.anchorAlarm ? .white : (state.anchorDistance ?? 0) > (state.anchorRadius ?? 0) * 0.8 ? .orange : .green)
            case .mob:
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(state.bearing.map(UnderwayFormat.bearing) ?? "–")
                        .font(.system(size: 40, weight: .heavy).monospacedDigit())
                    Text(state.distance.map(UnderwayFormat.distance) ?? "–")
                        .font(.title.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(.white)
                Text("Steer to the bearing. Keep the casualty in sight.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(16)
    }
}

private struct Figure: View {
    var caption: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Cross-track error and the run to the finish (navigation), or a one-line summary otherwise.
private struct DetailLine: View {
    var state: UnderwayAttributes.ContentState
    /// In the Dynamic Island: leave out the finish ETA to fit.
    var compact = false

    var body: some View {
        switch state.kind {
        case .navigation:
            HStack(spacing: 4) {
                if let xte = state.crossTrack {
                    let off = abs(xte) > 0.1
                    Image(systemName: xte > 0 ? "arrow.left" : "arrow.right")
                    Text("XTE \(UnderwayFormat.distance(abs(xte))) \(xte > 0 ? "R" : "L")")
                        .foregroundStyle(off ? .red : .secondary)
                }
                Spacer()
                if let remaining = state.remaining {
                    Text("Finish \(UnderwayFormat.distance(remaining))\(compact ? "" : state.etaFinish.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? "")")
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
        case .anchor:
            Text(state.anchorAlarm ? "Anchor dragging — open Leeway" : "Anchor holding")
                .foregroundStyle(state.anchorAlarm ? .red : .secondary)
        case .mob:
            Text("Man overboard — steer \(state.bearing.map(UnderwayFormat.bearing) ?? "–")")
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Text for each kind

private extension UnderwayAttributes.ContentState {
    var isAlarm: Bool { kind == .mob || (kind == .anchor && anchorAlarm) }

    var title: String {
        switch kind {
        case .navigation: arrived ? "Arrived" : "To \(nextName ?? "next waypoint")"
        case .anchor: anchorAlarm ? "ANCHOR DRAGGING" : "Anchor watch"
        case .mob: "MAN OVERBOARD"
        }
    }

    var symbol: String {
        switch kind {
        case .navigation: "location.north.line.fill"
        case .anchor: anchorAlarm ? "exclamationmark.triangle.fill" : "arrow.down.to.line"
        case .mob: "figure.wave"
        }
    }

    var primary: String {
        switch kind {
        case .navigation, .mob: bearing.map(UnderwayFormat.bearing) ?? "–"
        case .anchor: "\(Int(anchorDistance ?? 0)) m"
        }
    }

    var secondaryCaption: String {
        switch kind {
        case .navigation: etaNext.map { "ETA " + $0.formatted(date: .omitted, time: .shortened) } ?? "Distance"
        case .anchor: "Circle"
        case .mob: "Distance"
        }
    }

    var secondary: String {
        switch kind {
        case .navigation, .mob: distance.map(UnderwayFormat.distance) ?? "–"
        case .anchor: "\(Int(anchorRadius ?? 0)) m"
        }
    }

    var compactLeading: String {
        switch kind {
        case .navigation, .mob: bearing.map(UnderwayFormat.bearing) ?? ""
        case .anchor: ""
        }
    }

    var compactTrailing: String {
        switch kind {
        case .navigation, .mob: distance.map(UnderwayFormat.distance) ?? "–"
        case .anchor: "\(Int(anchorDistance ?? 0)) m"
        }
    }
}
