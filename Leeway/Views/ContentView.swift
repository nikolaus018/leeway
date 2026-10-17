import SwiftUI

/// The chart, full screen, with as little on top of it as possible: an instrument strip and map
/// controls at the top, a scale bar and one tab bar at the bottom. Everything else lives in sheets
/// that open from the tab bar and get out of the way again.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: AppSheet?
    @State private var showingLayers = false
    @AppStorage("acceptedDisclaimer") private var acceptedDisclaimer = false
    @State private var showingOnboarding = false

    var body: some View {
        ChartMapView(
            style: model.chartStyle,
            waypoints: model.route.waypoints,
            path: model.path,
            legHazards: model.legHazards,
            track: model.shownTrack?.points.map(\.coordinate) ?? model.location.track,
            samples: model.plan?.samples ?? [],
            legLabels: legLabels,
            windArrows: windArrows,
            vessels: vesselMarkers,
            underway: underwayMap,
            marks: model.marks,
            warnings: model.warnings.filter { $0.isMarine && ($0.expiresDate ?? .distantFuture) > .now },
            radar: model.radarFrame,
            measure: model.measurePoints,
            inspected: model.inspection?.coordinate,
            showGrid: model.showGrid,
            isEditing: model.isEditing,
            isMeasuring: model.isMeasuring,
            tracking: model.tracking,
            northRequest: model.northRequest,
            fitRouteRequest: model.fitRouteRequest,
            focus: model.focus,
            onAddWaypoint: { coordinate in
                model.addWaypoint(at: coordinate)
                sheet = nil
            },
            onMoveWaypoint: { model.moveWaypoint($0, to: $1) },
            onInspect: { model.inspect($0) },
            onMeasure: { model.addMeasurePoint($0) },
            onRegionChange: { model.mapMoved(to: $0) },
            onTrackingChange: { model.tracking = $0 },
            onCameraChange: { model.camera = $0 }
        )
        .ignoresSafeArea()
        .overlay {
            if model.showGrid { GridLabels(camera: model.camera) }
        }
        .overlay(alignment: .top) { TopChrome(showingLayers: $showingLayers) }
        .overlay(alignment: .bottom) { BottomChrome(sheet: $sheet) }
        .animation(.smooth(duration: 0.25), value: model.isEditing)
        .animation(.smooth(duration: 0.25), value: model.inspection)
        .animation(.smooth(duration: 0.25), value: model.underway.isNavigating)
        .animation(.smooth(duration: 0.25), value: model.underway.mob?.time)
        .animation(.smooth(duration: 0.25), value: model.underway.anchorAlarm)
        .animation(.smooth(duration: 0.25), value: model.isMeasuring)
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .search: SearchSheet(close: { self.sheet = nil })
                case .route: RouteSheet(close: { self.sheet = nil })
                case .weather: WeatherSheet()
                case .log: LogSheet(close: { self.sheet = nil })
                case .settings: SettingsSheet()
                }
            }
            .presentationDetents(sheet == .search ? [.large] : [.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingLayers) {
            LayersSheet()
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .onChange(of: model.isEditing) { _, editing in
            // Editing happens on the chart: get the sheet out of the way.
            if editing { sheet = nil }
        }
        .onChange(of: model.underway.isNavigating) { _, navigating in
            if navigating { sheet = nil }
        }
        .onChange(of: model.routeOpenedRequest) { _, _ in
            sheet = .route
        }
        // Night colours keep night vision: the whole app goes dark, sheets included.
        .preferredColorScheme(model.palette == .night ? .dark : nil)
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView {
                acceptedDisclaimer = true
                showingOnboarding = false
                model.location.start()
            }
        }
        .task {
            if acceptedDisclaimer { model.location.start() } else { showingOnboarding = true }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in model.isActive = phase == .active }
    }
}

enum AppSheet: String, Identifiable, CaseIterable {
    case search, route, weather, log, settings
    var id: Self { self }

    var title: String {
        switch self {
        case .search: "Search"
        case .route: "Route"
        case .weather: "Weather"
        case .log: "Log"
        case .settings: "More"
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        case .weather: "cloud.sun"
        case .log: "book.closed"
        case .settings: "ellipsis.circle"
        }
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
        return model.vessels.map { VesselMarker(vessel: $0, danger: model.isDangerous($0)) }
    }

    /// "128° · 4.2 NM" at the middle of each leg worth labelling.
    var legLabels: [LegAnnotationData] {
        guard let plan = model.plan, !model.isEditing, !model.underway.isNavigating else { return [] }
        return plan.legs.compactMap { leg in
            guard leg.distance >= 0.4, leg.index + 1 < model.path.count else { return nil }
            let mid = Geo.interpolate(model.path[leg.index], model.path[leg.index + 1], fraction: 0.5)
            let text = String(format: "%03.0f° · %.1f NM", leg.bearing, leg.distance)
            return LegAnnotationData(text: text, latitude: mid.latitude, longitude: mid.longitude)
        }
    }
}
