import XCTest
@testable import SDCore

final class ProjectPersistenceTests: XCTestCase {

    var tmpDir: URL!
    var persistence: ProjectPersistence!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        persistence = ProjectPersistence(rootURL: tmpDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testSaveAndLoadRoundTrip() throws {
        let layer1 = CanvasLayer(id: "l1", name: "Background", visible: true, locked: false, opacity: 0.8, lockMode: "free", blendMode: "multiply", colorLabel: "#FF0000")
        let layer2 = CanvasLayer(id: "l2", name: "Foreground", visible: false, locked: true, opacity: 0.5, lockMode: "full", blendMode: "screen", colorLabel: "#00FF00")

        let strokePoints = [
            StrokePoint(x: 10.0, y: 20.0, pressure: 0.5),
            StrokePoint(x: 30.0, y: 40.0, pressure: 1.0),
        ]
        let element = DrawnElement(
            id: "e1", tool: .brush, points: strokePoints,
            color: "#FF0000", width: 3.0, opacity: 1.0,
            fillColor: "#00FF00", layerID: "l1"
        )
        let frame = AnimationFrame(id: "f1", elements: [element])

        let doc = ProjectDocument(
            projectName: "Test Animation",
            canvasWidth: 1920,
            canvasHeight: 1080,
            fps: 24,
            frames: [frame],
            layers: [layer1, layer2],
            activeLayerID: "l1",
            currentFrameIndex: 0
        )

        try persistence.save(doc, projectID: "test-001")
        let loaded = try persistence.load(projectID: "test-001")

        XCTAssertEqual(loaded.projectName, "Test Animation")
        XCTAssertEqual(loaded.canvasWidth, 1920)
        XCTAssertEqual(loaded.canvasHeight, 1080)
        XCTAssertEqual(loaded.fps, 24)
        XCTAssertEqual(loaded.frames.count, 1)
        XCTAssertEqual(loaded.layers.count, 2)
        XCTAssertEqual(loaded.activeLayerID, "l1")

        let loadedLayer = loaded.layers[0]
        XCTAssertEqual(loadedLayer.id, "l1")
        XCTAssertEqual(loadedLayer.name, "Background")
        XCTAssertTrue(loadedLayer.visible)
        XCTAssertEqual(loadedLayer.opacity, 0.8, accuracy: 0.001)
        XCTAssertEqual(loadedLayer.blendMode, "multiply")
        XCTAssertEqual(loadedLayer.colorLabel, "#FF0000")

        let loadedElement = loaded.frames[0].elements[0]
        XCTAssertEqual(loadedElement.id, "e1")
        XCTAssertEqual(loadedElement.tool, .brush)
        XCTAssertEqual(loadedElement.points.count, 2)
        XCTAssertEqual(loadedElement.points[0].x, 10.0, accuracy: 0.001)
        XCTAssertEqual(loadedElement.points[0].pressure, 0.5, accuracy: 0.001)
        XCTAssertEqual(loadedElement.color, "#FF0000")
        XCTAssertEqual(loadedElement.fillColor, "#00FF00")
        XCTAssertEqual(loadedElement.layerID, "l1")
    }

    func testSaveCreatesDirectory() throws {
        let doc = ProjectDocument()
        try persistence.save(doc, projectID: "new-project")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: persistence.projectDir(for: "new-project").path,
            isDirectory: &isDir
        ))
        XCTAssertTrue(isDir.boolValue)
    }

    func testLoadNonexistentThrows() {
        XCTAssertThrowsError(try persistence.load(projectID: "does-not-exist")) { error in
            guard case ProjectPersistenceError.decodingFailed = error else {
                XCTFail("Expected decodingFailed, got \(error)")
                return
            }
        }
    }

    func testSaveAndLoadRaster() throws {
        let projectID = "raster-test"
        let testData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG header
        try persistence.saveRaster(testData, projectID: projectID, frameIndex: 0)

        let loaded = persistence.loadRaster(projectID: projectID, frameIndex: 0)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, testData)
    }

    func testDiscoverRasterIndicesSparse() throws {
        let projectID = "sparse-test"
        let data = Data([0x89])
        try persistence.saveRaster(data, projectID: projectID, frameIndex: 0)
        try persistence.saveRaster(data, projectID: projectID, frameIndex: 7)

        let indices = persistence.discoverRasterIndices(projectID: projectID)
        XCTAssertEqual(indices, [0, 7])
    }

    func testListProjects() throws {
        try persistence.save(ProjectDocument(projectName: "A"), projectID: "proj-a")
        try persistence.save(ProjectDocument(projectName: "B"), projectID: "proj-b")

        let list = persistence.listProjects()
        XCTAssertEqual(list, ["proj-a", "proj-b"])
    }

    func testDeleteProject() throws {
        try persistence.save(ProjectDocument(), projectID: "to-delete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.projectDir(for: "to-delete").path))
        try persistence.deleteProject(projectID: "to-delete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.projectDir(for: "to-delete").path))
    }

    func testDeleteNonexistentProjectDoesNotThrow() throws {
        try persistence.deleteProject(projectID: "never-existed")
    }

    func testDefaultValues() {
        let doc = ProjectDocument()
        XCTAssertEqual(doc.projectName, "Untitled Animation")
        XCTAssertEqual(doc.canvasWidth, 1080)
        XCTAssertEqual(doc.canvasHeight, 1080)
        XCTAssertEqual(doc.fps, 12)
        XCTAssertEqual(doc.frames.count, 1)
        XCTAssertEqual(doc.layers.count, 1)
    }

    func testLayerMetadataRoundTrip() throws {
        let layer = CanvasLayer(
            id: "meta-test",
            name: "Test Layer",
            visible: true,
            locked: false,
            opacity: 0.75,
            lockMode: "position",
            blendMode: "overlay",
            glowEnabled: true,
            glowColor: "#FFFF00",
            colorLabel: "#0000FF"
        )
        let doc = ProjectDocument(layers: [layer])
        try persistence.save(doc, projectID: "meta")
        let loaded = try persistence.load(projectID: "meta")

        let l = loaded.layers[0]
        XCTAssertEqual(l.lockMode, "position")
        XCTAssertEqual(l.blendMode, "overlay")
        XCTAssertTrue(l.glowEnabled)
        XCTAssertEqual(l.glowColor, "#FFFF00")
        XCTAssertEqual(l.colorLabel, "#0000FF")
    }
}
