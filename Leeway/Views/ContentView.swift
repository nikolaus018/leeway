import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var detent = PresentationDetent.collapsed

    var body: some View {
        ChartMapView(
            base: model.mapBase,
            showSeamarks: model.showSeamarks,
            showDepth: model.showDepth,
            showGrid: model.showGrid,
            regions: model.regions,
            safetyDepth: model.boat.safetyDepth,
            waypoints: model.route.waypoints,
            path: model.path,
            legHazards: model.legHazards,
            track: model.location.track,
            samples: model.plan?.samples ?? [],
            legLabels: legLabels,
            underway: underwayMap,
            inspected: model.inspection?.coordinate,
            isEditing: model.isEditing,
            tracking: model.tracking,
            fitRouteRequest: model.fitRouteRequest,
            onAddWaypoint: { model.addWaypoint(at: $0) },
            onMoveWaypoint: { model.moveWaypoint($0, to: $1) },
            onInspect: { model.inspect($0, seamark: $1) },
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
                ScaleBar(metresPerPoint: model.camera.metresPerPoint)
                if let inspection = model.inspection, !model.isEditing {
                    InspectorCard(inspection: inspection)
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
