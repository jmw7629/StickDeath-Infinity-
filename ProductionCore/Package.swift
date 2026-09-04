// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ProductionCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "ProductionCore", targets: ["ProductionCore"])
    ],
    targets: [
        .target(
            name: "ProductionCore",
            path: "Sources/ProductionCore"
        ),
        .testTarget(
            name: "ProductionCoreTests",
            dependencies: ["ProductionCore"],
            path: "Tests/ProductionCoreTests"
        )
    ]
)
