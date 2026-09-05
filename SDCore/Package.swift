// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SDCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
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
