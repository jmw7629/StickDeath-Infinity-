// SupabaseClient.swift
// Singleton Supabase connection — connects to your LIVE backend

import Foundation
import Supabase

enum AppConfig {
    // ── Your live Supabase project ──────────────────────
    static let supabaseURL = URL(string: "https://iohubnamsqnzyburydxr.supabase.co")!
    static let supabaseAnonKey = "sb_publishable_wYHTtPsLEEXP9tFuzoeRQw_j6UuoJWl"
    
    // ── Stripe (publishable key only — safe in client) ──
    static let stripePublishableKey = "pk_test_51SsnuxFLiSxiZ8KHvW6Rv8LOCjMUQ9eZdeGqFq8b8v4p2IpQcBWNX6Pz1uK7HGXVWoG6IIcXTlU4nIMaIBMzSPOt00gR6XxiKZ"
    
    // ── Edge Function URLs ──────────────────────────────
    static let edgeFunctionBase = "https://iohubnamsqnzyburydxr.supabase.co/functions/v1"
    static func edgeFunction(_ name: String) -> URL {
        URL(string: "\(edgeFunctionBase)/\(name)")!
    }
}

let supabase = SupabaseClient(
    supabaseURL: AppConfig.supabaseURL,
    supabaseKey: AppConfig.supabaseAnonKey
)
