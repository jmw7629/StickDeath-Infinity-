import Foundation

public struct SpatterBackendConfig: Sendable, Equatable {
    public var backendURL: String
    public var timeout: TimeInterval

    public init(backendURL: String = "", timeout: TimeInterval = 30) {
        self.backendURL = backendURL
        self.timeout = timeout
    }

    public var isConfigured: Bool {
        !backendURL.isEmpty
    }
}

public enum SpatterBackendError: LocalizedError, Sendable {
    case notConfigured
    case unauthorized
    case networkError(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Spatter backend is not configured"
        case .unauthorized: return "Not authenticated — please sign in"
        case .networkError(let msg): return "Network error: \(msg)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        }
    }
}

public struct SpatterChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public final class SpatterBackendClient: @unchecked Sendable {
    private let config: SpatterBackendConfig
    private let session: URLSession

    public init(config: SpatterBackendConfig = SpatterBackendConfig(), session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func chat(
        messages: [SpatterChatMessage],
        brainContext: String = "",
        authToken: String? = nil
    ) async throws -> String {
        guard config.isConfigured else {
            throw SpatterBackendError.notConfigured
        }

        guard let url = URL(string: "\(config.backendURL)/v1/chat") else {
            throw SpatterBackendError.invalidResponse("Invalid backend URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.timeout

        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "brain_context": brainContext,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpatterBackendError.invalidResponse("Not an HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = json["content"] as? String else {
                throw SpatterBackendError.invalidResponse("Missing content in response")
            }
            return reply
        case 401:
            throw SpatterBackendError.unauthorized
        default:
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw SpatterBackendError.networkError("HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    public func isAvailable() -> Bool {
        config.isConfigured
    }
}
