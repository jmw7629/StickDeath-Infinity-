import Foundation

public protocol Transport {
    func send(request: TransportRequest) async throws -> TransportResponse
}

public struct TransportRequest: Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct TransportResponse: Equatable {
    public var statusCode: Int
    public var body: Data?

    public init(statusCode: Int, body: Data? = nil) {
        self.statusCode = statusCode
        self.body = body
    }
}

public struct AuthenticatedTransport: Transport {
    private let baseURL: URL?
    private let sessionToken: String?
    private let delegate: TransportDelegate?

    public init(baseURL: URL?, sessionToken: String?, delegate: TransportDelegate? = nil) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.delegate = delegate
    }

    public func send(request: TransportRequest) async throws -> TransportResponse {
        guard let baseURL = baseURL else {
            throw TransportError.missingBackend
        }
        guard let token = sessionToken, !token.isEmpty else {
            throw TransportError.missingAuthToken
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(request.url.path))
        urlRequest.httpMethod = request.method
        urlRequest.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (key, value) in request.headers {
            urlRequest.addValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body

        if let delegate = delegate {
            return try await delegate.send(urlRequest)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        return TransportResponse(
            statusCode: httpResponse?.statusCode ?? 0,
            body: data
        )
    }
}

public protocol TransportDelegate {
    func send(_ request: URLRequest) async throws -> TransportResponse
}

public enum TransportError: LocalizedError {
    case missingBackend
    case missingAuthToken
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingBackend: return "Backend endpoint not configured"
        case .missingAuthToken: return "Session token not available"
        case .networkError(let msg): return "Network error: \(msg)"
        }
    }
}

public final class SpatterTransport {
    private let transport: Transport

    public init(transport: Transport) {
        self.transport = transport
    }

    public func chat(
        messages: [(role: String, content: String)],
        model: String
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": 500,
            "temperature": 0.8
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let request = TransportRequest(
            url: URL(string: "/v1/chat/completions")!,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: bodyData
        )

        let response = try await transport.send(request: request)
        guard response.statusCode == 200, let data = response.body else {
            throw TransportError.networkError("Status \(response.statusCode)")
        }

        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = parsed?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: String]
        return message?["content"] ?? ""
    }
}
