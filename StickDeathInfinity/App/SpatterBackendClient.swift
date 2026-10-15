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

/// An error whose own description is safe and specific enough to show the member
/// (for example own-key failures, which never carry the key).
protocol SpatterUserFacingError: LocalizedError {}

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
        case .httpStatus(402): return "Spatter is part of Creator and Pro, or buy Spatter credits in Profile, Plans to pay as you go."
        case .httpStatus(429): return "Spatter's backend is rate-limited or your daily Spatter budget is used up. Try again later."
        case .httpStatus(503): return "Spatter cloud is not configured on the server. Local animation guidance remains available."
        case .httpStatus: return "Spatter's backend reported an HTTP error."
        }
    }
}

/// Server-reported remaining allowance for this account. It is display data,
/// never a client-side entitlement, and absent when the backend omits it.
struct SpatterBudget: Equatable {
    let remaining: Int
    let resetsAt: Date?
    var displayText: String { "Remaining today: \(remaining)" }
}

/// The app's suggested Spatter prompts (owner decision 2026-10-14). Free
/// accounts may send only these, five per calendar month; the server keeps the
/// same id allowlist (backend/spatter/suggested_prompts.py and
/// sdi_private.spatter_suggested_prompt_ids) and, on Free, replaces any client
/// text with its own canonical prompt for the id. Ids must never change
/// without changing both server lists; backend/spatter/test_suggested_prompts.py
/// checks all three stay identical.
struct SpatterSuggestedPrompt: Identifiable, Equatable {
    let id: String
    let label: String
    let symbol: String

    static let all: [SpatterSuggestedPrompt] = [
        .init(id: "animation_tips", label: "Animation tips", symbol: "💡"),
        .init(id: "scene_ideas", label: "Scene ideas", symbol: "🎬"),
        .init(id: "fight_choreography", label: "Fight choreography", symbol: "🔥"),
        .init(id: "style_advice", label: "Style advice", symbol: "🎨"),
    ]

    static func find(_ id: String?) -> SpatterSuggestedPrompt? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
    var chipTitle: String { "\(symbol) \(label)" }
}

/// Spatter plan as reported by the server. Never derived on the device.
enum SpatterPlanTier: String, Equatable {
    case free, creator, pro
    /// Bring-your-own AI key is available on the paid plans (owner decision 2026-10-14).
    var allowsOwnKey: Bool { self != .free }
}

/// Server-reported Spatter allowance from `sdi_spatter_my_usage` or a metered
/// reply's `allowance`. Display data only: the server decides every prompt.
struct SpatterAllowance: Equatable {
    let plan: SpatterPlanTier
    /// Nil for Pro (unlimited by plan) or when the server did not send it.
    let remaining: Int?
    let limit: Int?
    let resetsAt: Date?
    /// Spatter credit balance (1 credit = 1 prompt); nil when the server did not report one.
    var credits: Int? = nil

    var suggestedPromptsOnly: Bool { plan == .free }
    var hasCredits: Bool { (credits ?? 0) > 0 }
    /// Free has no plan allowance (owner decision 2026-10-15) and pays as it goes
    /// with credits; Creator falls through to credits after its allowance.
    var isExhausted: Bool {
        switch plan {
        case .free: return !hasCredits
        case .creator: return remaining == 0 && !hasCredits
        case .pro: return false
        }
    }

    private static func day(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    var displayText: String {
        let creditLine = credits.map { $0 > 0 ? " Credits: \($0)." : "" } ?? ""
        return planText + creditLine
    }

    private var planText: String {
        switch plan {
        case .pro:
            return "Pro: unlimited Spatter prompts."
        case .creator:
            guard let remaining else { return "Creator: remaining prompts appear once the server reports them." }
            let of = limit.map { " of \($0)" } ?? ""
            return "Creator: \(remaining)\(of) Spatter prompts left this billing period."
        case .free:
            return hasCredits ? "Free: pay as you go with Spatter credits." : "Free: Spatter answers need Creator, Pro or credits."
        }
    }

    /// Shown when the allowance is used up; nil while prompts remain.
    var lockoutText: String? {
        guard isExhausted else { return nil }
        let reset = Self.day(resetsAt)
        switch plan {
        case .free:
            return "Spatter is part of Creator and Pro. Upgrade in Profile, Plans to activate it, or buy Spatter credits there to pay as you go. Creator also lets you use your own AI key."
        case .creator:
            return "You've used this billing period's Spatter allowance. It resets"
                + (reset.map { " on \($0)" } ?? " at renewal")
                + ". Buy Spatter credits to keep going, upgrade to Pro for unlimited prompts, or add your own AI key."
        case .pro:
            return nil
        }
    }

    /// Strict decode of `public.sdi_spatter_my_usage()`. An error object or an
    /// unknown plan is not an allowance; a count is never invented.
    static func decodeUsage(_ data: Data) throws -> SpatterAllowance {
        struct Usage: Decodable {
            let plan: String?
            let unlimited: Bool?
            let limit: Int?
            let remaining: Int?
            let resets_at: String?
            let credits: Int?
            let error: String?
        }
        guard data.count <= 16_384, let usage = try? JSONDecoder().decode(Usage.self, from: data),
              usage.error == nil, let raw = usage.plan, let plan = SpatterPlanTier(rawValue: raw) else {
            throw SpatterClientError.invalidResponse
        }
        return make(plan: plan, remaining: usage.remaining, limit: usage.limit, resetsAt: usage.resets_at, credits: usage.credits)
    }

    static func make(plan: SpatterPlanTier, remaining: Int?, limit: Int?, resetsAt: String?, credits: Int? = nil) -> SpatterAllowance {
        func sane(_ value: Int?) -> Int? { value.flatMap { (0...1_000_000).contains($0) ? $0 : nil } }
        let date = resetsAt.flatMap { value -> Date? in
            let plain = ISO8601DateFormatter()
            if let parsed = plain.date(from: value) { return parsed }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: value)
        }
        if plan == .pro { return SpatterAllowance(plan: .pro, remaining: nil, limit: nil, resetsAt: nil) }
        return SpatterAllowance(plan: plan, remaining: sane(remaining), limit: sane(limit), resetsAt: date, credits: sane(credits))
    }
}

