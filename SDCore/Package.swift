// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SDCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SDCore", targets: ["SDCore"]),
    ],
    targets: [
        .target(
            name: "SDCore"
        ),
        .testTarget(
            name: "SDCoreTests",
            dependencies: ["SDCore"]
        ),
    ]
)
