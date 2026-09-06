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
        let urlString = AppConfig.supabaseURL
        let key = AppConfig.supabaseAnonKey
        if !urlString.isEmpty, !key.isEmpty, let url = URL(string: urlString) {
            client = SupabaseClient(supabaseURL: url, supabaseKey: key)
        } else {
            client = SupabaseClient(
                supabaseURL: URL(string: "https://placeholder.supabase.co")!,
                supabaseKey: "placeholder-key"
            )
        }
    }
}
