// swift-tools-version: 5.9
// SPM Dependencies — use Xcode's "Add Package Dependency" or XcodeGen

import PackageDescription

let package = Package(
    name: "StickDeathInfinity",
    platforms: [.iOS(.v17)],
    dependencies: [
        // Supabase — Auth, Database, Storage, Realtime, Edge Functions
        .package(url: "https://github.com/supabase-community/supabase-swift.git", from: "2.0.0"),

        // LiveKit — Real-time video/voice calls
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.0.0"),

        // SDCore — Foundation-only production persistence model
        .package(path: "SDCore"),
    ]
)
