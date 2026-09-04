// ═══════════════════════════════════════════════════════════════════
// SpatterServerClient — Secure endpoint abstraction for production AI
// All authentication is handled server-side. The client carries only
// a user session token — never API keys, service-role keys, or
// privileged backend secrets.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Client Protocol

/// Contract for the server-side Spatter endpoint.
/// The production server authenticates the user via session JWT
/// and calls the LLM with its own API key.
protocol SpatterServerClient {
    var isConfigured: Bool { get }

    func sendRequest(
        _ request: SpatterServerRequest
    ) async throws -> SpatterServerResponse
}

// MARK: - Request / Response

struct SpatterServerRequest: Codable, Sendable {
    let messages: [SpatterChatMessage]
    let context: SpatterStudioContext?
    let tools: [SpatterToolDefinition]?
    let modelHint: String?
    let maxTokens: Int?
}

struct SpatterServerResponse: Codable, Sendable {
    let text: String?
    let toolCalls: [SpatterToolCall]?
    let modelID: String?
    let finishReason: String?
    let usage: UsageInfo?

    struct UsageInfo: Codable, Sendable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
    }
}

// MARK: - Configuration

/// Configuration for the server endpoint. No secrets — only URL and
/// optional model hint. Auth tokens are injected at call time from
/// the existing AuthService session.
struct SpatterServerConfig: Sendable {
    let baseURL: URL
    let modelHint: String
    let maxTokens: Int
    let timeoutInterval: TimeInterval

    static let `default` = SpatterServerConfig(
        baseURL: URL(string: "https://api.stickdeath.infinity/spatter")!,
        modelHint: "gpt-4o",
        maxTokens: 1024,
        timeoutInterval: 30
    )
}

// MARK: - Production Client

/// HTTP client that calls the server-side Spatter endpoint.
/// The user's Supabase session JWT is attached as a Bearer token.
/// No LLM API key is ever embedded in the iOS binary.
final class SpatterServerHTTPClient: SpatterServerClient {

    static let shared = SpatterServerHTTPClient()

    private let config: SpatterServerConfig
    private let session: URLSession
    private let decoder = JSONDecoder()

    var isConfigured: Bool { true }

    init(config: SpatterServerConfig = .default) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeoutInterval
        self.session = URLSession(configuration: sessionConfig)
    }

    func sendRequest(_ request: SpatterServerRequest) async throws -> SpatterServerResponse {
        let url = config.baseURL.appendingPathComponent("chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach the user's session token (no privileged secrets)
        if let token = try? await SupabaseManager.shared.client.auth.session.accessToken {
            urlRequest.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body = SpatterEndpointBody(
            messages: request.messages,
            context: request.context,
            tools: request.tools,
            model: request.modelHint ?? config.modelHint,
            maxTokens: request.maxTokens ?? config.maxTokens
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpatterProviderError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                return try decoder.decode(SpatterServerResponse.self, from: data)
            } catch {
                throw SpatterProviderError.decodingError(error)
            }
        case 429:
            throw SpatterProviderError.rateLimited
        default:
            throw SpatterProviderError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Internal Body

    private struct SpatterEndpointBody: Codable {
        let messages: [SpatterChatMessage]
        let context: SpatterStudioContext?
        let tools: [SpatterToolDefinition]?
        let model: String
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case messages, context, tools, model
            case maxTokens = "max_tokens"
        }
    }
}
