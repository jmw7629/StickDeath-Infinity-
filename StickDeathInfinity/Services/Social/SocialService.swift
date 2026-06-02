// ═══════════════════════════════════════════════════════════════════
// SocialService — Posts, follows, likes, comments
// Matches: src/services/SocialService.ts
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class SocialService {
    static let shared = SocialService()
    private let supabase = SupabaseManager.shared.client

    // MARK: - Posts
    func createPost(content: String, mediaURL: String?, projectID: String?) async throws -> Post {
        guard let userId = AuthService.shared.userId else { throw ServiceError.notAuthenticated }

        var data: [String: AnyJSON] = [
            "user_id": .string(userId),
            "content": .string(content),
        ]
        if let media = mediaURL { data["media_url"] = .string(media) }
        if let proj = projectID { data["project_id"] = .string(proj) }

        let result: Post = try await supabase.from("posts").insert(data).select().single().execute().value
        return result
    }

    func deletePost(postID: Int) async throws {
        try await supabase.from("posts").delete().eq("id", value: postID).execute()
    }

    // MARK: - Likes
    func likePost(postID: Int) async throws {
        guard let userId = AuthService.shared.userId else { return }
        try await supabase.from("likes").insert([
            "user_id": AnyJSON.string(userId),
            "post_id": .integer(postID),
        ]).execute()

        // Increment like count
        try await supabase.rpc("increment_likes", params: ["post_id_param": AnyJSON.integer(postID)]).execute()
    }

    func unlikePost(postID: Int) async throws {
        guard let userId = AuthService.shared.userId else { return }
        try await supabase.from("likes")
            .delete()
            .eq("user_id", value: userId)
            .eq("post_id", value: postID)
            .execute()
    }

    func isPostLiked(postID: Int) async -> Bool {
        guard let userId = AuthService.shared.userId else { return false }
        do {
            let result: [LikeRecord] = try await supabase.from("likes")
                .select()
                .eq("user_id", value: userId)
                .eq("post_id", value: postID)
                .execute()
                .value
            return !result.isEmpty
        } catch { return false }
    }

    // MARK: - Comments
    func addComment(postID: Int, content: String) async throws {
        guard let userId = AuthService.shared.userId else { return }
        try await supabase.from("comments").insert([
            "post_id": AnyJSON.integer(postID),
            "user_id": .string(userId),
            "content": .string(content),
        ]).execute()
    }

    func getComments(postID: Int) async throws -> [Comment] {
        try await supabase.from("comments")
            .select("*, users(username, avatar_url)")
            .eq("post_id", value: postID)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    // MARK: - Follows
    func followUser(targetID: String) async throws {
        guard let userId = AuthService.shared.userId else { return }
        try await supabase.from("follows").insert([
            "follower_id": AnyJSON.string(userId),
            "following_id": .string(targetID),
        ]).execute()
    }

    func unfollowUser(targetID: String) async throws {
        guard let userId = AuthService.shared.userId else { return }
        try await supabase.from("follows")
            .delete()
            .eq("follower_id", value: userId)
            .eq("following_id", value: targetID)
            .execute()
    }

    func isFollowing(targetID: String) async -> Bool {
        guard let userId = AuthService.shared.userId else { return false }
        do {
            let result: [FollowCheckRecord] = try await supabase.from("follows")
                .select("id")
                .eq("follower_id", value: userId)
                .eq("following_id", value: targetID)
                .execute()
                .value
            return !result.isEmpty
        } catch { return false }
    }

    enum ServiceError: Error {
        case notAuthenticated
    }
}

private struct LikeRecord: Codable { let user_id: String; let post_id: Int }
private struct FollowCheckRecord: Codable { let id: Int }
