import XCTest
@testable import SDCore

final class MigrationTests: XCTestCase {

    var tempDir: URL!
    var storage: StudioStorage!
    var migration: LegacyMigration!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreMigrationTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fm = FileManager.default

        let docsDir = tempDir.appendingPathComponent("Documents", isDirectory: true)
        try! fm.createDirectory(at: docsDir, withIntermediateDirectories: true)

        let animationsDir = docsDir.appendingPathComponent("Animations", isDirectory: true)
        try! fm.createDirectory(at: animationsDir, withIntermediateDirectories: true)

        let studioProjectsDir = docsDir.appendingPathComponent("StudioProjects", isDirectory: true)
        try! fm.createDirectory(at: studioProjectsDir, withIntermediateDirectories: true)

        storage = StudioStorage(fileManager: fm, baseDir: studioProjectsDir)
        migration = LegacyMigration(fileManager: fm, documentsDir: docsDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Discovery

    func testDiscoverLegacyProjects() throws {
        let fm = FileManager.default
        let animationsDir = tempDir.appendingPathComponent("Documents/Animations")
        try fm.createDirectory(at: animationsDir.appendingPathComponent("legacy_001", withIntermediateDirectories: true))
        try fm.createDirectory(at: animationsDir.appendingPathComponent("legacy_002", withIntermediateDirectories: true))
        // Non-directory file should be skipped
        try "not a project".data(using: .utf8)!.write(to: animationsDir.appendingPathComponent("readme.txt"))

        let discovered = migration.discoverLegacyProjects()
        XCTAssertEqual(discovered, ["legacy_001", "legacy_002"])
    }

    // MARK: - Sibling layout migration

    func testMigrateLegacySiblingLayout() throws {
        let fm = FileManager.default
        let projectID = "old_project_42"
        let legacyDir = migration.legacyAnimationsDir.appendingPathComponent(projectID)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        // frame_0.png — deterministic bytes A
        let frame0Data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
        try frame0Data.write(to: legacyDir.appendingPathComponent("frame_0.png"))

        // frame_7.png — deterministic bytes B (distinct from A)
        let frame7Data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        try frame7Data.write(to: legacyDir.appendingPathComponent("frame_7.png"))

        // Unrelated file
        let unrelatedData = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        try unrelatedData.write(to: legacyDir.appendingPathComponent("notes.txt"))

        // Legacy metadata
        let meta = ["title": "Old Animation"]
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        try metaData.write(to: legacyDir.appendingPathComponent("metadata.json"))

        let result = try migration.migrateLegacyProject(projectID: projectID, storage: storage)

        XCTAssertEqual(result.migratedProjectIDs, [projectID])
        XCTAssertEqual(result.migratedFrameCount, 2)
        XCTAssertTrue(result.conflicts.isEmpty)

        // Canonical files exist
        let canonicalFrame0 = storage.projectsRoot.appendingPathComponent(projectID).appendingPathComponent("frame_0.png")
        let canonicalFrame7 = storage.projectsRoot.appendingPathComponent(projectID).appendingPathComponent("frame_7.png")
        XCTAssertTrue(fm.fileExists(atPath: canonicalFrame0.path))
        XCTAssertTrue(fm.fileExists(atPath: canonicalFrame7.path))

        // Bytes match
        XCTAssertEqual(try Data(contentsOf: canonicalFrame0), frame0Data)
        XCTAssertEqual(try Data(contentsOf: canonicalFrame7), frame7Data)

        // Unrelated file preserved in assets
        let canonicalAsset = storage.projectsRoot.appendingPathComponent(projectID)
            .appendingPathComponent("assets/notes.txt")
        XCTAssertTrue(fm.fileExists(atPath: canonicalAsset.path))
        XCTAssertEqual(try Data(contentsOf: canonicalAsset), unrelatedData)
    }

    // MARK: - Legacy source preserved

    func testLegacySourcePreservedAfterMigration() throws {
        let fm = FileManager.default
        let projectID = "preserved_project"
        let legacyDir = migration.legacyAnimationsDir.appendingPathComponent(projectID)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let frameData = Data([0x01, 0x02, 0x03])
        try frameData.write(to: legacyDir.appendingPathComponent("frame_0.png"))

        try migration.migrateLegacyProject(projectID: projectID, storage: storage)

        // Legacy source still exists and is byte-identical
        XCTAssertTrue(migration.legacyFilePreserved(projectID: projectID, filename: "frame_0.png"))
        let legacyBytes = try migration.legacyFileBytes(projectID: projectID, filename: "frame_0.png")
        XCTAssertEqual(legacyBytes, frameData)
    }

    // MARK: - Collision: identical bytes

    func testMigrationCollisionIdenticalBytesSkips() throws {
        let fm = FileManager.default
        let projectID = "collision_identical"
        let legacyDir = migration.legacyAnimationsDir.appendingPathComponent(projectID)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let frameData = Data([0xAA, 0xBB, 0xCC])
        try frameData.write(to: legacyDir.appendingPathComponent("frame_0.png"))

        // Pre-create canonical destination with identical bytes
        let canonicalDir = storage.projectsRoot.appendingPathComponent(projectID)
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try frameData.write(to: canonicalDir.appendingPathComponent("frame_0.png"))

        let result = try migration.migrateLegacyProject(projectID: projectID, storage: storage)

        XCTAssertTrue(result.skippedFiles.contains("frame_0.png"))
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    // MARK: - Collision: different bytes

    func testMigrationCollisionDifferentBytesReportsConflict() throws {
        let fm = FileManager.default
        let projectID = "collision_different"
        let legacyDir = migration.legacyAnimationsDir.appendingPathComponent(projectID)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let legacyData = Data([0x01, 0x02, 0x03])
        let canonicalData = Data([0xFF, 0xFE, 0xFD])
        try legacyData.write(to: legacyDir.appendingPathComponent("frame_0.png"))

        let canonicalDir = storage.projectsRoot.appendingPathComponent(projectID)
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try canonicalData.write(to: canonicalDir.appendingPathComponent("frame_0.png"))

        let result = try migration.migrateLegacyProject(projectID: projectID, storage: storage)

        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.conflicts[0].filename, "frame_0.png")
        XCTAssertEqual(result.conflicts[0].legacyBytes, 3)
        XCTAssertEqual(result.conflicts[0].canonicalBytes, 3)

        // Legacy source preserved
        XCTAssertTrue(migration.legacyFilePreserved(projectID: projectID, filename: "frame_0.png"))

        // Canonical not overwritten
        let canonicalStill = try Data(contentsOf: canonicalDir.appendingPathComponent("frame_0.png"))
        XCTAssertEqual(canonicalStill, canonicalData)

        // Conflict file saved
        let conflictFile = canonicalDir.appendingPathComponent("\(projectID)_frame_0.png.legacy")
        XCTAssertTrue(fm.fileExists(atPath: conflictFile.path))
        XCTAssertEqual(try Data(contentsOf: conflictFile), legacyData)
    }

    // MARK: - Non-empty vector data and layer metadata survive

    func testVectorDataAndLayerMetadataSurviveSaveReload() throws {
        try storage.createProject(id: "proj_vector", name: "Vector Test")

        let layers = [
            CanvasLayer(
                id: "layer_bg", name: "Background",
                visible: true, locked: false, opacity: 0.75,
                lockMode: "position", blendMode: "multiply",
                glowEnabled: true, glowColor: "#FF00FF", colorLabel: "#00FF00"
            )
        ]
        let elements = [
            DrawnElement(
                id: "e1", tool: .pen,
                points: [
                    StrokePoint(x: 0, y: 0, pressure: 0.5),
                    StrokePoint(x: 50, y: 100, pressure: 0.8),
                    StrokePoint(x: 200, y: 150, pressure: 1.0)
                ],
                color: "#FF0000", width: 2.5, opacity: 0.9, layerID: "layer_bg"
            ),
            DrawnElement(
                id: "e2", tool: .rectangle,
                points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 200, y: 150)],
                color: "#0000FF", width: 1.0, opacity: 0.5, fillColor: "#00FF00", layerID: "layer_bg"
            )
        ]
        let frames = [AnimationFrame(id: "frame_0", elements: elements)]

