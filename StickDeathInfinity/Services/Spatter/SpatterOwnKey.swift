import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ═══════════════════════════════════════════════════════════════════
// Spatter bring-your-own AI key (#209, owner decision 2026-10-14)
//
// Creator (USD 4.99) and Pro (USD 9.99) members may use their own AI provider
// key. The key:
// - is stored only on this device, in the Keychain, as
//   kSecAttrAccessibleWhenUnlockedThisDeviceOnly and never synchronizable
//   (SpatterOwnKeyKeychain.swift), scoped to the signed-in account;
// - is sent only to the fixed provider endpoint below, directly from the
//   device, and never to the StickDeath backend;
// - never appears in errors, descriptions, mirrors or logs.
// Requests sent with an own key do not count against the monthly allowance;
// without one the normal server-metered path is used.
//
// Foundation only so Tests/SpatterOwnKey compiles it on Linux with a fake
// transport. No test makes a network call.
// ═══════════════════════════════════════════════════════════════════

/// Providers the member can choose. Limited to the hosts the provider-neutral
/// transport already models (SpatterEndpoint refuses them as backends) with a
/// documented key-based chat API. Endpoints are fixed constants: no
/// member-supplied URL can receive the key.
enum SpatterOwnKeyProvider: String, CaseIterable, Codable, Identifiable, Equatable {
    case openAI = "openai"
    case anthropic

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }
    var endpoint: URL {
        switch self {
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/messages")!
        }
    }
    /// Shape check only; the provider decides whether a key is valid.
    var keyPrefix: String {
        switch self {
        case .openAI: return "sk-"
        case .anthropic: return "sk-ant-"
        }
    }
    var modelHint: String {
        "Enter a chat model name your \(displayName) account can use, exactly as \(displayName) lists it."
    }
}

enum SpatterOwnKeyError: Error, SpatterUserFacingError, Equatable {
    case invalidKey, invalidModel, invalidAccount, planNotEligible
    case storageFailed, requestTooLarge
    case rejectedKey, rateLimited, requestRejected, providerUnavailable
    case invalidResponse, responseTooLarge, refused, emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "That doesn't look like a key for the selected provider. Nothing was saved."
        case .invalidModel: return "Enter a model name using letters, numbers, dots, dashes, underscores or colons (up to 128 characters)."
        case .invalidAccount: return "Sign in to manage your own AI key."
        case .planNotEligible: return "Your own AI key is available on the Creator and Pro plans."
        case .storageFailed: return "The key could not be saved to or read from this device's Keychain."
        case .requestTooLarge: return "This conversation is too large to send. Shorten it and try again."
        case .rejectedKey: return "Your AI provider rejected the saved key. Replace or remove it in Spatter settings."
        case .rateLimited: return "Your AI provider is rate-limiting this key. Try again later."
        case .requestRejected: return "Your AI provider rejected the request. Check the model name in Spatter settings."
        case .providerUnavailable: return "Your AI provider could not be reached. Try again later."
        case .invalidResponse: return "Your AI provider returned a response Spatter could not read."
        case .responseTooLarge: return "Your AI provider's response exceeded the size limit."
        case .refused: return "Your AI provider declined to answer this request."
        case .emptyResponse: return "Your AI provider returned no answer."
        }
    }
}

/// A validated own-key configuration. The key is redacted from every textual
/// and reflective representation so it cannot reach a log by accident.
struct SpatterOwnKeyCredential: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let provider: SpatterOwnKeyProvider
    let model: String
    let key: String

    static let maxKeyLength = 512
    static let minKeyLength = 20

    static func validated(provider: SpatterOwnKeyProvider, model: String, key: String) throws -> SpatterOwnKeyCredential {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (minKeyLength...maxKeyLength).contains(key.utf8.count),
              key.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              key.hasPrefix(provider.keyPrefix),
              // An Anthropic key pasted under OpenAI is a mistake, not an OpenAI key.
              provider != .openAI || !key.hasPrefix(SpatterOwnKeyProvider.anthropic.keyPrefix) else {
            throw SpatterOwnKeyError.invalidKey
        }
        guard isValidModel(model) else { throw SpatterOwnKeyError.invalidModel }
        return SpatterOwnKeyCredential(provider: provider, model: model, key: key)
    }

    static func isValidModel(_ model: String) -> Bool {
        guard (1...128).contains(model.utf8.count), let first = model.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        return model.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    var description: String { "SpatterOwnKeyCredential(provider: \(provider.rawValue), model: \(model), key: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["provider": provider, "model": model, "key": "<redacted>"], displayStyle: .struct)
    }
}

/// Account-scoped own-key storage. The production store is the Keychain.
protocol SpatterOwnKeyStore {
    func load(account: String) throws -> SpatterOwnKeyCredential?
    func save(_ credential: SpatterOwnKeyCredential, account: String) throws
    func remove(account: String) throws
}

enum SpatterOwnKeyAccount {
    /// Only a signed-in account id may own a key; guests and malformed ids may not.
    static func validated(_ account: String?) throws -> String {
        guard let account = account?.lowercased(), (1...128).contains(account.utf8.count),
              account.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }) else {
            throw SpatterOwnKeyError.invalidAccount
        }
        return account
    }
}

/// Test and preview store. Never used for a real key in the app.
final class InMemorySpatterOwnKeyStore: SpatterOwnKeyStore {
    private var items: [String: SpatterOwnKeyCredential] = [:]
    var failSaves = false
    func load(account: String) throws -> SpatterOwnKeyCredential? { items[try SpatterOwnKeyAccount.validated(account)] }
    func save(_ credential: SpatterOwnKeyCredential, account: String) throws {
        if failSaves { throw SpatterOwnKeyError.storageFailed }
        items[try SpatterOwnKeyAccount.validated(account)] = credential
    }
    func remove(account: String) throws { items[try SpatterOwnKeyAccount.validated(account)] = nil }
}

