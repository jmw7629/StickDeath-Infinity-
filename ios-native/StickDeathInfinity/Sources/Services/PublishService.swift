// PublishService.swift
// Calls render-video and publish-video edge functions

import Foundation

class PublishService {
    static let shared = PublishService()

    // Render animation frames into an MP4 on the server
    func renderVideo(projectId: Int) async throws -> String {
        guard let accessToken = AuthManager.shared.session?.accessToken else {
            throw AppError.notAuthenticated
        }

        var request = URLRequest(url: AppConfig.edgeFunction("render-video"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["project_id": projectId])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppError.serverError("Render failed")
        }

        struct RenderResponse: Decodable { let videoUrl: String }
        let result = try JSONDecoder().decode(RenderResponse.self, from: data)
        return result.videoUrl
    }

    // Publish video to YouTube, TikTok, Instagram, Facebook
    func publishToSocial(projectId: Int, platforms: [String]) async throws {
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
        }
        request.httpBody = try JSONEncoder().encode(PublishRequest(project_id: projectId, platforms: platforms))

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppError.serverError("Publish failed")
        }
    }
}
