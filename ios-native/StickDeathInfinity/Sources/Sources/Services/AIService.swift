// AIService.swift
// Calls the ai-assist edge function (Pro users only)

import Foundation

struct AIAssistRequest: Encodable {
    let prompt: String
    let context: String?
}

struct AIAssistResponse: Decodable {
    let suggestion: String
    let frames: [[String: Any]]?

    enum CodingKeys: String, CodingKey {
        case suggestion, frames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        suggestion = try container.decode(String.self, forKey: .suggestion)
        frames = nil // Complex nested JSON — handle separately if needed
    }
}

class AIService {
    static let shared = AIService()

    func getAssist(prompt: String, context: String? = nil) async throws -> String {
        guard let accessToken = await AuthManager.shared.session?.accessToken else {
            throw AppError.notAuthenticated
        }

        guard await AuthManager.shared.isPro else {
            throw AppError.serverError("AI Assist requires a Pro subscription")
        }

        var request = URLRequest(url: AppConfig.edgeFunction("ai-assist"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = AIAssistRequest(prompt: prompt, context: context)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppError.serverError("AI service unavailable")
        }

        let result = try JSONDecoder().decode(AIAssistResponse.self, from: data)
        return result.suggestion
    }
}
