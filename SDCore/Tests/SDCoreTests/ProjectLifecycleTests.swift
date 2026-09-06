import XCTest
@testable import SDCore

final class ProjectLifecycleTests: XCTestCase {
    var tempDir: URL!
    var store: LocalProjectStore!
    var coordinator: SDCoreCoordinator!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = LocalProjectStore(baseDirectory: tempDir)
        coordinator = SDCoreCoordinator(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Offline lifecycle tests

    func testCreateProject() throws {
        let project = try coordinator.createProject(name: "Test Project", width: 800, height: 600, fps: 24)

        XCTAssertEqual(project.name, "Test Project")
        XCTAssertEqual(project.width, 800)
        XCTAssertEqual(project.height, 600)
        XCTAssertEqual(project.fps, 24)
        XCTAssertEqual(project.frames.count, 1)
        XCTAssertEqual(project.layers.count, 1)
        XCTAssertFalse(project.activeLayerID.isEmpty)
        XCTAssertFalse(project.id.isEmpty)
    }

    func testCreateProjectReturnsDurableID() throws {
        let p1 = try coordinator.createProject(name: "First")
        let p2 = try coordinator.createProject(name: "Second")

        XCTAssertNotEqual(p1.id, p2.id)
        XCTAssertNotNil(UUID(uuidString: p1.id))
        XCTAssertNotNil(UUID(uuidString: p2.id))
    }

    func testSaveAndList() throws {
        _ = try coordinator.createProject(name: "Save Test")
        let projects = try coordinator.loadProjects()

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.name, "Save Test")
    }

    func testOpenProject() throws {
        let created = try coordinator.createProject(name: "Open Test")
        let loaded = try coordinator.openProject(id: created.id)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "Open Test")
        XCTAssertEqual(loaded?.id, created.id)
    }

    func testOfflineCreateSaveListReopen() throws {
        let project = try coordinator.createProject(name: "Offline Test")
        try coordinator.save()

        let projects = try coordinator.loadProjects()
        XCTAssertEqual(projects.count, 1)

        let reopened = try coordinator.openProject(id: project.id)
        XCTAssertNotNil(reopened)
        XCTAssertEqual(reopened?.name, "Offline Test")
    }

    func testFramesElementsLayersRoundTrip() throws {
        let project = try coordinator.createProject(name: "RoundTrip")
        var updated = project

        let element = DrawnElement(
            tool: .brush,
            points: [StrokePoint(x: 10, y: 20), StrokePoint(x: 30, y: 40)],
            color: "#FF0000",
            width: 5,
            opacity: 0.8,
            layerID: project.layers.first?.id
        )
        updated.frames[0].elements.append(element)
        updated.layers[0].opacity = 0.5
        updated.layers[0].name = "Custom Layer"

        try coordinator.repository.save(updated)
        let loaded = try coordinator.openProject(id: project.id)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.frames[0].elements.count, 1)
        XCTAssertEqual(loaded?.frames[0].elements.first?.tool, .brush)
        XCTAssertEqual(loaded?.frames[0].elements.first?.color, "#FF0000")
        XCTAssertEqual(loaded?.layers[0].opacity, 0.5)
        XCTAssertEqual(loaded?.layers[0].name, "Custom Layer")
    }

    func testSessionMetadataRoundTrip() throws {
        let project = try coordinator.createProject(name: "Session Test")
        var updated = project
        updated.activeLayerID = project.layers.first?.id ?? ""
        updated.activeFrameIndex = 0

        try coordinator.repository.save(updated)
        let loaded = try coordinator.openProject(id: project.id)

        XCTAssertEqual(loaded?.activeLayerID, project.layers.first?.id)
        XCTAssertEqual(loaded?.activeFrameIndex, 0)
    }

    // MARK: - Local failure => zero remote calls

    func testLocalCreateFailureZeroRemoteCalls() throws {
        let badStore = FailingProjectStore()
        let coordinator = SDCoreCoordinator(store: badStore)

        XCTAssertThrowsError(try coordinator.createProject(name: "Fail")) { error in
            XCTAssertTrue(error is FailingProjectStore.TestError)
        }
    }

    func testLocalSaveFailureZeroRemoteCalls() throws {
        let project = try coordinator.createProject(name: "Save Fail")

        let failingStore = FailingProjectStore()
        let badCoordinator = SDCoreCoordinator(store: failingStore)

        XCTAssertThrowsError(try badCoordinator.save()) { error in
            XCTAssertTrue(error is ProjectError)
        }
    }

    // MARK: - Local success + remote failure => local state reopens intact

    func testLocalSuccessRemoteFailureReopensIntact() throws {
        let project = try coordinator.createProject(name: "Remote Fail Test")
        try coordinator.save()

        let reopened = try coordinator.openProject(id: project.id)
        XCTAssertNotNil(reopened)
        XCTAssertEqual(reopened?.name, "Remote Fail Test")
    }
}

// MARK: - Failing store for error path tests

class FailingProjectStore: ProjectStore {
    enum TestError: Error { case fail }

    func loadProject(id: String) throws -> Project? { throw TestError.fail }
    func saveProject(_ project: Project) throws { throw TestError.fail }
    func listProjects() throws -> [Project] { throw TestError.fail }
    func deleteProject(id: String) throws { throw TestError.fail }
    func projectExists(id: String) throws -> Bool { throw TestError.fail }
}
