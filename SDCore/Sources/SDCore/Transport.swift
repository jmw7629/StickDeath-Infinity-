// ═══════════════════════════════════════════════════════════════════
// Transport — Linux-safe networking boundary for SDCore
// FoundationNetworking is required on Linux for URLRequest/URLSession
// ═══════════════════════════════════════════════════════════════════

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Transport Protocol

/// Abstraction over network requests. Production uses URLSession;
/// tests use recording fakes. No provider-key or credential fields.
public protocol Transport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

// MARK: - Transport Factory

/// Creates transport instances. Production injects current session token;
/// tests inject fakes.
public protocol TransportFactory {
    func makeTransport() -> Transport
}

// MARK: - AuthenticatedTransport

/// Production transport that adds Authorization header using a
/// token-provider seam. Token is obtained at request time, not frozen.
public final class AuthenticatedTransport: Transport {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: () -> String?

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var mutableRequest = request

        // Resolve absolute URL relative to baseURL
        if let relativePath = request.url?.path,
           request.url?.host == nil {
            mutableRequest.url = baseURL.appendingPathComponent(relativePath)
        }

        // Attach current session token
        if let token = tokenProvider(), !token.isEmpty {
            mutableRequest.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: mutableRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransportError.invalidResponse
        }

        return (data, httpResponse)
    }
}

// MARK: - Transport Errors

public enum TransportError: Error, LocalizedError {
    case notConfigured
    case missingToken
    case invalidResponse
    case serverError(Int)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend not configured"
        case .missingToken:
            return "No authentication token available"
        case .invalidResponse:
            return "Invalid server response"
        case .serverError(let code):
            return "Server error: \(code)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - No-Op Transport

/// Returns zero calls. Used when backend is unconfigured or token is missing.
public struct NoOpTransport: Transport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw TransportError.notConfigured
    }
}

// MARK: - Spatter Transport (Chat)

/// Transport for Spatter AI chat requests through the configured backend.
/// No direct OpenAI/Gemini/Anthropic/Pollinations host or provider-key
/// storage/input contract in the iOS client.
public final class SpatterTransport: Transport {
    private let backendTransport: Transport

    public init(backendTransport: Transport) {
        self.backendTransport = backendTransport
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        return try await backendTransport.send(request)
    }
}
