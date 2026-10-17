import CoreLocation
import SwiftUI

/// Latitude labels down the right edge and longitude labels along the bottom of the visible chart.
struct GridLabels: View {
    var camera: AppModel.MapCamera

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            ForEach(camera.latitudeLabels) { label in
                tag(label.text)
                    .position(x: proxy.size.width - 34, y: label.position - frame.minY)
            }
            ForEach(camera.longitudeLabels) { label in
                tag(label.text)
                    .position(x: label.position - frame.minX, y: proxy.size.height * 0.62)
            }
        }
        .allowsHitTesting(false)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.regularMaterial, in: .capsule)
    }
}

/// A card at the bottom of the chart with a symbol, a title, details and actions.
private struct Card<Content: View, Actions: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    content
                }
                Spacer(minLength: 0)
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
            HStack(spacing: 8) { actions }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding(.leading, 40)
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .catchesTouches(cornerRadius: 24)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// What's at a tapped point: the charted object, its light, zones, the depth, and the position.
struct InspectorCard: View {
    @Environment(AppModel.self) private var model
    var inspection: AppModel.Inspection
    @State private var tide: SeaLevel?

    var body: some View {
        Card(symbol: symbol, tint: tint, title: title) {
            if let mark = inspection.seamark {
                if mark.name != nil { Text(mark.kind).font(.subheadline).foregroundStyle(.secondary) }
                if let light = mark.light {
                    Label(light, systemImage: "light.max")
                        .font(.subheadline.monospaced())
                }
                if let colour = mark.colour {
                    Text(colour.replacingOccurrences(of: ";", with: " / ").capitalized)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(inspection.zones, id: \.self) { zone in
                Label(zoneText(zone), systemImage: "exclamationmark.octagon")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.pink)
            }
            HStack(spacing: 10) {
                Text(depthText).font(.subheadline.weight(.semibold))
                Text(inspection.coordinate.formatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let fix = model.location.location?.coordinate {
                let d = Geo.distanceNM(fix, inspection.coordinate)
                Text(String(format: "%03.0f° · %.1f NM from you", Geo.bearing(fix, inspection.coordinate), d))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let tide, let next = tide.turningPoints.first(where: { $0.time > .now }) {
                Text("Tide: \(next.high ? "high" : "low") \(String(format: "%+.2f m", next.height)) at \(next.time.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            if inspection.sounding != .land || inspection.seamark?.isHarbourLike == true {
                Button("Route here", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    model.routeHere(inspection.coordinate)
                }
                .buttonStyle(.glassProminent)
            }
            Button("Mark", systemImage: "mappin") { model.addMark(at: inspection.coordinate, name: inspection.seamark?.name) }
            Button("Measure", systemImage: "ruler") {
                model.isMeasuring = true
                model.addMeasurePoint(inspection.coordinate)
                model.inspection = nil
            }
        } close: {
            model.inspection = nil
        }
        .task(id: inspection.coordinate.latitude) {
            tide = nil
            guard inspection.sounding != .land else { return }
            tide = try? await Seadata.current.seaLevel(at: inspection.coordinate)
        }
    }

    private var title: String {
        if let mark = inspection.seamark { return mark.name ?? mark.kind }
        if inspection.sounding == .land { return "Land" }
        return inspection.zones.first.map { zoneTitle($0.kind) } ?? "Chart position"
    }

    private var depthText: String {
        switch inspection.sounding {
        case .land: return "Land"
        case .depth(let d): return d >= 125 ? "Depth 125+ m" : String(format: "Depth %.1f m", d)
        case nil:
            guard let band = inspection.depthBand else { return "Depth unknown" }
            return band.upperBound >= 12000 ? "Depth over \(Int(band.lowerBound)) m" : "Depth \(Int(band.lowerBound))–\(Int(band.upperBound)) m"
        }
    }

    private func zoneTitle(_ kind: String) -> String {
        switch kind {
        case "restricted": "Restricted area"
        case "anchorage": "Anchorage area"
        case "mooring": "Mooring area"
        case "tss_lane": "Traffic lane"
        case "tss_separation": "Traffic separation zone"
        case "fairway": "Fairway"
        case "cable": "Submarine cable"
        case "pipeline": "Submarine pipeline"
        case "seabed": "Seabed"
        case "marine_farm": "Fish farm"
        default: kind.capitalized
        }
    }

    private func zoneText(_ zone: ChartHit.Zone) -> String {
        var text = zone.name.map { "\(zoneTitle(zone.kind)): \($0)" } ?? zoneTitle(zone.kind)
        if let detail = zone.detail { text += " (\(detail.replacingOccurrences(of: "_", with: " ")))" }
        return text
    }

    private var symbol: String {
        guard let mark = inspection.seamark else {
            if !inspection.zones.isEmpty { return "exclamationmark.octagon" }
            return inspection.sounding == .land ? "mountain.2" : "scope"
        }
        switch mark.type {
        case "light_major", "light_minor", "light_vessel": return "light.beacon.max"
        case "harbour", "small_craft_facility": return "sailboat"
        case "anchorage", "mooring": return "anchor"
        case "rock", "wreck", "obstruction": return "exclamationmark.triangle.fill"
        default: return "mappin.and.ellipse"
        }
    }

    private var tint: Color {
        switch inspection.seamark?.type {
        case "rock", "wreck", "obstruction": .red
        case "light_major", "light_minor": .yellow
        default: inspection.zones.isEmpty ? .accentColor : .pink
        }
    }
}

/// A tapped ship: what it is, where it's going, and how close it will pass.
struct VesselCard: View {
    @Environment(AppModel.self) private var model
    var vessel: Vessel

    var body: some View {
        Card(symbol: "ferry.fill", tint: danger ? .red : .accentColor, title: vessel.displayName) {
            Text([vessel.kind, vessel.status].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(vessel.sog.map { String(format: "%.1f kn", $0) } ?? "– kn")
                Text(vessel.course.map { String(format: "%03.0f°", $0) } ?? "–°")
                if let length = vessel.length { Text("\(Int(length)) m") }
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            if let approach {
                Label(approachText(approach), systemImage: danger ? "exclamationmark.triangle.fill" : "scope")
                    .font(.subheadline.weight(danger ? .semibold : .regular))
                    .foregroundStyle(danger ? Color.red : Color.primary)
            }
            if let destination = vessel.destination {
                Text("To \(destination)").font(.caption)
            }
            Text("MMSI \(String(vessel.mmsi))\(vessel.callSign.map { " · \($0)" } ?? "") · \(vessel.lastHeard.formatted(.relative(presentation: .named)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } actions: {
            EmptyView()
        } close: {
            model.inspection = nil
        }
    }

    private var approach: Approach? { model.approach(to: vessel) }
    private var danger: Bool { model.isDangerous(vessel) }

    private func approachText(_ a: Approach) -> String {
        let distance = String(format: "%.2f NM", a.distance)
        if a.time < 1.0 / 60 { return "Closest now: \(distance)" }
        if a.time > 2 { return "Not closing" }
        return "Closest \(distance) in \(Int((a.time * 60).rounded())) min"
    }
}

/// One of the user's marks: rename, pick a symbol, add notes, navigate, delete.
struct MarkCard: View {
    @Environment(AppModel.self) private var model
    var mark: UserMark
    @State private var editing = false

    var body: some View {
        Card(symbol: mark.symbol, tint: .orange, title: mark.name) {
            if !mark.notes.isEmpty { Text(mark.notes).font(.subheadline) }
            Text(mark.coordinate.formatted)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let fix = model.location.location?.coordinate {
                Text(String(format: "%03.0f° · %.1f NM from you", Geo.bearing(fix, mark.coordinate), Geo.distanceNM(fix, mark.coordinate)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Route here", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { model.routeHere(mark.coordinate) }
                .buttonStyle(.glassProminent)
            Button("Edit", systemImage: "pencil") { editing = true }
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteMark(mark) }
                .labelStyle(.iconOnly)
        } close: {
            model.inspection = nil
        }
        .sheet(isPresented: $editing) {
            MarkEditor(mark: mark)
                .presentationDetents([.medium])
        }
    }
}

struct MarkEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var mark: UserMark

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $mark.name)
                Section("Symbol") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(UserMark.symbols, id: \.self) { symbol in
                            Button {
                                mark.symbol = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                                    .background(mark.symbol == symbol ? Color.orange.opacity(0.25) : .clear, in: .circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                        }
                    }
                }
                Section("Notes") {
                    TextField("Depth, holding, swell…", text: $mark.notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Mark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) {
                        model.updateMark(mark)
                        dismiss()
                    }
                }
            }
        }
    }
}
