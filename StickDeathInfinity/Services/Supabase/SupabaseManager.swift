// ═══════════════════════════════════════════════════════════════════
// SupabaseManager — Supabase client singleton
// Matches: src/lib/supabase.ts
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient?

    var isAvailable: Bool { client != nil }

    private init() {
        guard !AppConfig.supabaseURL.isEmpty,
              !AppConfig.supabaseAnonKey.isEmpty,
              let url = URL(string: AppConfig.supabaseURL) else {
            self.client = nil
            return
        }
        self.client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: AppConfig.supabaseAnonKey
        )
    }
}
