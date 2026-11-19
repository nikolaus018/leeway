import MapLibre
import SwiftUI

/// The whole Leeway app as one view, for the standalone app and the Hub.
public struct LeewayRootView: View {
    @State private var model: AppModel

    public init() {
        Self.configureMapLibre()
        _model = State(initialValue: AppModel())
    }

    public var body: some View {
        ContentView()
            .environment(model)
            .tint(Color(red: 0, green: 0.478, blue: 0.667))
    }

    private static var configured = false

    /// Tiles the map has seen stay on the phone for weeks (they're also what works offline
    /// outside downloaded regions), and every request identifies the app to the data server.
    private static func configureMapLibre() {
        guard !configured else { return }
        configured = true
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["X-Leeway-Client": Seadata.clientHeader]
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(1 << 30) { _ in }
    }
}
