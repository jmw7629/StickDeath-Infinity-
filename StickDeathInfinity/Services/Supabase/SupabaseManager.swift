// ═══════════════════════════════════════════════════════════════════
// SupabaseManager — Supabase client singleton
// Matches: src/lib/supabase.ts
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class SupabaseManager {
    static let shared = SupabaseManager()
    /// One configured HTTP stack shared by SDK auth and scoped community requests.
    let requestSession: URLSession = .shared

    private var cachedConfiguration: AppConfig.SupabaseConfiguration?
    private var cachedClient: SupabaseClient?

    /// No SDK client (including its auth refresh machinery) is created without
    /// validated public configuration. Never substitute an invented endpoint.
    var client: SupabaseClient {
        get throws {
            guard let configuration = AppConfig.supabaseConfiguration else {
                cachedClient = nil
                cachedConfiguration = nil
                throw AppConfigurationError.supabaseUnavailable
            }
            if cachedConfiguration == configuration, let cachedClient { return cachedClient }
            let client = SupabaseClient(
                supabaseURL: configuration.url,
                supabaseKey: configuration.publishableKey,
                options: .init(global: .init(session: requestSession))
            )
            cachedClient = client
            cachedConfiguration = configuration
            return client
        }
    }

    private init() {}
}
