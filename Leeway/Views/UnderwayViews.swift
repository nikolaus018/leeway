import CoreLocation
import SwiftUI

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
        .frame(maxWidth: 400, alignment: .leading)
        .catchesTouches(cornerRadius: 24)
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
        .frame(maxWidth: 400)
        .catchesTouches(cornerRadius: 24)
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
