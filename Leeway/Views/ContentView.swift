import SwiftUI

/// Main app interface using Apple's iOS HIG TabView architecture:
/// 1. Chart: Full-screen interactive marine chart, navigation instruments, search, layers, and inspector cards.
/// 2. Routes: Passage planning, leg analysis, departure weather, and saved routes.
/// 3. Weather: Marine forecast, wind graphs, tides, sun times, and official warnings.
/// 4. Log: Track recording, anchor watch, user marks, and logbook history.
/// 5. Settings: Boat profile, alarms, NMEA connections, offline charts, and about.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("acceptedDisclaimer") private var acceptedDisclaimer = false
    @State private var showingOnboarding = false

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            ChartTabView()
                .tabItem {
                    Label(AppTab.chart.title, systemImage: AppTab.chart.symbol)
                }
                .tag(AppTab.chart)

            RouteSheet(close: { model.selectedTab = .chart })
                .tabItem {
                    Label(AppTab.routes.title, systemImage: AppTab.routes.symbol)
                }
                .tag(AppTab.routes)

            WeatherSheet()
                .tabItem {
                    Label(AppTab.weather.title, systemImage: AppTab.weather.symbol)
                }
                .tag(AppTab.weather)

            LogSheet(close: { model.selectedTab = .chart })
                .tabItem {
                    Label(AppTab.log.title, systemImage: AppTab.log.symbol)
                }
                .tag(AppTab.log)

            SettingsSheet()
                .tabItem {
                    Label(AppTab.settings.title, systemImage: AppTab.settings.symbol)
                }
                .tag(AppTab.settings)
        }
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
        .onChange(of: model.isEditing) { _, editing in
            if editing { model.selectedTab = .chart }
        }
        .onChange(of: model.underway.isNavigating) { _, navigating in
            if navigating { model.selectedTab = .chart }
        }
    }
}

/// The chart, full screen, with top instruments/controls and bottom cards respecting safe areas.
struct ChartTabView: View {
    @Environment(AppModel.self) private var model
    @State private var showingLayers = false
    @State private var showingSearch = false

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
            },
            onMoveWaypoint: { model.moveWaypoint($0, to: $1) },
            onInspect: { hit in
                if let hit {
                    model.inspect(hit)
                } else {
                    model.inspection = nil
                }
            },
            onMeasure: { model.addMeasurePoint($0) },
            onRegionChange: { model.mapMoved(to: $0) },
            onTrackingChange: { model.tracking = $0 },
            onCameraChange: { model.camera = $0 }
        )
        .ignoresSafeArea()
        .overlay {
            if model.showGrid { GridLabels(camera: model.camera) }
        }
        .overlay(alignment: .top) {
            TopChrome(showingLayers: $showingLayers, showingSearch: $showingSearch)
                .safeAreaPadding(.top)
        }
        .overlay(alignment: .bottom) {
            BottomChrome()
                .safeAreaPadding(.bottom)
        }
        .animation(.smooth(duration: 0.25), value: model.isEditing)
        .animation(.smooth(duration: 0.25), value: model.inspection)
        .animation(.smooth(duration: 0.25), value: model.underway.isNavigating)
        .animation(.smooth(duration: 0.25), value: model.underway.mob?.time)
        .animation(.smooth(duration: 0.25), value: model.underway.anchorAlarm)
        .animation(.smooth(duration: 0.25), value: model.isMeasuring)
        .sheet(isPresented: $showingSearch) {
            SearchSheet(close: { showingSearch = false })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingLayers) {
            LayersSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private extension ChartTabView {
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
