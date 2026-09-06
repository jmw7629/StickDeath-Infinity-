// ═══════════════════════════════════════════════════════════════════
// ProjectRepositoryTests — Lifecycle coordinator test evidence
// Tests: create→local save, mutate→save, list signed out,
// reopen canonical state, local-failure-zero-remote,
// remote-failure-local-preserved, real project ID remote calls.
// ═══════════════════════════════════════════════════════════════════

import XCTest
@testable import SDCore

// MARK: - Fake Storage (for isolated testing)

final class FakeProjectStorage: ProjectStorage, @unchecked Sendable {
    var projects: [String: SDProject] = [:]
    var shouldFailSave = false
    var shouldFailDelete = false

    func saveProject(_ project: SDProject) throws {
        if shouldFailSave { throw StorageError.writeFailed("simulated failure") }
        projects[project.projectID] = project
    }

    func loadProject(id: String) throws -> SDProject? {
        projects[id]
    }

    func listProjects() -> [SDProject] {
        Array(projects.values)
    }

    func deleteProject(id: String) throws {
        if shouldFailDelete { throw StorageError.deleteFailed("simulated failure") }
        projects.removeValue(forKey: id)
    }

    func projectDirectory(for id: String) -> URL {
        URL(fileURLWithPath: "/tmp/test/\(id)", isDirectory: true)
    }
}

// MARK: - Fake Transport (counts calls)

final class CountingTransport: BackendTransport, @unchecked Sendable {
    var callCount = 0
    var lastRequest: TransportRequest?

    func send(request: TransportRequest) async throws -> TransportResponse {
        callCount += 1
        lastRequest = request
        return TransportResponse(statusCode: 200, data: Data())
    }
}

// MARK: - Tests

final class ProjectRepositoryTests: XCTestCase {

    // Test: create assigns durable String project ID and persists locally
    func testCreateAssignsDurableLocalProject() async throws {
        let storage = FakeProjectStorage()
        let transport = CountingTransport()
        let caller = BackendTransportCaller(config: nil, transport: transport)
        let repo = ProductionProjectRepository(storage: storage, transport: caller)

        let project = try await repo.createProject(name: "My Animation", width: 1080, height: 1080, fps: 12)

        // Verify durable String ID
        XCTAssertFalse(project.projectID.isEmpty)
        XCTAssertNotNil(UUID(uuidString: project.projectID))

        // Verify local persistence
        let loaded = try storage.loadProject(id: project.projectID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "My Animation")

        // Verify no remote calls when not configured
        XCTAssertEqual(transport.callCount, 0)
    }

    // Test: save writes canonical local state first
    func testSaveWritesLocalFirst() async throws {
        let storage = FakeProjectStorage()
        let transport = CountingTransport()
        let caller = BackendTransportCaller(config: nil, transport: transport)
        let repo = ProductionProjectRepository(storage: storage, transport: caller)

        let project = try await repo.createProject(name: "Test", width: 800, height: 600, fps: 24)
        var mutable = project
        mutable.name = "Updated"
        try await repo.saveProject(mutable)

        let loaded = try storage.loadProject(id: project.projectID)
        XCTAssertEqual(loaded?.name, "Updated")
    }

    // Test: list while signed out / no network returns local projects
    func testListReturnsLocalProjectsWhenOffline() async {
        let storage = FakeProjectStorage()
        let transport = CountingTransport()
        let caller = BackendTransportCaller(config: nil, transport: transport)
        let repo = ProductionProjectRepository(storage: storage, transport: caller)

        let _ = try? await repo.createProject(name: "Proj1", width: 1080, height: 1080, fps: 12)
        let _ = try? await repo.createProject(name: "Proj2", width: 720, height: 720, fps: 30)

        let projects = await repo.loadProjects()
        XCTAssertEqual(projects.count, 2)
    }

    // Test: reopen returns the saved canonical state
    func testReopenReturnsCanonicalState() async throws {
        let storage = FakeProjectStorage()
        let transport = CountingTransport()
        let caller = BackendTransportCaller(config: nil, transport: transport)
        let repo = ProductionProjectRepository(storage: storage, transport: caller)

        let project = try await repo.createProject(name: "Reopen Test", width: 1920, height: 1080, fps: 60)
        let reopened = try await repo.reopenProject(id: project.projectID)

        XCTAssertEqual(reopened.name, "Reopen Test")
        XCTAssertEqual(reopened.width, 1920)
        XCTAssertEqual(reopened.height, 1080)
        XCTAssertEqual(reopened.fps, 60)
    }

    // Test: local-create failure => zero remote calls
    func testLocalCreateFailureZeroRemoteCalls() async {
        let storage = FakeProjectStorage()
        storage.shouldFailSave = true
        let transport = CountingTransport()
        let caller = BackendTransportCaller(config: BackendConfig(baseURL: "https://api.example.com", sessionToken: "tok"), transport: transport)
        let repo = ProductionProjectRepository(storage: storage, transport: caller)

        do {
            _ = try await repo.createProject(name: "Fail", width: 1080, height: 1080, fps: 12)
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        XCTAssertEqual(transport.callCount, 0, "Local failure should prevent all remote calls")
    }

    // Test: local success + remote failure => local saved state still reopens intact
    func testRemoteFailureLocalPreserved() async throws {
        let storage = FakeProjectStorage()
        let transport = FailingTransport()
        let caller = BackendTransportCaller(config: BackendConfig(baseURL: "https://api.example.com", sessionToken: "tok"), transport: transport)
        let repo = ProductionProjectRepository(storage: storage, transport: caller)

        let project = try await repo.createProject(name: "Preserved", width: 1080, height: 1080, fps: 12)

        // Remote failed, but local should be intact
        let loaded = try await repo.openProject(id: project.projectID)
        XCTAssertEqual(loaded.name, "Preserved")
    }

    // Test: remote calls use the real project ID, never null/placeholder
    func testRemoteUsesRealProjectID() async throws {
        let storage = FakeProjectStorage()
        let transport = CountingTransport()
        let caller = BackendTransportCaller(config: BackendConfig(baseURL: "https://api.example.com", sessionToken: "tok"), transport: transport)
        let repo = ProductionProjectRepository(storage: storage, transport: caller)

        let project = try await repo.createProject(name: "ID Test", width: 1080, height: 1080, fps: 12)

        // Verify remote call was made with the real project ID
        XCTAssertEqual(transport.callCount, 1)
        if let body = transport.lastRequest?.body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            XCTAssertEqual(json["id"] as? String, project.projectID)
        }
    }
}

// MARK: - Failing Transport

private final class FailingTransport: BackendTransport, @unchecked Sendable {
    func send(request: TransportRequest) async throws -> TransportResponse {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "remote failure"])
    }
}
