import Foundation

// MARK: - Backend Transport Protocol

/// All cloud AI goes through one configurable public backend endpoint.
/// No direct provider host and no provider secret input/storage in client.
/// Valid authenticated session/token is required before transport invocation.
public protocol SpatterBackendTransport: Sendable {
    /// Invoke a backend endpoint. Returns nil if not configured or not authenticated.
    func invoke(
        path: String,
        body: Data?,
        authToken: String?
    ) async throws -> Data?
}

// MARK: - Backend Client

/// Foundation-testable client seam.
/// Proves: missing backend => 0 calls; missing auth => 0 calls;
/// configured+authenticated => Authorization/session transport with no provider credential in body.
public final class SpatterBackendClient: Sendable {
    private let backendEndpoint: String?
    private let transport: SpatterBackendTransport?

    /// Number of transport invocations (for testing).
    public private(set) var transportCallCount: Int = 0

    /// Last request details (for testing assertions).
    public private(set) var lastRequestPath: String?
    public private(set) var lastRequestHasAuthToken: Bool = false
    public private(set) var lastRequestBodyHasProviderKey: Bool = false

    public init(backendEndpoint: String? = nil, transport: SpatterBackendTransport? = nil) {
        self.backendEndpoint = backendEndpoint
        self.transport = transport
    }

    /// Send a chat request to the backend.
    /// - Returns: response data, or nil if not configured/authenticated.
    public func chat(
        messages: [(role: String, content: String)],
        authToken: String?
    ) async throws -> Data? {
        // Gate 1: Missing backend => 0 transport calls
        guard let endpoint = backendEndpoint, !endpoint.isEmpty else {
            return nil
        }

        // Gate 2: Missing auth => 0 transport calls
        guard let token = authToken, !token.isEmpty else {
            return nil
        }

        // Gate 3: Configured + authenticated => build request
        let body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        // Verify no provider credential leaks into body
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        let hasProviderKey = bodyString.contains("sk-") ||
            bodyString.contains("api_key") ||
            bodyString.contains("apiKey")

        lastRequestPath = endpoint
        lastRequestHasAuthToken = !token.isEmpty
        lastRequestBodyHasProviderKey = hasProviderKey
        transportCallCount += 1

        return try await transport?.invoke(
            path: endpoint,
            body: bodyData,
            authToken: token
        )
    }
}
