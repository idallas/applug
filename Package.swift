// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Applug",
    platforms: [.macOS(.v14)],
    products: [
        // Providers and consumers: what apps link.
        .library(name: "Applug", targets: ["Applug"]),
        // `applug list`, `watch`, `turn`, `press`, `demo`: for trying providers and consumers out.
        .executable(name: "applug", targets: ["ApplugCLI"]),
    ],
    targets: [
        .target(name: "Applug"),
        .executableTarget(name: "ApplugCLI", dependencies: ["Applug"]),
        .testTarget(name: "ApplugTests", dependencies: ["Applug"]),
    ]
)
