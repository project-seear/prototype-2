// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Prototype2",
    platforms: [.macOS(.v14)],
    targets: [
        // Geometry, HRTF audio graph, noise generation, CSV logging.
        .target(name: "Core", path: "Sources/Core"),
        // The experiment application (needs a signed .app bundle for CoreMotion).
        .executableTarget(name: "Prototype2", dependencies: ["Core"], path: "Sources/Prototype2"),
        // Offline-rendered measurement of the audio + geometry. No hardware needed.
        .executableTarget(name: "diag", dependencies: ["Core"], path: "Sources/diag"),
        .executableTarget(name: "verify", dependencies: ["Core"], path: "Sources/verify"),
    ]
)
