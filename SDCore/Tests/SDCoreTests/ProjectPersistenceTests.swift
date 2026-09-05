import XCTest
@testable import SDCore

final class ProjectPersistenceTests: XCTestCase {

    var tempRoot: URL!
    let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("SDCoreTests_\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        super.tearDown()
        try? fileManager.removeItem(at: tempRoot)
    }

    // MARK: - Full Integration Test (issue #48 acceptance criteria)

    func testPersistenceRoundTrip() throws {
        let persistence = ProjectPersistence()
        let projectID = "test-project-\(UUID().uuidString)"
        let root = tempRoot

        // 1. Create deterministic legacy raster files
        let rasterDir = persistence.rasterDirectory(root: root, projectID: projectID)
        try fileManager.createDirectory(at: rasterDir, withIntermediateDirectories: true)

        let frame0Bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]  // PNG header
        let frame7Bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]

        let frame0URL = rasterDir.appendingPathComponent("frame_0.png")
        let frame7URL = rasterDir.appendingPathComponent("frame_7.png")
        try Data(frame0Bytes).write(to: frame0URL)
        try Data(frame7Bytes).write(to: frame7URL)

        // Also create an unrelated file that must NOT be deleted
        let unrelatedURL = rasterDir.appendingPathComponent("notes.txt")
        let unrelatedBytes: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F]
        try Data(unrelatedBytes).write(to: unrelatedURL)

        // 2. Create a bundle with non-empty DrawnElement and canonical layer metadata
        let element = DrawnElement(
            id: "elem-001",
            tool: .brush,
            points: [
                StrokePoint(x: 10.5, y: 20.3, pressure: 0.8, timestamp: 1000),
                StrokePoint(x: 30.7, y: 40.1, pressure: 0.6, timestamp: 1050),
                StrokePoint(x: 50.0, y: 60.9, pressure: 0.4, timestamp: 1100)
            ],
            color: "#FF0000",
            width: 3.5,
            opacity: 0.9,
            fillColor: "#00FF00",
            layerID: "layer-001"
        )

        let frame = AnimationFrame(id: "frame-001", elements: [element])

        let layer = CanvasLayer(
            id: "layer-001",
            name: "Test Layer",
            visible: true,
            locked: false,
            opacity: 0.75,
            lockMode: "position",
            blendMode: "multiply",
            glowEnabled: true,
            glowColor: "#FFFF00",
            colorLabel: "#FF00FF"
        )

        let discoveredRasters = persistence.discoverLegacyRasters(root: root, projectID: projectID)
        XCTAssertEqual(discoveredRasters.count, 2, "Should discover both legacy rasters")

        let bundle = StudioProjectBundle(
            projectID: projectID,
            name: "Test Animation",
            width: 1920,
            height: 1080,
            fps: 24,
            frames: [frame],
            layers: [layer],
            legacyRasterReferences: discoveredRasters
        )

        // 3. Save through production persistence
        try persistence.save(bundle: bundle, root: root)

        // 4. Load through production persistence
        let loaded = try persistence.load(root: root, projectID: projectID)

        // 5. Assert vector element fields survive save/load
        XCTAssertEqual(loaded.frames.count, 1)
        XCTAssertEqual(loaded.frames[0].id, "frame-001")
        XCTAssertEqual(loaded.frames[0].elements.count, 1)
        let loadedElement = loaded.frames[0].elements[0]
        XCTAssertEqual(loadedElement.id, "elem-001")
        XCTAssertEqual(loadedElement.tool, .brush)
        XCTAssertEqual(loadedElement.points.count, 3)
        XCTAssertEqual(loadedElement.points[0].x, 10.5, accuracy: 0.001)
        XCTAssertEqual(loadedElement.points[0].y, 20.3, accuracy: 0.001)
        XCTAssertEqual(loadedElement.points[0].pressure!, 0.8, accuracy: 0.001)
        XCTAssertEqual(loadedElement.points[0].timestamp!, 1000, accuracy: 0.001)
        XCTAssertEqual(loadedElement.points[2].x, 50.0, accuracy: 0.001)
        XCTAssertEqual(loadedElement.color, "#FF0000")
        XCTAssertEqual(loadedElement.width, 3.5, accuracy: 0.001)
        XCTAssertEqual(loadedElement.opacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(loadedElement.fillColor, "#00FF00")
        XCTAssertEqual(loadedElement.layerID, "layer-001")

        // 6. Assert layer metadata survives
        XCTAssertEqual(loaded.layers.count, 1)
        let loadedLayer = loaded.layers[0]
        XCTAssertEqual(loadedLayer.id, "layer-001")
        XCTAssertEqual(loadedLayer.name, "Test Layer")
        XCTAssertTrue(loadedLayer.visible)
        XCTAssertFalse(loadedLayer.locked)
        XCTAssertEqual(loadedLayer.opacity, 0.75, accuracy: 0.001)
        XCTAssertEqual(loadedLayer.lockMode, "position")
        XCTAssertEqual(loadedLayer.blendMode, "multiply")
        XCTAssertTrue(loadedLayer.glowEnabled)
        XCTAssertEqual(loadedLayer.glowColor, "#FFFF00")
        XCTAssertEqual(loadedLayer.colorLabel, "#FF00FF")

        // 7. Assert both legacy raster refs are retained
        XCTAssertEqual(loaded.legacyRasterReferences.count, 2)
        XCTAssertEqual(loaded.legacyRasterReferences[0].frameIndex, 0)
        XCTAssertEqual(loaded.legacyRasterReferences[0].fileName, "frame_0.png")
        XCTAssertEqual(loaded.legacyRasterReferences[1].frameIndex, 7)
        XCTAssertEqual(loaded.legacyRasterReferences[1].fileName, "frame_7.png")

        // 8. Re-save and reload
        var mutatedBundle = loaded
        mutatedBundle.name = "Test Animation v2"
        mutatedBundle.updatedAt = Date()
        try persistence.save(bundle: mutatedBundle, root: root)

        let reloaded = try persistence.load(root: root, projectID: projectID)
        XCTAssertEqual(reloaded.name, "Test Animation v2")
        XCTAssertEqual(reloaded.frames[0].elements[0].points[0].x, 10.5, accuracy: 0.001)
        XCTAssertEqual(reloaded.layers[0].name, "Test Layer")
        XCTAssertEqual(reloaded.legacyRasterReferences.count, 2)

        // 9. Assert raster bytes are byte-identical after save
        let reloadedFrame0 = try Data(contentsOf: frame0URL)
        XCTAssertEqual(reloadedFrame0, Data(frame0Bytes))
        let reloadedFrame7 = try Data(contentsOf: frame7URL)
        XCTAssertEqual(reloadedFrame7, Data(frame7Bytes))

        // 10. Assert unrelated file is NOT silently deleted
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedURL.path))
        let reloadedUnrelated = try Data(contentsOf: unrelatedURL)
        XCTAssertEqual(reloadedUnrelated, Data(unrelatedBytes))
    }

    // MARK: - Legacy Raster Discovery

    func testLegacyRasterDiscovery() throws {
        let persistence = ProjectPersistence()
        let projectID = "discovery-test"

        let rasterDir = persistence.rasterDirectory(root: tempRoot, projectID: projectID)
        try fileManager.createDirectory(at: rasterDir, withIntermediateDirectories: true)

        // Create frame_0.png through frame_3.png (skip frame_2)
        for index in [0, 1, 3] {
            let data = Data([UInt8(index)])
            try data.write(to: rasterDir.appendingPathComponent("frame_\(index).png"))
        }

        // Create a non-PNG file that should be ignored
        try Data([0xFF]).write(to: rasterDir.appendingPathComponent("notes.txt"))

        let refs = persistence.discoverLegacyRasters(root: tempRoot, projectID: projectID)
        XCTAssertEqual(refs.count, 3)
        XCTAssertEqual(refs[0].frameIndex, 0)
        XCTAssertEqual(refs[1].frameIndex, 1)
        XCTAssertEqual(refs[2].frameIndex, 3)
    }

    // MARK: - Migration / Non-destructive Discovery

    func testMigrationAddsDiscoveredRasters() throws {
        let persistence = ProjectPersistence()
        let projectID = "migration-test"

        // Create raster files
        let rasterDir = persistence.rasterDirectory(root: tempRoot, projectID: projectID)
        try fileManager.createDirectory(at: rasterDir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: rasterDir.appendingPathComponent("frame_0.png"))
        try Data([0x02]).write(to: rasterDir.appendingPathComponent("frame_5.png"))

        // Create a bundle with no legacy refs
        let bundle = StudioProjectBundle(projectID: projectID, name: "Migration Test")
        try persistence.save(bundle: bundle, root: tempRoot)

        // Load and migrate
        let loaded = try persistence.load(root: tempRoot, projectID: projectID)
        let migrated = try persistence.migrateAndDiscover(
            root: tempRoot,
            projectID: projectID,
            existingBundle: loaded
        )

        XCTAssertEqual(migrated.legacyRasterReferences.count, 2)
        XCTAssertEqual(migrated.legacyRasterReferences[0].frameIndex, 0)
        XCTAssertEqual(migrated.legacyRasterReferences[1].frameIndex, 5)
    }

    // MARK: - List Projects

    func testListProjects() throws {
        let persistence = ProjectPersistence()

        for i in 0..<3 {
            let bundle = StudioProjectBundle(
                projectID: "proj-\(i)",
                name: "Project \(i)"
            )
            try persistence.save(bundle: bundle, root: tempRoot)
        }

        let projects = persistence.listProjects(root: tempRoot)
        XCTAssertEqual(projects.count, 3)
    }

    // MARK: - Delete Project

    func testDeleteProject() throws {
        let persistence = ProjectPersistence()
        let projectID = "delete-test"

        let bundle = StudioProjectBundle(projectID: projectID, name: "Delete Me")
        try persistence.save(bundle: bundle, root: tempRoot)

        let projectDir = persistence.projectDirectory(root: tempRoot, projectID: projectID)
        XCTAssertTrue(fileManager.fileExists(atPath: projectDir.path))

        try persistence.deleteProject(root: tempRoot, projectID: projectID)
        XCTAssertFalse(fileManager.fileExists(atPath: projectDir.path))
    }

    // MARK: - Foundation-only Compilation Test

    func testFoundationOnlyCompilation() {
        // This test verifies SDCore compiles and runs without UIKit/SwiftUI.
        // All types use Foundation-only Codable, Double (not CGFloat),
        // and FileManager for persistence.
        let bundle = StudioProjectBundle(
            projectID: "compile-check",
            name: "Compile Check"
        )
        XCTAssertEqual(bundle.name, "Compile Check")
        XCTAssertEqual(bundle.width, 1080)

        let element = DrawnElement(
            tool: .pen,
            points: [StrokePoint(x: 1.0, y: 2.0)],
            color: "#000000",
            width: 1.0,
            opacity: 1.0
        )
        XCTAssertEqual(element.tool, .pen)
        XCTAssertEqual(element.points[0].x, 1.0)

        let layer = CanvasLayer(name: "Test")
        XCTAssertEqual(layer.name, "Test")

        let ref = LegacyRasterReference(frameIndex: 0, fileName: "frame_0.png", byteCount: 1024)
        XCTAssertEqual(ref.frameIndex, 0)
    }

    // MARK: - Codable Round-Trip for All Model Types

    func testModelCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // DrawingTool
        let tool = DrawingTool.brush
        let toolData = try encoder.encode(tool)
        let decodedTool = try decoder.decode(DrawingTool.self, from: toolData)
        XCTAssertEqual(decodedTool, .brush)

        // StrokePoint
        let point = StrokePoint(x: 10.5, y: 20.3, pressure: 0.8, timestamp: 1000)
        let pointData = try encoder.encode(point)
        let decodedPoint = try decoder.decode(StrokePoint.self, from: pointData)
        XCTAssertEqual(decodedPoint.x, 10.5)
        XCTAssertEqual(decodedPoint.pressure!, 0.8)

        // DrawnElement
        let element = DrawnElement(
            id: "e1", tool: .pencil, points: [point],
            color: "#FF0000", width: 2.0, opacity: 0.5
        )
        let elemData = try encoder.encode(element)
        let decodedElem = try decoder.decode(DrawnElement.self, from: elemData)
        XCTAssertEqual(decodedElem.id, "e1")
        XCTAssertEqual(decodedElem.tool, .pencil)

        // AnimationFrame
        let frame = AnimationFrame(id: "f1", elements: [element])
        let frameData = try encoder.encode(frame)
        let decodedFrame = try decoder.decode(AnimationFrame.self, from: frameData)
        XCTAssertEqual(decodedFrame.id, "f1")

        // CanvasLayer
        let layer = CanvasLayer(id: "l1", name: "Layer 1", opacity: 0.5)
        let layerData = try encoder.encode(layer)
        let decodedLayer = try decoder.decode(CanvasLayer.self, from: layerData)
        XCTAssertEqual(decodedLayer.id, "l1")
        XCTAssertEqual(decodedLayer.opacity, 0.5)

        // StudioProjectBundle
        let bundle = StudioProjectBundle(
            projectID: "p1", name: "Test",
            frames: [frame], layers: [layer]
        )
        let bundleData = try encoder.encode(bundle)
        let decodedBundle = try decoder.decode(StudioProjectBundle.self, from: bundleData)
        XCTAssertEqual(decodedBundle.projectID, "p1")
        XCTAssertEqual(decodedBundle.frames.count, 1)

        // LegacyRasterReference
        let ref = LegacyRasterReference(frameIndex: 0, fileName: "frame_0.png", byteCount: 512)
        let refData = try encoder.encode(ref)
        let decodedRef = try decoder.decode(LegacyRasterReference.self, from: refData)
        XCTAssertEqual(decodedRef.frameIndex, 0)
    }
}
