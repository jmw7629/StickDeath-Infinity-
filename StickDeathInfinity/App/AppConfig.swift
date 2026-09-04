// ═══════════════════════════════════════════════════════════════════
// AppConfig — Public/publishable endpoint and client configuration
//
// This file is committed to source control. It contains ONLY:
//   - Public Supabase URL and anon key (client-safe, not privileged)
//   - Public LiveKit WebSocket endpoint
//   - Subscription/call-rate tier enums used by the app
//
// Secrets, API keys, service-role tokens, signing identities, and
// privileged credentials must NEVER appear here or in any committed
// file. Admin/superadmin authorization is server-controlled.
// ═══════════════════════════════════════════════════════════════════

import Foundation

enum AppConfig {

    // MARK: - Supabase (public anon key, client-safe)

    static let supabaseURL = "https://placeholder.supabase.co"
    static let supabaseAnonKey = "placeholder-anon-key"

    // MARK: - LiveKit (public WebSocket endpoint)

    static let liveKitWSURL = "wss://placeholder.livekit.cloud"

    // MARK: - AI provider endpoints (empty — no client-side secrets)

    static let openAIAPIKey = ""
    static let openAIModel = "gpt-4o"

    static let geminiAPIKey = ""

    // MARK: - Subscription Tiers

    enum SubscriptionTier: String, CaseIterable, Codable {
        case free, creator, pro, studio
    }

    // MARK: - Call Rate Tiers (R3 billing)

    enum CallRateTier: String, CaseIterable, Codable {
        case standard, creator, pro, studio

        var ratePerMinute: Double {
            switch self {
            case .standard: return 0.05
            case .creator:  return 0.10
            case .pro:      return 0.15
            case .studio:   return 0.25
            }
        }
    }
}
