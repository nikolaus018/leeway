import MapLibre
import SwiftUI

/// The chart: a MapLibre map drawing `ChartStyle`, with the live layers (route, track, ships, wind,
/// underway marks) fed into its GeoJSON sources and the waypoints as draggable pins.
struct ChartMapView: UIViewRepresentable {
    var style: ChartStyle
    var waypoints: [Waypoint]
    var path: [CLLocationCoordinate2D]
    var legHazards: [String?]
    var track: [CLLocationCoordinate2D]
    var samples: [PassageSample]
    var legLabels: [LegAnnotationData]
    var windArrows: [WindArrow]
    var vessels: [VesselMarker]
    var underway: UnderwayMapState
    var marks: [UserMark]
    var radar: RadarFrame?
    var measure: [CLLocationCoordinate2D]
    /// While measuring: the map's centre, where the next point would go.
    var measureCursor: CLLocationCoordinate2D?
    var measureAddRequest: Int
    var inspected: CLLocationCoordinate2D?
    var showGrid: Bool
    var isEditing: Bool
    var isMeasuring: Bool
    var tracking: AppModel.UserTracking
    var northRequest: Int
    var fitRouteRequest: Int
    var focus: AppModel.Focus?
    var onAddWaypoint: (CLLocationCoordinate2D) -> Void
    var onMoveWaypoint: (Waypoint.ID, CLLocationCoordinate2D) -> Void
    var onInspect: (ChartHit?) -> Void
    var onMeasure: (CLLocationCoordinate2D) -> Void
    var onRegionChange: (GeoBox) -> Void
    var onTrackingChange: (AppModel.UserTracking) -> Void
    var onCameraChange: (AppModel.MapCamera) -> Void

