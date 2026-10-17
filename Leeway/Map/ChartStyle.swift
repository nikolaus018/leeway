import CoreLocation
import UIKit

/// Light conditions the chart is drawn for, as on a chartplotter: full colour by day, dimmed at
/// dusk, dark with warm text at night so it doesn't wreck night vision.
enum ChartPalette: String, CaseIterable, Identifiable, Codable {
    case day, dusk, night
    var id: Self { self }

    var label: String {
        switch self {
        case .day: "Day"
        case .dusk: "Dusk"
        case .night: "Night"
        }
    }
}

/// The chart as a MapLibre style: one look for the whole world. The base map (OpenMapTiles), the
/// worldwide depth from the data server and the offline chart packs share the same colours, so a
/// pack is just the sharper version of the same chart. Live data (route, track, AIS, wind…) goes
/// into GeoJSON sources declared here and filled by `ChartMapView`.
struct ChartStyle: Equatable {
    struct Pack: Equatable {
        var id: String
        var file: URL
        var west, south, east, north: Double
    }

    var palette: ChartPalette
    var base: MapBase
    var server: URL
    var packs: [Pack]
    var safetyDepth: Double
    var showSeamarks: Bool
    var showSoundings: Bool

    /// Live sources the map view fills at runtime.
    enum Live: String, CaseIterable {
        case grid, track, route, underway, samples, legs, wind, aisVectors, ais, marks, inspect, measure
    }

    /// Contours the packs and the worldwide depth carry; the safety contour is the first one at or
    /// below the safety depth, as on a plotter.
    static let packContours: [Double] = [1, 2, 3, 5, 10, 15, 20, 30, 50, 100]
    static let bathyContours: [Double] = [2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000]

    static func safetyContour(_ depth: Double, in contours: [Double]) -> Double {
        contours.first { $0 >= depth } ?? contours.last ?? depth
    }

    // MARK: Colours

    struct Colours {
        var land, wood, residential, coast, road, majorRoad, building, boundary: String
        /// Water by depth band: under the safety depth, then < 5, < 10, < 20, < 50, deeper.
        var shallow, band5, band10, band20, band50, deep: String
        var contour, safety, ink, waterInk, landInk, sounding, magenta, halo, sectorWhite: String
    }

    var colours: Colours {
        switch palette {
        case .day:
            Colours(land: "#F2E5BE", wood: "#D9DDB0", residential: "#E9DAB4", coast: "#7A6A44", road: "#E0D2AA",
                    majorRoad: "#D3BF8E", building: "#E3D3A9", boundary: "#9A8F7A",
                    shallow: "#80B2E2", band5: "#9CC5EC", band10: "#B4D4F1", band20: "#CEE4F7", band50: "#E4F0FA", deep: "#F6FAFE",
                    contour: "#7896BE", safety: "#1E468C", ink: "#1F2433", waterInk: "#1F5299", landInk: "#4D432E",
                    sounding: "#404D66", magenta: "#BF1A99", halo: "rgba(255,255,255,0.85)", sectorWhite: "#E8B400")
        case .dusk:
            Colours(land: "#C9BC97", wood: "#B6B78F", residential: "#C3B391", coast: "#5E5236", road: "#BAAE8B",
                    majorRoad: "#AE9D73", building: "#BCAD88", boundary: "#7C7362",
                    shallow: "#5E8CB8", band5: "#769FC6", band10: "#8AB0D0", band20: "#A0BFD8", band50: "#B4CCE0", deep: "#C4D5E5",
                    contour: "#5A7499", safety: "#14306A", ink: "#141A26", waterInk: "#143A73", landInk: "#3A3222",
                    sounding: "#2E384C", magenta: "#99137A", halo: "rgba(230,230,230,0.7)", sectorWhite: "#C29600")
        case .night:
            Colours(land: "#2C281F", wood: "#2A2B1F", residential: "#302B22", coast: "#7A705A", road: "#3B352A",
                    majorRoad: "#4A4232", building: "#363026", boundary: "#5A5244",
                    shallow: "#1E4880", band5: "#183C6C", band10: "#14325A", band20: "#10284A", band50: "#0D1F3A", deep: "#0A162C",
                    contour: "#4A6488", safety: "#8FAAD0", ink: "#E0C9A0", waterInk: "#8FAFD8", landInk: "#C9B48C",
                    sounding: "#8C9AB4", magenta: "#E070D4", halo: "rgba(0,0,0,0.65)", sectorWhite: "#C8A040")
        }
    }

