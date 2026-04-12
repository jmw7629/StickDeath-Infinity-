// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StickDeathInfinity",
    platforms: [
        .iOS(.v18),          // Tab type requires iOS 18+
        .macOS(.v14),        // macOS Sonoma+
        .macCatalyst(.v18),  // Mac Catalyst with iOS 18 features
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/stripe/stripe-ios.git", from: "23.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "StickDeathInfinity",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "StripePaymentSheet", package: "stripe-ios"),
            ],
            path: "Sources"
        )
    ]
)
