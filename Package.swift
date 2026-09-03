// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "swift-goat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // App domain layer: session, settings, stores.
        .library(name: "GoatCore", targets: ["GoatCore"]),
        // The macOS app.
        .executable(name: "SwiftGoat", targets: ["SwiftGoat"]),
    ],
    dependencies: [
        // FountainKit, the typed Fountain client, lives in the Fountain repo
        // (sdk/swift) as of BinaryBourbon/fountain#1457. Pinned to that
        // branch until it merges; then this becomes `branch: "main"`, and a
        // version once a plain vX.Y.Z tag carries the root manifest.
        .package(
            url: "https://github.com/BinaryBourbon/fountain.git",
            branch: "sdk/swift-typed-client"
        )
    ],
    targets: [
        .target(
            name: "GoatCore",
            dependencies: [.product(name: "FountainKit", package: "fountain")]
        ),
        .executableTarget(
            name: "SwiftGoat",
            dependencies: [
                "GoatCore",
                .product(name: "FountainKit", package: "fountain"),
            ]
        ),
        .testTarget(name: "GoatCoreTests", dependencies: ["GoatCore"]),
    ]
)
