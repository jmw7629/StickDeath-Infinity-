import XCTest
@testable import SDCore

final class StudioStorageTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SDCoreTests-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Create Project

    func testCreateProject() throws {
        let project = try StudioStorage.shared.createProject(
            id: "test-1",
            name: "Test Animation",
            root: tempDir
        )
        XCTAssertEqual(project.id, "test-1")
        XCTAssertEqual(project.name, "Test Animation")
        XCTAssertEqual(project.width, 1080)
        XCTAssertEqual(project.height, 1080)
        XCTAssertEqual(project.fps, 12)
        XCTAssertEqual(project.frameCount, 1)
    }

    func testCreateProjectCustomDimensions() throws {
        let project = try StudioStorage.shared.createProject(
            id: "test-2",
            name: "Wide",
            width: 1920,
            height: 720,
            fps: 24,
            root: tempDir
        )
        XCTAssertEqual(project.width, 1920)
        XCTAssertEqual(project.height, 720)
        XCTAssertEqual(project.fps, 24)
    }

    func testCreateProjectCreatesDirectory() throws {
        try StudioStorage.shared.createProject(id: "dir-test", name: "Dir", root: tempDir)
        let dir = StudioStorage.shared.projectDirectory(id: "dir-test", root: tempDir)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - Save and Load Project

    func testSaveAndLoadProject() throws {
        try StudioStorage.shared.createProject(id: "save-load", name: "Original", root: tempDir)

        var metadata = try StudioStorage.shared.loadProject(id: "save-load", root: tempDir).metadata
        metadata.name = "Updated Name"
        metadata.frameCount = 5

        let newFrames = (0..<5).map { AnimationFrame(id: "f\($0)", elements: []) }
        try StudioStorage.shared.saveProject(id: "save-load", metadata: metadata, frames: newFrames, root: tempDir)

        let loaded = try StudioStorage.shared.loadProject(id: "save-load", root: tempDir)
        XCTAssertEqual(loaded.metadata.name, "Updated Name")
        XCTAssertEqual(loaded.metadata.frameCount, 5)
        XCTAssertEqual(loaded.frames.count, 5)
    }

    func testSaveLayersAndSession() throws {
        try StudioStorage.shared.createProject(id: "save-layers", name: "L", root: tempDir)

        let layers = [
            CanvasLayer(id: "a", name: "Layer A"),
            CanvasLayer(id: "b", name: "Layer B")
        ]
        let session = SessionState(activeLayerID: "b", currentFrameIndex: 3)
        try StudioStorage.shared.saveProject(id: "save-layers", layers: layers, session: session, root: tempDir)

        let loaded = try StudioStorage.shared.loadProject(id: "save-layers", root: tempDir)
        XCTAssertEqual(loaded.layers.count, 2)
        XCTAssertEqual(loaded.layers[0].name, "Layer A")
        XCTAssertEqual(loaded.session.activeLayerID, "b")
        XCTAssertEqual(loaded.session.currentFrameIndex, 3)
    }

    // MARK: - List Projects

    func testListProjects() throws {
        try StudioStorage.shared.createProject(id: "p1", name: "First", root: tempDir)
        try StudioStorage.shared.createProject(id: "p2", name: "Second", root: tempDir)
        try StudioStorage.shared.createProject(id: "p3", name: "Third", root: tempDir)

        let projects = StudioStorage.shared.listProjects(root: tempDir)
        XCTAssertEqual(projects.count, 3)
        let names = Set(projects.map(\.name))
        XCTAssertTrue(names.contains("First"))
        XCTAssertTrue(names.contains("Second"))
        XCTAssertTrue(names.contains("Third"))
    }

    func testListProjectsEmpty() {
        let projects = StudioStorage.shared.listProjects(root: tempDir)
        XCTAssertEqual(projects.count, 0)
    }

    // MARK: - Delete Project

    func testDeleteProject() throws {
        try StudioStorage.shared.createProject(id: "to-delete", name: "Delete Me", root: tempDir)
        try StudioStorage.shared.deleteProject(id: "to-delete", root: tempDir)

        XCTAssertThrowsError(try StudioStorage.shared.loadProject(id: "to-delete", root: tempDir)) { error in
            XCTAssertEqual(error as? StudioStorageError, .projectNotFound("to-delete"))
        }
    }

    func testDeleteNonexistentProject() throws {
        try StudioStorage.shared.deleteProject(id: "nonexistent", root: tempDir)
    }

    // MARK: - Load Nonexistent Project

    func testLoadNonexistentProject() {
        XCTAssertThrowsError(try StudioStorage.shared.loadProject(id: "ghost", root: tempDir)) { error in
            XCTAssertEqual(error as? StudioStorageError, .projectNotFound("ghost"))
        }
    }

    // MARK: - Create, Mutate, Save, List, Reopen Lifecycle

    func testFullLifecycle() throws {
        // 1. Create
        let project = try StudioStorage.shared.createProject(id: "lifecycle", name: "Lifecycle", root: tempDir)

        // 2. Load
        var loaded = try StudioStorage.shared.loadProject(id: "lifecycle", root: tempDir)
        XCTAssertEqual(loaded.frames.count, 1)
        XCTAssertEqual(loaded.layers.count, 1)

        // 3. Mutate — add frame
        var frames = loaded.frames
        frames.append(AnimationFrame(id: "f2", elements: [
            DrawnElement(id: "e1", tool: .brush, points: [StrokePoint(x: 10, y: 20)], color: "#F00", width: 3, opacity: 1)
        ]))

        // 4. Mutate — add layer
        var layers = loaded.layers
        layers.insert(CanvasLayer(id: "new-layer", name: "New Layer"), at: 0)

        // 5. Save
        let updatedMetadata = StudioProjectRecord(
            id: project.id,
            name: "Updated Lifecycle",
            width: project.width,
            height: project.height,
            fps: project.fps,
            frameCount: frames.count,
            createdAt: project.createdAt,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        try StudioStorage.shared.saveProject(
            id: "lifecycle",
            metadata: updatedMetadata,
            frames: frames,
            layers: layers,
            session: SessionState(activeLayerID: "new-layer", currentFrameIndex: 1),
            root: tempDir
        )

        // 6. Reopen
        let reopened = try StudioStorage.shared.loadProject(id: "lifecycle", root: tempDir)
        XCTAssertEqual(reopened.metadata.name, "Updated Lifecycle")
        XCTAssertEqual(reopened.frames.count, 2)
        XCTAssertEqual(reopened.layers.count, 2)
        XCTAssertEqual(reopened.layers[0].id, "new-layer")
        XCTAssertEqual(reopened.session.activeLayerID, "new-layer")
        XCTAssertEqual(reopened.session.currentFrameIndex, 1)
        XCTAssertEqual(reopened.frames[1].elements[0].tool, .brush)
        XCTAssertEqual(reopened.frames[1].elements[0].points[0].x, 10)
    }

    // MARK: - No Auth/Network Required

    func testCreateAndSaveWithoutAuth() throws {
        try StudioStorage.shared.createProject(id: "no-auth", name: "Offline", root: tempDir)
        let frames = [AnimationFrame(id: "f1", elements: [])]
        try StudioStorage.shared.saveProject(id: "no-auth", frames: frames, root: tempDir)
        let loaded = try StudioStorage.shared.loadProject(id: "no-auth", root: tempDir)
        XCTAssertEqual(loaded.frames.count, 1)
    }

    // MARK: - Sparse Raster Frames (Legacy Compatibility)

    func testRasterFrameData() throws {
        try StudioStorage.shared.createProject(id: "raster", name: "Raster", root: tempDir)
        let dir = StudioStorage.shared.projectDirectory(id: "raster", root: tempDir)

        // Write sparse frame_0.png and frame_7.png
        let frame0Data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let frame7Data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1B, 0x0B])
        try frame0Data.write(to: dir.appendingPathComponent("frame_0.png"))
        try frame7Data.write(to: dir.appendingPathComponent("frame_7.png"))

        let loaded0 = StudioStorage.shared.rasterFrameData(projectID: "raster", frameIndex: 0, root: tempDir)
        let loaded7 = StudioStorage.shared.rasterFrameData(projectID: "raster", frameIndex: 7, root: tempDir)

        XCTAssertEqual(loaded0, frame0Data)
        XCTAssertEqual(loaded7, frame7Data)
        XCTAssertNotEqual(loaded0, loaded7)
    }

    func testRasterFrameDataMissing() {
        let data = StudioStorage.shared.rasterFrameData(projectID: "nonexistent", frameIndex: 0, root: tempDir)
        XCTAssertNil(data)
    }

    // MARK: - Vector Data Survives Round-Trip

    func testVectorDataSurvivesRoundTrip() throws {
        let element = DrawnElement(
            id: "vec-1",
            tool: .neon,
            points: [
                StrokePoint(x: 0.123, y: 456.789, pressure: 0.42, timestamp: 1234.5),
                StrokePoint(x: 999, y: 0, pressure: 1.0, timestamp: 5678.9)
            ],
            color: "#FF6600",
            width: 7.5,
            opacity: 0.33,
            fillColor: "#0000FF",
            layerID: "special-layer-id"
        )
        let frame = AnimationFrame(id: "v-frame", elements: [element])
        let layers = [CanvasLayer(id: "v-layer", name: "Vector")]

        try StudioStorage.shared.createProject(id: "vector", name: "Vector Test", root: tempDir)
        try StudioStorage.shared.saveProject(id: "vector", frames: [frame], layers: layers, root: tempDir)

        let loaded = try StudioStorage.shared.loadProject(id: "vector", root: tempDir)
        let e = loaded.frames[0].elements[0]
        XCTAssertEqual(e.id, "vec-1")
        XCTAssertEqual(e.tool, .neon)
        XCTAssertEqual(e.points.count, 2)
        XCTAssertEqual(e.points[0].x, 0.123, accuracy: 0.001)
        XCTAssertEqual(e.points[0].pressure!, 0.42, accuracy: 0.001)
        XCTAssertEqual(e.color, "#FF6600")
        XCTAssertEqual(e.layerID, "special-layer-id")
    }

    // MARK: - Layer Metadata Survives

    func testLayerMetadataSurvivesRoundTrip() throws {
        let layers = [
            CanvasLayer(
                id: "meta-layer",
                name: "Special",
                visible: false,
                locked: true,
                opacity: 0.42,
                lockMode: "alpha",
                blendMode: "overlay",
                glowEnabled: true,
                glowColor: "#ABCDEF",
                colorLabel: "#123456"
            )
        ]

        try StudioStorage.shared.createProject(id: "meta", name: "Meta", root: tempDir)
        try StudioStorage.shared.saveProject(id: "meta", layers: layers, root: tempDir)

        let loaded = try StudioStorage.shared.loadProject(id: "meta", root: tempDir)
        let l = loaded.layers[0]
        XCTAssertEqual(l.id, "meta-layer")
        XCTAssertEqual(l.name, "Special")
        XCTAssertFalse(l.visible)
        XCTAssertTrue(l.locked)
        XCTAssertEqual(l.opacity, 0.42)
        XCTAssertEqual(l.lockMode, "alpha")
        XCTAssertEqual(l.blendMode, "overlay")
        XCTAssertTrue(l.glowEnabled)
        XCTAssertEqual(l.glowColor, "#ABCDEF")
        XCTAssertEqual(l.colorLabel, "#123456")
    }

    // MARK: - Normal Save Never Deletes Raster Assets

    func testSaveNeverDeletesRasterAssets() throws {
        try StudioStorage.shared.createProject(id: "raster-save", name: "R", root: tempDir)
        let dir = StudioStorage.shared.projectDirectory(id: "raster-save", root: tempDir)

        let frameData = Data([0x89, 0x50, 0x4E, 0x47])
        try frameData.write(to: dir.appendingPathComponent("frame_0.png"))

        try StudioStorage.shared.saveProject(
            id: "raster-save",
            frames: [AnimationFrame(id: "f1", elements: [])],
            root: tempDir
        )

        let loaded = StudioStorage.shared.rasterFrameData(projectID: "raster-save", frameIndex: 0, root: tempDir)
        XCTAssertEqual(loaded, frameData)
    }

    // MARK: - Session State Default When Missing

    func testSessionDefaultWhenMissing() throws {
        try StudioStorage.shared.createProject(id: "no-session", name: "NoSession", root: tempDir)
        let dir = StudioStorage.shared.projectDirectory(id: "no-session", root: tempDir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("session.json"))

        let loaded = try StudioStorage.shared.loadProject(id: "no-session", root: tempDir)
        XCTAssertEqual(loaded.session.activeLayerID, loaded.layers.first?.id ?? "")
        XCTAssertEqual(loaded.session.currentFrameIndex, 0)
    }
}
