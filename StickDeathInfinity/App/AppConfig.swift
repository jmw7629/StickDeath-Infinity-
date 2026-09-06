// ═══════════════════════════════════════════════════════════════════
// AppConfig — Public, non-secret application configuration
// This file is source-controlled. It contains only public config
// and enum definitions. No API keys, OAuth secrets, signing
// identities, or admin allowlists are stored here.
// ═══════════════════════════════════════════════════════════════════

import Foundation

enum AppConfig {

    // MARK: - Supabase (public anon config)
    // These are the *public anon* URL and key for the Supabase project.
    // They are safe to ship in a client binary. Set via build settings
    // or environment at deploy time. Empty string = unavailable.
    static let supabaseURL: String = ""
    static let supabaseAnonKey: String = ""

    // MARK: - LiveKit (public room config)
    static let liveKitWSURL: String = ""
    static let liveKitURL: String = ""

    // MARK: - Backend (public Spatter backend endpoint)
    static let backendBaseURL: String = ""

    // MARK: - Subscription Tiers (public contract)
    enum SubscriptionTier: String, CaseIterable {
        case free = "free"
        case starter = "starter"
        case pro = "pro"
        case studio = "studio"

        var displayName: String {
            switch self {
            case .free: return "Free"
            case .starter: return "Starter"
            case .pro: return "Pro"
            case .studio: return "Studio"
            }
        }

        var monthlyPrice: Double {
            switch self {
            case .free: return 0
            case .starter: return 4.99
            case .pro: return 9.99
            case .studio: return 19.99
            }
        }
    }

    // MARK: - Call Rate Tiers (public contract)
    enum CallRateTier: String, CaseIterable {
        case standard = "standard"
        case premium = "premium"
        case vip = "vip"

        var perMinuteRate: Double {
            switch self {
            case .standard: return 0.0
            case .premium: return 0.05
            case .vip: return 0.15
            }
        }
    }
}
