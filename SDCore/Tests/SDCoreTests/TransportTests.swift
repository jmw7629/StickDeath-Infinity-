import XCTest
@testable import SDCore

final class TransportTests: XCTestCase {
    // MARK: - Missing backend => zero transport calls

    func testMissingBackendThrows() async {
        let transport = AuthenticatedTransport(baseURL: nil, sessionToken: "token")
        do {
            _ = try await transport.send(request: TransportRequest(url: URL(string: "/test")!))
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TransportError, .missingBackend)
        }
    }

    // MARK: - Missing token => zero transport calls

    func testMissingTokenThrows() async {
        let transport = AuthenticatedTransport(baseURL: URL(string: "https://example.com"), sessionToken: nil)
        do {
            _ = try await transport.send(request: TransportRequest(url: URL(string: "/test")!))
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TransportError, .missingAuthToken)
        }
    }

    func testEmptyTokenThrows() async {
        let transport = AuthenticatedTransport(baseURL: URL(string: "https://example.com"), sessionToken: "")
        do {
            _ = try await transport.send(request: TransportRequest(url: URL(string: "/test")!))
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TransportError, .missingAuthToken)
        }
    }

    // MARK: - Configured transport makes exactly one call via delegate

    func testConfiguredTransportCallsDelegate() async throws {
        let delegate = MockTransportDelegate(
            response: TransportResponse(statusCode: 200, body: Data("ok".utf8))
        )
        let transport = AuthenticatedTransport(
            baseURL: URL(string: "https://backend.example.com"),
            sessionToken: "test-session-token",
            delegate: delegate
        )

        let request = TransportRequest(
            url: URL(string: "/v1/chat/completions")!,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        )

        let response = try await transport.send(request: request)

        XCTAssertEqual(delegate.callCount, 1)
        XCTAssertEqual(response.statusCode, 200)

        let sentRequest = delegate.lastRequest
        XCTAssertEqual(sentRequest?.url.absoluteString, "https://backend.example.com/v1/chat/completions")
        XCTAssertEqual(sentRequest?.httpMethod, "POST")
        XCTAssertEqual(sentRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-session-token")
        XCTAssertNil(sentRequest?.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertNil(sentRequest?.value(forHTTPHeaderField: "X-Provider-Key"))
    }

    // MARK: - SpatterTransport

    func testSpatterTransportChat() async throws {
        let responseJSON = """
        {"choices":[{"message":{"content":"Hello from Spatter"}}]}
        """
        let delegate = MockTransportDelegate(
            response: TransportResponse(statusCode: 200, body: Data(responseJSON.utf8))
        )
        let transport = AuthenticatedTransport(
            baseURL: URL(string: "https://backend.example.com"),
            sessionToken: "spatter-token",
            delegate: delegate
        )

        let spatter = SpatterTransport(transport: transport)
        let result = try await spatter.chat(
            messages: [("user", "Hello")],
            model: "gpt-4o"
        )

        XCTAssertEqual(result, "Hello from Spatter")
        XCTAssertEqual(delegate.callCount, 1)

        let sentRequest = delegate.lastRequest
        XCTAssertEqual(sentRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer spatter-token")
    }

    func testSpatterTransportNoProviderCredentials() async throws {
        let delegate = MockTransportDelegate(
            response: TransportResponse(statusCode: 200, body: Data("{}".utf8))
        )
        let transport = AuthenticatedTransport(
            baseURL: URL(string: "https://backend.example.com"),
            sessionToken: "token",
            delegate: delegate
        )

        let spatter = SpatterTransport(transport: transport)
        _ = try await spatter.chat(messages: [("user", "test")], model: "gpt-4o")

        let sentRequest = delegate.lastRequest
        XCTAssertNil(sentRequest?.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertNil(sentRequest?.value(forHTTPHeaderField: "X-Provider-Key"))
        XCTAssertNil(sentRequest?.value(forHTTPHeaderField: "X-Gemini-Key"))
        XCTAssertNil(sentRequest?.value(forHTTPHeaderField: "X-Anthropic-Key"))
    }

    func testSpatterTransportRequestURL() async throws {
        let delegate = MockTransportDelegate(
            response: TransportResponse(statusCode: 200, body: Data("{}".utf8))
        )
        let transport = AuthenticatedTransport(
            baseURL: URL(string: "https://my-backend.supabase.co"),
            sessionToken: "tok",
            delegate: delegate
        )

        let spatter = SpatterTransport(transport: transport)
        _ = try await spatter.chat(messages: [], model: "test")

        XCTAssertEqual(delegate.lastRequest?.url.absoluteString, "https://my-backend.supabase.co/v1/chat/completions")
    }

    func testSpatterTransportMissingBackend() async {
        let transport = AuthenticatedTransport(baseURL: nil, sessionToken: "tok")
        let spatter = SpatterTransport(transport: transport)

        do {
            _ = try await spatter.chat(messages: [], model: "test")
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TransportError, .missingBackend)
        }
    }

    func testSpatterTransportMissingToken() async {
        let transport = AuthenticatedTransport(baseURL: URL(string: "https://example.com"), sessionToken: nil)
        let spatter = SpatterTransport(transport: transport)

        do {
            _ = try await spatter.chat(messages: [], model: "test")
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? TransportError, .missingAuthToken)
        }
    }
}

// MARK: - Mock transport delegate

class MockTransportDelegate: TransportDelegate {
    let response: TransportResponse
    var callCount = 0
    var lastRequest: URLRequest?

    init(response: TransportResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> TransportResponse {
        callCount += 1
        lastRequest = request
        return response
    }
}
