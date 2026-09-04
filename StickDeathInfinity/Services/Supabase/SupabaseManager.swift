// ═══════════════════════════════════════════════════════════════════
// SupabaseManager — Supabase client singleton
// Matches: src/lib/supabase.ts
//
// When AppConfig is unconfigured (empty URL/key), the client is
// initialised with a safe fallback so the app compiles and launches
// in offline mode. All Supabase calls fail gracefully with network
// errors, which the existing services already handle via try? / catch.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    /// Whether the real Supabase backend is reachable
    var isConfigured: Bool { AppConfig.isSupabaseConfigured }

    private init() {
        // Use a safe fallback URL when config is empty so the app
        // does not crash at launch. Supabase calls will fail
        // gracefully with network errors.
        let rawURL = AppConfig.supabaseURL
        let safeURL: URL
        if let url = URL(string: rawURL), !rawURL.isEmpty {
            safeURL = url
        } else {
            safeURL = URL(string: "https://localhost")!
        }

        let key = AppConfig.supabaseAnonKey.isEmpty ? "placeholder" : AppConfig.supabaseAnonKey

        client = SupabaseClient(
            supabaseURL: safeURL,
            supabaseKey: key
        )
    }
}
