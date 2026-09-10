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
        // (sdk/swift, ADR 0041). On `main` until a release tag carries it:
        // v0.16.0 has the root manifest but predates FountainKit, so
        // `from: "0.16.0"` would resolve to a package without it.
        .package(
            url: "https://github.com/managoat/fountain.git",
            branch: "main"
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
