// ═══════════════════════════════════════════════════════════════════
// AppConfig — Non-secret app configuration
//
// This file contains ONLY non-secret infrastructure configuration.
// It should be committed to source control.
//
// REMOVED (must not exist in client):
//   - openAIAPIKey, geminiAPIKey, or any provider secret keys
//   - superuserEmails or any client-local admin authorization list
//   - Supabase service-role keys, YouTube OAuth secrets, signing secrets
//
// Production secrets live in the backend infrastructure, never in the client.
// ═══════════════════════════════════════════════════════════════════

import Foundation

enum AppConfig {
    // MARK: - Spatter AI Backend (public, configurable endpoint)
    // No provider secret keys. Cloud mode uses this backend URL.
    // If nil/empty, cloud AI is unavailable and embedded knowledge is used.
    static let spatterBackendEndpoint: String? = nil

    // MARK: - Supabase (public anon key — safe for client)
    static let supabaseURL = "https://iohubnamsqnzyburydxr.supabase.co"
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlvaHVibmFtc3FuenlidXJ5ZHhyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU5MzQ4MjcsImV4cCI6MjA5MTUxMDgyN30.5kwCtvB7SxInFZFISuDKgE9z6RvOFJPzi2VfefrL7m0"

    // MARK: - LiveKit
    static let liveKitWSURL = "wss://stickdeath-live.livekit.cloud"

    // MARK: - Subscription Tiers (StoreKit 2)
    enum SubscriptionTier: String, Codable, Comparable, CaseIterable {
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
            case .studio:  return -1 // unlimited
            }
        }

        var maxAIQueries: Int {
            switch self {
            case .free:    return 10
            case .creator: return 50
            case .pro:     return 200
            case .studio:  return -1 // unlimited
            }
        }

        static func < (lhs: AppConfig.SubscriptionTier, rhs: AppConfig.SubscriptionTier) -> Bool {
            let order: [SubscriptionTier] = [.free, .creator, .pro, .studio]
            return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
        }
    }

    // MARK: - Call Rate Tiers (R3 billing)
    enum CallRateTier: String, Codable, CaseIterable {
        case standard, creator, pro, studio

        var ratePerMinute: Double {
            switch self {
            case .standard: return 0.05
            case .creator:  return 0.10
            case .pro:      return 0.15
            case .studio:   return 0.25
            }
        }

        var displayName: String {
            switch self {
            case .standard: return "Standard"
            case .creator:  return "Creator"
            case .pro:      return "Pro"
            case .studio:   return "Studio"
            }
        }
    }
}
