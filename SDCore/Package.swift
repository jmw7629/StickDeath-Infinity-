// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SDCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
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
