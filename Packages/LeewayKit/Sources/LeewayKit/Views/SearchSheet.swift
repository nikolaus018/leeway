import CoreLocation
import SwiftUI

/// Find a harbour, marina, anchorage, bay, island or town: your marks and the offline charts first,
/// then the data server's search.
struct SearchSheet: View {
    @Environment(AppModel.self) private var model
    var close: () -> Void
    @State private var text = ""
    @State private var online: [PlaceResult] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if text.trimmingCharacters(in: .whitespaces).count < 2 {
                    Section {
                        ForEach(model.marks.prefix(5)) { mark in
                            row(name: mark.name, detail: "Your mark", symbol: mark.symbol, coordinate: mark.coordinate)
                        }
                    } header: {
                        if !model.marks.isEmpty { Text("Marks") }
                    } footer: {
                        Text("Search harbours, marinas, anchorages, bays, islands and towns.")
                    }
                } else {
                    let local = localResults
                    if !local.isEmpty {
                        Section("On your charts") {
                            ForEach(local, id: \.id) { r in
                                row(name: r.name, detail: r.detail, symbol: r.symbol, coordinate: r.coordinate)
                            }
                        }
                    }
                    let localIDs = Set(local.map(\.name))
                    let remote = online.filter { !localIDs.contains($0.name) }
                    if !remote.isEmpty {
                        Section("Places") {
                            ForEach(remote) { r in
                                row(name: r.name, detail: r.detail, symbol: r.symbol, coordinate: r.coordinate)
                            }
                        }
                    }
                    if local.isEmpty && remote.isEmpty && !searching {
                        Text("Nothing found for “\(text)”.").foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Harbour, bay, town…")
            .searchFocused($focused)
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { close() }
                }
            }
            .overlay(alignment: .top) {
                if searching { ProgressView().padding(.top, 8) }
            }
        }
        .task(id: text) {
            let query = text.trimmingCharacters(in: .whitespaces)
            guard query.count >= 2 else {
                online = []
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            let near = model.location.location?.coordinate ?? model.camera.center
            online = (try? await Seadata.current.search(query, near: near)) ?? []
        }
        .onAppear { focused = true }
    }

    private func row(name: String, detail: String?, symbol: String, coordinate: CLLocationCoordinate2D) -> some View {
        Button {
            model.centre(on: coordinate, zoom: 14)
            model.inspect(ChartHit(coordinate: coordinate))
            model.selectedTab = .chart
            close()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    HStack(spacing: 6) {
                        if let detail { Text(detail) }
                        if let here = model.location.location?.coordinate {
                            Text(String(format: "%.0f NM", Geo.distanceNM(here, coordinate)))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(.tint)
            }
        }
        .tint(.primary)
    }

    /// Offline: harbours and names from the installed chart packs, and the user's marks.
    private var localResults: [PlaceResult] {
        let q = text.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func matches(_ name: String) -> Bool {
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
        }
        var found: [PlaceResult] = model.marks.filter { matches($0.name) }.map {
            PlaceResult(name: $0.name, kind: "mark", lat: $0.latitude, lon: $0.longitude, detail: "Your mark")
        }
        for region in model.regions {
            for mark in region.seamarks where mark.isHarbourLike {
                if let name = mark.name, matches(name) {
                    found.append(PlaceResult(name: name, kind: mark.category == "marina" ? "marina" : mark.type == "anchorage" ? "anchorage" : "harbour",
                                             lat: mark.latitude, lon: mark.longitude, detail: mark.kind))
                }
            }
            for place in region.names where matches(place.name) {
                found.append(PlaceResult(name: place.name, kind: place.type, lat: place.latitude, lon: place.longitude, detail: place.type.capitalized))
            }
            if found.count > 40 { break }
        }
        let here = model.location.location?.coordinate ?? model.camera.center
        return Array(found.sorted { Geo.distanceNM(here, $0.coordinate) < Geo.distanceNM(here, $1.coordinate) }.prefix(20))
    }
}
