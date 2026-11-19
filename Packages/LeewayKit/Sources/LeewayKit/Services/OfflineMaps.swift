@preconcurrency import MapLibre
import Observation

/// Downloads the base map, worldwide depth and fonts for a chart pack's area, so the whole chart
/// works at sea without signal (the pack itself is already on the phone).
@Observable
final class OfflineMaps {
    struct Region: Identifiable, Equatable {
        var id: String
        var name: String
        /// 0…1 while downloading.
        var progress: Double
        var complete: Bool
        var bytes: UInt64
    }

    private(set) var regions: [String: Region] = [:]
    private(set) var error: String?
    @ObservationIgnored private var packs: [String: MLNOfflinePack] = [:]
    @ObservationIgnored private var observer: PacksObserver?
    /// Zoom levels saved: the packs carry the detail beyond this.
    static let maxZoom = 12.0

    init() {
        NotificationCenter.default.addObserver(forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let pack = note.object as? MLNOfflinePack
            MainActor.assumeIsolated { if let pack { self?.update(pack) } }
        }
        NotificationCenter.default.addObserver(forName: .MLNOfflinePackError, object: nil, queue: .main) { [weak self] note in
            let error = note.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
            MainActor.assumeIsolated { self?.error = error?.localizedDescription }
        }
        let observer = PacksObserver { [weak self] in self?.loadPacks() }
        MLNOfflineStorage.shared.addObserver(observer, forKeyPath: "packs", options: [.initial, .new], context: nil)
        self.observer = observer
    }

    private func loadPacks() {
        for pack in MLNOfflineStorage.shared.packs ?? [] {
            guard let id = Self.id(of: pack) else { continue }
            packs[id] = pack
            update(pack)
            if pack.state == .unknown { pack.requestProgress() }
        }
    }

    private static func id(of pack: MLNOfflinePack) -> String? {
        (try? JSONSerialization.jsonObject(with: pack.context) as? [String: String])?["id"]
    }

    private func update(_ pack: MLNOfflinePack) {
        guard let id = Self.id(of: pack) else { return }
        let p = pack.progress
        let name = (try? JSONSerialization.jsonObject(with: pack.context) as? [String: String])?["name"] ?? id
        regions[id] = Region(id: id, name: name,
                             progress: p.countOfResourcesExpected > 0 ? Double(p.countOfResourcesCompleted) / Double(p.countOfResourcesExpected) : 0,
                             complete: pack.state == .complete, bytes: p.countOfBytesCompleted)
    }

    /// Saves the chart's area for offline use with the current style.
    func download(_ region: ChartRegion, style: ChartStyle) {
        error = nil
        guard packs[region.id] == nil, let styleURL = try? style.file() else {
            packs[region.id]?.resume()
            return
        }
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: region.south, longitude: region.west),
                                         ne: CLLocationCoordinate2D(latitude: region.north, longitude: region.east))
        let area = MLNTilePyramidOfflineRegion(styleURL: styleURL, bounds: bounds, fromZoomLevel: 0, toZoomLevel: Self.maxZoom)
        let context = (try? JSONSerialization.data(withJSONObject: ["id": region.id, "name": region.name])) ?? Data()
        regions[region.id] = Region(id: region.id, name: region.name, progress: 0, complete: false, bytes: 0)
        MLNOfflineStorage.shared.addPack(for: area, withContext: context) { [weak self] pack, error in
            nonisolated(unsafe) let pack = pack
            MainActor.assumeIsolated {
                if let error { self?.error = error.localizedDescription; self?.regions[region.id] = nil; return }
                guard let pack else { return }
                self?.packs[region.id] = pack
                pack.resume()
            }
        }
    }

    func remove(_ id: String) {
        guard let pack = packs[id] else { return }
        MLNOfflineStorage.shared.removePack(pack) { _ in }
        packs[id] = nil
        regions[id] = nil
    }
}

/// KVO on the offline storage's pack list (it loads asynchronously at launch).
private final class PacksObserver: NSObject {
    let changed: @MainActor () -> Void
    init(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                           context: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.changed() }
    }
}
