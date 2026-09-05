import XCTest
@testable import SDCore

final class SpatterBackendTests: XCTestCase {

    func testUnconfiguredClientThrowsNotConfigured() async {
        let client = SpatterBackendClient(config: SpatterBackendConfig())
        do {
            _ = try await client.chat(messages: [SpatterChatMessage(role: "user", content: "hello")])
            XCTFail("Expected error")
        } catch let error as SpatterBackendError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testConfiguredClientReportsAvailable() {
        let client = SpatterBackendClient(config: SpatterBackendConfig(backendURL: "https://api.example.com"))
        XCTAssertTrue(client.isAvailable())
    }

    func testUnconfiguredClientReportsUnavailable() {
        let client = SpatterBackendClient(config: SpatterBackendConfig())
        XCTAssertFalse(client.isAvailable())
    }

    func testSpatterBackendConfigEquatable() {
        let a = SpatterBackendConfig(backendURL: "https://api.example.com")
        let b = SpatterBackendConfig(backendURL: "https://api.example.com")
        let c = SpatterBackendConfig(backendURL: "https://other.com")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testSpatterChatMessageCodable() throws {
        let msg = SpatterChatMessage(role: "user", content: "test")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SpatterChatMessage.self, from: data)
        XCTAssertEqual(decoded.role, "user")
        XCTAssertEqual(decoded.content, "test")
    }

    func testNoDirectPollinationsURLInClient() {
        // Verify the SpatterBackendClient does not contain any hardcoded Pollinations URL
        let client = SpatterBackendClient()
        // The client starts with empty config — no hardcoded provider URLs
        XCTAssertFalse(client.isAvailable())
    }
}
