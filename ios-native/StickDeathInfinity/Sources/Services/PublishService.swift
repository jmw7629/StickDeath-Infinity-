// PublishService.swift
// Calls render-video and publish-video edge functions
// Supports official StickDeath channels + user's own accounts
// Handles watermark flag for branding

import Foundation

class PublishService {
    static let shared = PublishService()

    // MARK: - Render Video (server-side)
    /// Triggers server to render animation frames into an MP4
    func renderVideo(projectId: Int, watermark: Bool = true) async throws -> String {
        guard let accessToken = AuthManager.shared.session?.accessToken else {
            throw AppError.notAuthenticated
        }

        var request = URLRequest(url: AppConfig.edgeFunction("render-video"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct RenderRequest: Encodable {
            let project_id: Int
            let watermark: Bool
            let watermark_text: String
        }
        request.httpBody = try JSONEncoder().encode(
            RenderRequest(
                project_id: projectId,
                watermark: watermark,
                watermark_text: "StickDeath ∞"
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppError.serverError("Render failed")
        }

        struct RenderResponse: Decodable { let videoUrl: String }
        let result = try JSONDecoder().decode(RenderResponse.self, from: data)
        return result.videoUrl
    }

    // MARK: - Publish to Social Platforms
    /// Sends video to selected platforms via edge function
    /// accountType: "official" for StickDeath channels, "user" for user's own
    func publishToSocial(
        projectId: Int,
        platforms: [String],
        title: String = "",
        description: String = "",
        watermark: Bool = true,
        accountType: String = "official"
    ) async throws {
        guard let accessToken = AuthManager.shared.session?.accessToken else {
            throw AppError.notAuthenticated
        }

        var request = URLRequest(url: AppConfig.edgeFunction("publish-video"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct PublishRequest: Encodable {
            let project_id: Int
            let platforms: [String]
            let title: String
            let description: String
            let watermark: Bool
            let watermark_text: String
            let account_type: String  // "official" or "user"
        }

        request.httpBody = try JSONEncoder().encode(
            PublishRequest(
                project_id: projectId,
                platforms: platforms,
                title: title,
                description: description,
                watermark: watermark,
                watermark_text: watermark ? "Made with StickDeath ∞" : "",
                account_type: accountType
            )
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppError.serverError("Publish failed")
        }
    }

    // MARK: - Export to Camera Roll (local)
    /// Exports video to local device camera roll
    func exportLocally(projectId: Int, watermark: Bool) async throws -> URL {
        // Render on server first
        let videoUrlString = try await renderVideo(projectId: projectId, watermark: watermark)
        guard let videoUrl = URL(string: videoUrlString) else {
            throw AppError.serverError("Invalid video URL")
        }

        // Download to temp
        let (localUrl, _) = try await URLSession.shared.download(from: videoUrl)
        return localUrl
    }
}
