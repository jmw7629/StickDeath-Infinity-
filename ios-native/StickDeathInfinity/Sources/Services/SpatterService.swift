// SpatterService.swift
// Client for the Spatter AI bot — handles DM chat, welcome, feedback requests
// Spatter is a community AI character, not just a help button

import Foundation
import Supabase

// MARK: - Spatter Bot ID (deterministic UUID from DB)
let SPATTER_USER_ID = "00000000-0000-0000-0000-000000000b01"

class SpatterService {
    static let shared = SpatterService()
    private init() {}

    private let functionName = "spatter-ai"

    // MARK: - Chat with Spatter (DM conversation)
    func chat(message: String, conversationHistory: [[String: String]]? = nil) async throws -> SpatterChatResponse {
        let body: [String: Any] = [
            "mode": "chat",
            "message": message,
            "conversation_history": conversationHistory ?? [],
        ]
        let result = try await callSpatter(body: body)
        return try JSONDecoder().decode(SpatterChatResponse.self, from: result)
    }

    // MARK: - Generate Animation from Prompt
    func generateAnimation(prompt: String) async throws -> SpatterAnimationResponse {
        let body: [String: Any] = [
            "mode": "generate",
            "animation_prompt": prompt,
        ]
        let result = try await callSpatter(body: body)
        return try JSONDecoder().decode(SpatterAnimationResponse.self, from: result)
    }

    // MARK: - Get Feedback on User's Animation
    func getFeedback(projectId: Int) async throws -> SpatterFeedbackResponse {
        let body: [String: Any] = [
            "mode": "feedback",
            "project_id": projectId,
        ]
        let result = try await callSpatter(body: body)
        return try JSONDecoder().decode(SpatterFeedbackResponse.self, from: result)
    }

    // MARK: - Trigger Welcome (called on new user signup)
    func welcomeNewUser() async throws -> SpatterWelcomeResponse {
        let body: [String: Any] = [
            "mode": "welcome",
        ]
        let result = try await callSpatter(body: body)
        return try JSONDecoder().decode(SpatterWelcomeResponse.self, from: result)
    }

    // MARK: - Edge Function Call
    private func callSpatter(body: [String: Any]) async throws -> Data {
        guard let session = try? await supabase.auth.session else {
            throw SpatterError.notAuthenticated
        }

        let url = AppConfig.edgeFunction(functionName)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpatterError.networkError
        }

        if httpResponse.statusCode == 429 {
            throw SpatterError.rateLimited
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SpatterError.serverError(errorMsg)
        }

        return data
    }
}

// MARK: - Response Types

struct SpatterChatResponse: Codable {
    let message: String?
    let poses: [SpatterPose]?
    let tips: [String]?
    let mode: String?
}

struct SpatterWelcomeResponse: Codable {
    let greeting: String?
    let tip: String?
    let starter_pose: SpatterPose?
    let catchphrase: String?
    let mode: String?
}

struct SpatterAnimationResponse: Codable {
    let title: String?
    let description: String?
    let fps: Int?
    let frames: [SpatterFrame]?
    let figures: [SpatterFigure]?
    let tags: [String]?
    let mode: String?
}

struct SpatterFeedbackResponse: Codable {
    let overall: String?
    let strengths: [String]?
    let suggestions: [SpatterSuggestion]?
    let encouragement: String?
    let skill_assessment: String?
    let mode: String?
}

struct SpatterPose: Codable {
    let name: String?
    let description: String?
    let joints: [String: SpatterPoint]?
}

struct SpatterPoint: Codable {
    let x: Double
    let y: Double
}

struct SpatterFrame: Codable {
    let figureStates: [SpatterFigureState]?
    let duration: Double?
}

struct SpatterFigureState: Codable {
    let figureId: String?
    let joints: [String: SpatterPoint]?
    let visible: Bool?
}

struct SpatterFigure: Codable {
    let id: String?
    let name: String?
    let color: CodableColor?
    let lineWidth: CGFloat?
    let headRadius: CGFloat?
}

struct SpatterSuggestion: Codable {
    let frame_range: String?
    let issue: String?
    let fix: String?
    let priority: String?
}

// MARK: - Errors

enum SpatterError: LocalizedError {
    case notAuthenticated
    case networkError
    case rateLimited
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Sign in to chat with Spatter"
        case .networkError: return "Couldn't reach Spatter — check your connection"
        case .rateLimited: return "Spatter needs a breather — try again in a bit"
        case .serverError(let msg): return "Spatter glitched: \(msg)"
        }
    }
}

// MARK: - Helper: Check if a user is Spatter
extension String {
    var isSpatter: Bool { self == SPATTER_USER_ID }
}
