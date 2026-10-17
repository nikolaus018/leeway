import SwiftUI

// MARK: - Top

extension View {
    /// Panels over the chart catch every touch inside their outline; SwiftUI would otherwise pass
    /// taps on text and backgrounds through to the map underneath.
    func catchesTouches(cornerRadius: CGFloat) -> some View {
        contentShape(.rect(cornerRadius: cornerRadius)).onTapGesture {}
    }
}

/// Instruments (or navigation, MOB, editing) on the left, map controls on the right. Everything
/// has a fixed or capped width, so nothing shifts as numbers change or the map zooms.
struct TopChrome: View {
    @Environment(AppModel.self) private var model
    @Binding var showingLayers: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if model.underway.anchorAlarm {
                    AnchorAlarmBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if model.underway.mob != nil {
                    MOBPanel()
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if model.underway.isNavigating {
                    NavigationBar()
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if model.isEditing {
                    EditingBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if model.isMeasuring {
                    MeasureBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if model.location.location != nil {
                    InstrumentStrip()
                        .transition(.opacity)
                }
                if let warning = model.activeWarning, !model.isEditing, model.underway.mob == nil {
                    WarningPill(warning: warning)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 400, alignment: .leading)
            Spacer(minLength: 0)
            MapRail(showingLayers: $showingLayers)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

/// SOG · COG · depth in one fixed-size strip; tap for position and logging state.
struct InstrumentStrip: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let tracker = model.location
        Button {
            withAnimation(.smooth(duration: 0.2)) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    Reading(title: "SOG", value: tracker.sog.map { String(format: "%.1f", $0) } ?? "–", unit: "kn")
                    Reading(title: "COG", value: tracker.cog.map { String(format: "%03.0f", $0) } ?? "–", unit: "°")
                    Reading(title: model.nmea.depth != nil ? "DPT" : "CHART", value: depth, unit: "m")
                    if tracker.isRecording {
                        Image(systemName: "record.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse)
                    }
                }
                if expanded, let position = tracker.location?.coordinate {
                    Text(position.formatted)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let wind = model.nmea.wind {
                        Text("Wind \(Int(wind.speed.rounded())) kn \(wind.relative ? "apparent" : "true") \(String(format: "%03.0f°", wind.angle))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .accessibilityLabel("Instruments")
    }

    /// From the boat's sounder over NMEA when connected, else the chart.
    private var depth: String {
        if let d = model.nmea.depth { return d >= 100 ? "\(Int(d))" : String(format: "%.1f", d) }
        guard let here = model.location.location?.coordinate,
              case .depth(let d)? = model.region(containing: [here])?.sounding(at: here) else { return "–" }
        return d >= 100 ? "\(Int(d))" : String(format: "%.1f", d)
    }
}

private struct Reading: View {
    var title: String
    var value: String
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.body, design: .rounded, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .frame(minWidth: 44, alignment: .leading)
    }
}

/// Following a route, in one row: next waypoint, bearing, distance, ETA, cross-track.
struct NavigationBar: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let underway = model.underway
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if underway.arrived {
                    Label("Arrived", systemImage: "flag.checkered")
                        .font(.headline)
                } else if let r = underway.readout {
                    Reading(title: r.nextName.uppercased(), value: String(format: "%03.0f", r.bearing), unit: "°")
                    Reading(title: "DTW", value: distance(r.distance), unit: r.distance < 0.3 ? "m" : "NM")
                    Reading(title: "ETA", value: r.etaNext.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–", unit: "")
                    VStack(alignment: .leading, spacing: 0) {
                        Text("XTE").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        HStack(spacing: 2) {
                            Image(systemName: r.crossTrack > 0 ? "arrow.left" : "arrow.right")
                                .font(.caption.weight(.bold))
                                .opacity(abs(r.crossTrack) < 0.005 ? 0 : 1)
                            Text(abs(r.crossTrack) < 0.3 ? "\(Int((abs(r.crossTrack) * 1852).rounded()))" : String(format: "%.1f", abs(r.crossTrack)))
                                .font(.system(.body, design: .rounded, weight: .semibold).monospacedDigit())
                            Text(abs(r.crossTrack) < 0.3 ? "m" : "NM").font(.caption2).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .fixedSize()
                    }
                    .foregroundStyle(r.offCourse ? Color.red : Color.primary)
                } else {
                    Label("Waiting for GPS…", systemImage: "location.slash")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tint)
            }
            .contentShape(.rect)
            .onTapGesture { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows more navigation details")
            if expanded {
                if let r = underway.readout {
                    Text("SOG \(r.sog.map { String(format: "%.1f", $0) } ?? "–") · VMG \(r.vmg.map { String(format: "%.1f", $0) } ?? "–") kn · finish \(String(format: "%.1f", r.remaining)) NM\(r.etaFinish.map { " at " + $0.formatted(date: .omitted, time: .shortened) } ?? "")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if r.offCourse {
                        Text(r.crossTrack > 0 ? "Off track: steer to port" : "Off track: steer to starboard")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    Button("Previous", systemImage: "backward.end.fill") { underway.skipWaypoint(by: -1) }
                    Button("Next", systemImage: "forward.end.fill") { underway.skipWaypoint(by: 1) }
                    Spacer()
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { model.stopNavigation() }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .catchesTouches(cornerRadius: 18)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }

    private func distance(_ nm: Double) -> String {
        nm < 0.3 ? "\(Int((nm * 1852).rounded()))" : nm < 100 ? String(format: "%.1f", nm) : "\(Int(nm.rounded()))"
    }
}

struct EditingBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .foregroundStyle(.tint)
            Text(model.route.waypoints.isEmpty ? "Tap the chart to set your start" : "Tap to add · hold a pin to move it")
                .font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undoLastWaypoint() }
                .labelStyle(.iconOnly)
                .disabled(model.route.waypoints.isEmpty)
            Button("Done") { model.finishEditing() }
                .buttonStyle(.glassProminent)
                .disabled(model.route.waypoints.count == 1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .catchesTouches(cornerRadius: 22)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct MeasureBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ruler")
                .foregroundStyle(.pink)
            Text(text)
                .font(.footnote.weight(.medium).monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if model.location.location != nil {
                Button("From boat", systemImage: "location.fill") { model.measureFromBoat() }
                    .labelStyle(.iconOnly)
            }
            Button("Done") { model.isMeasuring = false }
                .buttonStyle(.glassProminent)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .catchesTouches(cornerRadius: 22)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var text: String {
        let p = model.measurePoints
        guard let first = p.first else { return "Tap a point to measure from" }
        guard p.count >= 2, let last = p.last else { return "Tap where to measure to" }
        let d = Geo.distanceNM(first, last)
        let distance = d < 0.3 ? "\(Int((d * 1852).rounded())) m" : String(format: "%.2f NM", d)
        return String(format: "%03.0f° · ", Geo.bearing(first, last)) + distance
    }
}

/// An official warning for the area, in one line; tap for the text.
struct WarningPill: View {
    var warning: WeatherWarning
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(warning.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .lineLimit(expanded ? nil : 1)
                if expanded, let description = warning.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: 360, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(warning.colour)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }
}

/// Layers, position/orientation, compass and range-and-bearing, then the MOB button on its own.
struct MapRail: View {
    @Environment(AppModel.self) private var model
    @Binding var showingLayers: Bool

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                Button("Layers", systemImage: "square.2.layers.3d") { showingLayers = true }
                    .frame(width: 44, height: 44)
                Divider().frame(width: 28)
                Menu {
                    Picker("Orientation", selection: Binding(get: { model.tracking }, set: { model.tracking = $0 })) {
                        Label("North up", systemImage: "location.fill").tag(AppModel.UserTracking.follow)
                        Label("Heading up", systemImage: "location.north.line.fill").tag(AppModel.UserTracking.heading)
                        Label("Course up", systemImage: "location.north.circle.fill").tag(AppModel.UserTracking.course)
                    }
                    Button("Free map", systemImage: "location") { model.tracking = .none }
                } label: {
                    Image(systemName: trackingSymbol)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                } primaryAction: {
                    model.tracking = model.tracking == .none ? .follow : .none
                }
                .accessibilityLabel("Position and orientation")
                if abs(model.camera.heading) > 0.5 && abs(model.camera.heading) < 359.5 {
                    Divider().frame(width: 28)
                    Button {
                        model.northUp()
                    } label: {
                        Image(systemName: "location.north.fill")
                            .foregroundStyle(.red)
                            .rotationEffect(.degrees(-model.camera.heading))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("North up")
                }
                Divider().frame(width: 28)
                Button("Measure", systemImage: "ruler") { model.isMeasuring.toggle() }
                    .frame(width: 44, height: 44)
                    .foregroundStyle(model.isMeasuring ? Color.pink : Color.accentColor)
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.tint)
            .catchesTouches(cornerRadius: 22)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))

            MOBButton()
        }
    }

    private var trackingSymbol: String {
        switch model.tracking {
        case .none: "location"
        case .follow: "location.fill"
        case .heading: "location.north.line.fill"
        case .course: "location.north.circle.fill"
        }
    }
}

// MARK: - Bottom

/// Scale bar, wind time, the route or inspector card, and the tab bar.
struct BottomChrome: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: AppSheet?

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                ScaleBar(metresPerPoint: model.camera.metresPerPoint)
                Spacer(minLength: 0)
                if model.showWind || model.radarFrame != nil { TimeBar() }
            }
            Group {
                if let inspection = model.inspection, !model.isEditing {
                    if let vessel = inspection.vessel {
                        VesselCard(vessel: vessel)
                    } else if let mark = inspection.mark {
                        MarkCard(mark: mark)
                    } else {
                        InspectorCard(inspection: inspection)
                    }
                } else if !model.route.waypoints.isEmpty, !model.underway.isNavigating, !model.isMeasuring {
                    RouteCard(openDetails: { sheet = .route })
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            TabBar(sheet: $sheet)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

/// One row of glass buttons that open the sheets.
struct TabBar: View {
    @Binding var sheet: AppSheet?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppSheet.allCases) { item in
                Button {
                    sheet = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 18, weight: .medium))
                            .frame(height: 22)
                        Text(item.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(sheet == item ? Color.accentColor : Color.primary)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: 520)
        .catchesTouches(cornerRadius: 30)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// The open route at a glance: distance, time, arrival; start navigating or open the planner.
struct RouteCard: View {
    @Environment(AppModel.self) private var model
    var openDetails: () -> Void

    var body: some View {
        let plan = model.plan
        HStack(spacing: 12) {
            Button(action: openDetails) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.route.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(summary(plan))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if model.routingState == .routing || model.forecastState == .loading {
                ProgressView().controlSize(.small)
            }
            if plan != nil && !model.isEditing {
                Button("Go", systemImage: "location.north.line.fill") { model.startNavigation() }
                    .buttonStyle(.glassProminent)
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
            }
            Button("Close route", systemImage: "xmark") { model.closeRoute() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .catchesTouches(cornerRadius: 22)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func summary(_ plan: PassagePlan?) -> String {
        guard let plan else {
            let n = model.route.waypoints.count
            return n < 2 ? "Add a second waypoint" : String(format: "%.1f NM", Geo.length(of: model.path))
        }
        var parts = [String(format: "%.1f NM", plan.distance), plan.duration.hoursMinutes,
                     "ETA " + plan.arrival.formatted(date: .omitted, time: .shortened)]
        if plan.usedForecast { parts.append("max \(Int(plan.maxWind.rounded())) kn") }
        return parts.joined(separator: " · ")
    }
}

/// Nautical-mile scale bar, capped in width so it never pushes anything around; metres up close.
struct ScaleBar: View {
    var metresPerPoint: Double
    private static let maxWidth: CGFloat = 110

    var body: some View {
        if let (label, width) = scale {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
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
            .frame(width: Self.maxWidth + 20, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .allowsHitTesting(false)
        }
    }

    /// The longest round length that fits.
    private var scale: (String, CGFloat)? {
        guard metresPerPoint > 0, metresPerPoint.isFinite else { return nil }
        let pointsPerMetre = 1 / metresPerPoint
        let miles: [Double] = [0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000]
        if let nm = miles.last(where: { $0 * 1852 * pointsPerMetre <= Self.maxWidth }), nm * 1852 * pointsPerMetre >= 30 {
            return (nm < 1 ? "\(nm.formatted()) NM" : "\(Int(nm)) NM", CGFloat(nm * 1852 * pointsPerMetre))
        }
        let metres: [Double] = [5, 10, 20, 25, 50, 100]
        guard let m = metres.last(where: { $0 * pointsPerMetre <= Self.maxWidth }) else { return nil }
        return ("\(Int(m)) m", CGFloat(m * pointsPerMetre))
    }
}

/// Which hour the wind arrows (and radar frame) show.
struct TimeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            Button("Earlier", systemImage: "chevron.left") { model.stepTime(by: -1) }
            Button {
                model.resetTime()
            } label: {
                VStack(spacing: 0) {
                    Text(timeText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(statusIsError ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                .frame(width: 92)
            }
            .tint(.primary)
            Button("Later", systemImage: "chevron.right") { model.stepTime(by: 1) }
        }
        .labelStyle(.iconOnly)
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .catchesTouches(cornerRadius: 12)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
    }

    private var timeText: String {
        if model.showWind {
            return abs(model.windTime.timeIntervalSinceNow) < 1800 ? "Wind now"
                : model.windTime.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        guard let frame = model.radarFrame else { return "" }
        return "Rain " + frame.date.formatted(date: .omitted, time: .shortened)
    }

    private var statusText: String {
        switch model.windState {
        case .loading: "Loading…"
        case .failed: "Unavailable"
        default: model.showWind ? "kn · tap for now" : "radar"
        }
    }

    private var statusIsError: Bool {
        if case .failed = model.windState { return true }
        return false
    }
}
