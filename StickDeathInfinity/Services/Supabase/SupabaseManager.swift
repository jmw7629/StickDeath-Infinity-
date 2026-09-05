// ═══════════════════════════════════════════════════════════════════
// SupabaseManager — Supabase client singleton
// Matches: src/lib/supabase.ts
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        guard let url = URL(string: AppConfig.supabaseURL) else {
            fatalError("[SupabaseManager] Invalid Supabase URL: \(AppConfig.supabaseURL)")
        }
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: AppConfig.supabaseAnonKey
        )
    }
}