/// One decoded provider-neutral reply. `schemaVersion` 0 marks the legacy
/// choices-shaped response; `units` is the backend's own usage count, if sent.
/// `allowance` is the metered plan allowance the server reported, and
/// `viaOwnKey` marks a reply that went device-to-provider with the member's own
/// AI key and was not counted against the plan.
struct SpatterCloudReply: Equatable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let reply: String
    let usageUnits: Int?
    let budget: SpatterBudget?
    var allowance: SpatterAllowance? = nil
    var viaOwnKey: Bool = false
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

    /// Legacy convenience: the reply text only. Budget is dropped here.
    func complete(messages: [SpatterChatMessage]) async throws -> String {
        try await completeReply(messages: messages).reply
    }

    /// Request contract (schemaVersion 1): {schemaVersion, messages, max_tokens, temperature}.
    /// Response contract: {schemaVersion, reply, usage:{units}, budget:{remaining, resetsAt}}
    /// or the legacy {choices:[{message:{content}}]} shape. Unknown fields are ignored;
    /// an unsupported future schemaVersion is an invalid response, never a guess.
    func completeReply(messages: [SpatterChatMessage], suggestedPromptID: String? = nil) async throws -> SpatterCloudReply {
        try Task.checkCancellation()
        if let suggestedPromptID, SpatterSuggestedPrompt.find(suggestedPromptID) == nil {
            throw SpatterClientError.invalidRequest
        }
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
            let schemaVersion = SpatterCloudReply.currentSchemaVersion
            let messages: [SpatterChatMessage]
            let suggestedPromptId: String?
            let max_tokens = 500
            let temperature = 0.8
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(Payload(messages: messages, suggestedPromptId: suggestedPromptID))
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
        return try Self.decodeReply(data)
    }

    /// Pure decode of both accepted response shapes. Exposed for tests and for
    /// any future transport that shares the same contract.
    static func decodeReply(_ data: Data) throws -> SpatterCloudReply {
        struct Versioned: Decodable {
            struct Usage: Decodable { let units: Int? }
            struct Budget: Decodable { let remaining: Int?; let resetsAt: String? }
            struct Allowance: Decodable { let plan: String?; let remaining: Int?; let resetsAt: String?; let credits: Int? }
            let schemaVersion: Int
            let reply: String?
            let usage: Usage?
            let budget: Budget?
            let allowance: Allowance?
        }
        struct Legacy: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        func nonEmpty(_ text: String?) throws -> String {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpatterClientError.emptyResponse
            }
            return text
        }
        let decoder = JSONDecoder()
        if let versioned = try? decoder.decode(Versioned.self, from: data) {
            guard versioned.schemaVersion == SpatterCloudReply.currentSchemaVersion else {
                throw SpatterClientError.invalidResponse
            }
            let reply = try nonEmpty(versioned.reply)
            var budget: SpatterBudget?
            if let raw = versioned.budget {
                // A budget without a sane remaining count is dropped, not invented.
                if let remaining = raw.remaining, (0...1_000_000).contains(remaining) {
                    let formatter = ISO8601DateFormatter()
                    let resets = raw.resetsAt.flatMap { formatter.date(from: $0) }
                    budget = SpatterBudget(remaining: remaining, resetsAt: resets)
                }
            }
            let units = versioned.usage?.units.flatMap { (0...1_000_000_000).contains($0) ? $0 : nil }
            // A metered allowance with an unknown plan is dropped, not guessed.
            let allowance = versioned.allowance.flatMap { raw in
                raw.plan.flatMap(SpatterPlanTier.init(rawValue:)).map {
                    SpatterAllowance.make(plan: $0, remaining: raw.remaining, limit: nil, resetsAt: raw.resetsAt, credits: raw.credits)
                }
            }
            return SpatterCloudReply(schemaVersion: versioned.schemaVersion, reply: reply, usageUnits: units, budget: budget,
                                     allowance: allowance)
        }
        guard let legacy = try? decoder.decode(Legacy.self, from: data) else {
            throw SpatterClientError.invalidResponse
        }
        let content = try nonEmpty(legacy.choices.first?.message.content)
        return SpatterCloudReply(schemaVersion: 0, reply: content, usageUnits: nil, budget: nil)
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
