import MapKit
import SwiftUI

/// MKMapView wrapper: SwiftUI's `Map` can't draw raster tile overlays, which the
/// depth chart and the OpenSeaMap seamark layer need.
struct ChartMapView: UIViewRepresentable {
    var base: MapBase
    var showSeamarks: Bool
    var showDepth: Bool
    var showGrid: Bool
    var regions: [ChartRegion]
    var server: Seadata
    var safetyDepth: Double
    var waypoints: [Waypoint]
    var path: [CLLocationCoordinate2D]
    var legHazards: [String?]
    var track: [CLLocationCoordinate2D]
    var samples: [PassageSample]
    var legLabels: [LegAnnotationData]
    var windArrows: [WindArrow]
    var vessels: [VesselMarker]
    var underway: UnderwayMapState
    var inspected: CLLocationCoordinate2D?
    var isEditing: Bool
    var tracking: AppModel.UserTracking
    var fitRouteRequest: Int
    var onAddWaypoint: (CLLocationCoordinate2D) -> Void
    var onMoveWaypoint: (Waypoint.ID, CLLocationCoordinate2D) -> Void
    var onInspect: (CLLocationCoordinate2D, Seamark?) -> Void
    var onSelectVessel: (Vessel) -> Void
    var onRegionChange: (GeoBox) -> Void
    var onTrackingChange: (AppModel.UserTracking) -> Void
    var onCameraChange: (AppModel.MapCamera) -> Void

