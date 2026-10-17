import SwiftUI

/// Everything set once and rarely touched: the boat, alarms, instruments, data and charts, about.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @State private var showingBoat = false
    @State private var showingData = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    Button { showingBoat = true } label: {
                        LabeledContent {
                            Text(boatSummary).font(.caption)
                        } label: {
                            Label(model.boat.name, systemImage: "sailboat")
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text("Boat")
                }

                Section {
                    Toggle(isOn: $model.alarms.aisAlarm) { Label("Collision alarm (AIS)", systemImage: "exclamationmark.triangle") }
                    Stepper(value: $model.alarms.cpaDistance, in: 0.1...3, step: 0.1) {
                        LabeledContent("Closer than", value: String(format: "%.1f NM", model.alarms.cpaDistance))
                    }
                    Stepper(value: $model.alarms.cpaMinutes, in: 5...60, step: 5) {
                        LabeledContent("Within", value: "\(Int(model.alarms.cpaMinutes)) min")
                    }
                    Stepper(value: $model.alarms.crossTrack, in: 0.02...0.5, step: 0.02) {
                        LabeledContent("Off-track warning", value: "\(Int((model.alarms.crossTrack * 1852).rounded())) m")
                    }
                } header: {
                    Text("Alarms")
                } footer: {
                    Text("Ships that will pass closer than this turn red and sound the alarm. The anchor alarm is set in Log.")
                }

                Section {
                    NavigationLink {
                        InstrumentsView()
                    } label: {
                        LabeledContent {
                            Text(instrumentsStatus).font(.caption)
                        } label: {
                            Label("Boat instruments", systemImage: "gauge.with.dots.needle.50percent")
                        }
                    }
                    Button { showingData = true } label: {
                        LabeledContent {
                            Text(Seadata(model.serverURL)?.displayName ?? "").font(.caption)
                        } label: {
                            Label("Data & offline charts", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text("Connections")
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About & sources", systemImage: "info.circle")
                    }
                } footer: {
                    Text("Leeway is a planning aid, not a certified navigation system. Always cross-check with official charts and keep a lookout.")
                        .fontWeight(.semibold)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingBoat) { BoatSettingsView() }
            .sheet(isPresented: $showingData) { DataSettingsView() }
        }
    }

    private var boatSummary: String {
        let b = model.boat
        return String(format: "draft %.1f m · safety %.1f m · air %.0f m", b.draft, b.safetyDepth, b.airDraft)
    }

    private var instrumentsStatus: String {
        switch model.nmea.state {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .receiving: "Connected"
        case .failed: "Not connected"
        }
    }
}

/// NMEA 0183 over Wi-Fi from the boat's gateway or multiplexer.
struct InstrumentsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var nmea = model.nmea
        Form {
            Section {
                Toggle("Connect", isOn: $nmea.settings.enabled)
                Picker("Protocol", selection: $nmea.settings.transport) {
                    ForEach(NMEAClient.Transport.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if nmea.settings.transport == .tcp {
                    TextField("Address", text: $nmea.settings.host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField("Port", value: $nmea.settings.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
            } footer: {
                Text("Most Wi-Fi gateways (Yacht Devices, Digital Yacht, Quark-elec, Vesper, and many plotters) send NMEA 0183 on TCP or UDP port 10110. Depth, wind and heading replace the chart's values; AIS targets show on the chart without internet.")
            }

            Section("Status") {
                LabeledContent("Connection", value: stateText)
                LabeledContent("Sentences", value: "\(nmea.sentences)")
                LabeledContent("Depth", value: nmea.depth.map { String(format: "%.1f m", $0) } ?? "–")
                LabeledContent("Wind", value: nmea.wind.map { String(format: "%.0f kn %@ %03.0f°", $0.speed, $0.relative ? "AWA" : "TWD", $0.angle) } ?? "–")
                LabeledContent("Heading", value: nmea.heading.map { String(format: "%03.0f°", $0) } ?? "–")
                LabeledContent("AIS targets", value: "\(nmea.vessels.count)")
            }
        }
        .navigationTitle("Boat instruments")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var stateText: String {
        switch model.nmea.state {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .receiving: "Receiving"
        case .failed(let message): message
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            }
            Section("Not for navigation") {
                Text("The charts are built from open data (EMODnet survey grids, OpenStreetMap, GEBCO) and do not show every rock, wreck or shoal. Routes, depths and forecasts can be wrong. Use official charts, your eyes and your judgement.")
                    .font(.footnote)
            }
            Section("Data sources") {
                Source(name: "Base map", detail: "OpenFreeMap, © OpenMapTiles, © OpenStreetMap contributors (ODbL)")
                Source(name: "Detailed charts", detail: "EMODnet Bathymetry (CC BY 4.0), © OpenStreetMap contributors (ODbL), OpenSeaMap")
                Source(name: "Coastline, sea names, traffic separation, cables, pipelines",
                       detail: "Croatian Hydrographic Institute (HHI), open data with attribution")
                Source(name: "Worldwide depth", detail: "AWS Terrain Tiles: GEBCO, ETOPO1, NOAA and others")
                Source(name: "Seamarks outside charts", detail: "© OpenSeaMap contributors (CC BY-SA 2.0)")
                Source(name: "Weather, waves, currents, tides", detail: "Open-Meteo.com (CC BY 4.0); models by ItaliaMeteo-ARPAE, DWD, ECMWF, NOAA, Météo-France")
                Source(name: "Warnings", detail: "MeteoAlarm and the national weather services (CC BY 4.0)")
                Source(name: "Satellite", detail: "Sentinel-2 cloudless 2016 by EOX IT Services GmbH (contains modified Copernicus Sentinel data, CC BY 4.0)")
                Source(name: "Rain radar", detail: "RainViewer")
                Source(name: "Ships", detail: "aisstream.io")
                Source(name: "Search", detail: "Photon by komoot, © OpenStreetMap contributors")
                Source(name: "Map engine", detail: "MapLibre Native (BSD)")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Source: View {
    var name: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
