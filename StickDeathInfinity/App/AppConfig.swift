/// AppConfig — public, provider-neutral configuration boundary
/// Loaded from app configuration source (plist/UserDefaults). No API keys, no secrets.
/// Exposes only an optional backend URL for provider-neutral AI routing.

import Foundation

struct AppConfig {
    /// Optional provider-neutral backend URL for AI routing.
    /// When nil, AI chat functions must provide truthful unavailable/local-degradation behavior.
    static var backendURL: URL?

    /// Call rate tier for R3 billing (per-minute rates).
    enum CallRateTier: String, CaseIterable {
        case standard = "standard"
        case creator = "creator"
        case pro = "pro"
        case studio = "studio"

        var ratePerMinute: Double {
            switch self {
            case .standard: return 0.05
            case .creator: return 0.10
            case .pro: return 0.15
            case .studio: return 0.25
            }
        }
    }
}