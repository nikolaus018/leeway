import SwiftUI

struct BoatSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var boat = BoatProfile()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $boat.name)
                    Picker("Type", selection: $boat.propulsion.animation()) {
                        ForEach(Propulsion.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    if boat.propulsion == .sail {
                        SpeedRow(title: "Best sailing speed", value: $boat.sailSpeed, range: 3...15)
                        SpeedRow(title: "Engine on below", value: $boat.motorThreshold, range: 0...6)
                    }
                    SpeedRow(title: "Motoring speed", value: $boat.motorSpeed, range: 2...30)
                } header: {
                    Text("Performance")
                } footer: {
                    if boat.propulsion == .sail {
                        Text("Sailing speed is scaled through a generic cruising polar by wind angle and strength. Below the engine threshold the passage is timed at motoring speed.")
                    }
                }

                Section {
                    Stepper(value: $boat.draft, in: 0.3...5, step: 0.1) {
                        LabeledContent("Draft", value: String(format: "%.1f m", boat.draft))
                    }
                    Stepper(value: $boat.underKeelClearance, in: 0...5, step: 0.1) {
                        LabeledContent("Under-keel clearance", value: String(format: "%.1f m", boat.underKeelClearance))
                    }
                    Stepper(value: $boat.airDraft, in: 1...40, step: 0.5) {
                        LabeledContent("Air draft", value: String(format: "%.1f m", boat.airDraft))
                    }
                } header: {
                    Text("Clearances")
                } footer: {
                    Text("Automatic routes stay in water at least \(String(format: "%.1f m", boat.safetyDepth)) deep and keep clear of charted rocks and wrecks. The chart draws the safety depth as the bold contour. Air draft is the height of your mast top above the water; routes avoid bridges with less clearance (plus 1 m).")
                }

                Section {
                    Stepper(value: $boat.maxWind, in: 8...40, step: 1) {
                        LabeledContent("Max wind", value: "\(Int(boat.maxWind)) kn")
                    }
                    Stepper(value: $boat.maxGust, in: 10...60, step: 1) {
                        LabeledContent("Max gusts", value: "\(Int(boat.maxGust)) kn")
                    }
                    Stepper(value: $boat.maxWave, in: 0.3...5, step: 0.1) {
                        LabeledContent("Max waves", value: String(format: "%.1f m", boat.maxWave))
                    }
                } header: {
                    Text("Comfort limits")
                } footer: {
                    Text("Departure times that exceed these are shown as rough.")
                }
            }
            .navigationTitle("Boat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) {
                        model.boat = boat
                        dismiss()
                    }
                }
            }
        }
        .onAppear { boat = model.boat }
    }
}

private struct SpeedRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        Stepper(value: $value, in: range, step: 0.5) {
            LabeledContent(title, value: String(format: "%.1f kn", value))
        }
    }
}
