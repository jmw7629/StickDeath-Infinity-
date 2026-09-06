// ═══════════════════════════════════════════════════════════════════
// AppConfig — Public-only app configuration
// No secrets, no provider keys, no admin allowlists.
// Missing Supabase/LiveKit config produces truthful nil/unavailable state.
// ═══════════════════════════════════════════════════════════════════

import Foundation

enum AppConfig {
    // MARK: - Public model name (no transport credentials)
    static let openAIModel: String = "gpt-4o"

    // MARK: - Supabase (public anon config — backend auth required for transport)
    static let supabaseURL: String = ""
    static let supabaseAnonKey: String = ""

    // MARK: - LiveKit
    static let liveKitWSURL: String = ""

    // MARK: - Subscription tiers
    enum SubscriptionTier: String, CaseIterable {
        case free, starter, pro, studio
    }

    // MARK: - Call rate tiers
    enum CallRateTier: String, CaseIterable {
        case standard, premium, unlimited
    }
}
