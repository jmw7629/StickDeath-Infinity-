import XCTest
@testable import SDCore

final class StudioStorageTests: XCTestCase {

    private var tempDir: URL!
    private var storage: StudioStorage!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storage = StudioStorage(baseDirectory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Create → Save → List → Reopen Lifecycle

    func testCreateAndListProjects() throws {
        let p1 = try storage.createProject(id: "proj_1", name: "My Animation")
        let p2 = try storage.createProject(id: "proj_2", name: "Another Animation")

        let projects = try storage.listProjects()
        XCTAssertEqual(projects.count, 2)
        XCTAssertTrue(projects.contains { $0.id == "proj_1" })
        XCTAssertTrue(projects.contains { $0.id == "proj_2" })
    }

    func testCreateAssignsDurableStringID() throws {
        let project = try storage.createProject(id: "durable_id_42", name: "Test")
        XCTAssertEqual(project.id, "durable_id_42")
    }

    func testSavePersistsMetadataFramesElementsLayers() throws {
        var project = try storage.createProject(id: "save_test", name: "Save Test")

        // Mutate layers
        project.layers = [
            CanvasLayer.defaultLayer(),
            CanvasLayer.newLayer(index: 1, name: "Foreground")
        ]
        project.activeLayerID = "layer_1"

        // Mutate frames
        let element = DrawnElement(
            id: "elem_1",
            tool: .brush,
            points: [StrokePoint(x: 10, y: 20, pressure: 0.8)],
            color: "#FF0000",
            width: 3.0,
            layerID: "layer_default"
        )
        project.frames = [
            AnimationFrame(id: "frame_1", elements: [element]),
            AnimationFrame(id: "frame_2", elements: [])
        ]

        try storage.saveProject(project)

        // Reload and verify
        let loaded = try storage.loadProject(id: "save_test")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.layers.count, 2)
        XCTAssertEqual(loaded?.activeLayerID, "layer_1")
        XCTAssertEqual(loaded?.frames.count, 2)
        XCTAssertEqual(loaded?.frames.first?.elements.first?.id, "elem_1")
        XCTAssertEqual(loaded?.frames.first?.elements.first?.tool, .brush)
    }

    func testListReturnsLocalProjectsWhileOffline() throws {
        _ = try storage.createProject(id: "offline_1", name: "Offline Project")

        let projects = try storage.listProjects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.name, "Offline Project")
    }

    func testOpenReopenLoadsLocalState() throws {
        var project = try storage.createProject(id: "reopen_test", name: "Reopen Test")
        project.canvasWidth = 720
        project.canvasHeight = 480
        project.fps = 24
        project.layers = [CanvasLayer.defaultLayer(), CanvasLayer.newLayer(index: 1)]
        try storage.saveProject(project)

        let loaded = try storage.loadProject(id: "reopen_test")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.canvasWidth, 720)
        XCTAssertEqual(loaded?.canvasHeight, 480)
        XCTAssertEqual(loaded?.fps, 24)
        XCTAssertEqual(loaded?.layers.count, 2)
    }

    func testDeleteProject() throws {
        _ = try storage.createProject(id: "to_delete", name: "Delete Me")
        XCTAssertEqual(try storage.listProjects().count, 1)

        try storage.deleteProject(id: "to_delete")
        XCTAssertEqual(try storage.listProjects().count, 0)
    }

    func testLoadNonexistentProjectReturnsNil() throws {
        let project = try storage.loadProject(id: "does_not_exist")
        XCTAssertNil(project)
    }

    func testListEmptyDirectory() throws {
        let projects = try storage.listProjects()
        XCTAssertEqual(projects.count, 0)
    }

    // MARK: - Lifecycle: create → mutate → save → list → reopen

    func testFullLifecycle() throws {
        // Create
        var project = try storage.createProject(id: "lifecycle", name: "Lifecycle Test")

        // Mutate
        project.name = "Updated Name"
        project.layers.append(CanvasLayer.newLayer(index: 1))
        let elem = DrawnElement(
            tool: .pen,
            points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 100, y: 100)],
            color: "#000000",
            width: 2.0,
            layerID: "layer_default"
        )
        project.frames[0].elements.append(elem)

        // Save
        try storage.saveProject(project)

        // List
        let list = try storage.listProjects()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.name, "Updated Name")

        // Reopen
        let reopened = try storage.loadProject(id: "lifecycle")
        XCTAssertNotNil(reopened)
        XCTAssertEqual(reopened?.layers.count, 2)
        XCTAssertEqual(reopened?.frames.first?.elements.count, 1)
        XCTAssertEqual(reopened?.frames.first?.elements.first?.tool, .pen)
    }
}
