// ═══════════════════════════════════════════════════════════════════
// ServerSpatterProvider — Production AI provider via server endpoint
// Calls the server-side Spatter endpoint. The server authenticates
// the user and calls the LLM with its own API key.
// The client never sees API keys, service-role tokens, or backend
// secrets.
// ═══════════════════════════════════════════════════════════════════

import Foundation

final class ServerSpatterProvider: SpatterAIProvider {

    static let shared = ServerSpatterProvider()

    private let client: SpatterServerClient
    private let offlineFallback: OfflineSpatterProvider

    var isAvailable: Bool { client.isConfigured }
    var providerName: String { "Spatter Cloud" }

    init(
        client: SpatterServerClient = SpatterServerHTTPClient.shared,
        offlineFallback: OfflineSpatterProvider = .shared
    ) {
        self.client = client
        self.offlineFallback = offlineFallback
    }

    func chat(
        messages: [SpatterChatMessage],
        context: SpatterStudioContext?,
        tools: [SpatterToolDefinition]?
    ) async throws -> SpatterResponse {
        guard client.isConfigured else {
            // Fallback to offline if server is not configured
            return try await offlineFallback.chat(messages: messages, context: context, tools: tools)
        }

        let request = SpatterServerRequest(
            messages: messages,
            context: context,
            tools: tools ?? SpatterToolDefinitions.allTools,
            modelHint: nil,
            maxTokens: nil
        )

        do {
            let serverResponse = try await client.sendRequest(request)
            return SpatterResponse(
                text: serverResponse.text,
                toolCalls: serverResponse.toolCalls ?? [],
                providerName: providerName,
                modelID: serverResponse.modelID,
                finishReason: serverResponse.finishReason
            )
        } catch {
            // Fallback to offline on network/server errors
            return try await offlineFallback.chat(messages: messages, context: context, tools: tools)
        }
    }

    func streamChat(
        messages: [SpatterChatMessage],
        context: SpatterStudioContext?,
        tools: [SpatterToolDefinition]?,
        onToken: @escaping (String) -> Void
    ) async throws -> SpatterResponse {
        // Use non-streaming as fallback; the server endpoint can be
        // extended to support SSE streaming in a follow-up task.
        let response = try await chat(messages: messages, context: context, tools: tools)
        if let text = response.text {
            onToken(text)
        }
        return response
    }
}
