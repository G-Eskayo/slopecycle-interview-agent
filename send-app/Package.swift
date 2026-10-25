// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlopeCycleSend",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SlopeSendCore", targets: ["SlopeSendCore"]),
        .executable(name: "SlopeCycleSend", targets: ["SlopeCycleSend"]),
    ],
    targets: [
        // All pure logic: ids, meta.json, name check, outbox, Git Data API writer, retry state machine.
        .target(name: "SlopeSendCore"),
        // The SwiftUI menu-bar app (UI, Keychain, network monitor).
        .executableTarget(name: "SlopeCycleSend", dependencies: ["SlopeSendCore"]),
        .testTarget(name: "SlopeSendCoreTests", dependencies: ["SlopeSendCore"]),
    ]
)
