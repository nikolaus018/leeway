// swift-tools-version: 6.2
import PackageDescription

// Leeway as a reusable module: the standalone app and the Hub launcher both
// show `LeewayRootView()`. The bundled sea charts ship as package resources.
// What the host app must declare is listed in `hub-module.json`.
let package = Package(
    name: "LeewayKit",
    platforms: [.iOS(.v26)],
    products: [.library(name: "LeewayKit", targets: ["LeewayKit"])],
    dependencies: [
        .package(url: "https://github.com/maplibre/maplibre-gl-native-distribution", exact: "6.31.0"),
    ],
    targets: [
        .target(
            name: "LeewayKit",
            dependencies: [.product(name: "MapLibre", package: "maplibre-gl-native-distribution")],
            resources: [.copy("Charts")],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                // Routing and chart rendering crunch millions of grid cells; unoptimised builds are too slow to try out.
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
