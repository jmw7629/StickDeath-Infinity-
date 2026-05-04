// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StickDeathInfinity",
    platforms: [
        .iOS(.v17),          // iOS 17+ (works with Xcode 15+)
        .macOS(.v14),        // macOS Sonoma+
        .macCatalyst(.v17),  // Mac Catalyst 17+
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/stripe/stripe-ios.git", from: "23.0.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "8.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "StickDeathInfinity",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "StripePaymentSheet", package: "stripe-ios"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
            ],
            path: "Sources"
        )
    ]
)
