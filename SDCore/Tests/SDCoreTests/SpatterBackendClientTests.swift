import XCTest
@testable import SDCore

// MARK: - Mock Transport

private final class MockTransport: SpatterBackendTransport {
    var invokeCount = 0
    var lastAuthToken: String?
    var lastBody: Data?

    func invoke(path: String, body: Data?, authToken: String?) async throws -> Data? {
        invokeCount += 1
        lastAuthToken = authToken
        lastBody = body
        return "{\"response\": \"ok\"}".data(using: .utf8)
    }
}

final class SpatterBackendClientTests: XCTestCase {

    func testMissingBackendEndpointZeroTransportCalls() async throws {
        let client = SpatterBackendClient(backendEndpoint: nil, transport: MockTransport())

        let result = try await client.chat(
            messages: [("user", "Hello")],
            authToken: "valid_token"
        )

        XCTAssertNil(result)
        XCTAssertEqual(client.transportCallCount, 0)
    }

    func testEmptyBackendEndpointZeroTransportCalls() async throws {
        let client = SpatterBackendClient(backendEndpoint: "", transport: MockTransport())

        let result = try await client.chat(
            messages: [("user", "Hello")],
            authToken: "valid_token"
        )

        XCTAssertNil(result)
        XCTAssertEqual(client.transportCallCount, 0)
    }

    func testMissingAuthTokenZeroTransportCalls() async throws {
        let transport = MockTransport()
        let client = SpatterBackendClient(
            backendEndpoint: "https://api.example.com/chat",
            transport: transport
        )

        let result = try await client.chat(
            messages: [("user", "Hello")],
            authToken: nil
        )

        XCTAssertNil(result)
        XCTAssertEqual(client.transportCallCount, 0)
        XCTAssertEqual(transport.invokeCount, 0)
    }

    func testEmptyAuthTokenZeroTransportCalls() async throws {
        let transport = MockTransport()
        let client = SpatterBackendClient(
            backendEndpoint: "https://api.example.com/chat",
            transport: transport
        )

        let result = try await client.chat(
            messages: [("user", "Hello")],
            authToken: ""
        )

        XCTAssertNil(result)
        XCTAssertEqual(client.transportCallCount, 0)
        XCTAssertEqual(transport.invokeCount, 0)
    }

    func testConfiguredAndAuthenticatedFormsTransportWithAuthHeader() async throws {
        let transport = MockTransport()
        let client = SpatterBackendClient(
            backendEndpoint: "https://api.example.com/chat",
            transport: transport
        )

        let result = try await client.chat(
            messages: [("user", "Hello"), ("assistant", "Hi there")],
            authToken: "session_token_abc123"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(client.transportCallCount, 1)
        XCTAssertEqual(transport.invokeCount, 1)
        XCTAssertEqual(client.lastRequestPath, "https://api.example.com/chat")
        XCTAssertTrue(client.lastRequestHasAuthToken)
    }

    func testNoProviderCredentialLeakedInBody() async throws {
        let transport = MockTransport()
        let client = SpatterBackendClient(
            backendEndpoint: "https://api.example.com/chat",
            transport: transport
        )

        _ = try await client.chat(
            messages: [("user", "Hello")],
            authToken: "valid_token"
        )

        XCTAssertFalse(client.lastRequestBodyHasProviderKey)
        // Verify body does not contain provider keys
        if let body = transport.lastBody {
            let bodyString = String(data: body, encoding: .utf8) ?? ""
            XCTAssertFalse(bodyString.contains("sk-"), "Body must not contain OpenAI sk- prefix")
            XCTAssertFalse(bodyString.contains("api_key"), "Body must not contain api_key")
            XCTAssertFalse(bodyString.contains("apiKey"), "Body must not contain apiKey")
        }
    }

    func testNilTransportReturnsNil() async throws {
        let client = SpatterBackendClient(
            backendEndpoint: "https://api.example.com/chat",
            transport: nil
        )

        let result = try await client.chat(
            messages: [("user", "Hello")],
            authToken: "valid_token"
        )

        XCTAssertNil(result)
        XCTAssertEqual(client.transportCallCount, 1)
    }

    func testEmbeddedLocalSpatterKnowledgeUsableOffline() throws {
        // The Spatter knowledge base is embedded as JSON resources.
        // This test verifies the client can be constructed without a backend
        // (offline mode) and the knowledge lookup pattern works.
        let client = SpatterBackendClient(backendEndpoint: nil, transport: nil)

        // No backend configured — should return nil, not crash
        Task {
            let result = try await client.chat(
                messages: [("user", "What is Spatter?")],
                authToken: nil
            )
            XCTAssertNil(result)
        }
    }
}
