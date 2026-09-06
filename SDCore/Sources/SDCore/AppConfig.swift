// ═══════════════════════════════════════════════════════════════════
// AppConfig — Public non-secret configuration for SDCore
// No API keys, OAuth secrets, signing identities, or provider secrets.
// ═══════════════════════════════════════════════════════════════════

import Foundation

public enum AppConfig {

    // MARK: - Subscription Tiers

    public enum SubscriptionTier: String, Codable, CaseIterable, Sendable {
        case free
        case pro
        case studio
        case enterprise
    }

    // MARK: - Call Rate Tiers

    public enum CallRateTier: String, Codable, CaseIterable, Sendable {
        case standard
        case premium
        case unlimited
    }

    // MARK: - Backend Configuration (public, non-secret)

    public static var supabaseURL: String {
        ProcessInfo.processInfo.environment["SD_SUPABASE_URL"]
            ?? "https://your-project.supabase.co"
    }

    public static var supabaseAnonKey: String {
        ProcessInfo.processInfo.environment["SD_SUPABASE_ANON_KEY"]
            ?? ""
    }

    // MARK: - LiveKit Configuration (public, non-secret)

    public static var liveKitWSURL: String {
        ProcessInfo.processInfo.environment["SD_LIVEKIT_WS_URL"]
            ?? "wss://your-livekit-instance.com"
    }

    public static var liveKitServerURL: String {
        ProcessInfo.processInfo.environment["SD_LIVEKIT_SERVER_URL"]
            ?? "https://your-livekit-instance.com"
    }

    // MARK: - AI Configuration (public model names only)

    public static var openAIModel: String {
        ProcessInfo.processInfo.environment["SD_OPENAI_MODEL"]
            ?? "gpt-4o"
    }

    // MARK: - Admin Emails (public allowlist, not secrets)

    public static var superuserEmails: [String] {
        let envEmails = ProcessInfo.processInfo.environment["SD_SUPERUSER_EMAILS"] ?? ""
        return envEmails
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}
