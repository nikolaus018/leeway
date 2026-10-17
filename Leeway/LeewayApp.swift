import MapLibre
import SwiftUI

@main
struct LeewayApp: App {
    @State private var model = AppModel()

    init() {
        // Tiles the map has seen stay on the phone for weeks (they're also what works offline
        // outside downloaded regions), and every request identifies the app to the data server.
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["X-Leeway-Client": Seadata.clientHeader]
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(1 << 30) { _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
