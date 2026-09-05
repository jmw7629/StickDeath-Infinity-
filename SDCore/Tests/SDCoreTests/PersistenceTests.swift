// ═══════════════════════════════════════════════════════════════════
// PersistenceTests — Real file-system persistence integration tests
// Exercises the same ProjectPersistence used by the iOS app.
// Runs on Linux and macOS/iOS (no UIKit/CoreData dependency).
// ═══════════════════════════════════════════════════════════════════

import XCTest
@testable import SDCore

final class PersistenceTests: XCTestCase {

    var tempDir: URL!
    var persistence: ProjectPersistence!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        persistence = ProjectPersistence(baseDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    func makeProjectBundle(
        projectID: String = UUID().uuidString,
        frameCount: Int = 3,
        layerCount: Int = 2
    ) -> ProjectBundle {
        var frames: [AnimationFrame] = []
        for i in 0..<frameCount {
            var elements: [DrawnElement] = []
            // Add a vector element to the first frame
            if i == 0 {
                elements.append(DrawnElement(
                    id: "elem_\(i)",
                    tool: .brush,
                    points: [
                        StrokePoint(x: 100.0, y: 200.0, pressure: 0.8, timestamp: 1.0),
                        StrokePoint(x: 150.0, y: 250.0, pressure: 0.9, timestamp: 2.0),
                        StrokePoint(x: 200.0, y: 300.0, pressure: 0.7, timestamp: 3.0),
                    ],
                    color: "#FF0000",
                    width: 5.0,
                    opacity: 1.0,
                    fillColor: nil,
                    layerID: "layer_0"
                ))
            }
            frames.append(AnimationFrame(id: "frame_\(i)", elements: elements))
        }

        var layers: [CanvasLayer] = []
        for i in 0..<layerCount {
            layers.append(CanvasLayer(
                id: "layer_\(i)",
                name: "Layer \(i + 1)",
                visible: true,
                locked: false,
                opacity: 1.0 - Double(i) * 0.2
            ))
        }

        return ProjectBundle(
            project: StudioProjectRecord(
                id: projectID,
                userID: "user_001",
                name: "Test Animation",
                width: 1080,
                height: 720,
                fps: 12,
                frameCount: frameCount,
                legacyRasterFiles: ["frame_0.png", "frame_1.png"]
            ),
            frames: frames,
            layers: layers,
            legacyRasterFiles: ["frame_0.png", "frame_1.png"]
        )
    }

    func makeRasterData(filename: String, seed: UInt8 = 0x42) -> Data {
        // Deterministic raster bytes — simple PNG-like header + pattern
        var data = Data()
        // PNG signature (8 bytes)
        data.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // IHDR chunk (simplified)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D]) // length
        data.append(contentsOf: [0x49, 0x48, 0x44, 0x52]) // "IHDR"
        // Fill with deterministic pattern based on filename
        let nameBytes = Array(filename.utf8)
        for i in 0..<64 {
            data.append(nameBytes[i % nameBytes.count] &+ seed &+ UInt8(i))
        }
        return data
    }

    // MARK: - Test: Create and Save

    func testSaveAndLoad() throws {
        let bundle = makeProjectBundle()
        try persistence.save(bundle)

        let loaded = try persistence.load(projectID: bundle.project.id)
        XCTAssertEqual(loaded.project.id, bundle.project.id)
        XCTAssertEqual(loaded.project.name, "Test Animation")
        XCTAssertEqual(loaded.frames.count, 3)
        XCTAssertEqual(loaded.layers.count, 2)
    }

    // MARK: - Test: Vector element survives save/load

    func testVectorElementSurvivesSaveLoad() throws {
        let bundle = makeProjectBundle(frameCount: 2)
        try persistence.save(bundle)

        let loaded = try persistence.load(projectID: bundle.project.id)

        // First frame should have the vector element
        let firstFrame = loaded.frames[0]
        XCTAssertEqual(firstFrame.elements.count, 1)

        let elem = firstFrame.elements[0]
        XCTAssertEqual(elem.id, "elem_0")
        XCTAssertEqual(elem.tool, .brush)
        XCTAssertEqual(elem.points.count, 3)
        XCTAssertEqual(elem.color, "#FF0000")
        XCTAssertEqual(elem.width, 5.0, accuracy: 0.001)
        XCTAssertEqual(elem.opacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(elem.layerID, "layer_0")

        // Stroke points
        XCTAssertEqual(elem.points[0].x, 100.0, accuracy: 0.001)
        XCTAssertEqual(elem.points[0].y, 200.0, accuracy: 0.001)
        XCTAssertEqual(elem.points[0].pressure!, 0.8, accuracy: 0.001)
        XCTAssertEqual(elem.points[2].x, 200.0, accuracy: 0.001)
    }

    // MARK: - Test: Layer metadata survives save/load

    func testLayerMetadataSurvivesSaveLoad() throws {
        let bundle = makeProjectBundle(layerCount: 3)
        try persistence.save(bundle)

        let loaded = try persistence.load(projectID: bundle.project.id)
        XCTAssertEqual(loaded.layers.count, 3)

        XCTAssertEqual(loaded.layers[0].name, "Layer 1")
        XCTAssertEqual(loaded.layers[0].opacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(loaded.layers[0].visible, true)
        XCTAssertEqual(loaded.layers[0].locked, false)

        XCTAssertEqual(loaded.layers[1].name, "Layer 2")
        XCTAssertEqual(loaded.layers[1].opacity, 0.8, accuracy: 0.001)

        XCTAssertEqual(loaded.layers[2].name, "Layer 3")
        XCTAssertEqual(loaded.layers[2].opacity, 0.6, accuracy: 0.001)
    }

    // MARK: - Test: Legacy raster files survive save/load

    func testLegacyRasterFilesPreserved() throws {
        let projectID = UUID().uuidString
        let bundle = makeProjectBundle(projectID: projectID)

        // Create raster files
        let raster0 = makeRasterData(filename: "frame_0.png", seed: 0xAA)
        let raster1 = makeRasterData(filename: "frame_1.png", seed: 0xBB)
        let rasterFiles: [String: Data] = [
            "frame_0.png": raster0,
            "frame_1.png": raster1,
        ]

        // Save complete project with raster files
        try persistence.saveComplete(bundle: bundle, rasterFiles: rasterFiles)

        // Verify raster files exist on disk
        let projectDir = persistence.projectDir(for: projectID)
        let file0 = projectDir.appendingPathComponent("frame_0.png")
        let file1 = projectDir.appendingPathComponent("frame_1.png")

        XCTAssertTrue(FileManager.default.fileExists(atPath: file0.path), "frame_0.png should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path), "frame_1.png should exist")

        // Verify bytes are identical
        let loadedData0 = try Data(contentsOf: file0)
        let loadedData1 = try Data(contentsOf: file1)
        XCTAssertEqual(loadedData0, raster0, "frame_0.png bytes should be identical after save/load")
        XCTAssertEqual(loadedData1, raster1, "frame_1.png bytes should be identical after save/load")

        // Verify through loadLegacyRasterFiles
        let loadedRaster = try persistence.loadLegacyRasterFiles(projectID: projectID)
        XCTAssertEqual(loadedRaster["frame_0.png"], raster0)
        XCTAssertEqual(loadedRaster["frame_1.png"], raster1)
    }

    // MARK: - Test: Re-save does not delete unrelated raster files

    func testResaveDoesNotDeleteUnrelatedRasterFiles() throws {
        let projectID = UUID().uuidString
        var bundle = makeProjectBundle(projectID: projectID)

        // Save with raster files
        let raster0 = makeRasterData(filename: "frame_0.png", seed: 0x11)
        let raster5 = makeRasterData(filename: "frame_5.png", seed: 0x55)
        try persistence.saveComplete(
            bundle: bundle,
            rasterFiles: ["frame_0.png": raster0, "frame_5.png": raster5]
        )

        // Verify both raster files exist
        let projectDir = persistence.projectDir(for: projectID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("frame_0.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("frame_5.png").path))

        // Mutate the bundle (add a frame) and re-save
        bundle.frames.append(AnimationFrame(id: "frame_new", elements: []))
        bundle.project.frameCount = 4

        // Re-save WITHOUT explicitly providing raster files
        try persistence.saveComplete(bundle: bundle, rasterFiles: [:])

        // Verify frame_5.png is NOT silently deleted
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("frame_5.png").path),
            "frame_5.png must NOT be silently deleted by a normal save/re-save"
        )

        // Verify frame_0.png also survives
        let loadedData0 = try Data(contentsOf: projectDir.appendingPathComponent("frame_0.png"))
        XCTAssertEqual(loadedData0, raster0, "frame_0.png bytes must survive re-save")
    }

    // MARK: - Test: Re-save updates raster files when provided

    func testResaveUpdatesRasterFilesWhenProvided() throws {
        let projectID = UUID().uuidString
        let bundle = makeProjectBundle(projectID: projectID)

        let originalData = makeRasterData(filename: "frame_0.png", seed: 0xAA)
        try persistence.saveComplete(bundle: bundle, rasterFiles: ["frame_0.png": originalData])

        // Mutate raster file
        let newData = makeRasterData(filename: "frame_0.png", seed: 0xBB)
        try persistence.saveComplete(bundle: bundle, rasterFiles: ["frame_0.png": newData])

        let projectDir = persistence.projectDir(for: projectID)
        let loadedData = try Data(contentsOf: projectDir.appendingPathComponent("frame_0.png"))
        XCTAssertEqual(loadedData, newData, "Raster file should be updated when explicitly provided")
    }

    // MARK: - Test: Project metadata fields survive

    func testProjectMetadataSurvives() throws {
        let bundle = makeProjectBundle()
        try persistence.save(bundle)

        let loaded = try persistence.load(projectID: bundle.project.id)
        XCTAssertEqual(loaded.project.userID, "user_001")
        XCTAssertEqual(loaded.project.width, 1080)
        XCTAssertEqual(loaded.project.height, 720)
        XCTAssertEqual(loaded.project.fps, 12)
        XCTAssertEqual(loaded.project.frameCount, 3)
    }

    // MARK: - Test: List projects

    func testListProjects() throws {
        let bundle1 = makeProjectBundle(projectID: "proj_a")
        let bundle2 = makeProjectBundle(projectID: "proj_b")

        try persistence.save(bundle1)
        try persistence.save(bundle2)

        let projects = persistence.listProjects()
        XCTAssertEqual(projects.count, 2)
        let ids = Set(projects.map(\.id))
        XCTAssertTrue(ids.contains("proj_a"))
        XCTAssertTrue(ids.contains("proj_b"))
    }

    // MARK: - Test: Delete project

    func testDeleteProject() throws {
        let bundle = makeProjectBundle()
        try persistence.save(bundle)

        let projectDir = persistence.projectDir(for: bundle.project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.path))

        try persistence.delete(projectID: bundle.project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir.path))
    }

    // MARK: - Test: Load non-existent project throws

    func testLoadNonExistentProjectThrows() {
        XCTAssertThrowsError(try persistence.load(projectID: "nonexistent")) { error in
            guard let persistenceError = error as? PersistenceError else {
                XCTFail("Expected PersistenceError, got \(type(of: error))")
                return
            }
            if case .fileNotFound = persistenceError {
                // OK
            } else {
                XCTFail("Expected fileNotFound, got \(persistenceError)")
            }
        }
    }

    // MARK: - Test: Codable round-trip for all types

    func testCodableRoundTripAllTypes() throws {
        let strokePoint = StrokePoint(x: 42.5, y: 99.9, pressure: 0.75, timestamp: 1234567890.0)
        let element = DrawnElement(
            id: "test_elem",
            tool: .pen,
            points: [strokePoint],
            color: "#ABCDEF",
            width: 3.5,
            opacity: 0.9,
            fillColor: "#123456",
            layerID: "layer_test"
        )
        let frame = AnimationFrame(id: "test_frame", elements: [element])
        let layer = CanvasLayer(id: "layer_test", name: "Test Layer", visible: true, locked: false, opacity: 0.8)

        // Encode
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let frameData = try encoder.encode(frame)
        let layerData = try encoder.encode(layer)

        // Decode
        let decodedFrame = try JSONDecoder().decode(AnimationFrame.self, from: frameData)
        let decodedLayer = try JSONDecoder().decode(CanvasLayer.self, from: layerData)

        XCTAssertEqual(decodedFrame.id, "test_frame")
        XCTAssertEqual(decodedFrame.elements.count, 1)
        XCTAssertEqual(decodedFrame.elements[0].points[0].x, 42.5, accuracy: 0.001)
        XCTAssertEqual(decodedFrame.elements[0].color, "#ABCDEF")
        XCTAssertEqual(decodedLayer.name, "Test Layer")
        XCTAssertEqual(decodedLayer.opacity, 0.8, accuracy: 0.001)
    }

    // MARK: - Test: StrokePoint equality

    func testStrokePointEquality() {
        let a = StrokePoint(x: 1.0, y: 2.0, pressure: 0.5, timestamp: 100.0)
        let b = StrokePoint(x: 1.0, y: 2.0, pressure: 0.5, timestamp: 100.0)
        let c = StrokePoint(x: 1.0, y: 2.0, pressure: 0.6, timestamp: 100.0)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Test: Empty project save/load

    func testEmptyProjectSaveLoad() throws {
        let projectID = UUID().uuidString
        let bundle = ProjectBundle(
            project: StudioProjectRecord(id: projectID, userID: "u", name: "Empty"),
            frames: [],
            layers: [],
            legacyRasterFiles: []
        )
        try persistence.save(bundle)
        let loaded = try persistence.load(projectID: projectID)
        XCTAssertEqual(loaded.frames.count, 0)
        XCTAssertEqual(loaded.layers.count, 0)
    }
}
