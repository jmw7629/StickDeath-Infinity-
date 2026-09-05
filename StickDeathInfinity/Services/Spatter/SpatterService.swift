// ═══════════════════════════════════════════════════════════════════
// SpatterService — Spatter AI backend service
// Uses one configurable backend endpoint. Requires authenticated session.
// No direct provider (OpenAI/Gemini/Anthropic/etc.) calls.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

enum SpatterServiceError: Error {
    case notConfigured
    case notAuthenticated
    case backendError(String)
}

final class SpatterService {
    static let shared = SpatterService()

    private let backendURL: String?

    init() {
        self.backendURL = AppConfig.spatterBackendURL
    }

    private func requireAuth() async throws -> (backend: URL, token: String) {
        guard let backendURL, !backendURL.isEmpty else {
            throw SpatterServiceError.notConfigured
        }
        guard let url = URL(string: backendURL) else {
            throw SpatterServiceError.notConfigured
        }
        guard let token = await AuthService.shared.fetchSessionToken(), !token.isEmpty else {
            throw SpatterServiceError.notAuthenticated
        }
        return (url, token)
    }

    // MARK: - Chat

    func chat(
        messages: [(role: String, content: String)],
        context: SpatterContext? = nil
    ) async throws -> String {
        let auth = try await requireAuth()

        var apiMessages: [[String: String]] = []
        for msg in messages {
            apiMessages.append(["role": msg.role, "content": msg.content])
        }

        var request = URLRequest(url: auth.backend.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.addValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "messages": apiMessages,
            "max_tokens": 500,
            "temperature": 0.8,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SpatterServiceError.backendError("Backend returned non-200 status")
        }

        let result = try JSONDecoder().decode(BackendChatResponse.self, from: data)
        return result.choices.first?.message.content ?? "..."
    }

    // MARK: - Tool Knowledge Lookup (offline, no network)

    func toolKnowledge(for tool: String) -> SpatterKnowledgeModule? {
        SpatterKnowledgeBase.search(tool).first
    }

    func categories() -> [String] {
        Array(Set(SpatterKnowledgeBase.allModules.map(\.category))).sorted()
    }
}

// MARK: - Backend Response Model

private struct BackendChatResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let content: String
    }
}

// MARK: - SpatterContext

struct SpatterContext {
    let currentScreen: String
    let currentTool: String?
    let userName: String
}
