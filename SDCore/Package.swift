// swift-tools-version: 5.9
// SDCore — Shared production persistence model for StickDeath Infinity
// Platform-agnostic: uses Double for all spatial types (CGFloat-compatible on all platforms)

import PackageDescription

let package = Package(
    name: "SDCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SDCore", targets: ["SDCore"]),
    ],
    targets: [
        .target(
            name: "SDCore",
            path: "Sources/SDCore"
        ),
        .testTarget(
            name: "SDCoreTests",
            dependencies: ["SDCore"],
            path: "Tests/SDCoreTests"
        ),
    ]
)
