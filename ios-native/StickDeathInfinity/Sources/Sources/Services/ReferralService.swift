// ReferralService.swift
// Referral code generation, redemption, sharing, and stats
// Tables: referral_codes (user_id, code, created_at), referrals (referrer_id, referred_id, redeemed_at, pro_granted)

import Foundation
import UIKit
import Supabase

@MainActor
class ReferralService: ObservableObject {
    static let shared = ReferralService()

    @Published var referralCode: String?
    @Published var stats = ReferralStats()
    @Published var referredUsers: [ReferredUser] = []
    @Published var isLoading = false

    private init() {}

    // MARK: - Models

    struct ReferralStats {
        var totalInvited: Int = 0
        var totalRedeemed: Int = 0
    }

    struct ReferredUser: Identifiable {
        let id: String
        let displayName: String   // anonymized
        let redeemedAt: String
    }

    // Codable structs for Supabase
    private struct ReferralCodeRow: Codable {
        let user_id: String
        let code: String
        let created_at: String?
    }

    private struct ReferralRow: Codable {
        let id: Int?
        let referrer_id: String
        let referred_id: String
        let redeemed_at: String?
        let pro_granted: Bool?
    }

    private struct ReferralInsert: Encodable {
        let referrer_id: String
        let referred_id: String
        let redeemed_at: String
        let pro_granted: Bool
    }

    // MARK: - Generate Referral Code

    /// Fetches the user's existing referral code or creates a new one
    func fetchOrCreateCode() async throws -> String {
        guard let userId = AuthManager.shared.session?.user.id else {
            throw AppError.notAuthenticated
        }

        // Check if code already exists
        let existing: [ReferralCodeRow] = try await supabase
            .from("referral_codes")
            .select()
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value

        if let row = existing.first {
            referralCode = row.code
            return row.code
        }

        // Generate a unique 8-char alphanumeric code
        let code = generateUniqueCode()

        struct CodeInsert: Encodable {
            let user_id: String
            let code: String
            let created_at: String
        }

        try await supabase
            .from("referral_codes")
            .insert(CodeInsert(
                user_id: userId.uuidString,
                code: code,
                created_at: ISO8601DateFormatter().string(from: Date())
            ))
            .execute()

        referralCode = code
        return code
    }

    private func generateUniqueCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  // no ambiguous 0/O, 1/I/L
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    // MARK: - Redeem Referral Code

    /// Redeem a referral code — grants 1 month Pro to both referrer and redeemer
    func redeemCode(_ code: String) async throws {
        guard let userId = AuthManager.shared.session?.user.id else {
            throw AppError.notAuthenticated
        }

        // Look up referrer by code
        let codeRows: [ReferralCodeRow] = try await supabase
            .from("referral_codes")
            .select()
            .eq("code", value: code.uppercased())
            .execute()
            .value

        guard let codeRow = codeRows.first else {
            throw AppError.serverError("Invalid referral code")
        }

        // Can't refer yourself
        guard codeRow.user_id != userId.uuidString else {
            throw AppError.serverError("You can't use your own referral code")
        }

        // Check if already redeemed by this user
        let existingReferrals: [ReferralRow] = try await supabase
            .from("referrals")
            .select()
            .eq("referred_id", value: userId.uuidString)
            .execute()
            .value

        guard existingReferrals.isEmpty else {
            throw AppError.serverError("You've already redeemed a referral code")
        }

        // Create referral record
        try await supabase
            .from("referrals")
            .insert(ReferralInsert(
                referrer_id: codeRow.user_id,
                referred_id: userId.uuidString,
                redeemed_at: ISO8601DateFormatter().string(from: Date()),
                pro_granted: true
            ))
            .execute()

        // Grant 1 month Pro to both users (via edge function for secure billing logic)
        try await grantReferralPro(userId: codeRow.user_id)  // referrer
        try await grantReferralPro(userId: userId.uuidString) // redeemer
    }

    private func grantReferralPro(userId: String) async throws {
        guard let accessToken = AuthManager.shared.session?.accessToken else { return }

        var request = URLRequest(url: AppConfig.edgeFunction("grant-referral-pro"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct GrantRequest: Encodable { let user_id: String }
        request.httpBody = try JSONEncoder().encode(GrantRequest(user_id: userId))

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AppError.serverError("Failed to grant referral reward")
        }
    }

    // MARK: - Share Referral Link

    /// Present the system share sheet with the referral link
    func shareReferralLink(code: String) {
        let link = "https://stickdeath.app/invite/\(code)"
        let message = "Join me on StickDeath Infinity! Use my code \(code) and we both get 1 month of Pro free 🎬🔥\n\(link)"

        let activityVC = UIActivityViewController(
            activityItems: [message],
            applicationActivities: nil
        )

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

        // iPad popover support
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = rootVC.view
            popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        rootVC.present(activityVC, animated: true)
    }

    // MARK: - Fetch Stats

    func fetchStats() async {
        guard let userId = AuthManager.shared.session?.user.id else { return }
        isLoading = true

        do {
            // Total invited (referrals where this user is the referrer)
            let referrals: [ReferralRow] = try await supabase
                .from("referrals")
                .select()
                .eq("referrer_id", value: userId.uuidString)
                .execute()
                .value

            stats.totalInvited = referrals.count
            stats.totalRedeemed = referrals.filter { $0.pro_granted == true }.count

            // Build anonymized referred user list
            referredUsers = referrals.enumerated().map { index, row in
                ReferredUser(
                    id: row.referred_id,
                    displayName: "Friend #\(index + 1)",
                    redeemedAt: row.redeemed_at ?? ""
                )
            }
        } catch {
            print("⚠️ Failed to fetch referral stats: \(error.localizedDescription)")
        }

        isLoading = false
    }
}
