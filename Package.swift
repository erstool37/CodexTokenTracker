// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTokenTracker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CodexTokenTrackerCore",
            targets: ["CodexTokenTrackerCore"]
        ),
        .executable(
            name: "CodexTokenTracker",
            targets: ["CodexTokenTracker"]
        ),
        .executable(
            name: "CodexTokenTrackerChecks",
            targets: ["CodexTokenTrackerChecks"]
        )
    ],
    targets: [
        .target(
            name: "CodexTokenTrackerCore"
        ),
        .executableTarget(
            name: "CodexTokenTracker",
            dependencies: ["CodexTokenTrackerCore"]
        ),
        .executableTarget(
            name: "CodexTokenTrackerChecks",
            dependencies: ["CodexTokenTrackerCore"]
        )
    ]
)
