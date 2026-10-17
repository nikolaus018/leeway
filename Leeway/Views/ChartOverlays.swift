import CoreLocation
import SwiftUI

/// Nautical-mile scale bar, like the one on a paper chart's border.
struct ScaleBar: View {
    var metresPerPoint: Double

    var body: some View {
        if let (miles, width) = scale {
            VStack(alignment: .leading, spacing: 2) {
                Text(miles < 1 ? "\(miles.formatted()) NM" : "\(Int(miles)) NM")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                HStack(spacing: 0) {
                    Rectangle().frame(width: width / 2)
                    Rectangle().stroke(lineWidth: 1).frame(width: width / 2)
                }
                .frame(height: 4)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
    }

    private var scale: (Double, CGFloat)? {
        guard metresPerPoint > 0 else { return nil }
        let pointsPerMile = 1852 / metresPerPoint
        let miles = [0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10, 20, 50, 100].first { $0 * pointsPerMile >= 70 } ?? 100
        return (miles, CGFloat(miles * pointsPerMile))
    }
}

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

/// What's at a tapped point: the charted object, its light, the depth and the position.
struct InspectorCard: View {
    @Environment(AppModel.self) private var model
    var inspection: AppModel.Inspection

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
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
                HStack(spacing: 10) {
                    Text(depthText).font(.subheadline.weight(.semibold))
                    Text(inspection.coordinate.formatted)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if inspection.sounding != .land || inspection.seamark?.isHarbourLike == true {
                    Button("Route here", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        model.routeHere(inspection.coordinate)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Button("Close", systemImage: "xmark") { model.inspection = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var title: String {
        inspection.seamark.map { $0.name ?? $0.kind } ?? (inspection.sounding == .land ? "Land" : "Chart position")
    }

    private var depthText: String {
        switch inspection.sounding {
        case .land: "Land"
        case .depth(let d): d >= 125 ? "Depth 125+ m" : String(format: "Depth %.1f m", d)
        case nil: "Outside chart area"
        }
    }

    private var symbol: String {
        guard let mark = inspection.seamark else { return inspection.sounding == .land ? "mountain.2" : "scope" }
        switch mark.type {
        case "light_major", "light_minor", "light_vessel": return "light.beacon.max"
        case "harbour", "small_craft_facility": return "sailboat"
        case "anchorage", "mooring": return "water.waves"
        case "rock", "wreck", "obstruction": return "exclamationmark.triangle.fill"
        default: return "mappin.and.ellipse"
        }
    }

    private var tint: Color {
        switch inspection.seamark?.type {
        case "rock", "wreck", "obstruction": .red
        case "light_major", "light_minor": .yellow
        default: .accentColor
        }
    }
}

/// A tapped ship: what it is, where it's going, and how close it will pass.
struct VesselCard: View {
    @Environment(AppModel.self) private var model
    var vessel: Vessel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "ferry.fill")
                .font(.title3)
                .foregroundStyle(danger ? Color.red : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(vessel.displayName)
                    .font(.headline)
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
            }
            Spacer(minLength: 0)
            Button("Close", systemImage: "xmark") { model.inspection = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var approach: Approach? { model.approach(to: vessel) }
    private var danger: Bool { approach?.isDangerous ?? false }

    private func approachText(_ a: Approach) -> String {
        let distance = String(format: "%.2f NM", a.distance)
        if a.time < 1.0 / 60 { return "Closest now: \(distance)" }
        if a.time > 2 { return "Not closing" }
        return "Closest \(distance) in \(Int((a.time * 60).rounded())) min"
    }
}
