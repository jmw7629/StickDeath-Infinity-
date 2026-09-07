import Foundation

/// Public build configuration only. Provider credentials belong on the backend.
struct AppConfig {
    /// Configure SPATTER_BACKEND_URL in the app's Info.plist/xcconfig.
    /// Read on each use; do not keep a mutable endpoint or cache a missing value.
    static var backendURL: URL? {
        backendURL(from: Bundle.main.infoDictionary ?? [:])
    }

    static func backendURL(from values: [String: Any]) -> URL? {
        guard let value = values["SPATTER_BACKEND_URL"] as? String else { return nil }
        return SpatterEndpoint.url(from: value)
    }

    /// Existing display rates; actual billing authorization remains server-side.
    enum CallRateTier: String, CaseIterable {
        case standard, creator, pro, studio

        var ratePerMinute: Double {
            switch self {
            case .standard: return 0.05
            case .creator: return 0.10
            case .pro: return 0.15
            case .studio: return 0.25
            }
        }

        var displayName: String { rawValue.capitalized }
    }
}
