// ═══════════════════════════════════════════════════════════════════
// SDCoreTests — Tests for the exact coordinator used by StudioViewModel
// ═══════════════════════════════════════════════════════════════════

import XCTest
@testable import SDCore

// MARK: - Recording/Failing RemoteStore Fake

/// Records every upload call with call count and received project IDs.
/// Configurable to fail on demand.
final class RecordingRemoteStore: RemoteStore {
    var uploadCallCount = 0
    var receivedProjectIDs: [String] = []
    var shouldFail = false
    var listProjectsResult: [RemoteVersion] = []

    func uploadVersion(projectID: String, frameData: String) async throws -> String {
        guard !shouldFail else { throw RemoteStoreError.uploadFailed(500) }
        uploadCallCount += 1
        receivedProjectIDs.append(projectID)
        return "remote-version-\(uploadCallCount)"
    }

    func listVersions(projectID: String) async throws -> [RemoteVersion] {
        return []
    }

    func listProjects() async throws -> [RemoteVersion] {
        guard !shouldFail else { throw RemoteStoreError.fetchFailed(500) }
        return listProjectsResult
    }
}

// MARK: - Failing Local Repository

/// Always fails to save — proves zero remote calls on local failure.
final class FailingLocalRepository: ProjectRepository {
    func save(_ snapshot: ProjectSnapshot) throws {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local save failed"])
    }

    func load(id: String) throws -> ProjectSnapshot? { nil }
    func listAll() throws -> [ProjectSnapshot] { [] }
    func delete(id: String) throws {}
}

// MARK: - In-Memory Local Repository

/// Simple in-memory repository for testing coordinator behavior.
final class InMemoryLocalRepository: ProjectRepository {
    private var projects: [String: ProjectSnapshot] = [:]

    func save(_ snapshot: ProjectSnapshot) throws {
        projects[snapshot.id] = snapshot
    }

    func load(id: String) throws -> ProjectSnapshot? {
        projects[id]
    }

    func listAll() throws -> [ProjectSnapshot] {
        Array(projects.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(id: String) throws {
        projects.removeValue(forKey: id)
    }
}

// MARK: - Coordinator Tests

final class ProjectCoordinatorTests: XCTestCase {

    // MARK: - Test: Local failure => zero remote calls

    func testLocalSaveFailure_noRemoteCalls() async throws {
        let remote = RecordingRemoteStore()
        let local = FailingLocalRepository()
        let coordinator = DefaultProjectCoordinator(
            localRepository: local,
            remoteStore: remote
        )

        let snapshot = ProjectSnapshot(
            id: "test-project-1",
            name: "Test Project"
        )

        do {
            try await coordinator.save(snapshot)
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        XCTAssertEqual(remote.uploadCallCount, 0, "Zero remote calls on local failure")
        XCTAssertTrue(remote.receivedProjectIDs.isEmpty)
    }

    // MARK: - Test: Successful save => exactly expected remote call with real project ID

    func testSuccessfulSave_exactlyOneRemoteCallWithProjectID() async throws {
        let remote = RecordingRemoteStore()
        let local = InMemoryLocalRepository()
        let coordinator = DefaultProjectCoordinator(
            localRepository: local,
            remoteStore: remote
        )

        let snapshot = ProjectSnapshot(
            id: "real-project-id-abc",
            name: "My Animation"
        )

        try await coordinator.save(snapshot)

        XCTAssertEqual(remote.uploadCallCount, 1)
        XCTAssertEqual(remote.receivedProjectIDs.first, "real-project-id-abc")
    }

    // MARK: - Test: Remote failure => local state remains reopenable

    func testRemoteFailure_localStatePreserved() async throws {
        let remote = RecordingRemoteStore()
        remote.shouldFail = true
        let local = InMemoryLocalRepository()
        let coordinator = DefaultProjectCoordinator(
            localRepository: local,
            remoteStore: remote
        )

        let snapshot = ProjectSnapshot(
            id: "resilient-project",
            name: "Resilient"
        )

        try await coordinator.save(snapshot)

        // Local state should be reopenable
        let reopened = try coordinator.openProject(id: "resilient-project")
        XCTAssertNotNil(reopened)
        XCTAssertEqual(reopened?.id, "resilient-project")
        XCTAssertEqual(reopened?.name, "Resilient")
    }

    // MARK: - Test: List projects never hides local

    func testListProjects_localFirst() async throws {
        let remote = RecordingRemoteStore()
        remote.shouldFail = true // Remote fails
        let local = InMemoryLocalRepository()
        let coordinator = DefaultProjectCoordinator(
            localRepository: local,
            remoteStore: remote
        )

        let localProject = ProjectSnapshot(id: "local-1", name: "Local Project")
        try local.save(localProject)

        let projects = try await coordinator.loadProjects()

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.id, "local-1")
    }

    // MARK: - Test: Create project saves locally and pushes to remote

    func testCreateProject_localAndRemote() async throws {
        let remote = RecordingRemoteStore()
        let local = InMemoryLocalRepository()
        let coordinator = DefaultProjectCoordinator(
            localRepository: local,
            remoteStore: remote
        )

        let snapshot = ProjectSnapshot(
            id: "new-project-id",
            name: "New Project"
        )

        try await coordinator.createProject(snapshot)

        // Local saved
        let loaded = try local.load(id: "new-project-id")
        XCTAssertNotNil(loaded)

        // Remote called with real project ID
        XCTAssertEqual(remote.uploadCallCount, 1)
        XCTAssertEqual(remote.receivedProjectIDs.first, "new-project-id")
    }

    // MARK: - Test: Remote-only coordinator (no remote store) works fine

    func testLocalOnlyCoordinator() async throws {
        let local = InMemoryLocalRepository()
        let coordinator = DefaultProjectCoordinator(
            localRepository: local,
            remoteStore: nil
        )

        let snapshot = ProjectSnapshot(id: "local-only", name: "Local Only")
        try await coordinator.save(snapshot)

        let loaded = try coordinator.openProject(id: "local-only")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "Local Only")
    }

    // MARK: - Test: Open nonexistent project returns nil

    func testOpenNonexistentProject() async throws {
        let local = InMemoryLocalRepository()
        let coordinator = DefaultProjectCoordinator(
            localRepository: local,
            remoteStore: nil
        )

        let result = try await coordinator.openProject(id: "nonexistent")
        XCTAssertNil(result)
    }

    // MARK: - Test: Empty project ID rejected by remote

    func testEmptyProjectID_rejectedByRemote() async throws {
        let remote = RecordingRemoteStore()
        let local = InMemoryLocalRepository()
        let coordinator = DefaultProjectCoordinator(
            localRepository: local,
            remoteStore: remote
        )

        let snapshot = ProjectSnapshot(id: "", name: "Empty ID")

        do {
            try await coordinator.save(snapshot)
            XCTFail("Should have thrown for empty project ID")
        } catch {
            // Expected: local save succeeds but remote rejects empty ID
        }

        // Local should still be saved
        let loaded = try local.load(id: "")
        XCTAssertNotNil(loaded)
    }
}
