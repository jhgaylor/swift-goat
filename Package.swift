// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "swift-goat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // The Fountain API client, usable on its own (no UI dependencies).
        .library(name: "FountainKit", targets: ["FountainKit"]),
        // App domain layer: session, settings, stores.
        .library(name: "GoatCore", targets: ["GoatCore"]),
        // The macOS app.
        .executable(name: "SwiftGoat", targets: ["SwiftGoat"]),
    ],
    targets: [
        .target(name: "FountainKit"),
        .target(name: "GoatCore", dependencies: ["FountainKit"]),
        .executableTarget(name: "SwiftGoat", dependencies: ["GoatCore", "FountainKit"]),
        .testTarget(
            name: "FountainKitTests",
            dependencies: ["FountainKit"],
            // Read from the source tree by the conformance harness, not bundled.
            exclude: [
                "Conformance/scenarios",
                "Conformance/verdicts.json",
                "Conformance/SUITE.md",
            ]
        ),
        .testTarget(name: "GoatCoreTests", dependencies: ["GoatCore"]),
    ]
)