    // MARK: Style document

    func json() -> [String: Any] {
        let c = colours
        var sources: [String: Any] = [
            "base": [
                "type": "vector",
                "tiles": [server.appending(path: "v1/tiles/base").absoluteString + "/{z}/{x}/{y}.pbf"],
                "maxzoom": 14,
                "attribution": "© OpenMapTiles © OpenStreetMap contributors",
            ],
            "bathy": [
                "type": "vector",
                "tiles": [server.appending(path: "v1/tiles/bathy").absoluteString + "/{z}/{x}/{y}.pbf"],
                "maxzoom": 12,
                "attribution": "Depth: GEBCO, EMODnet",
            ],
            "satellite": [
                "type": "raster",
                "tiles": [server.appending(path: "v1/tiles/satellite").absoluteString + "/{z}/{x}/{y}.jpg"],
                "tileSize": 256,
                "maxzoom": 14,
                "attribution": "Sentinel-2 cloudless 2016 by EOX",
            ],
            "openseamap": [
                "type": "raster",
                "tiles": [seamarkTemplate],
                "tileSize": 256,
                "minzoom": 9,
                "maxzoom": 18,
                "attribution": "© OpenSeaMap",
            ],
        ]
        for pack in packs {
            sources["chart-\(pack.id)"] = [
                "type": "vector",
                "url": "pmtiles://" + pack.file.absoluteString,
            ]
        }
        for live in Live.allCases {
            sources["live-\(live.rawValue)"] = ["type": "geojson", "data": ["type": "FeatureCollection", "features": []]]
        }

        var layers: [[String: Any]] = []
        let satellite = base == .satellite
        layers.append(["id": "background", "type": "background", "paint": ["background-color": satellite ? "#000000" : c.land]])
        layers.append(layer("satellite", "raster", source: "satellite", visible: satellite, paint: ["raster-opacity": 1.0]))

        // Base map fills.
        layers.append(layer("landcover-wood", "fill", source: "base", sourceLayer: "landcover", minzoom: 7, visible: !satellite,
                            filter: ["==", ["get", "class"], "wood"], paint: ["fill-color": c.wood, "fill-opacity": 0.5]))
        layers.append(layer("landuse-residential", "fill", source: "base", sourceLayer: "landuse", minzoom: 10, visible: !satellite,
                            filter: ["in", ["get", "class"], ["literal", ["residential", "suburb", "neighbourhood", "commercial", "industrial"]]],
                            paint: ["fill-color": c.residential, "fill-opacity": 0.7]))
        layers.append(layer("water", "fill", source: "base", sourceLayer: "water", visible: !satellite,
                            filter: ["!=", ["get", "brunnel"], "tunnel"], paint: ["fill-color": c.deep]))
        layers.append(layer("waterway", "line", source: "base", sourceLayer: "waterway", minzoom: 9, visible: !satellite,
                            paint: ["line-color": c.band20, "line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.5, 14, 2]]))

        // Worldwide depth, then each chart pack on top.
        layers += depthLayers(prefix: "bathy", source: "bathy", contours: Self.bathyContours, satellite: satellite)
        layers.append(layer("coast", "line", source: "base", sourceLayer: "water", minzoom: 4,
                            filter: ["==", ["get", "class"], "ocean"],
                            paint: ["line-color": satellite ? "rgba(255,255,255,0.5)" : c.coast,
                                    "line-width": ["interpolate", ["linear"], ["zoom"], 4, 0.4, 12, 1.0]]))
        for pack in packs {
            let source = "chart-\(pack.id)"
            layers += depthLayers(prefix: "pack-\(pack.id)", source: source, contours: Self.packContours, satellite: satellite)
            layers.append(layer("pack-\(pack.id)-area-fill", "fill", source: source, sourceLayer: "area", minzoom: 9,
                                filter: ["all", ["==", ["geometry-type"], "Polygon"],
                                         ["in", ["get", "kind"], ["literal", ["restricted", "tss_separation", "marine_farm"]]]],
                                paint: ["fill-color": c.magenta, "fill-opacity": 0.08]))
            layers.append(layer("pack-\(pack.id)-land", "fill", source: source, sourceLayer: "land", visible: !satellite,
                                paint: ["fill-color": c.land]))
            layers.append(layer("pack-\(pack.id)-coast", "line", source: source, sourceLayer: "land",
                                paint: ["line-color": satellite ? "rgba(255,255,255,0.5)" : c.coast,
                                        "line-width": ["interpolate", ["linear"], ["zoom"], 8, 0.5, 14, 1.2]]))
        }

        // Land detail over the chart's land.
        // A sea chart keeps the land quiet: major roads faintly, minor ones only close in.
        layers.append(layer("road-minor", "line", source: "base", sourceLayer: "transportation", minzoom: 13, visible: !satellite,
                            filter: ["in", ["get", "class"], ["literal", ["minor", "tertiary", "secondary"]]],
                            paint: ["line-color": c.road, "line-opacity": 0.6,
                                    "line-width": ["interpolate", ["linear"], ["zoom"], 13, 0.5, 16, 2.5]]))
        layers.append(layer("road-major", "line", source: "base", sourceLayer: "transportation", minzoom: 8, visible: !satellite,
                            filter: ["in", ["get", "class"], ["literal", ["motorway", "trunk", "primary"]]],
                            paint: ["line-color": c.majorRoad, "line-opacity": 0.55,
                                    "line-width": ["interpolate", ["linear"], ["zoom"], 8, 0.4, 16, 3]]))
        layers.append(layer("building", "fill", source: "base", sourceLayer: "building", minzoom: 14, visible: !satellite,
                            paint: ["fill-color": c.building, "fill-opacity": 0.8]))
        layers.append(layer("boundary", "line", source: "base", sourceLayer: "boundary", visible: !satellite,
                            filter: ["all", ["==", ["get", "admin_level"], 2], ["!=", ["get", "maritime"], 1]],
                            paint: ["line-color": c.boundary, "line-width": 0.8, "line-dasharray": [3, 2]]))

        // Seamarks outside the packs, from OpenSeaMap.
        layers.append(layer("openseamap", "raster", source: "openseamap", minzoom: 9, visible: showSeamarks, paint: ["raster-opacity": 1.0]))
        layers.append(layer("live-grid", "line", source: "live-grid",
                            paint: ["line-color": palette == .night ? "rgba(255,255,255,0.22)" : "rgba(40,50,70,0.3)", "line-width": 1]))

        // Pack chart detail: zones, bridges, light sectors, soundings, seamarks, names.
        for pack in packs {
            layers += packDetail(pack, colours: c)
        }

        // Names from the base map.
        layers.append(symbol("water-name", source: "base", sourceLayer: "water_name", minzoom: 3,
                             layout: ["text-field": ["coalesce", ["get", "name:latin"], ["get", "name"]],
                                      "text-font": ["Noto Sans Italic"],
                                      "text-size": ["interpolate", ["linear"], ["zoom"], 3, 11, 10, 14],
                                      "text-letter-spacing": 0.1, "text-max-width": 8],
                             paint: ["text-color": c.waterInk, "text-halo-color": c.halo, "text-halo-width": 1.2]))
        layers.append(symbol("place-island", source: "base", sourceLayer: "place", minzoom: 9,
                             filter: ["in", ["get", "class"], ["literal", ["island", "islet"]]],
                             layout: ["text-field": ["coalesce", ["get", "name:latin"], ["get", "name"]],
                                      "text-font": ["Noto Sans Italic"], "text-size": 12, "text-max-width": 8],
                             paint: ["text-color": c.landInk, "text-halo-color": c.halo, "text-halo-width": 1.2]))
        layers.append(symbol("place-village", source: "base", sourceLayer: "place", minzoom: 11,
                             filter: ["in", ["get", "class"], ["literal", ["village", "hamlet", "suburb"]]],
                             layout: ["text-field": ["coalesce", ["get", "name:latin"], ["get", "name"]],
                                      "text-font": ["Noto Sans Regular"], "text-size": 11.5, "text-max-width": 8],
                             paint: ["text-color": c.ink, "text-halo-color": c.halo, "text-halo-width": 1.2]))
        layers.append(symbol("place-town", source: "base", sourceLayer: "place", minzoom: 6,
                             filter: ["in", ["get", "class"], ["literal", ["town", "city"]]],
                             layout: ["text-field": ["coalesce", ["get", "name:latin"], ["get", "name"]],
                                      "text-font": ["Noto Sans Bold"],
                                      "text-size": ["interpolate", ["linear"], ["zoom"], 6, ["case", ["==", ["get", "class"], "city"], 12, 10.5], 12, 15],
                                      "text-max-width": 8, "symbol-sort-key": ["get", "rank"]],
                             paint: ["text-color": c.ink, "text-halo-color": c.halo, "text-halo-width": 1.4]))
        layers.append(symbol("place-country", source: "base", sourceLayer: "place", maxzoom: 7,
                             filter: ["==", ["get", "class"], "country"],
                             layout: ["text-field": ["coalesce", ["get", "name:en"], ["get", "name"]],
                                      "text-font": ["Noto Sans Bold"], "text-size": 12, "text-transform": "uppercase",
                                      "text-letter-spacing": 0.15, "text-max-width": 8],
                             paint: ["text-color": c.landInk, "text-halo-color": c.halo, "text-halo-width": 1.4]))

        layers += liveLayers(colours: c)

        return [
            "version": 8,
            "name": "Leeway \(palette.rawValue)",
            "glyphs": server.appending(path: "v1/fonts").absoluteString + "/{fontstack}/{range}.pbf",
            "sources": sources,
            "layers": layers,
        ]
    }

    /// Writes the style where MapLibre can load it, named by its content so an unchanged style
    /// isn't reloaded.
    func file() throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: json(), options: [.sortedKeys])
        let directory = URL.cachesDirectory.appending(path: "Styles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var hasher = Hasher()
        hasher.combine(data)
        let url = directory.appending(path: "chart-\(String(UInt(bitPattern: hasher.finalize()), radix: 36)).json")
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            // Keep the last few (palettes switch back and forth); offline packs keep their own copy.
            let old = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let sorted = old.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            for stale in sorted.dropFirst(8) { try? FileManager.default.removeItem(at: stale) }
        }
        return url
    }

    /// OpenSeaMap tiles through the data server, skipping the packs (they draw their own seamarks).
    private var seamarkTemplate: String {
        // `v` changes when the tiles' meaning changes (v2: empty tiles are transparent images).
        var template = server.appending(path: "v1/tiles/seamark").absoluteString + "/{z}/{x}/{y}.png?v=2"
        if !packs.isEmpty {
            template += "&skip=" + packs.map { String(format: "%.4f,%.4f,%.4f,%.4f", $0.west, $0.south, $0.east, $0.north) }
                .joined(separator: ";")
        }
        return template
    }

    // MARK: Layer helpers

    private func layer(_ id: String, _ type: String, source: String, sourceLayer: String? = nil, minzoom: Double? = nil,
                       maxzoom: Double? = nil, visible: Bool = true, filter: [Any]? = nil,
                       layout: [String: Any] = [:], paint: [String: Any] = [:]) -> [String: Any] {
        var l: [String: Any] = ["id": id, "type": type, "source": source, "paint": paint]
        var layout = layout
        layout["visibility"] = visible ? "visible" : "none"
        l["layout"] = layout
        if let sourceLayer { l["source-layer"] = sourceLayer }
        if let minzoom { l["minzoom"] = minzoom }
        if let maxzoom { l["maxzoom"] = maxzoom }
        if let filter { l["filter"] = filter }
        return l
    }

    private func symbol(_ id: String, source: String, sourceLayer: String? = nil, minzoom: Double? = nil, maxzoom: Double? = nil,
                        visible: Bool = true, filter: [Any]? = nil, layout: [String: Any], paint: [String: Any] = [:]) -> [String: Any] {
        layer(id, "symbol", source: source, sourceLayer: sourceLayer, minzoom: minzoom, maxzoom: maxzoom, visible: visible,
              filter: filter, layout: layout, paint: paint)
    }

    /// Depth areas coloured by band, contours, and the bold safety contour.
    private func depthLayers(prefix: String, source: String, contours: [Double], satellite: Bool) -> [[String: Any]] {
        let c = colours
        let fill: [Any] = ["case",
                           ["<", ["get", "min"], safetyDepth], c.shallow,
                           ["<", ["get", "min"], 5], c.band5,
                           ["<", ["get", "min"], 10], c.band10,
                           ["<", ["get", "min"], 20], c.band20,
                           ["<", ["get", "min"], 50], c.band50,
                           c.deep]
        // Over imagery only water shallower than the safety depth is tinted.
        let opacity: Any = satellite ? ["case", ["<", ["get", "min"], safetyDepth], 0.45, 0.0] as [Any] : 1.0
        let safety = Self.safetyContour(safetyDepth, in: contours)
        return [
            layer("\(prefix)-area", "fill", source: source, sourceLayer: "depare",
                  paint: ["fill-color": fill, "fill-opacity": opacity, "fill-antialias": false]),
            layer("\(prefix)-contour", "line", source: source, sourceLayer: "depcnt", minzoom: 6,
                  filter: ["all", ["!=", ["get", "depth"], safety],
                           ["any", [">=", ["zoom"], 10], [">=", ["get", "depth"], 10]]],
                  paint: ["line-color": c.contour, "line-opacity": satellite ? 0.6 : 0.8,
                          "line-width": ["interpolate", ["linear"], ["zoom"], 6, 0.3, 14, 0.9]]),
            layer("\(prefix)-safety", "line", source: source, sourceLayer: "depcnt", minzoom: 6,
                  filter: ["==", ["get", "depth"], safety],
                  paint: ["line-color": satellite ? "#FFFFFF" : c.safety,
                          "line-width": ["interpolate", ["linear"], ["zoom"], 6, 0.8, 14, 2.2]]),
        ]
    }

    private func packDetail(_ pack: Pack, colours c: Colours) -> [[String: Any]] {
        let source = "chart-\(pack.id)"
        let id = "pack-\(pack.id)"
        let lightColour: [Any] = ["match", ["get", "col"], "R", "#D81B2A", "G", "#0E9E4A", c.sectorWhite]
        let areaLabel: [Any] = ["match", ["get", "kind"],
                                "restricted", ["coalesce", ["get", "n"], "Restricted area"],
                                "anchorage", ["coalesce", ["get", "n"], "Anchorage"],
                                "cable", "Cable", "pipeline", "Pipeline", "marine_farm", "Fish farm",
                                "seabed", ["coalesce", ["get", "c"], ""], ""]
        var layers: [[String: Any]] = [
            // Dash patterns can't vary per feature: one layer per pattern.
            layer("\(id)-area-line", "line", source: source, sourceLayer: "area", minzoom: 10,
                  filter: ["in", ["get", "kind"], ["literal", ["restricted", "anchorage", "mooring", "tss_lane", "fairway", "marine_farm"]]],
                  paint: ["line-color": c.magenta, "line-opacity": 0.8, "line-width": 1.2, "line-dasharray": [3, 2]]),
            layer("\(id)-area-separation", "line", source: source, sourceLayer: "area", minzoom: 9,
                  filter: ["==", ["get", "kind"], "tss_separation"],
                  paint: ["line-color": c.magenta, "line-opacity": 0.8, "line-width": 2]),
            layer("\(id)-area-cable", "line", source: source, sourceLayer: "area", minzoom: 11,
                  filter: ["in", ["get", "kind"], ["literal", ["cable", "pipeline"]]],
                  paint: ["line-color": c.magenta, "line-opacity": 0.8, "line-width": 1.2, "line-dasharray": [1, 1.5]]),
            symbol("\(id)-area-label", source: source, sourceLayer: "area", minzoom: 12,
                   filter: ["all", ["!=", ["geometry-type"], "LineString"],
                            ["in", ["get", "kind"], ["literal", ["restricted", "anchorage", "seabed", "marine_farm"]]]],
                   layout: ["text-field": areaLabel, "text-font": ["Noto Sans Italic"], "text-size": 10.5, "text-max-width": 8],
                   paint: ["text-color": c.magenta, "text-halo-color": c.halo, "text-halo-width": 1]),
            symbol("\(id)-area-line-label", source: source, sourceLayer: "area", minzoom: 13,
                   filter: ["all", ["==", ["geometry-type"], "LineString"], ["in", ["get", "kind"], ["literal", ["cable", "pipeline"]]]],
                   layout: ["text-field": areaLabel, "text-font": ["Noto Sans Italic"], "text-size": 10, "symbol-placement": "line"],
                   paint: ["text-color": c.magenta, "text-halo-color": c.halo, "text-halo-width": 1]),
            layer("\(id)-bridge", "line", source: source, sourceLayer: "bridge", minzoom: 11,
                  paint: ["line-color": c.ink, "line-width": 3]),
            layer("\(id)-sector-arc", "line", source: source, sourceLayer: "lightsector", minzoom: 11, visible: showSeamarks,
                  filter: ["==", ["get", "part"], "arc"],
                  paint: ["line-color": lightColour, "line-width": 3, "line-opacity": 0.9]),
            layer("\(id)-sector-limit", "line", source: source, sourceLayer: "lightsector", minzoom: 12, visible: showSeamarks,
                  filter: ["==", ["get", "part"], "limit"],
                  paint: ["line-color": c.ink, "line-width": 0.7, "line-dasharray": [4, 3], "line-opacity": 0.7]),
            symbol("\(id)-soundings", source: source, sourceLayer: "soundg", minzoom: 11, visible: showSoundings,
                   layout: ["text-field": ["to-string", ["get", "depth"]],
                            "text-font": ["Noto Sans Italic"],
                            "text-size": ["interpolate", ["linear"], ["zoom"], 11, 9, 16, 12],
                            "text-padding": 4],
                   paint: ["text-color": c.sounding]),
            symbol("\(id)-names", source: source, sourceLayer: "names",
                   layout: ["text-field": ["get", "n"], "text-font": ["Noto Sans Italic"],
                            "text-size": ["match", ["get", "t"], "strait", 12, "bay", 11.5, 10.5],
                            "text-max-width": 7, "text-anchor": ["match", ["get", "t"], "cape", "left", "center"],
                            "text-offset": ["match", ["get", "t"], "cape", ["literal", [0.6, 0]], ["literal", [0, 0]]]],
                   paint: ["text-color": ["match", ["get", "t"], ["strait", "bay"], c.waterInk, c.landInk],
                           "text-halo-color": c.halo, "text-halo-width": 1.2]),
        ]
        // Lights: the flare, then the symbol, then the label.
        layers.append(symbol("\(id)-flare", source: source, sourceLayer: "seamark", visible: showSeamarks,
                             filter: ["has", "lc"],
                             layout: ["icon-image": ["concat", "flare-", ["get", "lc"]],
                                      "icon-size": ["case", ["==", ["get", "t"], "light_major"], 1.25, 1.0],
                                      "icon-anchor": "bottom-left", "icon-offset": ["literal", [-2, 2]],
                                      "icon-allow-overlap": true, "icon-ignore-placement": true]))
        layers.append(symbol("\(id)-seamark", source: source, sourceLayer: "seamark", visible: showSeamarks,
                             filter: ["has", "sym"],
                             layout: ["icon-image": ["get", "sym"],
                                      "icon-size": ["interpolate", ["linear"], ["zoom"], 10, 0.7, 14, 1.0],
                                      "icon-allow-overlap": true, "icon-ignore-placement": true,
                                      "symbol-sort-key": ["case", ["has", "l"], 2, 1]]))
        layers.append(symbol("\(id)-seamark-label", source: source, sourceLayer: "seamark", minzoom: 11, visible: showSeamarks,
                             filter: ["any", ["has", "ls"], ["all", ["has", "n"], ["!", ["in", ["get", "t"], ["literal", ["harbour", "small_craft_facility", "anchorage"]]]]],
                                      ["in", ["get", "t"], ["literal", ["harbour", "small_craft_facility", "anchorage"]]]],
                             layout: [
                                "text-field": ["step", ["zoom"],
                                               ["case", ["==", ["get", "t"], "light_major"], ["coalesce", ["get", "ls"], ""], ""],
                                               13, ["case",
                                                    ["in", ["get", "t"], ["literal", ["harbour", "small_craft_facility", "anchorage"]]], ["coalesce", ["get", "n"], ""],
                                                    ["coalesce", ["get", "ls"], ""]],
                                               15, ["case",
                                                    ["all", ["has", "l"], ["has", "n"]], ["concat", ["get", "l"], "\n", ["get", "n"]],
                                                    ["coalesce", ["get", "l"], ["get", "n"], ""]]],
                                "text-font": ["Noto Sans Bold"], "text-size": 10,
                                "text-anchor": "left", "text-offset": ["literal", [0.9, -0.3]], "text-justify": "left",
                                "text-optional": true],
                             paint: ["text-color": ["case", ["has", "l"], c.magenta,
                                                    ["in", ["get", "t"], ["literal", ["harbour", "small_craft_facility", "anchorage"]]], c.waterInk, c.ink],
                                     "text-halo-color": c.halo, "text-halo-width": 1.2]))
        return layers
    }

    /// Route, track, AIS, wind and the rest, drawn on top of the chart.
    private func liveLayers(colours c: Colours) -> [[String: Any]] {
        let route = palette == .night ? "#5AA9FF" : "#0A6FD6"
        return [
            layer("live-track", "line", source: "live-track",
                  layout: ["line-cap": "round", "line-join": "round"],
                  paint: ["line-color": "#F28C1E", "line-width": 3]),
            layer("live-route-casing", "line", source: "live-route",
                  layout: ["line-cap": "round", "line-join": "round"],
                  paint: ["line-color": palette == .night ? "#000000" : "#FFFFFF", "line-width": 7, "line-opacity": 0.7]),
            layer("live-route", "line", source: "live-route",
                  filter: ["!", ["get", "hazard"]],
                  layout: ["line-cap": "round", "line-join": "round"],
                  paint: ["line-color": route, "line-width": 4]),
            layer("live-route-hazard", "line", source: "live-route",
                  filter: ["get", "hazard"],
                  paint: ["line-color": "#E5322D", "line-width": 4, "line-dasharray": [2, 1.5]]),
            layer("live-underway-fill", "fill", source: "live-underway",
                  filter: ["==", ["geometry-type"], "Polygon"],
                  paint: ["fill-color": ["case", ["get", "alarm"], "#E5322D", "#8E44D9"], "fill-opacity": 0.1]),
            layer("live-underway", "line", source: "live-underway",
                  filter: ["in", ["get", "style"], ["literal", ["activeLeg", "ahead", "cog", "swing"]]],
                  layout: ["line-cap": "round"],
                  paint: ["line-color": ["match", ["get", "style"],
                                         "activeLeg", "#E0337A", "ahead", "rgba(224,51,122,0.6)",
                                         "cog", palette == .night ? "#FFFFFF" : "#000000", "rgba(142,68,217,0.7)"],
                          "line-width": ["match", ["get", "style"], "activeLeg", 6, "ahead", 3, "cog", 2.5, 1.5]]),
            layer("live-underway-dashed", "line", source: "live-underway",
                  filter: ["in", ["get", "style"], ["literal", ["bearing", "mob", "circle"]]],
                  paint: ["line-color": ["match", ["get", "style"], "bearing", "#E0337A", "mob", "#E5322D",
                                         ["case", ["get", "alarm"], "#E5322D", "#8E44D9"]],
                          "line-width": ["match", ["get", "style"], "bearing", 2, "mob", 3, 2],
                          "line-dasharray": [3, 2]]),
            symbol("live-underway-marks", source: "live-underway",
                   filter: ["==", ["geometry-type"], "Point"],
                   layout: ["icon-image": ["get", "icon"], "icon-allow-overlap": true, "icon-ignore-placement": true]),
            layer("live-ais-vectors", "line", source: "live-aisVectors",
                  paint: ["line-color": ["case", ["get", "danger"], "#E5322D", ["get", "colour"]], "line-width": 1.5,
                          "line-dasharray": [2, 1.5]]),
            symbol("live-samples", source: "live-samples", minzoom: 7,
                   layout: ["icon-image": "wind-arrow", "icon-rotate": ["+", ["get", "from"], 180],
                            "icon-rotation-alignment": "map", "icon-size": 0.8,
                            "text-field": ["concat", ["to-string", ["round", ["get", "speed"]]], " kn"],
                            "text-font": ["Noto Sans Bold"], "text-size": 11, "text-anchor": "left", "text-offset": ["literal", [1.1, 0]]],
                   paint: ["icon-color": windColour, "text-color": c.ink, "text-halo-color": c.halo, "text-halo-width": 1.5]),
            symbol("live-legs", source: "live-legs",
                   layout: ["text-field": ["get", "text"], "text-font": ["Noto Sans Bold"], "text-size": 11,
                            "symbol-placement": "point", "text-padding": 6],
                   paint: ["text-color": route, "text-halo-color": c.halo, "text-halo-width": 2]),
            symbol("live-wind", source: "live-wind",
                   layout: ["icon-image": "wind-arrow", "icon-rotate": ["+", ["get", "from"], 180],
                            "icon-rotation-alignment": "map", "icon-allow-overlap": true,
                            "text-field": ["to-string", ["round", ["get", "speed"]]], "text-font": ["Noto Sans Bold"],
                            "text-size": 11, "text-offset": ["literal", [0, 1.5]], "text-allow-overlap": true],
                   paint: ["icon-color": windColour, "text-color": c.ink, "text-halo-color": c.halo, "text-halo-width": 1.5]),
            symbol("live-ais", source: "live-ais",
                   layout: ["icon-image": ["case", ["get", "moving"], "vessel-moving", "vessel-stopped"],
                            "icon-rotate": ["get", "course"], "icon-rotation-alignment": "map",
                            "icon-allow-overlap": true, "icon-ignore-placement": true,
                            "symbol-sort-key": ["case", ["get", "danger"], 1, 0],
                            "text-field": ["step", ["zoom"], "", 12, ["get", "name"]], "text-font": ["Noto Sans Regular"],
                            "text-size": 10, "text-offset": ["literal", [0, 1.4]], "text-optional": true],
                   paint: ["icon-color": ["case", ["get", "danger"], "#E5322D", ["get", "colour"]],
                           "text-color": c.ink, "text-halo-color": c.halo, "text-halo-width": 1.2]),
            symbol("live-marks", source: "live-marks",
                   layout: ["icon-image": ["get", "icon"], "icon-allow-overlap": true,
                            "text-field": ["get", "name"], "text-font": ["Noto Sans Bold"], "text-size": 11,
                            "text-anchor": "top", "text-offset": ["literal", [0, 1.0]], "text-optional": true],
                   paint: ["text-color": c.ink, "text-halo-color": c.halo, "text-halo-width": 1.5]),
            layer("live-measure", "line", source: "live-measure",
                  filter: ["==", ["geometry-type"], "LineString"],
                  paint: ["line-color": "#E0337A", "line-width": 2.5, "line-dasharray": [2, 1.5]]),
            symbol("live-measure-label", source: "live-measure",
                   filter: ["==", ["geometry-type"], "Point"],
                   layout: ["icon-image": "measure-end", "icon-allow-overlap": true,
                            "text-field": ["get", "text"], "text-font": ["Noto Sans Bold"], "text-size": 13,
                            "text-anchor": "bottom", "text-offset": ["literal", [0, -1]], "text-allow-overlap": true],
                   paint: ["text-color": "#E0337A", "text-halo-color": c.halo, "text-halo-width": 2]),
            symbol("live-inspect", source: "live-inspect",
                   layout: ["icon-image": "inspect", "icon-allow-overlap": true, "icon-ignore-placement": true]),
        ]
    }

    /// Wind arrow colour by strength (Beaufort-ish).
    private var windColour: [Any] {
        ["step", ["get", "speed"], "#2BB3C0", 6, "#2DB34A", 12, "#E8C21A", 18, "#F08A1C", 24, "#E5322D", 30, "#9B3FD1"]
    }
}
