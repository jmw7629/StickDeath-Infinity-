// ═══════════════════════════════════════════════════════════════════
// SpatterAIProvider — Provider-neutral abstraction for Spatter AI
// Production path: server-side endpoint (no secrets in client)
// Offline path: embedded knowledge + deterministic local commands
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Provider Protocol

/// Provider-neutral protocol. Every implementation must be able to
/// return either a text reply, structured tool calls, or both.
protocol SpatterAIProvider {
    var isAvailable: Bool { get }
    var providerName: String { get }

    func chat(
        messages: [SpatterChatMessage],
        context: SpatterStudioContext?,
        tools: [SpatterToolDefinition]?
    ) async throws -> SpatterResponse

    func streamChat(
        messages: [SpatterChatMessage],
        context: SpatterStudioContext?,
        tools: [SpatterToolDefinition]?,
        onToken: @escaping (String) -> Void
    ) async throws -> SpatterResponse
}

// MARK: - Chat Message

struct SpatterChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

// MARK: - Response

/// Unified response from any provider. May contain text, tool calls, or both.
struct SpatterResponse: Sendable {
    let text: String?
    let toolCalls: [SpatterToolCall]
    let providerName: String
    let modelID: String?
    let finishReason: String?
}

// MARK: - Tool Call

struct SpatterToolCall: Codable, Sendable {
    let id: String
    let name: String
    let arguments: String
}

// MARK: - Provider Errors

enum SpatterProviderError: Error, LocalizedError {
    case notAvailable
    case apiKeyMissing
    case networkError(Error)
    case decodingError(Error)
    case rateLimited
    case serverError(Int)
    case invalidToolCall(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "AI provider is not available"
        case .apiKeyMissing: return "API key not configured"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError(let e): return "Decoding error: \(e.localizedDescription)"
        case .rateLimited: return "Rate limited — try again later"
        case .serverError(let code): return "Server error \(code)"
        case .invalidToolCall(let msg): return "Invalid tool call: \(msg)"
        }
    }
}
