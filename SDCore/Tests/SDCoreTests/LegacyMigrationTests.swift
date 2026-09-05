import XCTest
@testable import SDCore

final class LegacyMigrationTests: XCTestCase {

    var tmpDir: URL!
    var legacyRoot: URL!
    var persistence: ProjectPersistence!
    var migration: LegacyMigration!

    let projectID = "test-project-001"

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        legacyRoot = tmpDir.appendingPathComponent("Legacy", isDirectory: true)
        try? FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)

        persistence = ProjectPersistence(rootURL: tmpDir.appendingPathComponent("Canonical", isDirectory: true))
        migration = LegacyMigration(legacyRoot: legacyRoot, persistence: persistence)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func createLegacyProject() throws {
        let projectDir = migration.legacyProjectDir(for: projectID)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // frame_0.png with deterministic bytes
        let frame0Data = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x0D, 0x00, 0x01])
        try frame0Data.write(to: projectDir.appendingPathComponent("frame_0.png"))

        // frame_7.png with different deterministic bytes
        let frame7Data = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x0D, 0x00, 0x07])
        try frame7Data.write(to: projectDir.appendingPathComponent("frame_7.png"))

        // Unrelated file
        let notesData = "My animation notes\n".data(using: .utf8)!
        try notesData.write(to: projectDir.appendingPathComponent("notes.txt"))
    }

    private func createCanonicalProject() throws {
        let layer = CanvasLayer(id: "layer-1", name: "Main", visible: true, locked: false, opacity: 0.9, lockMode: "free", blendMode: "multiply", colorLabel: "#FF0000")

        let strokePoints = [StrokePoint(x: 5.0, y: 10.0, pressure: 0.7)]
        let element = DrawnElement(id: "el-1", tool: .brush, points: strokePoints, color: "#FF0000", width: 3.0, opacity: 1.0, layerID: "layer-1")
        let frame = AnimationFrame(id: "frame-1", elements: [element])

        let doc = ProjectDocument(
            projectName: "Test Project",
            canvasWidth: 1080,
            canvasHeight: 1080,
            fps: 12,
            frames: [frame],
            layers: [layer],
            activeLayerID: "layer-1",
            currentFrameIndex: 0
        )
        try persistence.save(doc, projectID: projectID)
    }

    // MARK: - Tests

    func testDiscoverLegacyFrameIndices() throws {
        try createLegacyProject()
        let indices = migration.discoverLegacyFrameIndices(for: projectID)
        XCTAssertEqual(indices, [0, 7])
    }

    func testDiscoverLegacyFrameIndicesEmpty() {
        let indices = migration.discoverLegacyFrameIndices(for: "nonexistent")
        XCTAssertEqual(indices, [])
    }

    func testLegacyUnrelatedFiles() throws {
        try createLegacyProject()
        let unrelated = migration.legacyUnrelatedFiles(for: projectID)
        XCTAssertEqual(unrelated.count, 1)
        XCTAssertEqual(unrelated.first?.lastPathComponent, "notes.txt")
    }

    func testMigrateCopiesFramesNonDestructively() throws {
        try createLegacyProject()
        try createCanonicalProject()

        let result = try migration.migrate(projectID: projectID)

        XCTAssertEqual(result.migratedFrameIndices.sorted(), [0, 7])

        // Verify destination files exist
        let dest0 = persistence.rasterURL(for: projectID, frameIndex: 0)
        let dest7 = persistence.rasterURL(for: projectID, frameIndex: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest0.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest7.path))

        // Verify byte identity
        XCTAssertTrue(migration.verifyMigrationIntegrity(projectID: projectID, indices: [0, 7]))

        // Verify original legacy files still exist
        let legacy0 = migration.legacyRasterURL(for: projectID, frameIndex: 0)
        let legacy7 = migration.legacyRasterURL(for: projectID, frameIndex: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy0.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy7.path))

        // Verify unrelated file preserved
        let notesURL = migration.legacyProjectDir(for: projectID).appendingPathComponent("notes.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: notesURL.path))
        let notesContent = try String(contentsOf: notesURL)
        XCTAssertEqual(notesContent, "My animation notes\n")
    }

    func testMigrateSparseIndices() throws {
        try createLegacyProject()
        // Only frame_0 and frame_7 exist (sparse: no 1-6)
        let result = try migration.migrate(projectID: projectID)
        XCTAssertEqual(result.migratedFrameIndices.sorted(), [0, 7])

        // Verify no frame_1 through frame_6 were created
        for i in 1...6 {
            let url = persistence.rasterURL(for: projectID, frameIndex: i)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "frame_\(i) should not exist")
        }
    }

    func testMigrateDoesNotOverwriteExistingCanonical() throws {
        try createLegacyProject()
        try createCanonicalProject()

        // Write a different file at the canonical destination
        let canonicalFrame0 = persistence.rasterURL(for: projectID, frameIndex: 0)
        let canonicalData = Data([0xFF, 0xFF, 0xFF])
        try FileManager.default.createDirectory(
            at: persistence.rasterDir(for: projectID),
            withIntermediateDirectories: true
        )
        try canonicalData.write(to: canonicalFrame0)

        // Migrate should NOT overwrite the existing canonical file
        try migration.migrate(projectID: projectID)

        let loadedData = try Data(contentsOf: canonicalFrame0)
        XCTAssertEqual(loadedData, canonicalData, "Existing canonical file should not be overwritten")
    }

    func testMigratePreservesVectorData() throws {
        try createLegacyProject()
        try createCanonicalProject()

        try migration.migrate(projectID: projectID)

        // Load canonical project and verify vector data survives
        let doc = try persistence.load(projectID: projectID)
        XCTAssertEqual(doc.frames.count, 1)
        XCTAssertEqual(doc.frames[0].elements.count, 1)
        XCTAssertEqual(doc.frames[0].elements[0].points[0].x, 5.0, accuracy: 0.001)
        XCTAssertEqual(doc.frames[0].elements[0].color, "#FF0000")
        XCTAssertEqual(doc.layers[0].opacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(doc.layers[0].blendMode, "multiply")
        XCTAssertEqual(doc.layers[0].colorLabel, "#FF0000")
    }

    func testMigrateRoundTripSaveResaveReload() throws {
        try createLegacyProject()
        try createCanonicalProject()

        try migration.migrate(projectID: projectID)

        // Load, modify slightly, save, reload
        var doc = try persistence.load(projectID: projectID)
        doc.projectName = "Modified Name"
        try persistence.save(doc, projectID: projectID)

        let reloaded = try persistence.load(projectID: projectID)
        XCTAssertEqual(reloaded.projectName, "Modified Name")
        XCTAssertEqual(reloaded.frames[0].elements[0].points[0].x, 5.0, accuracy: 0.001)
        XCTAssertEqual(reloaded.layers[0].blendMode, "multiply")

        // Legacy files still intact
        XCTAssertTrue(migration.verifyMigrationIntegrity(projectID: projectID, indices: [0, 7]))
    }

    func testVerifyByteIdentity() throws {
        try createLegacyProject()
        let src = migration.legacyRasterURL(for: projectID, frameIndex: 0)

        try FileManager.default.createDirectory(
            at: persistence.rasterDir(for: projectID),
            withIntermediateDirectories: true
        )
        let dst = persistence.rasterURL(for: projectID, frameIndex: 0)
        try FileManager.default.copyItem(at: src, to: dst)

        XCTAssertTrue(migration.verifyByteIdentity(source: src, destination: dst))
    }

    func testVerifyByteIdentityMismatch() throws {
        try FileManager.default.createDirectory(at: migration.legacyProjectDir(for: projectID), withIntermediateDirectories: true)
        try Data([0x01]).write(to: migration.legacyRasterURL(for: projectID, frameIndex: 0))

        try FileManager.default.createDirectory(at: persistence.rasterDir(for: projectID), withIntermediateDirectories: true)
        try Data([0x02]).write(to: persistence.rasterURL(for: projectID, frameIndex: 0))

        XCTAssertFalse(migration.verifyByteIdentity(
            source: migration.legacyRasterURL(for: projectID, frameIndex: 0),
            destination: persistence.rasterURL(for: projectID, frameIndex: 0)
        ))
    }

    func testMigrateWithEmptyLegacyDir() throws {
        let projectDir = migration.legacyProjectDir(for: projectID)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let result = try migration.migrate(projectID: projectID)
        XCTAssertEqual(result.migratedFrameIndices, [])
        XCTAssertEqual(result.preservedUnrelatedFiles, [])
    }

    func testMigrateWithNoLegacyDir() throws {
        let result = try migration.migrate(projectID: "no-such-project")
        XCTAssertEqual(result.migratedFrameIndices, [])
    }
}
