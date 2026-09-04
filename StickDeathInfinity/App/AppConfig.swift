// ═══════════════════════════════════════════════════════════════════
// AppConfig — Public client configuration (no secrets)
//
// This file is gitignored. It is NOT committed to source control.
// It provides the compile-time type definitions and safe defaults
// so the project compiles and the Studio works locally.
//
// Secrets (Supabase URL/key, OpenAI key, Gemini key, LiveKit URL,
// superuser emails) must be filled in per-developer and never
// committed. The app degrades gracefully when they are empty.
// ═══════════════════════════════════════════════════════════════════

import Foundation

enum AppConfig {

    // MARK: - Supabase (public anon key, safe for client)

    /// Supabase project URL — leave empty to run fully offline
    static let supabaseURL: String = ""

    /// Supabase anonymous (public) key — safe for client, NOT a secret
    static let supabaseAnonKey: String = ""

    // MARK: - AI Providers

    /// OpenAI API key — leave empty to disable cloud AI chat
    static let openAIAPIKey: String = ""

    /// OpenAI model identifier
    static let openAIModel: String = "gpt-4o"

    /// Google Gemini API key — leave empty to disable Gemini
    static let geminiAPIKey: String = ""

    // MARK: - LiveKit

    /// LiveKit WebSocket server URL
    static let liveKitWSURL: String = ""

    // MARK: - Access Control

    /// Email addresses that get superadmin access (lowercased)
    static let superuserEmails: [String] = []

    // MARK: - Helpers

    /// Whether Supabase is configured (non-empty URL + key)
    static var isSupabaseConfigured: Bool {
        !supabaseURL.isEmpty && !supabaseAnonKey.isEmpty
    }

    /// Whether LiveKit is configured
    static var isLiveKitConfigured: Bool {
        !liveKitWSURL.isEmpty
    }

    // MARK: - Call Rate Tiers (R3 Billing)

    enum CallRateTier: String, CaseIterable, Identifiable {
        case standard = "standard"
        case creator  = "creator"
        case pro      = "pro"
        case studio   = "studio"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .standard: return "Standard"
            case .creator:  return "Creator"
            case .pro:      return "Pro"
            case .studio:   return "Studio"
            }
        }

        var ratePerMinute: Double {
            switch self {
            case .standard: return 0.05
            case .creator:  return 0.10
            case .pro:      return 0.15
            case .studio:   return 0.25
            }
        }
    }

    // MARK: - Subscription Tiers

    enum SubscriptionTier: String, CaseIterable, Identifiable, Comparable {
        case free    = "free"
        case creator = "creator"
        case pro     = "pro"
        case studio  = "studio"

        var id: String { rawValue }

        /// Numeric price for comparison
        var price: Double {
            switch self {
            case .free:    return 0.0
            case .creator: return 4.99
            case .pro:     return 9.99
            case .studio:  return 19.99
            }
        }

        var maxProjects: Int {
            switch self {
            case .free:    return 5
            case .creator: return 25
            case .pro:     return -1  // unlimited
            case .studio:  return -1  // unlimited
            }
        }

        var maxAIQueries: Int {
            switch self {
            case .free:    return 0
            case .creator: return 5
            case .pro:     return 50
            case .studio:  return -1  // unlimited
            }
        }

        static func < (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool {
            let order: [SubscriptionTier] = [.free, .creator, .pro, .studio]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }
}
