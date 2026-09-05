import Foundation

/// App-wide public configuration.
///
/// All values here are non-secret public identifiers.
/// Supabase anon key is designed to be public (Row Level Security enforces access).
/// Never embed service-role keys, provider API secrets, OAuth client secrets,
/// signing identities, or privileged tokens here.

enum AppConfig {

    // MARK: - Supabase (public, non-secret)

    static let supabaseURL: String = {
        if let url = Bundle.main.infoDictionary?["SUPABASE_URL"] as? String,
           !url.isEmpty, !url.contains("YOUR_SUPABASE") {
            return url
        }
        // Fallback: production URL
        return "https://xyzcompany.supabase.co"
    }()

    static let supabaseAnonKey: String = {
        if let key = Bundle.main.infoDictionary?["SUPABASE_ANON_KEY"] as? String,
           !key.isEmpty, !key.contains("YOUR_SUPABASE") {
            return key
        }
        // Fallback: production anon key
        return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.placeholder"
    }()

    // MARK: - Spatter Backend (public endpoint)

    static let spatterBackendURL: String = {
        if let url = Bundle.main.infoDictionary?["SPATTER_BACKEND_URL"] as? String,
           !url.isEmpty {
            return url
        }
        // Empty = backend unavailable; local brain knowledge only
        return ""
    }()

    // MARK: - Superadmin emails (allowlist for admin features)

    static let superuserEmails: [String] = {
        if let emails = Bundle.main.infoDictionary?["SUPERUSER_EMAILS"] as? String,
           !emails.isEmpty {
            return emails.components(separatedBy: ",").map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        }
        return []
    }()

    // MARK: - Validation

    /// Returns true if the Supabase configuration is usable (non-placeholder values).
    static var isSupabaseConfigured: Bool {
        !supabaseURL.contains("YOUR_SUPABASE") &&
        !supabaseAnonKey.contains("YOUR_SUPABASE") &&
        URL(string: supabaseURL) != nil
    }

    /// Returns true if the Spatter backend is configured.
    static var isSpatterBackendConfigured: Bool {
        !spatterBackendURL.isEmpty && URL(string: spatterBackendURL) != nil
    }
}

// MARK: - Call Rate Tier (used by R3CallState)
extension AppConfig {
    enum CallRateTier: String, Codable {
        case standard, premium, unlimited
    }
}
