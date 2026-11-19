import SwiftUI

/// What the chart shows: chart or satellite, the light palette, chart detail, and the live layers.
struct LayersSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Map", selection: $model.mapBase) {
                        ForEach(MapBase.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Colours", selection: $model.paletteMode) {
                        ForEach(PaletteMode.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text(model.paletteMode == .auto
                         ? "Day colours by day, dimmed at dusk, dark at night. Now: \(model.palette.label)."
                         : "Night colours keep your night vision.")
                }

                Section("Chart") {
                    Toggle(isOn: $model.showSeamarks) { Label("Seamarks & lights", systemImage: "light.beacon.max") }
                    Toggle(isOn: $model.showSoundings) { Label("Soundings", systemImage: "number") }
                    Toggle(isOn: $model.showGrid) { Label("Lat/Lon grid", systemImage: "grid") }
                }

                Section {
                    Toggle(isOn: $model.showWind) {
                        Label { status("Wind forecast", model.windState) } icon: { Image(systemName: "wind") }
                    }
                    Toggle(isOn: $model.showRadar) { Label("Rain radar", systemImage: "cloud.rain") }
                    Toggle(isOn: $model.showAIS) {
                        Label { status("Ships (AIS)", model.aisState, count: model.vessels.count) } icon: { Image(systemName: "ferry") }
                    }
                    if model.showAIS && !model.vessels.isEmpty {
                        NavigationLink("Ships nearby") { ShipList() }
                    }
                } header: {
                    Text("Live")
                } footer: {
                    Text("Ships come from the data server's AIS feed and, when connected, your boat's own AIS receiver. Coverage has gaps: keep a lookout.")
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func status(_ title: String, _ state: AppModel.LayerState, count: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            switch state {
            case .loading: Text("Loading…").font(.caption).foregroundStyle(.secondary)
            case .zoomIn: Text("Zoom in to see ships").font(.caption).foregroundStyle(.secondary)
            case .failed(let message): Text(message).font(.caption).foregroundStyle(.orange)
            case .idle:
                if let count, model.showAIS { Text("\(count) in view").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Ships in view, the ones that will pass closest soonest first.
struct ShipList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let here = model.location.location?.coordinate ?? model.camera.center
        let ships = model.vessels.map { v in (vessel: v, approach: model.approach(to: v), distance: Geo.distanceNM(here, v.coordinate)) }
            .sorted { a, b in
                let ca = a.approach.map { $0.time < 2 ? $0.distance : 99 } ?? 99, cb = b.approach.map { $0.time < 2 ? $0.distance : 99 } ?? 99
                return ca != cb ? ca < cb : a.distance < b.distance
            }
        List(ships, id: \.vessel.mmsi) { ship in
            Button {
                model.centre(on: ship.vessel.coordinate, zoom: 13)
                model.inspection = AppModel.Inspection(coordinate: ship.vessel.coordinate, vessel: ship.vessel)
            } label: {
                HStack {
                    Image(systemName: "ferry.fill")
                        .foregroundStyle(model.isDangerous(ship.vessel) ? Color.red : Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ship.vessel.displayName)
                        Text([ship.vessel.kind, ship.vessel.sog.map { String(format: "%.1f kn", $0) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "%.1f NM", ship.distance)).font(.subheadline.monospacedDigit())
                        if let a = ship.approach, a.time < 2, a.time > 0 {
                            Text(String(format: "CPA %.2f in %d min", a.distance, Int((a.time * 60).rounded())))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(model.isDangerous(ship.vessel) ? .red : .secondary)
                        }
                    }
                }
            }
            .tint(.primary)
        }
        .navigationTitle("Ships")
    }
}
