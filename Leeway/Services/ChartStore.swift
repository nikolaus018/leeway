import Foundation
import Observation

/// Chart packs from the data server: what it offers, and downloading them into
/// `ChartRegion.downloadDirectory`, where they replace the bundled pack with the same name.
@Observable
final class ChartStore {
    enum ListState: Equatable { case idle, loading, loaded, failed(String) }
    enum Status { case notInstalled, installed, updateAvailable }

    private(set) var available: [ChartPackInfo] = []
    private(set) var listState = ListState.idle
    private(set) var downloading: Set<String> = []
    private(set) var downloadError: String?
    /// Installed version per pack id.
    private(set) var installed: [String: String] {
        didSet { UserDefaults.standard.set(installed, forKey: "chartVersions") }
    }
    /// Called after a pack is installed or removed, to reload the charts.
    var onChange: (() -> Void)?

    init() {
        installed = UserDefaults.standard.dictionary(forKey: "chartVersions") as? [String: String] ?? [:]
    }

    func refresh(from server: Seadata) async {
        listState = .loading
        do {
            available = try await server.charts()
            listState = .loaded
        } catch {
            listState = .failed(error.localizedDescription)
        }
    }

    func status(of pack: ChartPackInfo) -> Status {
        guard let version = installed[pack.id] else { return .notInstalled }
        return version == pack.version ? .installed : .updateAvailable
    }

    func download(_ pack: ChartPackInfo, from server: Seadata) async {
        // File names come from the server: never let one point outside the charts folder.
        let files = pack.files.filter { !$0.contains("/") && !$0.hasPrefix(".") }
        guard !downloading.contains(pack.id), let json = files.first(where: { $0.hasSuffix(".json") }) else { return }
        downloading.insert(pack.id)
        downloadError = nil
        defer { downloading.remove(pack.id) }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "chart-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in files {
                let (file, response) = try await Seadata.session.download(from: server.chartFile(name, version: pack.version))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw Seadata.Failure.status(status, name) }
                try fm.moveItem(at: file, to: staging.appending(path: name))
            }
            // Make sure it loads before it replaces anything.
            let stem = String(json.dropLast(".json".count))
            let meta = staging.appending(path: json)
            let depth = staging.appending(path: "\(stem).depth")
            let land = staging.appending(path: "\(stem).land")
            try await Task.detached(priority: .userInitiated) {
                _ = try ChartRegion(metadata: meta, depth: depth, land: land)
            }.value
            let target = ChartRegion.downloadDirectory
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in files {
                let destination = target.appending(path: name)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: staging.appending(path: name), to: destination)
            }
            installed[pack.id] = pack.version
            onChange?()
        } catch {
            downloadError = "\(pack.name): \(error.localizedDescription)"
        }
    }

    /// Deletes a downloaded pack; the bundled one (if any) takes over again.
    func remove(_ pack: ChartPackInfo) {
        for name in pack.files where !name.contains("/") && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: ChartRegion.downloadDirectory.appending(path: name))
        }
        installed[pack.id] = nil
        onChange?()
    }
}