    static let home = CLLocationCoordinate2D(latitude: 45.2, longitude: 14.42)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero)
        let c = context.coordinator
        map.delegate = c
        map.showsUserLocation = true
        map.showsUserHeadingIndicator = true
        map.compassView.compassVisibility = .hidden
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        map.scaleBar.isHidden = true
        // No twisting by hand; heading-up and course-up tracking still turn the map.
        map.allowsRotating = false
        map.maximumZoomLevel = 18
        map.minimumZoomLevel = 1.5
        map.automaticallyAdjustsContentInset = false
        map.preferredFramesPerSecond = .maximum
        c.applyStyle(style, to: map)

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        let press = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.pressed(_:)))
        // Double-tap-and-drag zoom, reversed: dragging up zooms in. MapLibre's own is the long press
        // that starts with a tap and has no delay; replace it with one that goes the other way.
        let quickZoom = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.quickZoomed(_:)))
        quickZoom.numberOfTapsRequired = 1
        quickZoom.minimumPressDuration = 0
        quickZoom.delegate = c
        c.quickZoom = quickZoom
        for recognizer in map.gestureRecognizers ?? [] {
            if let double = recognizer as? UITapGestureRecognizer, double.numberOfTapsRequired == 2 {
                tap.require(toFail: double)
                quickZoom.require(toFail: double)
            }
            if let builtIn = recognizer as? UILongPressGestureRecognizer, builtIn.numberOfTapsRequired == 1,
               builtIn.minimumPressDuration == 0 {
                builtIn.isEnabled = false
            }
        }
        map.addGestureRecognizer(quickZoom)
        tap.delegate = c
        press.delegate = c
        map.addGestureRecognizer(tap)
        map.addGestureRecognizer(press)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.applyStyle(style, to: map)
        c.syncAll(on: map)
        c.syncWaypoints(waypoints, editing: isEditing, on: map)
        c.applyTracking(tracking, to: map)
        if c.lastNorthRequest != northRequest {
            c.lastNorthRequest = northRequest
            map.resetNorth()
        }
        if c.lastMeasureRequest != measureAddRequest {
            c.lastMeasureRequest = measureAddRequest
            onMeasure(map.centerCoordinate)
        }
        if c.lastFitRequest != fitRouteRequest {
            c.lastFitRequest = fitRouteRequest
            c.fitRoute(on: map)
        }
        if let focus, c.lastFocus != focus.id {
            c.lastFocus = focus.id
            map.setCenter(focus.coordinate, zoomLevel: max(map.zoomLevel, focus.zoom), animated: true)
        }
    }

    /// Kvarner, or `-debugCenter "lat,lon,spanDegrees"` in debug builds (simulator testing).
    fileprivate static var initialCamera: (CLLocationCoordinate2D, Double) {
        #if DEBUG
        if let spec = AppModel.debugArgument("debugCenter") {
            let v = spec.split(separator: ",").compactMap { Double($0) }
            if v.count == 3 {
                return (CLLocationCoordinate2D(latitude: v[0], longitude: v[1]), log2(360 / max(v[2], 0.001)) + 0.5)
            }
        }
        #endif
        if let saved = UserDefaults.standard.array(forKey: "lastCamera") as? [Double], saved.count == 3,
           saved[2] >= 3, abs(saved[0]) < 85, saved[0] != 0 || saved[1] != 0 {
            return (CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1]), saved[2])
        }
        return (home, 9.3)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: ChartMapView
        var lastFitRequest = 0
        var lastMeasureRequest = 0
        var lastNorthRequest = 0
        var lastFocus = 0
        private var loadedStyle: ChartStyle?
        private var styleReady = false
        private var currentTracking = AppModel.UserTracking.none

        init(_ parent: ChartMapView) { self.parent = parent }

        // MARK: Style

        func applyStyle(_ style: ChartStyle, to map: MLNMapView) {
            guard style != loadedStyle else { return }
            loadedStyle = style
            styleReady = false
            do {
                map.styleURL = try style.file()
            } catch {
                assertionFailure("chart style: \(error)")
            }
        }

        private var cameraPlaced = false

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // Loading a style resets the camera to the style's; place it once the first one is in.
            if !cameraPlaced {
                cameraPlaced = true
                let (center, zoom) = ChartMapView.initialCamera
                mapView.setCenter(center, zoomLevel: zoom, animated: false)
            }
            styleReady = true
            drawn = [:]
            shownRadar = nil
            syncAll(on: mapView)
        }

        /// Seamark symbols and markers are drawn the first time the map needs them.
        func mapView(_ mapView: MLNMapView, didFailToLoadImage imageName: String) -> UIImage? {
            SeamarkSymbols.image(named: imageName, palette: loadedStyle?.palette ?? .day)
        }

        // MARK: Live layers

        /// What each live source currently shows, so unchanged data isn't re-sent.
        private var drawn: [ChartStyle.Live: AnyHashable] = [:]

        func syncAll(on map: MLNMapView) {
            guard styleReady, let style = map.style else { return }
            let p = parent
            set(.route, key: RouteKey(path: p.path, hazards: p.legHazards.map { $0 != nil }), on: style) { routeFeatures(p.path, p.legHazards) }
            set(.track, key: p.track.count, on: style) {
                p.track.count >= 2 ? [polyline(p.track, [:])] : []
            }
            set(.samples, key: p.samples.map(\.time), on: style) {
                p.samples.map { point($0.coordinate, ["speed": $0.conditions.windSpeed, "from": $0.conditions.windFrom]) }
            }
            set(.legs, key: p.legLabels.map(\.text) + p.legLabels.map { "\($0.latitude)" }, on: style) {
                p.legLabels.map { point($0.coordinate, ["text": $0.text]) }
            }
            set(.wind, key: WindKey(arrows: p.windArrows), on: style) {
                p.windArrows.map { point($0.coordinate, ["speed": $0.speed, "from": $0.from]) }
            }
            set(.ais, key: VesselKey(markers: p.vessels), on: style) { aisFeatures(p.vessels) }
            set(.aisVectors, key: VesselKey(markers: p.vessels), on: style) { aisVectors(p.vessels) }
            set(.underway, key: UnderwayKey(state: p.underway), on: style) { underwayFeatures(p.underway) }
            set(.marks, key: p.marks, on: style) {
                p.marks.map { point($0.coordinate, ["name": $0.name, "icon": "mark-\($0.symbol)", "id": $0.id.uuidString]) }
            }
            let cursor = p.measureCursor.map { "\(Int($0.latitude * 1e5)),\(Int($0.longitude * 1e5))" } ?? ""
            set(.measure, key: p.measure.map { "\($0.latitude),\($0.longitude)" } + [cursor], on: style) {
                measureFeatures(p.measure, cursor: p.measureCursor)
            }
            set(.inspect, key: p.inspected.map { "\($0.latitude),\($0.longitude)" } ?? "", on: style) {
                p.inspected.map { [point($0, [:])] } ?? []
            }
            if !p.showGrid { set(.grid, key: "off", on: style) { [] } } else if let region = lastRegion { updateGrid(map, region) }
            syncRadar(p.radar, on: style)
        }

        // MARK: Radar

        private var shownRadar: RadarFrame?

        /// Rain radar is a raster source per frame: swapped when the frame changes.
        private func syncRadar(_ frame: RadarFrame?, on style: MLNStyle) {
            guard frame != shownRadar else { return }
            shownRadar = frame
            if let layer = style.layer(withIdentifier: "radar") { style.removeLayer(layer) }
            if let source = style.source(withIdentifier: "radar") { style.removeSource(source) }
            guard let frame else { return }
            let source = MLNRasterTileSource(identifier: "radar", tileURLTemplates: [frame.tiles],
                                             options: [.tileSize: 256, .maximumZoomLevel: 7, .attributionInfos: []])
            style.addSource(source)
            let layer = MLNRasterStyleLayer(identifier: "radar", source: source)
            layer.rasterOpacity = NSExpression(forConstantValue: 0.9)
            layer.rasterSaturation = NSExpression(forConstantValue: 0.3)
            layer.rasterContrast = NSExpression(forConstantValue: 0.25)
            layer.rasterFadeDuration = NSExpression(forConstantValue: 0)
            if let below = style.layer(withIdentifier: "live-track") {
                style.insertLayer(layer, below: below)
            } else {
                style.addLayer(layer)
            }
        }

        private func set(_ live: ChartStyle.Live, key: AnyHashable, on style: MLNStyle, features: () -> [MLNShape]) {
            guard drawn[live] != key else { return }
            drawn[live] = key
            guard let source = style.source(withIdentifier: "live-\(live.rawValue)") as? MLNShapeSource else { return }
            source.shape = MLNShapeCollectionFeature(shapes: features())
        }

        // MARK: Waypoints

        private var drawnWaypoints: [Waypoint] = []
        private var drawnEditing = false

        func syncWaypoints(_ waypoints: [Waypoint], editing: Bool, on map: MLNMapView) {
            guard waypoints != drawnWaypoints || editing != drawnEditing else { return }
            let structureChanged = waypoints.map(\.id) != drawnWaypoints.map(\.id) || editing != drawnEditing
            drawnWaypoints = waypoints
            drawnEditing = editing
            let current = (map.annotations ?? []).compactMap { $0 as? WaypointAnnotation }
            if structureChanged {
                map.removeAnnotations(current)
                map.addAnnotations(waypoints.enumerated().map { i, w in
                    WaypointAnnotation(id: w.id, coordinate: w.coordinate, index: i, count: waypoints.count)
                })
            } else {
                // Only positions changed (a drag): move the pins in place so the drag isn't interrupted.
                for annotation in current {
                    if let w = waypoints.first(where: { $0.id == annotation.id }) { annotation.coordinate = w.coordinate }
                }
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is MLNUserLocation {
                return (mapView.dequeueReusableAnnotationView(withIdentifier: BoatArrowView.reuseID) as? BoatArrowView)
                    ?? BoatArrowView(reuseIdentifier: BoatArrowView.reuseID)
            }
            guard let waypoint = annotation as? WaypointAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: WaypointPin.reuseID) as? WaypointPin)
                ?? WaypointPin(reuseIdentifier: WaypointPin.reuseID)
            view.configure(waypoint, editing: parent.isEditing)
            view.onDragEnded = { [weak self] coordinate in
                self?.parent.onMoveWaypoint(waypoint.id, coordinate)
            }
            return view
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { false }

        // MARK: Camera

        func applyTracking(_ tracking: AppModel.UserTracking, to map: MLNMapView) {
            guard tracking != currentTracking else { return }
            currentTracking = tracking
            let mode: MLNUserTrackingMode = switch tracking {
            case .none: .none
            case .follow: .follow
            case .heading: .followWithHeading
            case .course: .followWithCourse
            }
            if mode == .none { map.resetNorth() }
            map.setUserTrackingMode(mode, animated: true, completionHandler: nil)
        }

        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            let tracking: AppModel.UserTracking = switch mode {
            case .follow: .follow
            case .followWithHeading: .heading
            case .followWithCourse: .course
            default: .none
            }
            guard tracking != currentTracking else { return }
            currentTracking = tracking
            DispatchQueue.main.async { self.parent.onTrackingChange(tracking) }
        }

        func fitRoute(on map: MLNMapView) {
            let coordinates = parent.path.isEmpty ? parent.waypoints.map(\.coordinate) : parent.path
            guard coordinates.count >= 2 else { return }
            var bounds = MLNCoordinateBounds(sw: coordinates[0], ne: coordinates[0])
            for c in coordinates {
                bounds.sw.latitude = min(bounds.sw.latitude, c.latitude)
                bounds.sw.longitude = min(bounds.sw.longitude, c.longitude)
                bounds.ne.latitude = max(bounds.ne.latitude, c.latitude)
                bounds.ne.longitude = max(bounds.ne.longitude, c.longitude)
            }
            map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 130, left: 50, bottom: 260, right: 70),
                                           animated: true, completionHandler: nil)
        }

        private var lastRegion: MLNCoordinateBounds?
        private var lastCamera = AppModel.MapCamera()
        private var lastCameraUpdate = Date.distantPast

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            publishCamera(mapView, force: false)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            publishCamera(mapView, force: true)
            let b = mapView.visibleCoordinateBounds
            lastRegion = b
            if parent.showGrid { updateGrid(mapView, b) }
            // Remember where the chart was, once it has been placed (before that it sits at 0°, 0°).
            if cameraPlaced {
                UserDefaults.standard.set([mapView.centerCoordinate.latitude, mapView.centerCoordinate.longitude, mapView.zoomLevel],
                                          forKey: "lastCamera")
            }
            let box = GeoBox(west: max(-180, b.sw.longitude), south: max(-85, b.sw.latitude),
                             east: min(180, b.ne.longitude), north: min(85, b.ne.latitude))
            guard box.width > 0, box.height > 0 else { return }
            // Layer fetches are model state; don't change it in the middle of a view update.
            DispatchQueue.main.async { self.parent.onRegionChange(box) }
        }

        /// Scale bar, grid labels and the map's heading; throttled while the map moves.
        private func publishCamera(_ map: MLNMapView, force: Bool) {
            guard force || Date().timeIntervalSince(lastCameraUpdate) > 0.12 else { return }
            lastCameraUpdate = Date()
            guard map.bounds.width > 0 else { return }
            var camera = AppModel.MapCamera()
            camera.metresPerPoint = map.metersPerPoint(atLatitude: map.centerCoordinate.latitude)
            camera.heading = map.direction
            camera.center = map.centerCoordinate
            camera.zoom = map.zoomLevel
            if parent.showGrid { camera.latitudeLabels = gridLabels.lat; camera.longitudeLabels = gridLabels.lon }
            let scaleChanged = abs(camera.metresPerPoint - lastCamera.metresPerPoint) > lastCamera.metresPerPoint * 0.02
            let headingChanged = abs(camera.heading - lastCamera.heading) > 1
            // The crosshair follows the map's centre while measuring.
            let centreMoved = parent.isMeasuring && (camera.center.latitude != lastCamera.center.latitude
                                                    || camera.center.longitude != lastCamera.center.longitude)
            guard force || scaleChanged || headingChanged || centreMoved || camera.latitudeLabels != lastCamera.latitudeLabels
                    || camera.longitudeLabels != lastCamera.longitudeLabels else { return }
            lastCamera = camera
            parent.onCameraChange(camera)
        }

        // MARK: Grid

        private var gridLabels: (lat: [AppModel.MapCamera.Label], lon: [AppModel.MapCamera.Label]) = ([], [])

        private func updateGrid(_ map: MLNMapView, _ b: MLNCoordinateBounds) {
            guard let style = map.style else { return }
            let span = b.ne.longitude - b.sw.longitude
            guard span > 0 else { return }
            let minutes = Graticule.step(pointsPerDegree: map.bounds.width / span)
            let step = minutes / 60
            var lines: [MLNShape] = []
            var lat: [AppModel.MapCamera.Label] = [], lon: [AppModel.MapCamera.Label] = []
            var x = (b.sw.longitude / step).rounded(.up) * step
            while x <= b.ne.longitude, lines.count < 80 {
                lines.append(polyline([CLLocationCoordinate2D(latitude: max(-85, b.sw.latitude - 1), longitude: x),
                                       CLLocationCoordinate2D(latitude: min(85, b.ne.latitude + 1), longitude: x)], [:]))
                let p = map.convert(CLLocationCoordinate2D(latitude: map.centerCoordinate.latitude, longitude: x), toPointTo: map)
                lon.append(.init(position: p.x, text: Graticule.format(x, positive: "E", negative: "W", step: minutes)))
                x += step
            }
            var y = (b.sw.latitude / step).rounded(.up) * step
            while y <= b.ne.latitude, lines.count < 160 {
                lines.append(polyline([CLLocationCoordinate2D(latitude: y, longitude: b.sw.longitude - 1),
                                       CLLocationCoordinate2D(latitude: y, longitude: b.ne.longitude + 1)], [:]))
                let p = map.convert(CLLocationCoordinate2D(latitude: y, longitude: map.centerCoordinate.longitude), toPointTo: map)
                lat.append(.init(position: p.y, text: Graticule.format(y, positive: "N", negative: "S", step: minutes)))
                y += step
            }
            gridLabels = (lat, lon)
            drawn[.grid] = nil
            set(.grid, key: "\(b.sw.latitude),\(b.sw.longitude),\(step)", on: style) { lines }
        }

        // MARK: Gestures

        /// A long press ends with the finger lifting, which the tap recogniser also sees.
        private var lastPress = Date.distantPast

        var quickZoom: UILongPressGestureRecognizer?
        private var quickZoomStart: (y: CGFloat, zoom: Double)?

        /// Points of finger travel per zoom level.
        private static let pointsPerZoomLevel: CGFloat = 75

        @objc func quickZoomed(_ gesture: UILongPressGestureRecognizer) {
            guard let map = gesture.view as? MLNMapView else { return }
            let y = gesture.location(in: map).y
            switch gesture.state {
            case .began:
                quickZoomStart = (y, map.zoomLevel)
            case .changed:
                guard let start = quickZoomStart else { return }
                let zoom = start.zoom - Double((y - start.y) / Self.pointsPerZoomLevel)
                map.setZoomLevel(min(max(zoom, map.minimumZoomLevel), map.maximumZoomLevel), animated: false)
            default:
                quickZoomStart = nil
            }
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MLNMapView, Date.now.timeIntervalSince(lastPress) > 0.5 else { return }
            let point = gesture.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            if parent.isEditing {
                parent.onAddWaypoint(coordinate)
                return
            }
            // Measuring places points under the crosshair, not by tapping.
            if parent.isMeasuring { return }
            let h = hit(at: point, coordinate: coordinate, on: map)
            if h.mmsi != nil || h.markID != nil || h.seamark != nil {
                parent.onInspect(h)
            } else {
                parent.onInspect(nil)
            }
        }

        @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
            lastPress = .now
            guard gesture.state == .began, !parent.isEditing, let map = gesture.view as? MLNMapView else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let point = gesture.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            parent.onInspect(hit(at: point, coordinate: coordinate, on: map))
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Only touches on the map itself: not the controls and cards drawn over it.
            guard let map = g.view, let touched = touch.view, touched.isDescendant(of: map) else { return false }
            // Let pins handle their own taps and drags.
            var view = touch.view
            while let v = view {
                if v is MLNAnnotationView { return false }
                view = v.superview
            }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // The zoom drag must not also pan the map.
            g !== quickZoom && other !== quickZoom
        }

        /// What's under a tap: a ship, a charted object, a zone, and the charted depth.
        private func hit(at point: CGPoint, coordinate: CLLocationCoordinate2D, on map: MLNMapView) -> ChartHit {
            var hit = ChartHit(coordinate: coordinate)
            let reach = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let layerIDs = Set(map.style?.layers.map(\.identifier) ?? [])
            func layers(_ suffixes: [String]) -> Set<String> {
                layerIDs.filter { id in suffixes.contains { id.hasSuffix($0) } }
            }
            // Closest feature to the finger first.
            func nearest(_ features: [MLNFeature]) -> MLNFeature? {
                features.min { a, b in
                    let pa = map.convert(a.coordinate, toPointTo: map), pb = map.convert(b.coordinate, toPointTo: map)
                    return hypot(pa.x - point.x, pa.y - point.y) < hypot(pb.x - point.x, pb.y - point.y)
                }
            }
            if let ship = nearest(map.visibleFeatures(in: reach, styleLayerIdentifiers: ["live-ais"])),
               let mmsi = (ship.attribute(forKey: "mmsi") as? NSNumber)?.intValue {
                hit.mmsi = mmsi
                return hit
            }
            if let mark = nearest(map.visibleFeatures(in: reach, styleLayerIdentifiers: ["live-marks"])),
               let id = (mark.attribute(forKey: "id") as? String).flatMap(UUID.init) {
                hit.markID = id
                return hit
            }
            let seamarkLayers = layers(["-seamark", "-flare"])
            if let feature = nearest(map.visibleFeatures(in: reach, styleLayerIdentifiers: seamarkLayers)) {
                hit.seamark = Seamark(feature: feature)
            }
            let here = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
            for feature in map.visibleFeatures(in: here, styleLayerIdentifiers: layers(["-area-fill", "-area-line", "-area-separation", "-area-cable"])) {
                if let kind = feature.attribute(forKey: "kind") as? String {
                    hit.zones.append(ChartHit.Zone(kind: kind, name: feature.attribute(forKey: "n") as? String,
                                                   detail: feature.attribute(forKey: "res") as? String ?? feature.attribute(forKey: "c") as? String))
                }
            }
            // Depth band where no pack grid knows better.
            let depthLayers = layers(["-area"]).filter { $0.hasPrefix("pack-") || $0.hasPrefix("bathy") }
            if let band = map.visibleFeatures(at: point, styleLayerIdentifiers: depthLayers).first,
               let min = (band.attribute(forKey: "min") as? NSNumber)?.doubleValue,
               let max = (band.attribute(forKey: "max") as? NSNumber)?.doubleValue {
                hit.depthBand = min...max
            }
            return hit
        }
    }
}

