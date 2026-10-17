import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var detent = PresentationDetent.collapsed

    var body: some View {
        ChartMapView(
            base: model.mapBase,
            showSeamarks: model.showSeamarks,
            showDepth: model.showDepth,
            showGrid: model.showGrid,
            regions: model.regions,
            server: Seadata(model.serverURL) ?? Seadata.current,
            safetyDepth: model.boat.safetyDepth,
            waypoints: model.route.waypoints,
            path: model.path,
            legHazards: model.legHazards,
            track: model.location.track,
            samples: model.plan?.samples ?? [],
            legLabels: legLabels,
            windArrows: windArrows,
            vessels: vesselMarkers,
            underway: underwayMap,
            inspected: model.inspection?.coordinate,
            isEditing: model.isEditing,
            tracking: model.tracking,
            fitRouteRequest: model.fitRouteRequest,
            onAddWaypoint: { model.addWaypoint(at: $0) },
            onMoveWaypoint: { model.moveWaypoint($0, to: $1) },
            onInspect: { model.inspect($0, seamark: $1) },
            onSelectVessel: { model.inspect(vessel: $0) },
            onRegionChange: { model.mapMoved(to: $0) },
            onTrackingChange: { model.tracking = $0 },
            onCameraChange: { model.camera = $0 }
        )
        .ignoresSafeArea()
        .overlay {
            if model.showGrid { GridLabels(camera: model.camera) }
        }
        .overlay(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                if model.underway.anchorAlarm {
                    AnchorAlarmBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                HStack(alignment: .top, spacing: 10) {
                    if model.underway.mob != nil {
                        MOBPanel()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if model.underway.isNavigating {
                        NavigationPanel()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if model.isEditing {
                        EditingBanner()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if model.location.location != nil {
                        InstrumentsHUD()
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 10) {
                        MapControls()
                        MOBButton()
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    ScaleBar(metresPerPoint: model.camera.metresPerPoint)
                    if model.showWind { WindTimeBar() }
                    if model.showAIS { AISStatus() }
                }
                if let inspection = model.inspection, !model.isEditing {
                    Group {
                        if let vessel = inspection.vessel {
                            VesselCard(vessel: vessel)
                        } else {
                            InspectorCard(inspection: inspection)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .animation(.smooth, value: model.isEditing)
        .animation(.smooth, value: model.inspection)
        .animation(.smooth, value: model.underway.isNavigating)
        .animation(.smooth, value: model.underway.mob?.time)
        .animation(.smooth, value: model.underway.anchorAlarm)
        .sheet(isPresented: .constant(true)) {
            PlannerSheet(detent: $detent)
                .presentationDetents([.collapsed, .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .onChange(of: model.isEditing) { _, editing in
            if editing { detent = .collapsed }
        }
        .onChange(of: model.underway.isNavigating) { _, navigating in
            if navigating { detent = .collapsed }
        }
        .task { model.location.start() }
        .onChange(of: scenePhase, initial: true) { _, phase in model.isActive = phase == .active }
    }
}

private extension ContentView {
    var underwayMap: UnderwayMapState {
        let underway = model.underway
        let fix = model.location.location
        var state = UnderwayMapState()
        state.boat = fix.map { .init($0.coordinate) }
        state.cog = model.location.cog
        state.sog = model.location.sog
        if let leg = underway.activeLegPoints {
            state.activeLeg = [.init(leg.0), .init(leg.1)]
            state.next = .init(leg.1)
            state.ahead = underway.pointsAhead.map(UnderwayMapState.Point.init)
        }
        state.mob = underway.mob.map { .init($0.coordinate) }
        if let anchor = underway.anchor {
            state.anchor = .init(anchor.coordinate)
            state.anchorRadius = anchor.radius
            state.anchorAlarm = underway.anchorAlarm
            state.swing = underway.swing.map(UnderwayMapState.Point.init)
        }
        return state
    }

    /// Wind at the chosen hour on the visible grid.
    var windArrows: [WindArrow] {
        guard model.showWind, let grid = model.windGrid, let hour = grid.hour(for: model.windTime) else { return [] }
        return grid.points.compactMap { p in
            guard hour < p.windSpeed.count, hour < p.windFrom.count,
                  let speed = p.windSpeed[hour], let from = p.windFrom[hour] else { return nil }
            return WindArrow(latitude: p.lat, longitude: p.lon, speed: speed, from: from)
        }
    }

    /// Ships, the ones about to pass close flagged.
    var vesselMarkers: [VesselMarker] {
        guard model.showAIS else { return [] }
        let moving = (model.location.sog ?? 0) >= 0.5
        return model.vessels.map { vessel in
            let danger = (moving || vessel.isUnderway) && (model.approach(to: vessel)?.isDangerous ?? false)
            return VesselMarker(vessel: vessel, danger: danger)
        }
    }

    /// "128° 4.2 NM" at the middle of each leg worth labelling.
    var legLabels: [LegAnnotationData] {
        guard let plan = model.plan, !model.isEditing else { return [] }
        return plan.legs.compactMap { leg in
            guard leg.distance >= 0.4, leg.index + 1 < model.path.count else { return nil }
            let mid = Geo.interpolate(model.path[leg.index], model.path[leg.index + 1], fraction: 0.5)
            let text = String(format: "%03.0f° · %.1f NM", leg.bearing, leg.distance)
            return LegAnnotationData(text: text, latitude: mid.latitude, longitude: mid.longitude)
        }
    }
}

extension PresentationDetent {
    static let collapsed = PresentationDetent.height(150)
}

private struct MapControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Menu {
                Picker("Map", selection: $model.mapBase) {
                    ForEach(MapBase.allCases) { base in
                        Label(base.label, systemImage: base.symbol).tag(base)
                    }
                }
                Section("Overlays") {
                    Toggle(isOn: $model.showDepth) {
                        Label("Depths & contours", systemImage: "water.waves")
                    }
                    Toggle(isOn: $model.showSeamarks) {
                        Label("Seamarks", systemImage: "light.beacon.max")
                    }
                    Toggle(isOn: $model.showGrid) {
                        Label("Lat/Lon grid", systemImage: "grid")
                    }
                }
                Section("Live") {
                    Toggle(isOn: $model.showWind) {
                        Label("Wind forecast", systemImage: "wind")
                    }
                    Toggle(isOn: $model.showAIS) {
                        Label("Ships (AIS)", systemImage: "ferry")
                    }
                }
            } label: {
                Image(systemName: "square.2.layers.3d")
                    .frame(width: 44, height: 44)
            }
            Divider().frame(width: 28)
            Button {
                model.tracking = switch model.tracking {
                case .none: .follow
                case .follow: .heading
                case .heading: .none
                }
            } label: {
                Image(systemName: trackingSymbol)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
            }
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.tint)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    private var trackingSymbol: String {
        switch model.tracking {
        case .none: "location"
        case .follow: "location.fill"
        case .heading: "location.north.line.fill"
        }
    }
}

private struct EditingBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .foregroundStyle(.tint)
            Text(model.route.waypoints.isEmpty ? "Tap the chart to set your start" : "Tap to add, drag to move")
                .font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undoLastWaypoint() }
                .labelStyle(.iconOnly)
                .disabled(model.route.waypoints.isEmpty)
            Button("Done") { model.isEditing = false }
                .buttonStyle(.glassProminent)
                .disabled(model.route.waypoints.count < 2 && !model.route.waypoints.isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}

/// Which forecast hour the wind arrows show; steps by 3 h, tap the time to go back to now.
private struct WindTimeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            Button("Earlier", systemImage: "chevron.left") { model.stepWind(hours: -3) }
                .disabled(model.windGrid?.start.map { model.windTime <= $0 } ?? true)
            Button {
                model.windTime = .now
            } label: {
                VStack(spacing: 0) {
                    Text(timeText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(statusIsError ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 84)
            }
            .tint(.primary)
            Button("Later", systemImage: "chevron.right") { model.stepWind(hours: 3) }
                .disabled(model.windGrid?.end.map { model.windTime >= $0 } ?? true)
        }
        .labelStyle(.iconOnly)
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
    }

    private var timeText: String {
        abs(model.windTime.timeIntervalSinceNow) < 1800 ? "Wind now"
            : model.windTime.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var statusText: String {
        switch model.windState {
        case .loading: "Loading…"
        case .failed: "Unavailable"
        default: "kn · tap for now"
        }
    }

    private var statusIsError: Bool {
        if case .failed = model.windState { return true }
        return false
    }
}

/// Ship count, or why there are none.
private struct AISStatus: View {
    @Environment(AppModel.self) private var model

    private var text: String {
        switch model.aisState {
        case .zoomIn: "Zoom in for ships"
        case .failed(let message): message
        default: "\(model.vessels.count) ships"
        }
    }

    var body: some View {
        Label(text, systemImage: "ferry")
            .font(.caption.weight(.semibold))
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 200, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