    static let kvarner = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 45.2, longitude: 14.42),
        span: MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.5)
    )

    private static var initialRegion: MKCoordinateRegion {
        #if DEBUG
        // `-debugCenter "lat,lon,span"` opens the map at a given spot (simulator testing).
        if let spec = UserDefaults.standard.string(forKey: "debugCenter") {
            let v = spec.split(separator: ",").compactMap { Double($0) }
            if v.count == 3 {
                return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: v[0], longitude: v[1]),
                                          span: MKCoordinateSpan(latitudeDelta: v[2], longitudeDelta: v[2]))
            }
        }
        #endif
        return kvarner
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = SizedMapView()
        map.onFirstLayout = { [weak map] in map?.setRegion(Self.initialRegion, animated: false) }
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = false
        map.register(WaypointView.self, forAnnotationViewWithReuseIdentifier: WaypointView.reuseID)
        map.register(ConditionsView.self, forAnnotationViewWithReuseIdentifier: ConditionsView.reuseID)
        map.register(HarbourView.self, forAnnotationViewWithReuseIdentifier: HarbourView.reuseID)
        map.register(InspectView.self, forAnnotationViewWithReuseIdentifier: InspectView.reuseID)
        map.register(LegLabelView.self, forAnnotationViewWithReuseIdentifier: LegLabelView.reuseID)
        map.register(BadgeView.self, forAnnotationViewWithReuseIdentifier: BadgeView.reuseID)
        map.register(WindArrowView.self, forAnnotationViewWithReuseIdentifier: WindArrowView.reuseID)
        map.register(VesselView.self, forAnnotationViewWithReuseIdentifier: VesselView.reuseID)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.delegate = context.coordinator
        map.addGestureRecognizer(press)

        let coordinator = context.coordinator
        map.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (map: MKMapView, _: UITraitCollection) in
            coordinator.applyChart(to: map)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.syncRegions(regions, on: map)
        c.applyBase(base, to: map)
        c.applyChart(to: map)
        c.applySeamarks(showSeamarks, to: map)
        c.syncWaypoints(waypoints, editing: isEditing, on: map)
        c.syncPath(path, hazards: legHazards, on: map)
        c.syncTrack(track, on: map)
        c.syncSamples(samples, on: map)
        c.syncLegLabels(legLabels, on: map)
        c.syncWind(windArrows, on: map)
        c.syncVessels(vessels, on: map)
        c.syncUnderway(underway, on: map)
        c.syncInspected(inspected, on: map)
        c.applyTracking(tracking, to: map)
        if c.lastFitRequest != fitRouteRequest {
            c.lastFitRequest = fitRouteRequest
            c.fitRoute(on: map)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: ChartMapView
        var lastFitRequest = 0

        private var currentBase: MapBase?
        private var seamarkOverlay: SeamarkTileOverlay?
        private var seamarkKey: String?
        private let graticule = GraticuleOverlay()
        private var chartOverlays: [ChartOverlay] = []
        private var depthKey: String?
        private var routeLines: [MKPolyline] = []
        /// Manual-mode legs that cross land or shallows (MapKit's polyline factories can't be subclassed).
        private var hazardLines: Set<ObjectIdentifier> = []
        private var drawnPath: [Double] = []
        private var drawnHazards: [Bool] = []
        private var trackLine: MKPolyline?
        private var trackCount = -1
        private var drawnWaypoints: [Waypoint] = []
        private var drawnEditing = false
        private var drawnSampleTimes: [Date] = []
        private var inspectAnnotation: InspectAnnotation?
        var harbours: [SeamarkAnnotation] = []
        private var harboursShown = false
        private var loadedRegions: [ObjectIdentifier] = []

        /// Charts arrive after launch (and again after a download); rebuild what depends on them.
        func syncRegions(_ regions: [ChartRegion], on map: MKMapView) {
            let ids = regions.map { ObjectIdentifier($0) }
            guard ids != loadedRegions else { return }
            loadedRegions = ids
            if harboursShown { map.removeAnnotations(harbours) }
            harbours = regions.flatMap { $0.seamarks.filter(\.isHarbourLike) }.map(SeamarkAnnotation.init)
            if harboursShown { map.addAnnotations(harbours) }
            depthKey = nil
            seamarkKey = nil
        }
        private var currentTracking = AppModel.UserTracking.none

        init(_ parent: ChartMapView) { self.parent = parent }

        func applyBase(_ base: MapBase, to map: MKMapView) {
            guard base != currentBase else { return }
            currentBase = base
            switch base {
            case .chart:
                let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
                config.pointOfInterestFilter = MKPointOfInterestFilter(including: [.marina, .beach, .gasStation])
                map.preferredConfiguration = config
            case .satellite:
                map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
            }
        }

        /// The offline chart and the lat/lon grid; rebuilt when the look or the safety depth changes.
        func applyChart(to map: MKMapView) {
            let dark = map.traitCollection.userInterfaceStyle == .dark
            let style = ChartStyle(paintLand: parent.base == .chart, dark: dark, safetyDepth: parent.safetyDepth, seamarks: parent.showSeamarks)
            let key = parent.showDepth ? "\(style)" : "off"
            if key != depthKey {
                depthKey = key
                map.removeOverlays(chartOverlays)
                chartOverlays = parent.showDepth ? parent.regions.map { ChartOverlay(region: $0, style: style) } : []
                for overlay in chartOverlays { map.insertOverlay(overlay, at: 0, level: .aboveRoads) }
            }
            let gridShown = map.overlays.contains { $0 === graticule }
            if parent.showGrid && !gridShown { map.addOverlay(graticule, level: .aboveRoads) }
            if !parent.showGrid && gridShown { map.removeOverlay(graticule) }
            if parent.showGrid, let renderer = map.renderer(for: graticule) as? GraticuleRenderer, renderer.dark != dark {
                renderer.dark = dark
                renderer.setNeedsDisplay()
            }
        }

        /// OpenSeaMap symbols for areas without an offline chart (the chart draws its own seamarks).
        func applySeamarks(_ show: Bool, to map: MKMapView) {
            let key = show ? (parent.showDepth ? "outside-charts" : "everywhere") + parent.server.base.absoluteString : "off"
            guard key != seamarkKey else { return }
            seamarkKey = key
            if let seamarkOverlay { map.removeOverlay(seamarkOverlay) }
            seamarkOverlay = nil
            guard show else { return }
            let overlay = SeamarkTileOverlay(regions: parent.showDepth ? parent.regions : [], server: parent.server)
            map.addOverlay(overlay, level: .aboveLabels)
            seamarkOverlay = overlay
        }

        func syncWaypoints(_ waypoints: [Waypoint], editing: Bool, on map: MKMapView) {
            guard waypoints != drawnWaypoints || editing != drawnEditing else { return }
            let structureChanged = waypoints.map(\.id) != drawnWaypoints.map(\.id) || editing != drawnEditing
            drawnWaypoints = waypoints
            drawnEditing = editing

            if structureChanged {
                map.removeAnnotations(map.annotations.filter { $0 is WaypointAnnotation })
                map.addAnnotations(waypoints.enumerated().map { i, w in
                    WaypointAnnotation(waypoint: w, index: i, count: waypoints.count)
                })
            } else {
                // Only positions changed (a drag): move the pins in place so the drag isn't interrupted.
                for case let annotation as WaypointAnnotation in map.annotations {
                    if let w = waypoints.first(where: { $0.id == annotation.id }) {
                        annotation.coordinate = w.coordinate
                    }
                }
            }
        }

        func syncPath(_ path: [CLLocationCoordinate2D], hazards: [String?], on map: MKMapView) {
            let key = path.flatMap { [$0.latitude, $0.longitude] }
            let hazardKey = hazards.map { $0 != nil }
            guard key != drawnPath || hazardKey != drawnHazards else { return }
            drawnPath = key
            drawnHazards = hazardKey
            map.removeOverlays(routeLines)
            routeLines = []
            hazardLines = []
            guard path.count >= 2 else { return }
            if hazardKey.contains(true), hazardKey.count == path.count - 1 {
                // Manual route with problems: draw leg by leg so the bad ones stand out.
                for (i, pair) in zip(path, path.dropFirst()).enumerated() {
                    let line = MKGeodesicPolyline(coordinates: [pair.0, pair.1], count: 2)
                    if hazardKey[i] { hazardLines.insert(ObjectIdentifier(line)) }
                    routeLines.append(line)
                }
            } else {
                routeLines = [MKPolyline(coordinates: path, count: path.count)]
            }
            map.addOverlays(routeLines, level: .aboveLabels)
        }

        func syncTrack(_ track: [CLLocationCoordinate2D], on map: MKMapView) {
            guard track.count != trackCount else { return }
            trackCount = track.count
            if let trackLine { map.removeOverlay(trackLine) }
            trackLine = nil
            if track.count >= 2 {
                let line = MKPolyline(coordinates: track, count: track.count)
                map.addOverlay(line, level: .aboveLabels)
                trackLine = line
            }
        }

        func syncSamples(_ samples: [PassageSample], on map: MKMapView) {
            let key = samples.map(\.time)
            guard key != drawnSampleTimes || samples.isEmpty != map.annotations.contains(where: { $0 is ConditionsAnnotation }) else { return }
            drawnSampleTimes = key
            map.removeAnnotations(map.annotations.filter { $0 is ConditionsAnnotation })
            map.addAnnotations(samples.map(ConditionsAnnotation.init))
        }

        private var drawnLegLabels: [LegAnnotationData] = []

        // MARK: Live layers

        private var drawnWind: [WindArrow] = []

        func syncWind(_ arrows: [WindArrow], on map: MKMapView) {
            guard arrows != drawnWind else { return }
            drawnWind = arrows
            map.removeAnnotations(map.annotations.filter { $0 is WindArrowAnnotation })
            map.addAnnotations(arrows.map(WindArrowAnnotation.init))
        }

        private var vesselAnnotations: [Int: VesselAnnotation] = [:]

        /// Ships move every few seconds: update pins in place rather than replacing them.
        func syncVessels(_ markers: [VesselMarker], on map: MKMapView) {
            let wanted = Dictionary(markers.map { ($0.vessel.mmsi, $0) }, uniquingKeysWith: { a, _ in a })
            let gone = vesselAnnotations.filter { wanted[$0.key] == nil }
            if !gone.isEmpty {
                map.removeAnnotations(Array(gone.values))
                gone.keys.forEach { vesselAnnotations[$0] = nil }
            }
            var added: [VesselAnnotation] = []
            for (mmsi, marker) in wanted {
                if let annotation = vesselAnnotations[mmsi] {
                    guard annotation.marker != marker else { continue }
                    annotation.marker = marker
                    annotation.coordinate = marker.vessel.coordinate
                    (map.view(for: annotation) as? VesselView)?.configure(marker)
                } else {
                    let annotation = VesselAnnotation(marker)
                    vesselAnnotations[mmsi] = annotation
                    added.append(annotation)
                }
            }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        // MARK: Underway

        private enum LineStyle { case activeLeg, ahead, bearing, cog, mob, swing }
        private var drawnUnderway = UnderwayMapState()
        private var underwayOverlays: [MKOverlay] = []
        private var underwayAnnotations: [MKAnnotation] = []
        private var lineStyles: [ObjectIdentifier: LineStyle] = [:]
        private var anchorAlarmShown = false
        /// The planned route is already drawn when the planner still has it; otherwise draw what's left from navigation.
        private var drawnPathIsEmpty: Bool { drawnPath.isEmpty }

        func syncUnderway(_ state: UnderwayMapState, on map: MKMapView) {
            guard state != drawnUnderway else { return }
            let annotationsChanged = state.mob != drawnUnderway.mob || state.anchor != drawnUnderway.anchor
                || state.anchorAlarm != drawnUnderway.anchorAlarm
            drawnUnderway = state
            map.removeOverlays(underwayOverlays)
            underwayOverlays = []
            lineStyles = [:]
            anchorAlarmShown = state.anchorAlarm

            func line(_ points: [CLLocationCoordinate2D], _ style: LineStyle) {
                guard points.count >= 2 else { return }
                let polyline = MKPolyline(coordinates: points, count: points.count)
                lineStyles[ObjectIdentifier(polyline)] = style
                underwayOverlays.append(polyline)
            }
            if state.ahead.count >= 2, state.activeLeg.isEmpty == false, drawnPathIsEmpty { line(state.ahead.map(\.coordinate), .ahead) }
            if state.activeLeg.count == 2 { line(state.activeLeg.map(\.coordinate), .activeLeg) }
            if let boat = state.boat {
                if let next = state.next { line([boat.coordinate, next.coordinate], .bearing) }
                if let mob = state.mob { line([boat.coordinate, mob.coordinate], .mob) }
                // Where the boat will be in 6 minutes on its current course and speed.
                if let cog = state.cog, let sog = state.sog, sog > 0.3 {
                    line([boat.coordinate, Geo.destination(from: boat.coordinate, bearing: cog, distanceNM: sog / 10)], .cog)
                }
            }
            if let anchor = state.anchor {
                underwayOverlays.append(MKCircle(center: anchor.coordinate, radius: state.anchorRadius))
                line(state.swing.map(\.coordinate), .swing)
            }
            map.addOverlays(underwayOverlays, level: .aboveLabels)

            guard annotationsChanged else { return }
            map.removeAnnotations(underwayAnnotations)
            underwayAnnotations = []
            if let anchor = state.anchor { underwayAnnotations.append(AnchorAnnotation(anchor.coordinate)) }
            if let mob = state.mob { underwayAnnotations.append(MOBAnnotation(mob.coordinate)) }
            map.addAnnotations(underwayAnnotations)
        }

        func syncLegLabels(_ labels: [LegAnnotationData], on map: MKMapView) {
            guard labels != drawnLegLabels else { return }
            drawnLegLabels = labels
            map.removeAnnotations(map.annotations.filter { $0 is LegAnnotation })
            map.addAnnotations(labels.map { LegAnnotation(text: $0.text, coordinate: $0.coordinate) })
        }

        func syncInspected(_ coordinate: CLLocationCoordinate2D?, on map: MKMapView) {
            if let coordinate {
                if let inspectAnnotation {
                    inspectAnnotation.coordinate = coordinate
                } else {
                    let annotation = InspectAnnotation(coordinate)
                    map.addAnnotation(annotation)
                    inspectAnnotation = annotation
                }
            } else if let inspectAnnotation {
                map.removeAnnotation(inspectAnnotation)
                self.inspectAnnotation = nil
            }
        }

        func applyTracking(_ tracking: AppModel.UserTracking, to map: MKMapView) {
            guard tracking != currentTracking else { return }
            currentTracking = tracking
            let mode: MKUserTrackingMode = switch tracking {
            case .none: .none
            case .follow: .follow
            case .heading: .followWithHeading
            }
            map.setUserTrackingMode(mode, animated: true)
        }

        func fitRoute(on map: MKMapView) {
            let rect = routeLines.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
            guard !rect.isNull else { return }
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 140, left: 50, bottom: 420, right: 70), animated: true)
        }

        // MARK: Gestures

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            if parent.isEditing {
                parent.onAddWaypoint(coordinate)
                return
            }
            // Pick the closest charted object within a finger's reach, else just the spot.
            var best: (Seamark, CGFloat)?
            for region in parent.regions where region.contains(coordinate) {
                for mark in region.seamarks {
                    let p = map.convert(mark.coordinate, toPointTo: map)
                    let d = hypot(p.x - point.x, p.y - point.y)
                    if d < 26, d < (best?.1 ?? .infinity) { best = (mark, d) }
                }
            }
            parent.onInspect(coordinate, best?.0)
        }

        @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, !parent.isEditing, let map = gesture.view as? MKMapView else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.onAddWaypoint(map.convert(gesture.location(in: map), toCoordinateFrom: map))
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Let pins handle their own taps and drags.
            var view = touch.view
            while let v = view {
                if v is MKAnnotationView { return false }
                view = v.superview
            }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let chart = overlay as? ChartOverlay {
                return ChartRenderer(chart: chart)
            }
            if let tiles = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tiles)
            }
            if overlay is GraticuleOverlay {
                let renderer = GraticuleRenderer(overlay: overlay)
                renderer.dark = mapView.traitCollection.userInterfaceStyle == .dark
                return renderer
            }
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                let colour: UIColor = anchorAlarmShown ? .systemRed : .systemPurple
                renderer.strokeColor = colour
                renderer.fillColor = colour.withAlphaComponent(0.1)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [6, 4]
                return renderer
            }
            if let line = overlay as? MKPolyline, let style = lineStyles[ObjectIdentifier(line)] {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.lineCap = .round
                switch style {
                case .activeLeg:
                    renderer.strokeColor = .systemPink
                    renderer.lineWidth = 6
                case .ahead:
                    renderer.strokeColor = UIColor.systemPink.withAlphaComponent(0.6)
                    renderer.lineWidth = 3
                case .bearing:
                    renderer.strokeColor = .systemPink
                    renderer.lineWidth = 2
                    renderer.lineDashPattern = [6, 5]
                case .cog:
                    renderer.strokeColor = mapView.traitCollection.userInterfaceStyle == .dark ? .white : .black
                    renderer.lineWidth = 2.5
                case .mob:
                    renderer.strokeColor = .systemRed
                    renderer.lineWidth = 3
                    renderer.lineDashPattern = [8, 5]
                case .swing:
                    renderer.strokeColor = UIColor.systemPurple.withAlphaComponent(0.7)
                    renderer.lineWidth = 1.5
                }
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                if line === trackLine {
                    renderer.strokeColor = .systemOrange
                    renderer.lineWidth = 3
                } else if hazardLines.contains(ObjectIdentifier(line)) {
                    renderer.strokeColor = .systemRed
                    renderer.lineWidth = 4
                    renderer.lineDashPattern = [8, 6]
                } else {
                    renderer.strokeColor = .tintColor
                    renderer.lineWidth = 4
                    renderer.lineCap = .round
                    renderer.lineJoin = .round
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case let waypoint as WaypointAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: WaypointView.reuseID, for: waypoint) as! WaypointView
                view.configure(waypoint, editing: parent.isEditing)
                return view
            case let sample as ConditionsAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: ConditionsView.reuseID, for: sample) as! ConditionsView
                view.configure(sample.sample)
                return view
            case let mark as SeamarkAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: HarbourView.reuseID, for: mark) as! HarbourView
                view.configure(mark.seamark)
                return view
            case is AnchorAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: BadgeView.reuseID, for: annotation) as! BadgeView
                view.configure(text: "⚓︎", fill: anchorAlarmShown ? .systemRed : .systemPurple, textColor: .white, size: 30)
                return view
            case is MOBAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: BadgeView.reuseID, for: annotation) as! BadgeView
                view.configure(text: "MOB", fill: .systemRed, textColor: .white, size: 40)
                return view
            case let leg as LegAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: LegLabelView.reuseID, for: leg) as! LegLabelView
                view.configure(leg.text)
                return view
            case is InspectAnnotation:
                return mapView.dequeueReusableAnnotationView(withIdentifier: InspectView.reuseID, for: annotation)
            case let wind as WindArrowAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: WindArrowView.reuseID, for: wind) as! WindArrowView
                view.configure(wind.arrow)
                return view
            case let vessel as VesselAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: VesselView.reuseID, for: vessel) as! VesselView
                view.configure(vessel.marker)
                return view
            default:
                return nil
            }
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard let waypoint = view.annotation as? WaypointAnnotation else { return }
            switch newState {
            case .ending, .canceling:
                view.dragState = .none
                parent.onMoveWaypoint(waypoint.id, waypoint.coordinate)
            default: break
            }
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if annotation is MKUserLocation { return }
            // A tap that drops a pin lands on the new pin too; pins have nothing to show, so don't select.
            mapView.deselectAnnotation(annotation, animated: false)
            if let mark = annotation as? SeamarkAnnotation, !parent.isEditing {
                parent.onInspect(mark.coordinate, mark.seamark)
            }
            if let vessel = annotation as? VesselAnnotation, !parent.isEditing {
                parent.onSelectVessel(vessel.marker.vessel)
            }
        }

        private var followedFirstFix = false

        /// A follow request made before the first GPS fix is lost; repeat it once the boat shows up.
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !followedFirstFix, userLocation.location != nil else { return }
            followedFirstFix = true
            guard currentTracking != .none, mapView.userTrackingMode == .none else { return }
            let mode: MKUserTrackingMode = currentTracking == .heading ? .followWithHeading : .follow
            mapView.setUserTrackingMode(mode, animated: true)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            let tracking: AppModel.UserTracking = switch mode {
            case .follow: .follow
            case .followWithHeading: .heading
            default: .none
            }
            guard tracking != currentTracking else { return }
            // MapKit drops a follow request it can't honour yet (no fix); keep ours until the first fix.
            if tracking == .none && !followedFirstFix { return }
            currentTracking = tracking
            // Panning the map drops follow mode; mirror that back into the model.
            DispatchQueue.main.async { self.parent.onTrackingChange(tracking) }
        }

        private var lastCamera = AppModel.MapCamera()
        private var lastCameraUpdate = Date.distantPast

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            publishCamera(mapView, force: true)
            let region = mapView.region
            guard region.span.longitudeDelta > 0 else { return }
            let box = GeoBox(west: region.center.longitude - region.span.longitudeDelta / 2,
                             south: region.center.latitude - region.span.latitudeDelta / 2,
                             east: region.center.longitude + region.span.longitudeDelta / 2,
                             north: region.center.latitude + region.span.latitudeDelta / 2)
            // Layer fetches are model state; don't change it in the middle of a view update.
            DispatchQueue.main.async { self.parent.onRegionChange(box) }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            publishCamera(mapView, force: false)
        }

        /// Scale bar and grid labels; throttled while the map moves so SwiftUI isn't re-rendered every frame.
        private func publishCamera(_ mapView: MKMapView, force: Bool) {
            guard force || Date().timeIntervalSince(lastCameraUpdate) > 0.12 else { return }
            lastCameraUpdate = Date()
            let bounds = mapView.bounds
            guard bounds.width > 0 else { return }
            var camera = AppModel.MapCamera()
            let left = mapView.convert(CGPoint(x: bounds.midX - 50, y: bounds.midY), toCoordinateFrom: mapView)
            let right = mapView.convert(CGPoint(x: bounds.midX + 50, y: bounds.midY), toCoordinateFrom: mapView)
            camera.metresPerPoint = Geo.distanceNM(left, right) * 1852 / 100

            // Harbours and anchorages only once zoomed in far enough to tell them apart.
            let showHarbours = camera.metresPerPoint < 30
            if showHarbours != harboursShown {
                harboursShown = showHarbours
                if showHarbours { mapView.addAnnotations(harbours) } else { mapView.removeAnnotations(harbours) }
            }

            if parent.showGrid {
                let region = mapView.region
                let pointsPerDegree = bounds.width / region.span.longitudeDelta
                let minutes = Graticule.step(pointsPerDegree: pointsPerDegree)
                let step = minutes / 60
                let west = region.center.longitude - region.span.longitudeDelta / 2
                let north = region.center.latitude + region.span.latitudeDelta / 2
                var lon = (west / step).rounded(.up) * step
                while lon < west + region.span.longitudeDelta {
                    let x = mapView.convert(CLLocationCoordinate2D(latitude: region.center.latitude, longitude: lon), toPointTo: mapView).x
                    camera.longitudeLabels.append(.init(position: x, text: Graticule.format(lon, positive: "E", negative: "W", step: minutes)))
                    lon += step
                }
                var lat = (north / step).rounded(.down) * step
                while lat > north - region.span.latitudeDelta {
                    let y = mapView.convert(CLLocationCoordinate2D(latitude: lat, longitude: region.center.longitude), toPointTo: mapView).y
                    camera.latitudeLabels.append(.init(position: y, text: Graticule.format(lat, positive: "N", negative: "S", step: minutes)))
                    lat -= step
                }
            }
            let scaleChanged = abs(camera.metresPerPoint - lastCamera.metresPerPoint) > lastCamera.metresPerPoint * 0.02
            guard scaleChanged || camera.longitudeLabels != lastCamera.longitudeLabels || camera.latitudeLabels != lastCamera.latitudeLabels else { return }
            lastCamera = camera
            parent.onCameraChange(camera)
        }
    }
}
