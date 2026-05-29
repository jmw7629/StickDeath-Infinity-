// ═══════════════════════════════════════════════════════════════════
// ChallengeService — Animation challenges via Supabase
// Matches: src/services/ChallengeService.ts
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class ChallengeService {
    static let shared = ChallengeService()
    private let supabase = SupabaseManager.shared.client

    /// Fetch all active challenges
    func fetchChallenges() async throws -> [Challenge] {
        let challenges: [Challenge] = try await supabase
            .from("challenges")
            .select()
            .order("start_date", ascending: false)
            .execute()
            .value
        return challenges
    }

    /// Submit to a challenge
    func submitEntry(challengeID: Int, userID: String, projectID: String, mediaURL: String?) async throws {
        try await supabase
            .from("challenge_submissions")
            .insert([
                "challenge_id": "\(challengeID)",
                "user_id": userID,
                "project_id": projectID,
                "media_url": mediaURL ?? ""
            ])
            .execute()
    }

    /// Get submissions for a challenge
    func fetchSubmissions(challengeID: Int) async throws -> [ChallengeSubmission] {
        let submissions: [ChallengeSubmission] = try await supabase
            .from("challenge_submissions")
            .select("*, profiles(username, avatar_url)")
            .eq("challenge_id", value: challengeID)
            .order("created_at", ascending: false)
            .execute()
            .value
        return submissions
    }
}

struct ChallengeSubmission: Codable, Identifiable {
    let id: Int
    var challengeID: Int
    var userID: String
    var projectID: String?
    var mediaURL: String?
    var voteCount: Int?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case challengeID = "challenge_id"
        case userID = "user_id"
        case projectID = "project_id"
        case mediaURL = "media_url"
        case voteCount = "vote_count"
        case createdAt = "created_at"
    }
}
