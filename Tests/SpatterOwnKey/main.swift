import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Standalone suite for the Spatter plan rules on the device (#209, owner
// decisions 2026-10-14): suggested-prompt catalogue, server-reported allowance
// decoding, Free lockout copy, the backend request's suggestedPromptId, and the
// bring-your-own-key credential, store and direct provider client.
// Every transport is a fake. No socket is opened and no provider is called;
// the "keys" are random markers that must never appear in output or errors.

private struct TestFailure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message: message) }
}

private final class FakeTransport {
    var requests: [URLRequest] = []
    var result: Result<(Data, HTTPURLResponse), Error>
    init(_ result: Result<(Data, HTTPURLResponse), Error>) { self.result = result }
    func callAsFunction(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try result.get()
    }
}

private struct LeakyError: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct SpatterOwnKeyTests {
    static var passed = 0
    static let openAIKey = "sk-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static let anthropicKey = "sk-ant-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    static func http(_ code: Int = 200, url: URL, mime: String = "application/json") -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
    }
    static func test(_ name: String, _ body: () async throws -> Void) async throws {
        try await body()
        passed += 1
        print("PASS \(name)")
    }
    static func expectOwnKey(_ expected: SpatterOwnKeyError, _ body: () async throws -> Void) async throws {
        do { try await body(); throw TestFailure(message: "expected \(expected)") }
        catch let error as SpatterOwnKeyError { try require(error == expected, "got \(error), expected \(expected)") }
    }
    static func json(_ data: Data?) throws -> [String: Any] {
        guard let data, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(message: "body is not a JSON object")
        }
        return object
    }

    static func main() async {
        do {
            try await test("suggested prompt catalogue matches the server allowlist ids and labels") {
                try require(SpatterSuggestedPrompt.all.map(\.id) == ["animation_tips", "scene_ideas", "fight_choreography", "style_advice"], "ids changed")
                try require(SpatterSuggestedPrompt.all.map(\.label) == ["Animation tips", "Scene ideas", "Fight choreography", "Style advice"], "labels changed")
                try require(SpatterSuggestedPrompt.find("scene_ideas")?.chipTitle == "🎬 Scene ideas", "chip title")
                try require(SpatterSuggestedPrompt.find("write my essay") == nil && SpatterSuggestedPrompt.find(nil) == nil, "unknown id found")
            }

            try await test("own key is a paid-plan feature only") {
                try require(!SpatterPlanTier.free.allowsOwnKey && SpatterPlanTier.creator.allowsOwnKey && SpatterPlanTier.pro.allowsOwnKey,
                            "own key plan gate")
            }

            try await test("server usage decodes strictly and never invents a count") {
                let free = try SpatterAllowance.decodeUsage(Data("""
                {"plan":"free","unlimited":false,"limit":5,"used":2,"remaining":3,"period":"calendar_month","resets_at":"2026-11-01T00:00:00+00:00","suggested_prompts_only":true,"service":"metered"}
                """.utf8))
                try require(free.plan == .free && free.remaining == 3 && free.limit == 5 && free.suggestedPromptsOnly, "free usage")
                try require(free.resetsAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"), "reset date")
                try require(free.displayText == "Free: Spatter answers need Creator or Pro." && free.isExhausted
                            && free.lockoutText?.contains("Creator and Pro") == true, "free copy")
                let pro = try SpatterAllowance.decodeUsage(Data("{\"plan\":\"pro\",\"unlimited\":true,\"limit\":null,\"remaining\":null}".utf8))
                try require(pro.plan == .pro && pro.remaining == nil && !pro.isExhausted && pro.displayText.contains("unlimited"), "pro usage")
                let creator = try SpatterAllowance.decodeUsage(Data("{\"plan\":\"creator\",\"limit\":15,\"remaining\":0,\"resets_at\":\"2026-11-20T10:00:00.123+00:00\"}".utf8))
                try require(creator.isExhausted && creator.resetsAt != nil && creator.lockoutText?.contains("Upgrade to Pro") == true
                            && creator.lockoutText?.contains("own AI key") == true, "creator lockout")
                let noCount = try SpatterAllowance.decodeUsage(Data("{\"plan\":\"creator\",\"remaining\":-2}".utf8))
                try require(noCount.remaining == nil && !noCount.isExhausted && noCount.displayText.contains("once the server reports"), "negative count accepted")
                for bad in ["{\"error\":\"Sign in to view your Spatter allowance.\"}", "{\"plan\":\"gold\"}", "[]", "nope"] {
                    do { _ = try SpatterAllowance.decodeUsage(Data(bad.utf8)); throw TestFailure(message: "accepted \(bad)") }
                    catch let error as SpatterClientError { try require(error == .invalidResponse, "wrong error") }
                }
            }

            try await test("free always shows the upgrade note; creator lockout says when it resets") {
                let free = SpatterAllowance(plan: .free, remaining: nil, limit: nil, resetsAt: nil)
                try require(free.isExhausted && free.lockoutText?.contains("Upgrade in Profile") == true, "free upgrade note")
                let reset = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")
                let used = SpatterAllowance(plan: .creator, remaining: 0, limit: 174, resetsAt: reset)
                guard let text = used.lockoutText else { throw TestFailure(message: "no lockout") }
                try require(text.contains("resets on") && text.contains("Upgrade to Pro"), "lockout copy: \(text)")
                let unknownReset = SpatterAllowance(plan: .creator, remaining: 0, limit: 174, resetsAt: nil)
                try require(unknownReset.lockoutText?.contains("at renewal") == true, "reset fallback")
            }

            try await test("metered reply carries the allowance; unknown plans are dropped") {
                let reply = try SpatterBackendClient.decodeReply(Data("""
                {"schemaVersion":1,"reply":"tips","usage":{"units":3},"allowance":{"plan":"free","period":"calendar_month","remaining":4,"resetsAt":"2026-11-01T00:00:00Z"}}
                """.utf8))
                try require(reply.allowance == SpatterAllowance(plan: .free, remaining: 4, limit: nil,
                                                                resetsAt: ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")), "allowance decode")
                try require(!reply.viaOwnKey && reply.budget == nil, "metered reply flags")
                let unknown = try SpatterBackendClient.decodeReply(Data("{\"schemaVersion\":1,\"reply\":\"x\",\"allowance\":{\"plan\":\"vip\",\"remaining\":3}}".utf8))
                try require(unknown.allowance == nil, "unknown plan accepted")
            }

            try await test("backend request carries a known suggestedPromptId and refuses an unknown one") {
                let url = URL(string: "https://backend.example/chat")!
                let fake = FakeTransport(.success((Data("{\"schemaVersion\":1,\"reply\":\"ok\"}".utf8), http(url: url))))
                let client = SpatterBackendClient(endpoint: { url }, sessionToken: { "session-token" }, transport: { try await fake($0) })
                _ = try await client.completeReply(messages: [.init(role: .user, content: "Scene ideas")], suggestedPromptID: "scene_ideas")
                try require(try json(fake.requests.last?.httpBody)["suggestedPromptId"] as? String == "scene_ideas", "id not sent")
                _ = try await client.completeReply(messages: [.init(role: .user, content: "free text")])
                try require(try json(fake.requests.last?.httpBody)["suggestedPromptId"] == nil, "id invented for free text")
                do {
                    _ = try await client.completeReply(messages: [.init(role: .user, content: "x")], suggestedPromptID: "made_up")
                    throw TestFailure(message: "unknown id sent")
                } catch let error as SpatterClientError { try require(error == .invalidRequest, "wrong error") }
                try require(fake.requests.count == 2, "unknown id reached the transport")
            }

            try await test("credential validation checks provider shape and model names") {
                let openAI = try SpatterOwnKeyCredential.validated(provider: .openAI, model: " chat-model-1 ", key: " \(openAIKey) ")
                try require(openAI.key == openAIKey && openAI.model == "chat-model-1", "trimmed")
                _ = try SpatterOwnKeyCredential.validated(provider: .anthropic, model: "model.v2:latest", key: anthropicKey)
                let invalidKeys: [(SpatterOwnKeyProvider, String)] = [
                    (.openAI, anthropicKey), (.anthropic, openAIKey), (.openAI, "sk-short"),
                    (.openAI, "sk-" + String(repeating: "a", count: 600)), (.openAI, "sk-abc def ghi jkl mno pqr"), (.openAI, "sk-ключключключключключ"),
                ]
                for (provider, key) in invalidKeys {
                    await expectInvalidKey { try SpatterOwnKeyCredential.validated(provider: provider, model: "m", key: key) }
                }
                for model in ["", " ", "-leading", "has space", "a/b", String(repeating: "m", count: 129), "модель"] {
                    try await expectOwnKey(.invalidModel) { _ = try SpatterOwnKeyCredential.validated(provider: .openAI, model: model, key: openAIKey) }
                }
            }

            try await test("the key never appears in descriptions, mirrors or dumps") {
                let credential = try SpatterOwnKeyCredential.validated(provider: .openAI, model: "m1", key: openAIKey)
                var dumped = ""
                dump(credential, to: &dumped)
                for text in [String(describing: credential), String(reflecting: credential), "\(credential)", dumped] {
                    try require(!text.contains(openAIKey) && text.contains("<redacted>"), "key leaked: \(text)")
                }
                for error in [SpatterOwnKeyError.invalidKey, .rejectedKey, .providerUnavailable, .storageFailed] {
                    try require(!(error.errorDescription ?? "").contains("sk-"), "error mentions key material")
                }
            }

            try await test("own-key store is account-scoped with add, replace and remove") {
                let store = InMemorySpatterOwnKeyStore()
                let a = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
                let b = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                let first = try SpatterOwnKeyCredential.validated(provider: .openAI, model: "m1", key: openAIKey)
                let second = try SpatterOwnKeyCredential.validated(provider: .anthropic, model: "m2", key: anthropicKey)
                try store.save(first, account: a)
                try require(try store.load(account: a.lowercased()) == first && store.load(account: b) == nil, "scoping")
                try store.save(second, account: a)
                try require(try store.load(account: a) == second, "replace")
                try store.remove(account: a)
                try require(try store.load(account: a) == nil, "remove")
                for bad in [nil, "", "guest account", "../x", String(repeating: "a", count: 200)] as [String?] {
                    try await expectOwnKey(.invalidAccount) { _ = try SpatterOwnKeyAccount.validated(bad) }
                }
                store.failSaves = true
                try await expectOwnKey(.storageFailed) { try store.save(first, account: a) }
            }

            try await test("OpenAI request goes only to the fixed endpoint with the key in one header") {
                let credential = try SpatterOwnKeyCredential.validated(provider: .openAI, model: "m1", key: openAIKey)
                let messages: [SpatterChatMessage] = [.init(role: .system, content: "be brief"), .init(role: .user, content: "timing?")]
                let request = try SpatterDirectProviderClient.makeRequest(messages: messages, credential: credential)
                try require(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions" && request.httpMethod == "POST", "endpoint")
                try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(openAIKey)", "auth header")
                let body = try json(request.httpBody)
                try require(body["model"] as? String == "m1" && body["max_completion_tokens"] as? Int == 800, "body fields")
                try require((body["messages"] as? [[String: Any]])?.count == 2, "messages")
                try require(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(openAIKey), "key in body")
                try require(request.timeoutInterval == 30, "timeout")
            }

            try await test("Anthropic request splits the system prompt and starts with the user") {
                let credential = try SpatterOwnKeyCredential.validated(provider: .anthropic, model: "m2", key: anthropicKey)
                let messages: [SpatterChatMessage] = [.init(role: .system, content: "persona"), .init(role: .assistant, content: "stale"),
                                                      .init(role: .user, content: "q1"), .init(role: .assistant, content: "a1"), .init(role: .user, content: "q2")]
                let request = try SpatterDirectProviderClient.makeRequest(messages: messages, credential: credential)
                try require(request.url?.absoluteString == "https://api.anthropic.com/v1/messages", "endpoint")
                try require(request.value(forHTTPHeaderField: "x-api-key") == anthropicKey && request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "headers")
                try require(request.value(forHTTPHeaderField: "Authorization") == nil, "unexpected auth header")
                let body = try json(request.httpBody)
                let turns = body["messages"] as? [[String: Any]] ?? []
                try require(body["system"] as? String == "persona" && turns.count == 3 && turns.first?["role"] as? String == "user", "turns")
                try require(body["max_tokens"] as? Int == 800, "max tokens")
            }

            try await test("oversized or malformed conversations never reach the transport") {
                let credential = try SpatterOwnKeyCredential.validated(provider: .openAI, model: "m1", key: openAIKey)
                let fake = FakeTransport(.failure(TestFailure(message: "must not be called")))
                let client = SpatterDirectProviderClient(transport: { try await fake($0) })
                let huge = Array(repeating: SpatterChatMessage(role: .user, content: String(repeating: "x", count: 30_000)), count: 6)
                for messages in [[], huge, [SpatterChatMessage(role: .assistant, content: "last is not user")]] {
                    try await expectOwnKey(.requestTooLarge) { _ = try await client.complete(messages: messages, credential: credential) }
                }
                try require(fake.requests.isEmpty, "transport called")
            }

            try await test("successful own-key replies are marked and not metered") {
                let openAI = try SpatterOwnKeyCredential.validated(provider: .openAI, model: "m1", key: openAIKey)
                let url = openAI.provider.endpoint
                let fake = FakeTransport(.success((Data("{\"choices\":[{\"message\":{\"content\":\"hold two frames\"},\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":42}}".utf8), http(url: url))))
                let reply = try await SpatterDirectProviderClient(transport: { try await fake($0) })
                    .complete(messages: [.init(role: .user, content: "timing?")], credential: openAI)
                try require(reply.reply == "hold two frames" && reply.usageUnits == 42 && reply.viaOwnKey && reply.allowance == nil && reply.budget == nil, "openai reply")
                let anthropic = try SpatterOwnKeyCredential.validated(provider: .anthropic, model: "m2", key: anthropicKey)
                fake.result = .success((Data("{\"content\":[{\"type\":\"text\",\"text\":\"ease \"},{\"type\":\"text\",\"text\":\"in\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}".utf8), http(url: anthropic.provider.endpoint)))
                let second = try await SpatterDirectProviderClient(transport: { try await fake($0) })
                    .complete(messages: [.init(role: .user, content: "q")], credential: anthropic)
                try require(second.reply == "ease in" && second.usageUnits == 15 && second.viaOwnKey, "anthropic reply")
            }

            try await test("provider failures map to key-free errors") {
                let credential = try SpatterOwnKeyCredential.validated(provider: .openAI, model: "m1", key: openAIKey)
                let url = credential.provider.endpoint
                let cases: [(Result<(Data, HTTPURLResponse), Error>, SpatterOwnKeyError)] = [
                    (.failure(SpatterClientError.httpStatus(401)), .rejectedKey),
                    (.failure(SpatterClientError.httpStatus(403)), .rejectedKey),
                    (.failure(SpatterClientError.httpStatus(429)), .rateLimited),
                    (.failure(SpatterClientError.httpStatus(404)), .requestRejected),
                    (.failure(SpatterClientError.httpStatus(302)), .providerUnavailable),
                    (.failure(SpatterClientError.httpStatus(503)), .providerUnavailable),
                    (.failure(SpatterClientError.responseTooLarge), .responseTooLarge),
                    (.failure(LeakyError(description: "TLS failed for key " + openAIKey)), .providerUnavailable),
                    (.success((Data("{}".utf8), http(500, url: url))), .providerUnavailable),
                    (.success((Data("<html>".utf8), http(url: url, mime: "text/html"))), .invalidResponse),
                    (.success((Data("{\"choices\":[]}".utf8), http(url: url))), .invalidResponse),
                    (.success((Data("{\"choices\":[{\"message\":{\"content\":null,\"refusal\":\"no\"}}]}".utf8), http(url: url))), .refused),
                    (.success((Data("{\"choices\":[{\"message\":{\"content\":\"  \"}}]}".utf8), http(url: url))), .emptyResponse),
                    (.success((Data(repeating: 65, count: 140_000), http(url: url))), .responseTooLarge),
                ]
                for (result, expected) in cases {
                    let fake = FakeTransport(result)
                    do {
                        _ = try await SpatterDirectProviderClient(transport: { try await fake($0) })
                            .complete(messages: [.init(role: .user, content: "q")], credential: credential)
                        throw TestFailure(message: "expected \(expected)")
                    } catch let error as SpatterOwnKeyError {
                        try require(error == expected, "got \(error), expected \(expected)")
                        try require(!(error.errorDescription ?? "").contains(openAIKey) && !String(describing: error).contains(openAIKey), "key in error")
                    }
                }
                let anthropic = try SpatterOwnKeyCredential.validated(provider: .anthropic, model: "m2", key: anthropicKey)
                let refusal = FakeTransport(.success((Data("{\"content\":[],\"stop_reason\":\"refusal\"}".utf8), http(url: anthropic.provider.endpoint))))
                try await expectOwnKey(.refused) {
                    _ = try await SpatterDirectProviderClient(transport: { try await refusal($0) })
                        .complete(messages: [.init(role: .user, content: "q")], credential: anthropic)
                }
            }

            try await test("own-key errors are user-facing to the conversation coordinator") {
                let error: Error = SpatterOwnKeyError.rejectedKey
                try require((error as? SpatterUserFacingError)?.errorDescription == SpatterOwnKeyError.rejectedKey.errorDescription, "not user-facing")
            }

            print("SpatterOwnKey: \(passed) passed")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }

    /// Invalid keys must throw `.invalidKey`.
    static func expectInvalidKey(_ body: () throws -> SpatterOwnKeyCredential) async {
        do { _ = try body(); print("FAIL invalid key accepted"); exit(1) }
        catch let error as SpatterOwnKeyError where error == .invalidKey { return }
        catch { print("FAIL wrong error for invalid key"); exit(1) }
    }
}
