// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AudioPlayer",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "AudioPlayer",
            targets: ["AudioPlayer"]
        ),
    ],
    targets: [
        .target(
            name: "AudioPlayer"
        ),
        .testTarget(
            name: "AudioPlayerTests",
            dependencies: ["AudioPlayer"]
        ),
    ]
)
