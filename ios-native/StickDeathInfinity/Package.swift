// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StickDeathInfinity",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),       // Mac Catalyst / native macOS
        .macCatalyst(.v16),  // Mac Catalyst support
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