/// What the user tapped on the chart.
struct ChartHit: Equatable {
    struct Zone: Equatable, Hashable {
        var kind: String
        var name: String?
        var detail: String?
    }
    var coordinate: CLLocationCoordinate2D
    var seamark: Seamark?
    var mmsi: Int?
    var markID: UUID?
    var zones: [Zone] = []
    var depthBand: ClosedRange<Double>?

    static func == (a: ChartHit, b: ChartHit) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
            && a.seamark == b.seamark && a.mmsi == b.mmsi && a.markID == b.markID && a.zones == b.zones && a.depthBand == b.depthBand
    }
}

extension Seamark {
    /// A seamark from a vector chart feature (the pack's `seamark` layer).
    init?(feature: MLNFeature) {
        guard let type = feature.attribute(forKey: "t") as? String else { return nil }
        func text(_ key: String) -> String? { feature.attribute(forKey: key) as? String }
        self.init(type: type, name: text("n"), latitude: feature.coordinate.latitude, longitude: feature.coordinate.longitude,
                  category: text("c"), colour: text("col"), light: text("l"), depth: text("d"), waterLevel: text("wl"))
    }
}

// MARK: - Features

private func point(_ c: CLLocationCoordinate2D, _ attributes: [String: Any]) -> MLNPointFeature {
    let f = MLNPointFeature()
    f.coordinate = c
    f.attributes = attributes
    return f
}

