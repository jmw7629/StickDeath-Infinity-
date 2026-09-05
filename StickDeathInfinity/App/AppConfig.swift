// ═══════════════════════════════════════════════════════════════════
// AppConfig — Public/publishable client configuration only
//
// Security: No provider secrets, no service-role keys, no client-local
// admin allowlists, no OAuth secrets, no signing credentials.
//
// Cloud endpoints are public/configurable. Absent values report
// truthful unavailable state — no invented production endpoints.
// ═══════════════════════════════════════════════════════════════════

import Foundation

enum AppConfig {

    // MARK: - Supabase (public anon key only)

    static let supabaseURL = ""
    static let supabaseAnonKey = ""

    // MARK: - AI provider endpoints (public, configurable)

    static let openAIAPIKey = ""
    static let openAIModel = "gpt-4o"

    static let geminiAPIKey = ""

    // MARK: - LiveKit (public WebSocket URL)

    static let liveKitWSURL = ""

    // MARK: - Spatter cloud endpoint (public, optional)

    static let spatterEndpoint: String? = nil

    // MARK: - Subscription Tiers

    enum SubscriptionTier: String, CaseIterable, Comparable {
        case free, creator, pro, studio

        var price: Double {
            switch self {
            case .free:    return 0
            case .creator: return 4.99
            case .pro:     return 9.99
            case .studio:  return 19.99
            }
        }

        var maxProjects: Int {
            switch self {
            case .free:    return 3
            case .creator: return 10
            case .pro:     return 50
            case .studio:  return -1
            }
        }

        var maxAIQueries: Int {
            switch self {
            case .free:    return 5
            case .creator: return 25
            case .pro:     return 100
            case .studio:  return -1
            }
        }

        static func < (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool {
            let order: [SubscriptionTier] = [.free, .creator, .pro, .studio]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    // MARK: - Call Rate Tiers

    enum CallRateTier: String, CaseIterable {
        case standard

        var ratePerMinute: Double {
            switch self {
            case .standard: return 0.05
            }
        }

        var displayName: String {
            switch self {
            case .standard: return "Standard"
            }
        }
    }
}
