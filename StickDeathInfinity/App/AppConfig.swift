import Foundation

/// Public application configuration — no secrets, no provider API keys.
/// All values here are safe for source control.
struct AppConfig {

    // MARK: - Supabase (public anon endpoint + public anon key)

    static let supabaseURL = "https://YOUR_SUPABASE_URL.supabase.co"
    static let supabaseAnonKey = "YOUR_SUPABASE_ANON_KEY"

    // MARK: - AI Backend Endpoint (optional)

    /// Backend endpoint for AI features. If nil or empty, AI features
    /// report as unavailable. No direct provider API calls from client.
    static let spatterBackendURL: String? = nil

    // MARK: - Call Rate Tiers

    enum CallRateTier: String, CaseIterable {
        case standard, premium, vip
    }
}