private func polyline(_ coordinates: [CLLocationCoordinate2D], _ attributes: [String: Any]) -> MLNPolylineFeature {
    var coordinates = coordinates
    let f = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
    f.attributes = attributes
    return f
}

private func polygon(_ ring: [CLLocationCoordinate2D], _ attributes: [String: Any]) -> MLNPolygonFeature {
    var ring = ring
    let f = MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count))
    f.attributes = attributes
    return f
}

private func routeFeatures(_ path: [CLLocationCoordinate2D], _ hazards: [String?]) -> [MLNShape] {
    guard path.count >= 2 else { return [] }
    if hazards.contains(where: { $0 != nil }), hazards.count == path.count - 1 {
        // Manual route with problems: leg by leg so the bad ones stand out.
        return zip(path, path.dropFirst()).enumerated().map { i, pair in polyline([pair.0, pair.1], ["hazard": hazards[i] != nil]) }
    }
    return [polyline(path, ["hazard": false])]
}

private func aisFeatures(_ vessels: [VesselMarker]) -> [MLNShape] {
    vessels.map { m in
        let v = m.vessel
        let moving = v.isUnderway && v.course != nil
        return point(v.coordinate, [
            "mmsi": v.mmsi, "name": v.displayName, "colour": m.colour, "danger": m.danger,
            "moving": moving, "course": moving ? v.course ?? 0 : 0,
        ])
    }
}