        try storage.save(frames: frames, layers: layers, activeLayerID: "layer_bg", currentFrameIndex: 0, for: "proj_vector")

        // Reload and verify all vector data preserved
        let result = try storage.load(for: "proj_vector")
        XCTAssertEqual(result.layers[0].id, "layer_bg")
        XCTAssertEqual(result.layers[0].name, "Background")
        XCTAssertEqual(result.layers[0].opacity, 0.75)
        XCTAssertEqual(result.layers[0].lockMode, "position")
        XCTAssertEqual(result.layers[0].blendMode, "multiply")
        XCTAssertTrue(result.layers[0].glowEnabled)
        XCTAssertEqual(result.layers[0].glowColor, "#FF00FF")
        XCTAssertEqual(result.layers[0].colorLabel, "#00FF00")

        XCTAssertEqual(result.frames[0].elements.count, 2)
        XCTAssertEqual(result.frames[0].elements[0].points.count, 3)
        XCTAssertEqual(result.frames[0].elements[0].points[2].pressure, 1.0)
        XCTAssertEqual(result.frames[0].elements[1].fillColor, "#00FF00")
    }

    // MARK: - Re-save does not destroy raster assets

    func testResaveDoesNotDestroyRasterAssets() throws {
        try storage.createProject(id: "proj_resave")
        let rasterData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try storage.saveRasterAsset(data: rasterData, projectID: "proj_resave", filename: "frame_0.png")

        // Re-save frames and layers
        let frames = [AnimationFrame(id: "f1", elements: [
            DrawnElement(tool: .brush, points: [StrokePoint(x: 0, y: 0)], color: "#000", width: 2, opacity: 1)
        ])]
        try storage.save(frames: frames, layers: [CanvasLayer(id: "l1", name: "L")], activeLayerID: "l1", currentFrameIndex: 0, for: "proj_resave")

        // Raster still intact
        let loaded = try storage.loadRasterAsset(projectID: "proj_resave", filename: "frame_0.png")
        XCTAssertEqual(loaded, rasterData)
    }
}