/// Minimal, bounded direct client for the member's own provider. The default
/// transport is `BoundedSpatterRequest` (ephemeral session, no cache, no
/// cookies, no redirects, 30 s request / 45 s resource timeouts, 128 KiB
/// response cap). Errors are `SpatterOwnKeyError` values that never carry the key.
@MainActor
struct SpatterDirectProviderClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let requestLimit = 128 * 1024
    static let responseLimit = 128 * 1024
    static let anthropicVersion = "2023-06-01"
    static let maxOutputTokens = 800
    let transport: Transport

    init(transport: @escaping Transport = { request in try await BoundedSpatterRequest(request: request).run() }) {
        self.transport = transport
    }

    static func makeRequest(messages: [SpatterChatMessage], credential: SpatterOwnKeyCredential) throws -> URLRequest {
        guard !messages.isEmpty, messages.count <= 41, messages.last?.role == .user,
              messages.allSatisfy({ !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.content.utf8.count <= 32_768 }) else {
            throw SpatterOwnKeyError.requestTooLarge
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var request = URLRequest(url: credential.provider.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: Data
        switch credential.provider {
        case .openAI:
            struct Payload: Encodable {
                let model: String
                let messages: [SpatterChatMessage]
                let max_completion_tokens: Int
            }
            body = try encoder.encode(Payload(model: credential.model, messages: messages, max_completion_tokens: maxOutputTokens))
            request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            struct Turn: Encodable { let role: String; let content: String }
            struct Payload: Encodable {
                let model: String
                let max_tokens: Int
                let system: String?
                let messages: [Turn]
            }
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            var turns = messages.filter { $0.role != .system }.map { Turn(role: $0.role.rawValue, content: $0.content) }
            // The Messages API needs a conversation that starts with the user.
            while turns.first?.role == "assistant" { turns.removeFirst() }
            guard !turns.isEmpty else { throw SpatterOwnKeyError.requestTooLarge }
            body = try encoder.encode(Payload(model: credential.model, max_tokens: maxOutputTokens,
                                              system: system.isEmpty ? nil : system, messages: turns))
            request.setValue(credential.key, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
        guard body.count <= requestLimit else { throw SpatterOwnKeyError.requestTooLarge }
        request.httpBody = body
        return request
    }

    /// Decode one provider reply into (text, usage units). Refusals and empty
    /// answers are errors, never an invented reply.
    static func decode(_ data: Data, provider: SpatterOwnKeyProvider) throws -> (String, Int?) {
        guard data.count <= responseLimit else { throw SpatterOwnKeyError.responseTooLarge }
        let decoder = JSONDecoder()
        switch provider {
        case .openAI:
            struct Response: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String?; let refusal: String? }
                    let message: Message
                    let finish_reason: String?
                }
                struct Usage: Decodable { let total_tokens: Int? }
                let choices: [Choice]
                let usage: Usage?
            }
            guard let response = try? decoder.decode(Response.self, from: data), let choice = response.choices.first else {
                throw SpatterOwnKeyError.invalidResponse
            }
            if choice.message.refusal != nil || choice.finish_reason == "content_filter" { throw SpatterOwnKeyError.refused }
            guard let text = choice.message.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpatterOwnKeyError.emptyResponse
            }
            return (text, response.usage?.total_tokens)
        case .anthropic:
            struct Response: Decodable {
                struct Block: Decodable { let type: String; let text: String? }
                struct Usage: Decodable { let input_tokens: Int?; let output_tokens: Int? }
                let content: [Block]
                let stop_reason: String?
                let usage: Usage?
            }
            guard let response = try? decoder.decode(Response.self, from: data) else { throw SpatterOwnKeyError.invalidResponse }
            if response.stop_reason == "refusal" { throw SpatterOwnKeyError.refused }
            let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpatterOwnKeyError.emptyResponse }
            let units = response.usage.map { ($0.input_tokens ?? 0) + ($0.output_tokens ?? 0) }
            return (text, units)
        }
    }

    func complete(messages: [SpatterChatMessage], credential: SpatterOwnKeyCredential) async throws -> SpatterCloudReply {
        try Task.checkCancellation()
        let request = try Self.makeRequest(messages: messages, credential: credential)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch SpatterClientError.httpStatus(let code) { throw Self.classify(status: code) }
        catch SpatterClientError.responseTooLarge { throw SpatterOwnKeyError.responseTooLarge }
        catch SpatterClientError.invalidResponse { throw SpatterOwnKeyError.invalidResponse }
        // Any other transport error is reported generically; its text is never surfaced.
        catch { throw SpatterOwnKeyError.providerUnavailable }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw Self.classify(status: response.statusCode) }
        guard response.mimeType?.lowercased() == "application/json" else { throw SpatterOwnKeyError.invalidResponse }
        let (text, units) = try Self.decode(data, provider: credential.provider)
        let reply = text.utf8.count > 32_768 ? String(decoding: Data(text.utf8.prefix(32_768)), as: UTF8.self) : text
        return SpatterCloudReply(schemaVersion: SpatterCloudReply.currentSchemaVersion, reply: reply,
                                 usageUnits: units.flatMap { (0...1_000_000_000).contains($0) ? $0 : nil },
                                 budget: nil, allowance: nil, viaOwnKey: true)
    }

    static func classify(status: Int) -> SpatterOwnKeyError {
        switch status {
        case 401, 403: return .rejectedKey
        case 429: return .rateLimited
        case 400, 404, 413, 422: return .requestRejected
        default: return .providerUnavailable
        }
    }
}
