// ═══════════════════════════════════════════════════════════════════
// Transport — Injectable backend transport seam
// Requires: backend configured + authenticated + non-empty session token
// before any transport invocation. Foundation-testable with no real network.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Transport Request

public struct TransportRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

// MARK: - Transport Response

public struct TransportResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int = 200, data: Data = Data()) {
        self.statusCode = statusCode
        self.data = data
    }
}

// MARK: - Transport Protocol

public protocol BackendTransport: Sendable {
    func send(request: TransportRequest) async throws -> TransportResponse
}

// MARK: - Backend Configuration

public struct BackendConfig: Sendable, Equatable {
    public let baseURL: String
    public let sessionToken: String?

    public init(baseURL: String, sessionToken: String? = nil) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
    }

    public var isFullyConfigured: Bool {
        !baseURL.isEmpty
    }

    public var isAuthenticated: Bool {
        guard let token = sessionToken else { return false }
        return !token.isEmpty
    }
}

// MARK: - Transport Caller (production seam)

public struct BackendTransportCaller: Sendable {
    private let config: BackendConfig?
    private let transport: BackendTransport

    public init(config: BackendConfig?, transport: BackendTransport) {
        self.config = config
        self.transport = transport
    }

    /// Returns true only when backend is configured AND authenticated with non-empty token.
    public var canMakeTransportCalls: Bool {
        guard let config else { return false }
        return config.isFullyConfigured && config.isAuthenticated
    }

    /// Execute a transport call. Returns nil if not configured/authenticated.
    @discardableResult
    public func call(
        path: String,
        method: String = "POST",
        body: [String: Any]? = nil
    ) async throws -> TransportResponse? {
        guard canMakeTransportCalls, let config else { return nil }

        let url = URL(string: "\(config.baseURL)/\(path)")!
        var headers: [String: String] = [
            "Content-Type": "application/json"
        ]
        if let token = config.sessionToken {
            headers["Authorization"] = "Bearer \(token)"
        }

        var requestData: Data?
        if let body {
            requestData = try JSONSerialization.data(withJSONObject: body)
        }

        let request = TransportRequest(url: url, method: method, headers: headers, body: requestData)
        return try await transport.send(request: request)
    }
}
