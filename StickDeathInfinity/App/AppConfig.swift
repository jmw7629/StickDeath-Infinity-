import Foundation

/// Public build configuration only. Provider credentials belong on the backend.
struct AppConfig {
    /// Configure SPATTER_BACKEND_URL in the app's Info.plist/xcconfig.
    /// Read on each use; do not keep a mutable endpoint or cache a missing value.
    static var backendURL: URL? {
        backendURL(from: Bundle.main.infoDictionary ?? [:])
    }

    static func backendURL(from values: [String: Any]) -> URL? {
        guard let value = values["SPATTER_BACKEND_URL"] as? String else { return nil }
        return SpatterEndpoint.url(from: value)
    }

    struct SupabaseConfiguration: Equatable {
        let url: URL
        let publishableKey: String
    }

    static var supabaseConfiguration: SupabaseConfiguration? {
        supabaseConfiguration(from: Bundle.main.infoDictionary ?? [:])
    }

    /// Build configuration accepts public keys only. Decoding a legacy JWT here
    /// classifies its role; the server still verifies its signature and authority.
    static func supabaseConfiguration(from values: [String: Any]) -> SupabaseConfiguration? {
        guard let endpoint = configuredString(values["SUPABASE_URL"]),
              let url = serviceURL(endpoint, scheme: "https"),
              url.path.isEmpty || url.path == "/",
              let key = configuredString(values["SUPABASE_PUBLISHABLE_KEY"])
                ?? configuredString(values["SUPABASE_ANON_KEY"]),
              isPublicSupabaseKey(key) else { return nil }
        return SupabaseConfiguration(url: url, publishableKey: key)
    }

    static var liveKitWSURL: URL? {
        liveKitWSURL(from: Bundle.main.infoDictionary ?? [:])
    }

    static func liveKitWSURL(from values: [String: Any]) -> URL? {
        guard let value = configuredString(values["LIVEKIT_WS_URL"]) else { return nil }
        return serviceURL(value, scheme: "wss")
    }

    private static func configuredString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$("), !trimmed.contains("${") else { return nil }
        return trimmed
    }

    private static func serviceURL(_ value: String, scheme: String) -> URL? {
        guard value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == scheme,
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443 else { return nil }
        return components.url
    }

    private static func isPublicSupabaseKey(_ key: String) -> Bool {
        guard key.utf8.count <= 8192 else { return false }
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        if key.hasPrefix("sb_publishable_") {
            let suffix = key.dropFirst("sb_publishable_".count)
            return !suffix.isEmpty && suffix.unicodeScalars.allSatisfy(alphabet.contains)
        }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(alphabet.contains) }),
              let header = jwtObject(parts[0]), header["alg"] as? String == "HS256",
              let payload = jwtObject(parts[1]), payload["role"] as? String == "anon",
              payload["iss"] as? String == "supabase" else { return false }
        return true
    }

    private static func jwtObject(_ part: Substring) -> [String: Any]? {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    /// Ordering of existing StoreKit product families, not a price or entitlement policy.
    enum SubscriptionTier: String, CaseIterable {
        case free, creator, pro, studio

        var rank: Int {
            switch self {
            case .free: return 0
            case .creator: return 1
            case .pro: return 2
            case .studio: return 3
            }
        }
    }

    /// Existing display rates; actual billing authorization remains server-side.
    enum CallRateTier: String, CaseIterable {
        case standard, creator, pro, studio

        var ratePerMinute: Double {
            switch self {
            case .standard: return 0.05
            case .creator: return 0.10
            case .pro: return 0.15
            case .studio: return 0.25
            }
        }

        var displayName: String { rawValue.capitalized }
    }
}

enum AppConfigurationError: Error, LocalizedError {
    case supabaseUnavailable, liveKitUnavailable

    var errorDescription: String? {
        switch self {
        case .supabaseUnavailable:
            return "Cloud services are unavailable because their public configuration is missing or invalid."
        case .liveKitUnavailable:
            return "Calls are unavailable because their secure server configuration is missing or invalid."
        }
    }
}
