// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FitheWake",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "FitheWakeCore", targets: ["FitheWakeCore"])],
    targets: [
        // Ships in the app: alarm lifecycle, Smart Wake engine, Bluetooth parsing.
        .target(name: "FitheWakeCore"),
        // Synthetic nights and the evaluation bench. Never linked into the app.
        .target(name: "NightLab", dependencies: ["FitheWakeCore"]),
        .executableTarget(name: "night-eval", dependencies: ["FitheWakeCore", "NightLab"]),
        .testTarget(name: "FitheWakeCoreTests", dependencies: ["FitheWakeCore", "NightLab"]),
    ]
)
