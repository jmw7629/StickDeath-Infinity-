// swift-tools-version: 5.9
// Root Package — wires SDCore as a local package for Xcode/SPM.
// For Linux CI: use swift build/test --package-path SDCore

import PackageDescription

let package = Package(
    name: "StickDeathInfinity",
    platforms: [.iOS(.v17)],
    dependencies: [
        // SDCore — local package (Foundation-only, Linux-compatible)
        .package(path: "SDCore"),

        // Supabase — Auth, Database, Storage, Realtime, Edge Functions
        .package(url: "https://github.com/supabase-community/supabase-swift.git", from: "2.0.0"),

        // LiveKit — Real-time video/voice calls
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "StickDeathInfinity",
            dependencies: [
                "SDCore",
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            path: "StickDeathInfinity"
        )
    ]
)
