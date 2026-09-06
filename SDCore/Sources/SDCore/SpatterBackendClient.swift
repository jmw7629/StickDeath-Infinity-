import Foundation

// MARK: - Backend Configuration (public, non-secret)

public struct BackendConfig: Equatable {
    public var baseURL: String
    public var isEnabled: Bool

    public init(baseURL: String = "", isEnabled: Bool = false) {
        self.baseURL = baseURL
        self.isEnabled = isEnabled
    }

    public static let unavailable = BackendConfig(baseURL: "", isEnabled: false)
}

// MARK: - Auth Token Provider

public protocol AuthTokenProvider {
    var currentAuthToken: String? { get }
    var isAuthenticated: Bool { get }
}

// MARK: - Spatter Backend Client

public final class SpatterBackendClient {
    private let config: BackendConfig
    private let authProvider: AuthTokenProvider
    private let session: URLSession

    private(set) var transportCallCount = 0

    public init(
        config: BackendConfig,
        authProvider: AuthTokenProvider,
        session: URLSession = .shared
    ) {
        self.config = config
        self.authProvider = authProvider
        self.session = session
    }

    /// Whether the backend is ready to make transport calls
    public var canMakeTransportCalls: Bool {
        config.isEnabled && !config.baseURL.isEmpty && authProvider.isAuthenticated
    }

    /// Send a chat request to the production backend seam.
    /// Returns nil (zero transport calls) if backend is not configured or auth is missing.
    public func chat(
        messages: [(role: String, content: String)],
        systemPrompt: String? = nil,
        maxTokens: Int = 500
    ) async throws -> String? {
        guard canMakeTransportCalls else { return nil }
        guard let token = authProvider.currentAuthToken else { return nil }

        transportCallCount += 1

        var apiMessages: [[String: String]] = []
        if let system = systemPrompt {
            apiMessages.append(["role": "system", "content": system])
        }
        for msg in messages {
            apiMessages.append(["role": msg.role, "content": msg.content])
        }

        let body: [String: Any] = [
            "messages": apiMessages,
            "max_tokens": maxTokens,
        ]

        let url = URL(string: "\(config.baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(BackendChatResponse.self, from: data)
        return response.choices.first?.message.content
    }
}

// MARK: - Backend response models

struct BackendChatResponse: Codable {
    let choices: [Choice]
    struct Choice: Codable {
        let message: Message
    }
    struct Message: Codable {
        let content: String
    }
}
