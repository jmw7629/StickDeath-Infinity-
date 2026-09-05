import XCTest
@testable import SDCore

final class PersistenceTests: XCTestCase {

    var tempDir: URL!
    var storage: StudioStorage!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storage = StudioStorage(fileManager: .default, baseDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Create project

    func testCreateProject() throws {
        let meta = try storage.createProject(
            id: "proj_1",
            name: "Test Project",
            width: 1920,
            height: 1080,
            fps: 24
        )
        XCTAssertEqual(meta.id, "proj_1")
        XCTAssertEqual(meta.name, "Test Project")
        XCTAssertEqual(meta.width, 1920)
        XCTAssertEqual(meta.height, 1080)
        XCTAssertEqual(meta.fps, 24)
    }

    func testCreateProjectAssignsIDImmediately() throws {
        let meta = try storage.createProject(name: "Auto ID")
        XCTAssertFalse(meta.id.isEmpty)
    }

    func testCreateProjectCreatesFiles() throws {
        try storage.createProject(id: "proj_2")
        let metaURL = tempDir.appendingPathComponent("proj_2/metadata.json")
        let framesURL = tempDir.appendingPathComponent("proj_2/frames.json")
        let layersURL = tempDir.appendingPathComponent("proj_2/layers.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: framesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layersURL.path))
    }

    // MARK: - Save and load

    func testSaveAndLoadFrames() throws {
        try storage.createProject(id: "proj_3")
        let frames = [
            AnimationFrame(id: "f1", elements: [
                DrawnElement(tool: .brush, points: [StrokePoint(x: 0, y: 0)], color: "#FF0000", width: 3, opacity: 1)
            ]),
            AnimationFrame(id: "f2", elements: [])
        ]
        try storage.saveFrames(frames, for: "proj_3")
        let loaded = try storage.loadFrames(for: "proj_3")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, "f1")
        XCTAssertEqual(loaded[0].elements[0].width, 3)
    }

    func testSaveAndLoadLayers() throws {
        try storage.createProject(id: "proj_4")
        let layers = [
            CanvasLayer(id: "l1", name: "Background", visible: true, opacity: 0.8),
            CanvasLayer(id: "l2", name: "Foreground", visible: false, opacity: 0.5)
        ]
        try storage.saveLayers(layers, for: "proj_4")
        let loaded = try storage.loadLayers(for: "proj_4")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Background")
        XCTAssertFalse(loaded[1].visible)
    }

    func testSaveAndLoadState() throws {
        try storage.createProject(id: "proj_5")
        try storage.save(
            frames: [AnimationFrame(id: "f1")],
            layers: [CanvasLayer(id: "l1", name: "Layer 1")],
            activeLayerID: "l1",
            currentFrameIndex: 0,
            for: "proj_5"
        )
        let state = storage.loadState(for: "proj_5")
        XCTAssertEqual(state.activeLayerID, "l1")
        XCTAssertEqual(state.currentFrameIndex, 0)
    }

    func testSaveFullProjectAndReload() throws {
        try storage.createProject(id: "proj_6", name: "Full Save Test")
        let frames = [
            AnimationFrame(id: "frame_0", elements: [
                DrawnElement(
                    id: "e1", tool: .pen,
                    points: [StrokePoint(x: 10, y: 20), StrokePoint(x: 30, y: 40)],
                    color: "#FF0000", width: 2.5, opacity: 0.9, layerID: "l1"
                )
            ])
        ]
        let layers = [CanvasLayer(id: "l1", name: "Layer 1", visible: true, opacity: 1.0)]
        try storage.save(frames: frames, layers: layers, activeLayerID: "l1", currentFrameIndex: 0, for: "proj_6")

        let result = try storage.load(for: "proj_6")
        XCTAssertEqual(result.meta.name, "Full Save Test")
        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames[0].elements[0].points[1].x, 30)
        XCTAssertEqual(result.layers.count, 1)
        XCTAssertEqual(result.state.activeLayerID, "l1")
    }

    // MARK: - List projects

    func testListProjects() throws {
        try storage.createProject(id: "p1", name: "First")
        try storage.createProject(id: "p2", name: "Second")
        try storage.createProject(id: "p3", name: "Third")
        let projects = storage.listProjects()
        XCTAssertEqual(projects.count, 3)
    }

    func testListProjectsEmpty() {
        let projects = storage.listProjects()
        XCTAssertTrue(projects.isEmpty)
    }

    // MARK: - Delete project

    func testDeleteProject() throws {
        try storage.createProject(id: "proj_del")
        try storage.deleteProject(id: "proj_del")
        XCTAssertThrowsError(try storage.loadMetadata(for: "proj_del"))
    }

    func testDeleteNonexistentProject() {
        XCTAssertThrowsError(try storage.deleteProject(id: "nonexistent"))
    }

    // MARK: - Raster assets

    func testSaveAndLoadRasterAsset() throws {
        try storage.createProject(id: "proj_raster")
        let data = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header bytes
        let url = try storage.saveRasterAsset(data: data, projectID: "proj_raster", filename: "frame_0.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let loaded = try storage.loadRasterAsset(projectID: "proj_raster", filename: "frame_0.png")
        XCTAssertEqual(loaded, data)
    }

    func testRasterAssetExists() throws {
        try storage.createProject(id: "proj_exists")
        XCTAssertFalse(storage.rasterAssetExists(projectID: "proj_exists", filename: "frame_0.png"))
        try storage.saveRasterAsset(data: Data([0x01]), projectID: "proj_exists", filename: "frame_0.png")
        XCTAssertTrue(storage.rasterAssetExists(projectID: "proj_exists", filename: "frame_0.png"))
    }

    func testListRasterAssets() throws {
        try storage.createProject(id: "proj_list")
        try storage.saveRasterAsset(data: Data([0x01]), projectID: "proj_list", filename: "frame_0.png")
        try storage.saveRasterAsset(data: Data([0x02]), projectID: "proj_list", filename: "frame_7.png")
        let assets = storage.listRasterAssets(projectID: "proj_list")
        XCTAssertEqual(assets, ["frame_0.png", "frame_7.png"])
    }

    // MARK: - Non-destructive save

    func testNormalSaveDoesNotDeleteRasterAssets() throws {
        try storage.createProject(id: "proj_nodelete")
        let data = Data([0xFF, 0xFF, 0xFF])
        try storage.saveRasterAsset(data: data, projectID: "proj_nodelete", filename: "frame_0.png")

        let frames = [AnimationFrame(id: "f1", elements: [
            DrawnElement(tool: .brush, points: [StrokePoint(x: 0, y: 0)], color: "#000", width: 2, opacity: 1)
        ])]
        try storage.save(frames: frames, layers: [CanvasLayer(id: "l1", name: "L")], activeLayerID: "l1", currentFrameIndex: 0, for: "proj_nodelete")

        let loaded = try storage.loadRasterAsset(projectID: "proj_nodelete", filename: "frame_0.png")
        XCTAssertEqual(loaded, data)
    }

    // MARK: - Metadata is Codable

    func testProjectMetadataCodable() throws {
        let meta = ProjectMetadata(id: "m1", name: "Test", width: 800, height: 600, fps: 30, frameCount: 5, layerCount: 3)
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ProjectMetadata.self, from: data)
        XCTAssertEqual(decoded.id, "m1")
        XCTAssertEqual(decoded.width, 800)
        XCTAssertEqual(decoded.frameCount, 5)
    }
}
