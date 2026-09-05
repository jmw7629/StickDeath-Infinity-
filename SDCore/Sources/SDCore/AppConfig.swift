// ═══════════════════════════════════════════════════════════════════
// AppConfig — Shared configuration (no secrets in source)
// Loaded from Config.plist at runtime; empty defaults = unconfigured.
// ═══════════════════════════════════════════════════════════════════

import Foundation

public struct AppConfig {

    // MARK: - Subscription Tier

    public enum SubscriptionTier: String, CaseIterable, Codable {
        case free = "free"
        case starter = "starter"
        case pro = "pro"
        case studio = "studio"
    }

    // MARK: - Call Rate Tier

    public enum CallRateTier: String, CaseIterable, Codable {
        case standard = "standard"
        case premium = "premium"
        case unlimited = "unlimited"
    }

    // MARK: - Supabase

    public static let supabaseURL: String = {
        Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
    }()

    public static let supabaseAnonKey: String = {
        Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
    }()

    // MARK: - LiveKit

    public static let liveKitWSURL: String = {
        Bundle.main.object(forInfoDictionaryKey: "LIVEKIT_WS_URL") as? String ?? ""
    }()

    // MARK: - AI Provider Keys (read from Config.plist — NEVER hardcoded)

    public static let openAIAPIKey: String = {
        Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String ?? ""
    }()

    public static let openAIModel: String = {
        Bundle.main.object(forInfoDictionaryKey: "OPENAI_MODEL") as? String ?? "gpt-4o"
    }()

    public static let geminiAPIKey: String = {
        Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String ?? ""
    }()

    // MARK: - Owner / Admin

    public static let superuserEmails: [String] = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPERUSER_EMAILS") as? String else {
            return []
        }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }()
}
