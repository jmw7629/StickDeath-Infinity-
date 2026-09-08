import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTPS app-backend endpoints only, never client-configured provider credentials.
enum SpatterEndpoint {
    static func url(from value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443 else { return nil }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let providers = ["openai.com", "anthropic.com", "pollinations.ai",
                         "generativelanguage.googleapis.com", "aiplatform.googleapis.com"]
        guard !providers.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return components.url
    }
}

enum SpatterClientError: Error, LocalizedError, Equatable {
    case notConfigured, notAuthenticated, invalidEndpoint, invalidRequest
    case invalidResponse, emptyResponse, responseTooLarge, networkUnavailable
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Spatter cloud is not configured. Local animation guidance remains available."
        case .notAuthenticated: return "Sign in to use Spatter cloud. Local animation guidance remains available."
        case .invalidEndpoint: return "Spatter's backend configuration is invalid."
        case .invalidRequest: return "This Spatter request is empty or too large. Shorten the conversation and try again."
        case .invalidResponse: return "Spatter's backend returned an invalid response."
        case .emptyResponse: return "Spatter's backend returned no answer."
        case .responseTooLarge: return "Spatter's backend response exceeded the size limit."
        case .networkUnavailable: return "Spatter's backend could not be reached. Try again later."
        case .httpStatus(401), .httpStatus(403): return "Spatter's backend did not authorize this request."
        case .httpStatus(429): return "Spatter's backend is rate-limited. Try again later."
        case .httpStatus: return "Spatter's backend reported an HTTP error."
        }
    }
}

struct SpatterChatMessage: Codable, Equatable {
    enum Role: String, Codable { case system, user, assistant }
    let role: Role
    let content: String
}

/// Both app chat entry points use this exact, Foundation-testable boundary.
/// The transport and session source are injected; tests never hold real tokens.
@MainActor
struct SpatterBackendClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let responseLimit = 128 * 1024
    static let requestLimit = 128 * 1024
    let endpoint: () -> URL?
    let sessionToken: () async throws -> String?
    let transport: Transport

    init(endpoint: @escaping () -> URL? = { AppConfig.backendURL },
         sessionToken: @escaping () async throws -> String?,
         transport: @escaping Transport = { request in
             try await BoundedSpatterRequest(request: request).run()
         }) {
        self.endpoint = endpoint
        self.sessionToken = sessionToken
        self.transport = transport
    }

    func complete(messages: [SpatterChatMessage]) async throws -> String {
        try Task.checkCancellation()
        guard let endpoint = endpoint() else { throw SpatterClientError.notConfigured }
        guard SpatterEndpoint.url(from: endpoint.absoluteString) != nil else {
            throw SpatterClientError.invalidEndpoint
        }
        let token: String?
        do { token = try await sessionToken() }
        catch is CancellationError { throw CancellationError() }
        catch { throw SpatterClientError.notAuthenticated }
        guard let token, !token.isEmpty, token.utf8.count <= 16_384,
              token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            throw SpatterClientError.notAuthenticated
        }
        guard !messages.isEmpty, messages.count <= 41,
              messages.allSatisfy({ !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.content.utf8.count <= 32_768 }) else { throw SpatterClientError.invalidRequest }
        struct Payload: Encodable {
            let messages: [SpatterChatMessage]
            let max_tokens = 500
            let temperature = 0.8
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(Payload(messages: messages))
        guard body.count <= Self.requestLimit else { throw SpatterClientError.invalidRequest }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        try Task.checkCancellation()
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SpatterClientError { throw error }
        catch { throw SpatterClientError.networkUnavailable }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw SpatterClientError.httpStatus(response.statusCode)
        }
        guard data.count <= Self.responseLimit else { throw SpatterClientError.responseTooLarge }
        guard response.mimeType?.lowercased() == "application/json" else {
            throw SpatterClientError.invalidResponse
        }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let parsed = try? JSONDecoder().decode(Response.self, from: data) else {
            throw SpatterClientError.invalidResponse
        }
        guard let content = parsed.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpatterClientError.emptyResponse
        }
        return content
    }
}

/// One request per instance. Delegate/cancellation state is protected by `lock`;
/// no mutable state escapes it. URLSession requires Sendable delegate conformance.
/// The response is bounded during ingestion, not sliced after an unbounded load.
final class BoundedSpatterRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let byteLimit = 128 * 1024
    private var data = Data()
    private var response: HTTPURLResponse?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var result: Result<(Data, HTTPURLResponse), Error>?

    init(request: URLRequest, configuration: URLSessionConfiguration = .ephemeral) {
        self.request = request
        self.configuration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        super.init()
    }

    func run() async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 45
                configuration.urlCache = nil
                configuration.urlCredentialStorage = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: {
            self.finish(.failure(CancellationError()))
        })
    }

    private func finish(_ outcome: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let continuation = self.continuation
        let session = self.session
        let task = self.task
        self.continuation = nil
        self.session = nil
        self.task = nil
        data.removeAll(keepingCapacity: false)
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: outcome)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward the session token or conversation to a redirect target.
        completionHandler(nil)
        finish(.failure(SpatterClientError.httpStatus(response.statusCode)))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(SpatterClientError.invalidResponse))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(SpatterClientError.httpStatus(http.statusCode)))
            return
        }
        guard response.expectedContentLength <= Int64(byteLimit) else {
            completionHandler(.cancel)
            finish(.failure(SpatterClientError.responseTooLarge))
            return
        }
        lock.lock()
        let finished = result != nil
        if !finished { self.response = http }
        lock.unlock()
        completionHandler(finished ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let tooLarge = chunk.count > byteLimit - data.count
        if !tooLarge { data.append(chunk) }
        lock.unlock()
        if tooLarge { finish(.failure(SpatterClientError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let response = self.response
        let data = self.data
        let finished = result != nil
        lock.unlock()
        guard !finished else { return }
        if error != nil { finish(.failure(SpatterClientError.networkUnavailable)) }
        else if let response { finish(.success((data, response))) }
        else { finish(.failure(SpatterClientError.invalidResponse)) }
    }
}