/// Where each moving ship will be in six minutes, as on a plotter's AIS overlay.
private func aisVectors(_ vessels: [VesselMarker]) -> [MLNShape] {
    vessels.compactMap { m in
        let v = m.vessel
        guard v.isUnderway, let sog = v.sog, sog > 1, let course = v.cog ?? v.heading else { return nil }
        let ahead = Geo.destination(from: v.coordinate, bearing: course, distanceNM: sog / 10)
        return polyline([v.coordinate, ahead], ["danger": m.danger, "colour": m.colour])
    }
}

private func underwayFeatures(_ state: UnderwayMapState) -> [MLNShape] {
    var features: [MLNShape] = []
    func line(_ points: [CLLocationCoordinate2D], _ style: String) {
        if points.count >= 2 { features.append(polyline(points, ["style": style, "alarm": state.anchorAlarm])) }
    }
    if state.ahead.count >= 2, !state.activeLeg.isEmpty { line(state.ahead.map(\.coordinate), "ahead") }
    if state.activeLeg.count == 2 { line(state.activeLeg.map(\.coordinate), "activeLeg") }
    if let boat = state.boat {
        if let next = state.next { line([boat.coordinate, next.coordinate], "bearing") }
        if let mob = state.mob { line([boat.coordinate, mob.coordinate], "mob") }
        // Where the boat will be in 6 minutes on its current course and speed.
        if let cog = state.cog, let sog = state.sog, sog > 0.3 {
            line([boat.coordinate, Geo.destination(from: boat.coordinate, bearing: cog, distanceNM: sog / 10)], "cog")
        }
    }
    if let anchor = state.anchor {
        let ring = (0...64).map { Geo.destination(from: anchor.coordinate, bearing: Double($0) * 360 / 64, distanceNM: state.anchorRadius / 1852) }
        features.append(polygon(ring, ["alarm": state.anchorAlarm]))
        line(ring, "circle")
        line(state.swing.map(\.coordinate), "swing")
        features.append(point(anchor.coordinate, ["icon": state.anchorAlarm ? "anchor-alarm" : "anchor-mark"]))
    }
    if let mob = state.mob { features.append(point(mob.coordinate, ["icon": "mob-mark"])) }
    return features
}

