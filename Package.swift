// swift-tools-version: 5.9
// SPM Dependencies — use Xcode's "Add Package Dependency" or XcodeGen

import PackageDescription

let package = Package(
    name: "StickDeathInfinity",
    platforms: [.iOS(.v17)],
    dependencies: [
        // Supabase — Auth, Database, Storage, Realtime, Edge Functions
        .package(url: "https://github.com/supabase-community/supabase-swift.git", from: "2.0.0"),

        // Calls and messaging are retired scope: no LiveKit dependency.
        // iOS subscriptions use StoreKit 2 (built in); Stripe is server-side only.
    ]
)
