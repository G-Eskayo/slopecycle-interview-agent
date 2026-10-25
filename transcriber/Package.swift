// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "slope-transcribe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "slope-transcribe", targets: ["SlopeTranscribe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
    ],
    targets: [
        // Pure logic: token -> word -> speaker turn merging and the JSON shape. No FluidAudio.
        .target(name: "TranscriptMerge"),
        .executableTarget(
            name: "SlopeTranscribe",
            dependencies: [
                "TranscriptMerge",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(name: "TranscriptMergeTests", dependencies: ["TranscriptMerge"]),
    ]
)