/// The measured path: a solid line, a dot at each point, a distance on every leg, and a dashed
/// leg from the last point to the crosshair.
private func measureFeatures(_ points: [CLLocationCoordinate2D], cursor: CLLocationCoordinate2D?) -> [MLNShape] {
    func label(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> MLNShape {
        point(Geo.interpolate(a, b, fraction: 0.5), ["text": formatDistance(Geo.distanceNM(a, b))])
    }
    var features: [MLNShape] = []
    if points.count >= 2 {
        features.append(polyline(points, ["live": false]))
        for (a, b) in zip(points, points.dropFirst()) { features.append(label(a, b)) }
    }
    if let last = points.last, let cursor, Geo.distanceNM(last, cursor) > 0.001 {
        features.append(polyline([last, cursor], ["live": true]))
        features.append(label(last, cursor))
    }
    for p in points { features.append(point(p, ["vertex": true])) }
    return features
}

func formatDistance(_ nm: Double) -> String {
    nm < 0.3 ? "\(Int((nm * 1852).rounded())) m" : String(format: "%.2f NM", nm)
}

// MARK: - Keys for change detection

private struct RouteKey: Hashable {
    var path: [Double]
    var hazards: [Bool]
    init(path: [CLLocationCoordinate2D], hazards: [Bool]) {
        self.path = path.flatMap { [$0.latitude, $0.longitude] }
        self.hazards = hazards
    }
}

private struct WindKey: Hashable {
    var values: [Double]
    init(arrows: [WindArrow]) { values = arrows.flatMap { [$0.latitude, $0.longitude, $0.speed, $0.from] } }
}

private struct VesselKey: Hashable {
    var values: [String]
    init(markers: [VesselMarker]) {
        values = markers.map { "\($0.vessel.mmsi):\($0.vessel.lat):\($0.vessel.lon):\($0.vessel.cog ?? -1):\($0.danger)" }
    }
}

private struct UnderwayKey: Hashable {
    var text: String
    init(state: UnderwayMapState) { text = String(describing: state) }
}

// MARK: - Views

nonisolated final class WaypointAnnotation: MLNPointAnnotation, @unchecked Sendable {
    let id: Waypoint.ID
    let index: Int
    let count: Int

    init(id: Waypoint.ID, coordinate: CLLocationCoordinate2D, index: Int, count: Int) {
        self.id = id
        self.index = index
        self.count = count
        super.init()
        self.coordinate = coordinate
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A round waypoint marker: a boat at the start, a flag at the finish, the number in between.
final class WaypointPin: MLNAnnotationView {
    static let reuseID = "waypoint"
    var onDragEnded: ((CLLocationCoordinate2D) -> Void)?
    private let disc = UIView()
    private let label = UILabel()
    private let icon = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        disc.frame = bounds
        disc.layer.cornerRadius = 15
        disc.layer.borderWidth = 2.5
        disc.layer.borderColor = UIColor.white.cgColor
        disc.layer.shadowColor = UIColor.black.cgColor
        disc.layer.shadowOpacity = 0.3
        disc.layer.shadowRadius = 2
        disc.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(disc)
        label.frame = bounds
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .white
        addSubview(label)
        icon.frame = bounds.insetBy(dx: 7, dy: 7)
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .white
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ waypoint: WaypointAnnotation, editing: Bool) {
        let isStart = waypoint.index == 0
        let isEnd = waypoint.index == waypoint.count - 1 && waypoint.count > 1
        disc.backgroundColor = isStart ? .systemGreen : isEnd ? .systemRed : .systemBlue
        label.text = isStart || isEnd ? nil : "\(waypoint.index + 1)"
        icon.image = isStart ? UIImage(systemName: "sailboat.fill") : isEnd ? UIImage(systemName: "flag.checkered") : nil
        isDraggable = editing
        transform = editing ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
    }

    override func setDragState(_ dragState: MLNAnnotationViewDragState, animated: Bool) {
        super.setDragState(dragState, animated: animated)
        switch dragState {
        case .starting:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            UIView.animate(withDuration: 0.15) { self.transform = CGAffineTransform(scaleX: 1.4, y: 1.4) }
        case .ending, .canceling:
            UIView.animate(withDuration: 0.15) { self.transform = CGAffineTransform(scaleX: 1.15, y: 1.15) }
            if let coordinate = annotation?.coordinate { onDragEnded?(coordinate) }
        default:
            break
        }
    }
}


/// The boat's own position: an arrow that points the way it is heading (course over ground when
/// moving, the compass when not), in place of the usual blue dot.
final class BoatArrowView: MLNUserLocationAnnotationView {
    static let reuseID = "boat"
    private let arrow = CAShapeLayer()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        // A pointed hull with a notch at the stern, tip up.
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 20, y: 3))
        path.addLine(to: CGPoint(x: 32, y: 35))
        path.addLine(to: CGPoint(x: 20, y: 28))
        path.addLine(to: CGPoint(x: 8, y: 35))
        path.close()
        arrow.path = path.cgPath
        arrow.fillColor = UIColor(red: 0.0, green: 0.64, blue: 0.85, alpha: 1).cgColor
        arrow.strokeColor = UIColor.white.cgColor
        arrow.lineWidth = 2.5
        arrow.lineJoin = .round
        arrow.shadowColor = UIColor.black.cgColor
        arrow.shadowOpacity = 0.45
        arrow.shadowRadius = 3
        arrow.shadowOffset = CGSize(width: 0, height: 1)
        arrow.frame = bounds
        layer.addSublayer(arrow)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update() {
        guard let mapView, let location = userLocation?.location else { return }
        let moving = location.speed > 0.5 && location.course >= 0
        let heading = moving ? location.course : (userLocation?.heading?.trueHeading ?? -1)
        guard heading >= 0 else {
            arrow.setAffineTransform(.identity)
            return
        }
        // Screen angle: heading relative to where the top of the map points.
        let angle = (heading - mapView.direction) * .pi / 180
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
    }
}
