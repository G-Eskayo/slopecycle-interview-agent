// swift-tools-version: 6.0
import PackageDescription

// slope-wake: rings the processor's doorbell at login and whenever the Mac wakes from sleep (ADR 0005/0006).
let package = Package(
    name: "SlopeWake",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "slope-wake", targets: ["SlopeWake"])],
    targets: [
        .target(name: "WakeCore"),
        .executableTarget(name: "SlopeWake", dependencies: ["WakeCore"]),
        .testTarget(name: "WakeCoreTests", dependencies: ["WakeCore"]),
    ]
)
