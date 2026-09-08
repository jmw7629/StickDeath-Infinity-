import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct TestFailure: Error { let message: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure(message: message) }
}

/// Test-only network fixture. No sockets, providers, user tokens, or mirrored client logic.
private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path == "/stall" { return }
        let status = path == "/denied" ? 401 : 200
        var headers = ["Content-Type": "application/json"]
        if path == "/declared-large" { headers["Content-Length"] = "999999" }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/stream-large" {
            for _ in 0..<20 { client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 8192)) }
        } else if path == "/burst-large" {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 150_000))
        } else {
            client?.urlProtocol(self, didLoad: Data("{\"choices\":[{\"message\":{\"content\":\"draw a pose\"}}]}".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RedirectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false
    func set(_ request: URLRequest?) { lock.lock(); rejected = request == nil; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return rejected }
}

@main
@MainActor
struct SpatterClientTests {
    static let url = URL(string: "https://backend.example/chat")!
    static let message = [SpatterChatMessage(role: .user, content: "animate a step")]
    static let valid = Data("{\"choices\":[{\"message\":{\"content\":\"draw a pose\"}}]}".utf8)
    static var passed = 0

    static func http(_ code: Int = 200, mime: String = "application/json") -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
    }
    static func expect(_ expected: SpatterClientError, _ body: () async throws -> Void) async throws {
        do { try await body(); throw TestFailure(message: "expected error") }
        catch let error as SpatterClientError { try require(error == expected, "wrong error classification") }
    }
    static func test(_ name: String, _ body: () async throws -> Void) async throws {
        try await body()
        passed += 1
        print("PASS \(name)")
    }
    static func fixture(_ path: String) -> BoundedSpatterRequest {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return BoundedSpatterRequest(request: URLRequest(url: URL(string: "https://backend.example" + path)!), configuration: config)
    }

    /// Construct an unsigned, deliberately unusable legacy-key shape for local
    /// role-classification tests. No real project key is included in fixtures.
    static func legacyKey(role: String, issuer: String = "supabase", algorithm: String = "HS256") throws -> String {
        func encode(_ value: [String: String]) throws -> String {
            try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
                .base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return try encode(["alg": algorithm, "typ": "JWT"]) + "."
            + encode(["role": role, "iss": issuer]) + ".test_signature_not_valid"
    }

    static func main() async {
        do {
            try await test("Supabase requires both a valid URL and a public key") {
                let key = "sb_publishable_test_fixture_not_a_real_key"
                for values: [String: Any] in [[:], ["SUPABASE_URL": "https://project.example"], ["SUPABASE_PUBLISHABLE_KEY": key], ["SUPABASE_URL": 17, "SUPABASE_PUBLISHABLE_KEY": key], ["SUPABASE_URL": "$(SUPABASE_URL)", "SUPABASE_PUBLISHABLE_KEY": key]] {
                    try require(AppConfig.supabaseConfiguration(from: values) == nil, "incomplete config accepted")
                }
                let config = AppConfig.supabaseConfiguration(from: ["SUPABASE_URL": " https://project.example/ ", "SUPABASE_PUBLISHABLE_KEY": key])
                try require(config?.url.absoluteString == "https://project.example/" && config?.publishableKey == key, "public config not loaded")
            }
            try await test("Supabase rejects insecure or credential-bearing endpoints") {
                for endpoint in ["http://project.example", "file:///tmp/project", "/relative", "https://user:pass@project.example", "https://project.example?secret=value", "https://project.example/#token", "https://project.example:444", "https://project.example/rest/v1", "https://project.example/\npath", "https://pro ject.example"] {
                    try require(AppConfig.supabaseConfiguration(from: ["SUPABASE_URL": endpoint, "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_fixture"]) == nil, "unsafe Supabase endpoint accepted")
                }
            }
            try await test("Supabase permits publishable and legacy anon keys only") {
                let anon = try legacyKey(role: "anon")
                let config = ["SUPABASE_URL": "https://project.example", "SUPABASE_ANON_KEY": anon]
                try require(AppConfig.supabaseConfiguration(from: config)?.publishableKey == anon, "legacy anon compatibility missing")
                for key in ["sb_secret_fixture", "sb_publishable_", "sb_publishable_bad\nheader", "unrecognized", try legacyKey(role: "service_role"), try legacyKey(role: "authenticated"), try legacyKey(role: "anon", issuer: "untrusted"), try legacyKey(role: "anon", algorithm: "none"), "e30.e30.signature", String(repeating: "a", count: 8193)] {
                    try require(AppConfig.supabaseConfiguration(from: ["SUPABASE_URL": "https://project.example", "SUPABASE_PUBLISHABLE_KEY": key]) == nil, "privileged or malformed key accepted")
                }
            }
            try await test("explicit invalid primary key cannot fall back to a legacy key") {
                let anon = try legacyKey(role: "anon")
                let values = ["SUPABASE_URL": "https://project.example", "SUPABASE_PUBLISHABLE_KEY": "sb_secret_fixture", "SUPABASE_ANON_KEY": anon]
                try require(AppConfig.supabaseConfiguration(from: values) == nil, "invalid primary key bypassed")
                let unresolvedPrimary = ["SUPABASE_URL": "https://project.example", "SUPABASE_PUBLISHABLE_KEY": "$(SUPABASE_PUBLISHABLE_KEY)", "SUPABASE_ANON_KEY": anon]
                try require(AppConfig.supabaseConfiguration(from: unresolvedPrimary)?.publishableKey == anon, "optional unexpanded primary blocks explicit legacy config")
            }
            try await test("public configuration reads reflect changed or removed values") {
                var values = ["SUPABASE_URL": "https://one.example", "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_fixture"]
                try require(AppConfig.supabaseConfiguration(from: values)?.url.host == "one.example", "initial host")
                values["SUPABASE_URL"] = "https://two.example"
                try require(AppConfig.supabaseConfiguration(from: values)?.url.host == "two.example", "stale host")
                values.removeValue(forKey: "SUPABASE_PUBLISHABLE_KEY")
                try require(AppConfig.supabaseConfiguration(from: values) == nil, "removed config cached")
            }
            try await test("LiveKit requires a secure configured endpoint without credentials") {
                try require(AppConfig.liveKitWSURL(from: ["LIVEKIT_WS_URL": "wss://calls.example"])?.host == "calls.example", "secure LiveKit URL rejected")
                try require(AppConfig.liveKitWSURL(from: [:]) == nil, "missing LiveKit defaulted")
                for endpoint in ["", "$(LIVEKIT_WS_URL)", "${LIVEKIT_WS_URL}", "https://calls.example", "ws://calls.example", "wss://user:pass@calls.example", "wss://calls.example?token=test", "wss://calls.example#token", "wss://calls.example:7880", "wss://calls.example/\npath"] {
                    try require(AppConfig.liveKitWSURL(from: ["LIVEKIT_WS_URL": endpoint]) == nil, "unsafe LiveKit endpoint accepted")
                }
            }
            try await test("subscription family order is independent of prices") {
                let tiers = AppConfig.SubscriptionTier.allCases
                try require(tiers.map(\.rawValue) == ["free", "creator", "pro", "studio"], "existing product families changed")
                try require(tiers.map(\.rank) == [0, 1, 2, 3], "StoreKit selection order invalid")
                try require(AppConfig.SubscriptionTier(rawValue: "unknown") == nil, "invented product family")
            }
            try await test("configuration loads only public plist key") {
                try require(AppConfig.backendURL(from: [:]) == nil, "missing config")
                try require(AppConfig.backendURL(from: ["SPATTER_BACKEND_URL": 17]) == nil, "invalid config type")
                try require(AppConfig.backendURL(from: ["SPATTER_BACKEND_URL": url.absoluteString]) == url, "configured URL")
                try require(AppConfig.backendURL(from: ["SPATTER_BACKEND_URL": "$(SPATTER_BACKEND_URL)"]) == nil, "unexpanded build variable")
            }
            try await test("endpoint rejects credentials providers queries and insecure schemes") {
                for value in ["", "http://backend.example", "file:///tmp/test", "/relative", "https://user:pass@backend.example", "https://backend.example?key=secret", "https://backend.example/#token", "https://backend.example:444/", "https://api.openai.com/v1", "https://api.anthropic.com", "https://text.pollinations.ai", "https://generativelanguage.googleapis.com", "https://api.OpenAI.com./v1", "https://backend.example/\npath"] {
                    try require(SpatterEndpoint.url(from: value) == nil, "unsafe endpoint accepted")
                }
            }
            try await test("missing configuration makes zero auth and transport calls") {
                var authCalls = 0; var transportCalls = 0
                let client = SpatterBackendClient(endpoint: { nil }, sessionToken: { authCalls += 1; return "test-session" }, transport: { _ in transportCalls += 1; return (valid, http()) })
                try await expect(.notConfigured) { _ = try await client.complete(messages: message) }
                try require(authCalls == 0 && transportCalls == 0, "unexpected external call")
            }
            try await test("injected invalid URL makes zero auth and transport calls") {
                var calls = 0
                let client = SpatterBackendClient(endpoint: { URL(string: "http://backend.example") }, sessionToken: { calls += 1; return "test-session" }, transport: { _ in calls += 1; return (valid, http()) })
                try await expect(.invalidEndpoint) { _ = try await client.complete(messages: message) }
                try require(calls == 0, "invalid endpoint sent")
            }
            try await test("missing malformed and oversized sessions never reach transport") {
                var calls = 0
                for token: String? in [nil, "", " ", "test\r\nInjected:bad", String(repeating: "a", count: 16_385)] {
                    let client = SpatterBackendClient(endpoint: { url }, sessionToken: { token }, transport: { _ in calls += 1; return (valid, http()) })
                    try await expect(.notAuthenticated) { _ = try await client.complete(messages: message) }
                }
                try require(calls == 0, "invalid session sent")
            }
            try await test("session lookup failure is not configured or backend success") {
                let client = SpatterBackendClient(endpoint: { url }, sessionToken: { throw TestFailure(message: "session unavailable") }, transport: { _ in throw TestFailure(message: "transport called") })
                try await expect(.notAuthenticated) { _ = try await client.complete(messages: message) }
            }
            try await test("authenticated request carries token only in authorization header") {
                var calls = 0
                let client = SpatterBackendClient(endpoint: { url }, sessionToken: { "test-session" }, transport: { request in
                    calls += 1
                    try require(request.httpMethod == "POST" && request.url == url, "wrong request")
                    try require(request.timeoutInterval == 30, "unbounded timeout")
                    try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-session", "missing auth")
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    try require(Set(body.keys) == Set(["messages", "max_tokens", "temperature"]), "unexpected body field")
                    try require(!String(decoding: request.httpBody!, as: UTF8.self).contains("test-session"), "token in body")
                    return (valid, http())
                })
                let answer = try await client.complete(messages: message)
                try require(answer == "draw a pose" && calls == 1, "not actual backend reply")
            }
            try await test("changed configuration and session are read each request") {
                var endpoint = url; var token = "session-one"; var count = 0
                let client = SpatterBackendClient(endpoint: { endpoint }, sessionToken: { token }, transport: { request in
                    count += 1
                    try require(request.url == endpoint, "stale endpoint")
                    try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token, "stale token")
                    return (valid, http())
                })
                _ = try await client.complete(messages: message)
                endpoint = URL(string: "https://backend.example/second")!; token = "session-two"
                _ = try await client.complete(messages: message)
                try require(count == 2, "missing second request")
            }
            try await test("HTTP errors stay errors even with valid JSON body") {
                for code in [301, 401, 403, 429, 500] {
                    let client = SpatterBackendClient(endpoint: { url }, sessionToken: { "test-session" }, transport: { _ in (valid, http(code)) })
                    try await expect(.httpStatus(code)) { _ = try await client.complete(messages: message) }
                }
            }
            try await test("malformed response is distinguished from missing config") {
                for data in [Data(), Data("{}".utf8), Data("not json".utf8)] {
                    let client = SpatterBackendClient(endpoint: { url }, sessionToken: { "test-session" }, transport: { _ in (data, http()) })
                    try await expect(.invalidResponse) { _ = try await client.complete(messages: message) }
                }
            }
            try await test("empty choices and whitespace answer are truthful empty responses") {
                for text in ["{\"choices\":[]}", "{\"choices\":[{\"message\":{\"content\":\"   \"}}]}"] {
                    let client = SpatterBackendClient(endpoint: { url }, sessionToken: { "test-session" }, transport: { _ in (Data(text.utf8), http()) })
                    try await expect(.emptyResponse) { _ = try await client.complete(messages: message) }
                }
            }
            try await test("non JSON media type rejected") {
                let client = SpatterBackendClient(endpoint: { url }, sessionToken: { "test-session" }, transport: { _ in (valid, http(mime: "text/html")) })
                try await expect(.invalidResponse) { _ = try await client.complete(messages: message) }
            }
            try await test("invalid request count content and encoded bytes never transported") {
                var count = 0
                let client = SpatterBackendClient(endpoint: { url }, sessionToken: { "test-session" }, transport: { _ in count += 1; return (valid, http()) })
                for input in [[], [SpatterChatMessage(role: .user, content: " ")], Array(repeating: message[0], count: 42), [SpatterChatMessage(role: .user, content: String(repeating: "x", count: 32_769))], Array(repeating: SpatterChatMessage(role: .user, content: String(repeating: "x", count: 32_768)), count: 5)] {
                    try await expect(.invalidRequest) { _ = try await client.complete(messages: input) }
                }
                try require(count == 0, "oversized request sent")
            }
            try await test("oversized injected response is rejected") {
                let client = SpatterBackendClient(endpoint: { url }, sessionToken: { "test-session" }, transport: { _ in (Data(repeating: 65, count: 131_073), http()) })
                try await expect(.responseTooLarge) { _ = try await client.complete(messages: message) }
            }
            try await test("transport failure does not leak diagnostics") {
                let client = SpatterBackendClient(endpoint: { url }, sessionToken: { "test-session" }, transport: { _ in throw TestFailure(message: "private-transport-diagnostic") })
                try await expect(.networkUnavailable) { _ = try await client.complete(messages: message) }
                try require(!SpatterClientError.networkUnavailable.localizedDescription.contains("private-transport"), "leaked details")
            }
            try await test("actual delegate transport consumes fixture response") {
                let (data, response) = try await fixture("/ok").run()
                try require(data == valid && response.statusCode == 200, "delegate path failed")
            }
            try await test("actual delegate rejects declared oversized response") {
                try await expect(.responseTooLarge) { _ = try await fixture("/declared-large").run() }
            }
            try await test("actual delegate bounds chunked accumulation") {
                try await expect(.responseTooLarge) { _ = try await fixture("/stream-large").run() }
            }
            try await test("actual delegate rejects one oversized chunk") {
                try await expect(.responseTooLarge) { _ = try await fixture("/burst-large").run() }
            }
            try await test("actual delegate rejects unauthorized response") {
                try await expect(.httpStatus(401)) { _ = try await fixture("/denied").run() }
            }
            try await test("actual redirect callback refuses target request") {
                let request = URLRequest(url: url)
                let transport = BoundedSpatterRequest(request: request)
                let session = URLSession(configuration: .ephemeral)
                let task = session.dataTask(with: request) // deliberately not resumed
                let box = RedirectBox()
                transport.urlSession(session, task: task, willPerformHTTPRedirection: http(302), newRequest: URLRequest(url: URL(string: "https://other.example/chat")!), completionHandler: { box.set($0) })
                try require(box.get(), "redirect allowed")
                try await expect(.httpStatus(302)) { _ = try await transport.run() }
                session.invalidateAndCancel()
            }
            try await test("cancellation of actual stalled transport completes and next request works") {
                let work = Task { try await fixture("/stall").run() }
                try await Task.sleep(nanoseconds: 20_000_000)
                work.cancel()
                do { _ = try await work.value; throw TestFailure(message: "cancellation lost") }
                catch is CancellationError { }
                let (data, _) = try await fixture("/ok").run()
                try require(data == valid, "next request stalled")
            }
            print("SPATTER_CLIENT_TESTS=PASS \(passed)/\(passed)")
        } catch {
            print("SPATTER_CLIENT_TESTS=FAIL after \(passed) tests: \(error)")
            exit(1)
        }
    }
}
