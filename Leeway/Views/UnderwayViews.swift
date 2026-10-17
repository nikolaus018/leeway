import CoreLocation
import SwiftUI

/// Following a route: next waypoint, cross-track error, speeds and ETAs.
struct NavigationPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let underway = model.underway
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(underway.readout?.nextName ?? "Waiting for GPS…", systemImage: "arrow.forward.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Spacer(minLength: 4)
                Button("Previous waypoint", systemImage: "chevron.backward") { underway.skipWaypoint(by: -1) }
                    .labelStyle(.iconOnly)
                Button("Next waypoint", systemImage: "chevron.forward") { underway.skipWaypoint(by: 1) }
                    .labelStyle(.iconOnly)
                Button("Stop navigation", systemImage: "xmark.circle.fill") { model.stopNavigation() }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .font(.body.weight(.semibold))

            if underway.arrived {
                Label("Arrived", systemImage: "flag.checkered")
                    .font(.title2.weight(.bold))
            } else if let r = underway.readout {
                HStack(spacing: 16) {
                    Big(value: String(format: "%03.0f°", r.bearing), caption: "BTW")
                    Big(value: distance(r.distance), caption: "DTW")
                    Big(value: r.etaNext.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–", caption: "ETA")
                }
                HStack(spacing: 6) {
                    // Right of track means steer to port to get back, and vice versa.
                    Image(systemName: r.crossTrack > 0 ? "arrow.left" : "arrow.right")
                        .opacity(abs(r.crossTrack) < 0.005 ? 0 : 1)
                    Text("XTE \(distance(abs(r.crossTrack))) \(r.crossTrack > 0 ? "R" : "L")")
                        .monospacedDigit()
                    if r.offCourse {
                        Text(r.crossTrack > 0 ? "· steer to port" : "· steer to starboard")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(r.offCourse ? Color.red : Color.secondary)
                Text("SOG \(r.sog.map { String(format: "%.1f", $0) } ?? "–") · VMG \(r.vmg.map { String(format: "%.1f", $0) } ?? "–") kn · Finish \(String(format: "%.1f", r.remaining)) NM\(r.etaFinish.map { " at " + $0.formatted(date: .omitted, time: .shortened) } ?? "")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    /// NM, or metres when close.
    private func distance(_ nm: Double) -> String {
        nm < 0.3 ? "\(Int((nm * 1852).rounded())) m" : String(format: "%.1f NM", nm)
    }
}

private struct Big: View {
    var value: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Man overboard: the way back to the casualty, impossible to overlook.
struct MOBPanel: View {
    @Environment(AppModel.self) private var model
    /// Two taps to cancel (a system dialog would fight the planner sheet).
    @State private var confirmCancel = false

    var body: some View {
        let underway = model.underway
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MAN OVERBOARD")
                    .font(.headline.weight(.heavy))
                Spacer()
                if let time = underway.mob?.time {
                    Text(time, style: .timer)
                        .font(.headline.monospacedDigit())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(underway.mobBearing.map { String(format: "%03.0f°", $0) } ?? "–")
                    .font(.system(size: 40, weight: .heavy).monospacedDigit())
                Text(underway.mobDistance.map { $0 < 0.3 ? "\(Int(($0 * 1852).rounded())) m" : String(format: "%.2f NM", $0) } ?? "–")
                    .font(.title.weight(.bold).monospacedDigit())
            }
            HStack {
                Text("Steer to the bearing. Keep the casualty in sight, throw a flotation aid, call MAYDAY on VHF 16 if needed.")
                    .font(.caption)
                Spacer()
                Button(confirmCancel ? "Recovered?" : "Cancel") {
                    if confirmCancel {
                        model.cancelMOB()
                    } else {
                        confirmCancel = true
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            confirmCancel = false
                        }
                    }
                }
                .buttonStyle(.glass)
                .tint(confirmCancel ? .white : nil)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.red, in: .rect(cornerRadius: 24))
    }
}

/// The always-there red button.
struct MOBButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.manOverboard()
        } label: {
            Text("MOB")
                .font(.footnote.weight(.heavy))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.red, in: .circle)
        }
        .disabled(model.location.location == nil || model.underway.mob != nil)
        .accessibilityLabel("Man overboard")
        .accessibilityHint("Marks this position and guides you back to it")
    }
}

/// Red banner when the anchor drags.
struct AnchorAlarmBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let underway = model.underway
        HStack(spacing: 12) {
            Text("⚓︎").font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("ANCHOR DRAGGING").font(.headline.weight(.heavy))
                Text("\(Int(underway.anchorDistance ?? 0)) m from the anchor · circle \(Int(underway.anchor?.radius ?? 0)) m")
                    .font(.subheadline)
            }
            Spacer()
            Button("Silence") { underway.silenceAnchorAlarm() }
                .buttonStyle(.glass)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: 420)
        .background(.red, in: .rect(cornerRadius: 24))
    }
}

/// Home sheet: set and watch the anchor.
struct AnchorWatchSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("anchorRadius") private var radius = 40.0

    var body: some View {
        let underway = model.underway
        Section {
            if let anchor = underway.anchor {
                LabeledContent("From anchor") {
                    Text("\(Int(underway.anchorDistance ?? 0)) m · max \(Int(underway.anchorMaxDistance)) m")
                        .monospacedDigit()
                        .foregroundStyle(underway.anchorAlarm ? .red : .primary)
                }
                Stepper(value: Binding(get: { anchor.radius }, set: { underway.setAnchorRadius($0) }), in: 10...300, step: 5) {
                    LabeledContent("Alarm circle", value: "\(Int(anchor.radius)) m")
                }
                LabeledContent("Down since") { Text(anchor.dropped, style: .time) }
                if underway.anchorAlarm {
                    Button("Silence alarm", systemImage: "bell.slash.fill") { underway.silenceAnchorAlarm() }
                        .tint(.red)
                }
                Button("Lift anchor", systemImage: "arrow.up.circle", role: .destructive) { model.liftAnchor() }
            } else {
                Stepper(value: $radius, in: 10...300, step: 5) {
                    LabeledContent("Alarm circle", value: "\(Int(radius)) m")
                }
                Button("Drop anchor here", systemImage: "arrow.down.to.line") { model.dropAnchor(radius: radius) }
                    .disabled(model.location.location == nil)
            }
        } header: {
            Text("Anchor watch")
        } footer: {
            if underway.anchor == nil {
                Text("Set the circle to your chain length plus the boat's length. The alarm sounds, even with the phone on silent and the screen off, if the boat leaves it.")
            }
        }
    }
}
