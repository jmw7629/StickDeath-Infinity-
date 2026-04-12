// SocialAccountsManager.swift
// Manages StickDeath official channels + user's own connected social accounts

import Foundation

/// A social platform the user can publish to
struct SocialPlatform: Identifiable, Hashable {
    let id: String           // e.g. "tiktok", "youtube", "discord"
    let name: String
    let icon: String         // SF Symbol name
    let color: String        // hex color for branding
    let supportsVideo: Bool
    let supportsDirectUpload: Bool
}

/// A connected account (either official StickDeath or user's own)
struct ConnectedAccount: Identifiable, Codable {
    let id: String
    let platform: String     // matches SocialPlatform.id
    let handle: String       // @username or channel name
    let accountType: String  // "official" or "user"
    var isConnected: Bool
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: String?
}

@MainActor
class SocialAccountsManager: ObservableObject {
    static let shared = SocialAccountsManager()

    // ─── All supported platforms ───
    static let allPlatforms: [SocialPlatform] = [
        SocialPlatform(id: "tiktok",    name: "TikTok",    icon: "music.note",          color: "#00F2EA", supportsVideo: true, supportsDirectUpload: true),
        SocialPlatform(id: "youtube",   name: "YouTube",   icon: "play.rectangle.fill",  color: "#FF0000", supportsVideo: true, supportsDirectUpload: true),
        SocialPlatform(id: "discord",   name: "Discord",   icon: "bubble.left.fill",     color: "#5865F2", supportsVideo: true, supportsDirectUpload: true),
        SocialPlatform(id: "instagram", name: "Instagram", icon: "camera.fill",          color: "#E4405F", supportsVideo: true, supportsDirectUpload: true),
        SocialPlatform(id: "facebook",  name: "Facebook",  icon: "person.2.fill",        color: "#1877F2", supportsVideo: true, supportsDirectUpload: true),
        SocialPlatform(id: "twitter",   name: "X (Twitter)", icon: "at",                 color: "#1DA1F2", supportsVideo: true, supportsDirectUpload: true),
        SocialPlatform(id: "snapchat",  name: "Snapchat",  icon: "camera.viewfinder",    color: "#FFFC00", supportsVideo: true, supportsDirectUpload: false),
        SocialPlatform(id: "reddit",    name: "Reddit",    icon: "bubble.left.and.bubble.right", color: "#FF4500", supportsVideo: true, supportsDirectUpload: false),
        SocialPlatform(id: "vimeo",     name: "Vimeo",     icon: "play.circle.fill",     color: "#1AB7EA", supportsVideo: true, supportsDirectUpload: true),
        SocialPlatform(id: "twitch",    name: "Twitch",    icon: "tv.fill",              color: "#9146FF", supportsVideo: true, supportsDirectUpload: false),
    ]

    // ─── Official StickDeath channels (ALWAYS upload to these) ───
    static let officialChannels: [ConnectedAccount] = [
        ConnectedAccount(id: "sd_tiktok",  platform: "tiktok",  handle: "@stickdeathinfinity",     accountType: "official", isConnected: true),
        ConnectedAccount(id: "sd_youtube", platform: "youtube", handle: "@stickdeath.infinity",     accountType: "official", isConnected: true),
        ConnectedAccount(id: "sd_discord", platform: "discord", handle: "StickDeath_Infinity",      accountType: "official", isConnected: true),
        ConnectedAccount(id: "sd_instagram", platform: "instagram", handle: "@stickdeathinfinity",  accountType: "official", isConnected: true),
        ConnectedAccount(id: "sd_facebook",  platform: "facebook",  handle: "StickDeath Infinity",  accountType: "official", isConnected: true),
    ]

    @Published var userAccounts: [ConnectedAccount] = []
    @Published var isLoading = false

    /// Fetch user's connected accounts from Supabase
    func fetchUserAccounts() async {
        guard let userId = AuthManager.shared.session?.user.id else { return }
        isLoading = true
        do {
            let tokens: [SocialTokenRow] = try await supabase
                .from("social_tokens")
                .select()
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value

            userAccounts = tokens.map { token in
                ConnectedAccount(
                    id: "user_\(token.platform)",
                    platform: token.platform,
                    handle: token.handle ?? "@me",
                    accountType: "user",
                    isConnected: true,
                    accessToken: token.access_token,
                    refreshToken: token.refresh_token,
                    expiresAt: token.expires_at
                )
            }
        } catch {
            print("⚠️ Failed to fetch social accounts: \(error)")
        }
        isLoading = false
    }

    /// Connect a new platform via OAuth
    func connectPlatform(_ platformId: String) async throws -> URL {
        guard let accessToken = AuthManager.shared.session?.accessToken else {
            throw AppError.notAuthenticated
        }

        // Call edge function to get OAuth URL
        var request = URLRequest(url: AppConfig.edgeFunction("social-connect"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["platform": platformId])

        let (data, _) = try await URLSession.shared.data(for: request)
        struct OAuthResponse: Decodable { let authUrl: String }
        let result = try JSONDecoder().decode(OAuthResponse.self, from: data)
        guard let url = URL(string: result.authUrl) else {
            throw AppError.serverError("Invalid OAuth URL")
        }
        return url
    }

    /// Disconnect a platform
    func disconnectPlatform(_ platformId: String) async throws {
        guard let userId = AuthManager.shared.session?.user.id else { return }
        try await supabase
            .from("social_tokens")
            .delete()
            .eq("user_id", value: userId.uuidString)
            .eq("platform", value: platformId)
            .execute()
        userAccounts.removeAll { $0.platform == platformId }
    }

    /// Get platform by ID
    static func platform(for id: String) -> SocialPlatform? {
        allPlatforms.first { $0.id == id }
    }
}

// DB row shape
private struct SocialTokenRow: Decodable {
    let platform: String
    let handle: String?
    let access_token: String?
    let refresh_token: String?
    let expires_at: String?
}
