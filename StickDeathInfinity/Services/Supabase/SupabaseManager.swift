// ═══════════════════════════════════════════════════════════════════
// SupabaseManager — Supabase client singleton
// Matches: src/lib/supabase.ts
// No fake/placeholder URL/key fallback.
// Unavailable => client is nil, call sites handle gracefully.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient?

    var isConfigured: Bool { client != nil }

    private init() {
        guard AppConfig.isSupabaseConfigured,
              let url = URL(string: AppConfig.supabaseURL) else {
            client = nil
            return
        }
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: AppConfig.supabaseAnonKey
        )
    }
}
