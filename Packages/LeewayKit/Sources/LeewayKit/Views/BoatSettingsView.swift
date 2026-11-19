import SwiftUI

import UniformTypeIdentifiers

struct BoatSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var boat = BoatProfile()
    @State private var importingPolar = false
    @State private var polarError: String?

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

                if boat.propulsion == .sail {
                    Section {
                        Picker("Polar", selection: Binding(get: { boat.polar?.name ?? "" }, set: { name in
                            boat.polar = name.isEmpty ? nil : PolarTable.presets.first { $0.name == name } ?? boat.polar
                        })) {
                            Text("Generic, scaled to best speed").tag("")
                            ForEach(PolarTable.presets, id: \.name) { Text($0.name).tag($0.name) }
                            if let custom = boat.polar, !PolarTable.presets.contains(where: { $0.name == custom.name }) {
                                Text(custom.name).tag(custom.name)
                            }
                        }
                        PolarDiagram(boat: boat)
                            .frame(height: 170)
                        Button("Import polar file…", systemImage: "square.and.arrow.down") { importingPolar = true }
                        if let polarError {
                            Text(polarError).font(.footnote).foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Polar")
                    } footer: {
                        Text("Boat speed by wind angle and strength. Fastest routing and passage times use it. Import your boat's polar (tab- or semicolon-separated: wind speeds across, angles down) from your designer, sailmaker or ORC certificate.")
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
            .fileImporter(isPresented: $importingPolar, allowedContentTypes: [.plainText, .commaSeparatedText, .tabSeparatedText, .data]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
                if let polar = PolarTable.parse(text, name: url.deletingPathExtension().lastPathComponent) {
                    boat.polar = polar
                    polarError = nil
                } else {
                    polarError = "That file doesn't look like a polar table."
                }
            }
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

/// The boat's speed by wind angle, as the usual half-circle polar plot, at 8, 12, 16 and 20 kn.
private struct PolarDiagram: View {
    var boat: BoatProfile

    var body: some View {
        Canvas { context, size in
            let winds: [(Double, Color)] = [(8, .teal), (12, .green), (16, .orange), (20, .red)]
            let speeds = winds.map { w in stride(from: 0.0, through: 180, by: 3).map { ($0, Polar.speed(twa: $0, tws: w.0, boat: boat)) } }
            let top = max(1, speeds.flatMap { $0.map(\.1) }.max() ?? 1)
            let origin = CGPoint(x: 12, y: size.height / 2)
            let scale = min(size.width - 24, size.height / 2 - 6) / top
            // Speed rings every 2 kn.
            for ring in stride(from: 2.0, through: top, by: 2) {
                var arc = Path()
                arc.addArc(center: origin, radius: ring * scale, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                context.stroke(arc, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            }
            for (curve, wind) in zip(speeds, winds) {
                var path = Path()
                for (i, (angle, speed)) in curve.enumerated() {
                    let a = (angle - 90).radians
                    let p = CGPoint(x: origin.x + cos(a) * speed * scale, y: origin.y + sin(a) * speed * scale)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(wind.1), lineWidth: 1.6)
            }
            for (i, wind) in winds.enumerated() {
                context.draw(Text("\(Int(wind.0)) kn").font(.caption2).foregroundStyle(wind.1),
                             at: CGPoint(x: size.width - 30, y: 12 + CGFloat(i) * 14))
            }
        }
        .accessibilityLabel("Polar diagram")
    }
}
