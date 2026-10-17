import SwiftUI

/// Where the app gets its data: the data server address, and chart packs to download from it.
struct DataSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var check = Check.idle

    enum Check: Equatable {
        case idle, checking
        case ok(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $address, prompt: Text(Seadata.defaultURL))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await test() } }
                    HStack {
                        Button("Test connection") { Task { await test() } }
                            .disabled(server == nil || check == .checking)
                        Spacer()
                        checkLabel
                    }
                    if address != Seadata.defaultURL {
                        Button("Use default server") {
                            address = Seadata.defaultURL
                            Task { await test() }
                        }
                    }
                } header: {
                    Text("Data server")
                } footer: {
                    Text("Forecasts, wind arrows, seamarks, ships (AIS) and chart downloads come through this server. If it can't be reached, forecasts and seamarks are fetched directly instead. Run your own from the server folder of the Leeway repository.")
                }

                ChartsSection(server: server ?? Seadata.current)
            }
            .navigationTitle("Data & charts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) {
                        if let server { model.serverURL = server.base.absoluteString }
                        dismiss()
                    }
                    .disabled(server == nil)
                }
            }
        }
        .onAppear {
            address = model.serverURL
            Task { await test() }
        }
    }

    private var server: Seadata? { Seadata(address) }

    @ViewBuilder private var checkLabel: some View {
        switch check {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView()
        case .ok(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func test() async {
        guard let server else {
            check = .failed("Not a valid address")
            return
        }
        check = .checking
        do {
            let info = try await server.info()
            check = .ok("v\(info.version)\(info.features.contains("ais") ? " · AIS" : "")")
        } catch {
            check = .failed(error.localizedDescription)
        }
    }
}

/// Chart packs on the server, with download, update and remove.
private struct ChartsSection: View {
    @Environment(AppModel.self) private var model
    var server: Seadata

    var body: some View {
        let store = model.charts
        Section {
            switch store.listState {
            case .idle, .loading:
                Label {
                    Text("Loading charts…")
                } icon: {
                    ProgressView()
                }
                .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            case .loaded:
                if store.available.isEmpty {
                    Text("This server has no chart packs.").foregroundStyle(.secondary)
                }
                ForEach(store.available) { pack in
                    ChartRow(pack: pack, server: server)
                }
            }
            if let error = store.downloadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Offline charts")
        } footer: {
            Text("Charts with depths, contours and seamarks that work without signal, and that automatic routing needs. The app ships with the Eastern Adriatic; downloading gets the server's latest build.")
        }
        .task(id: server.base) { await store.refresh(from: server) }
    }
}

private struct ChartRow: View {
    @Environment(AppModel.self) private var model
    var pack: ChartPackInfo
    var server: Seadata

    var body: some View {
        let store = model.charts
        let status = store.status(of: pack)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                Text(detail(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.downloading.contains(pack.id) {
                ProgressView()
            } else if status == .installed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(status == .updateAvailable ? "Update" : "Download") {
                    Task { await store.download(pack, from: server) }
                }
                .buttonStyle(.bordered)
            }
        }
        .swipeActions {
            if status != .notInstalled {
                Button("Remove", role: .destructive) { store.remove(pack) }
            }
        }
    }

    private func detail(_ status: ChartStore.Status) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(pack.size), countStyle: .file)
        let bundled = model.regions.contains { $0.id == pack.id }
        switch status {
        case .installed: return "\(size) · downloaded, up to date"
        case .updateAvailable: return "\(size) · update available"
        case .notInstalled: return bundled ? "\(size) · built-in copy in use" : size
        }
    }
}
