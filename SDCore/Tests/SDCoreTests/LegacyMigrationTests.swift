import XCTest
@testable import SDCore

final class LegacyMigrationTests: XCTestCase {

    private var tempDir: URL!
    private var documentsDir: URL!
    private var legacyDir: URL!
    private var canonicalDir: URL!
    private var migration: LegacyMigration!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationTests_\(UUID().uuidString)")
        documentsDir = tempDir.appendingPathComponent("Documents")
        legacyDir = documentsDir
            .appendingPathComponent("Animations", isDirectory: true)
            .appendingPathComponent("test_project", isDirectory: true)
        canonicalDir = documentsDir
            .appendingPathComponent("StudioProjects", isDirectory: true)
            .appendingPathComponent("test_project", isDirectory: true)

        try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        migration = LegacyMigration()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testDestinationMissingCopiesByteIdentically() throws {
        // Create legacy frame files with sparse indices
        let frame0Data = "frame0_png_data".data(using: .utf8)!
        let frame3Data = "frame3_png_data".data(using: .utf8)!
        try frame0Data.write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try frame3Data.write(to: legacyDir.appendingPathComponent("frame_3.png"))

        // Also add a non-frame file
        let vectorData = "vector_svg_data".data(using: .utf8)!
        try vectorData.write(to: legacyDir.appendingPathComponent("drawing.svg"))

        let result = try migration.migrate(
            projectID: "test_project",
            documentsDirectory: documentsDir
        )

        XCTAssertEqual(result.copiedFiles, 3)
        XCTAssertEqual(result.skippedIdentical, 0)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertFalse(result.alreadyMigrated)

        // Verify byte-identical copies
        let destFrame0 = try Data(contentsOf: canonicalDir.appendingPathComponent("frame_0.png"))
        let destFrame3 = try Data(contentsOf: canonicalDir.appendingPathComponent("frame_3.png"))
        let destSVG = try Data(contentsOf: canonicalDir.appendingPathComponent("drawing.svg"))

        XCTAssertEqual(destFrame0, frame0Data)
        XCTAssertEqual(destFrame3, frame3Data)
        XCTAssertEqual(destSVG, vectorData)
    }

    func testIdenticalDestinationSkipsWithoutDestructiveRewrite() throws {
        // Create legacy file
        let data = "identical_data".data(using: .utf8)!
        try data.write(to: legacyDir.appendingPathComponent("frame_0.png"))

        // Create identical canonical file
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try data.write(to: canonicalDir.appendingPathComponent("frame_0.png"))

        let result = try migration.migrate(
            projectID: "test_project",
            documentsDirectory: documentsDir
        )

        XCTAssertEqual(result.copiedFiles, 0)
        XCTAssertEqual(result.skippedIdentical, 1)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.alreadyMigrated)
    }

    func testDifferentDestinationPreservesBothReportsConflict() throws {
        let legacyData = "legacy_version".data(using: .utf8)!
        let canonicalData = "canonical_version".data(using: .utf8)!

        try legacyData.write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try canonicalData.write(to: canonicalDir.appendingPathComponent("frame_0.png"))

        let result = try migration.migrate(
            projectID: "test_project",
            documentsDirectory: documentsDir
        )

        XCTAssertEqual(result.copiedFiles, 0)
        XCTAssertEqual(result.skippedIdentical, 0)
        XCTAssertEqual(result.conflicts, ["frame_0.png"])

        // Verify neither was overwritten
        let legacyStill = try Data(contentsOf: legacyDir.appendingPathComponent("frame_0.png"))
        let canonicalStill = try Data(contentsOf: canonicalDir.appendingPathComponent("frame_0.png"))
        XCTAssertEqual(legacyStill, legacyData)
        XCTAssertEqual(canonicalStill, canonicalData)
    }

    func testLegacyDirectoryMissingReturnsNoop() throws {
        let result = try migration.migrate(
            projectID: "nonexistent",
            documentsDirectory: documentsDir
        )

        XCTAssertEqual(result.copiedFiles, 0)
        XCTAssertEqual(result.skippedIdentical, 0)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertFalse(result.alreadyMigrated)
    }

    func testSparseFrameIndicesPreserved() throws {
        // Create frames 0, 5, 10 (sparse)
        for idx in [0, 5, 10] {
            let data = "frame_\(idx)".data(using: .utf8)!
            try data.write(to: legacyDir.appendingPathComponent("frame_\(idx).png"))
        }

        let result = try migration.migrate(
            projectID: "test_project",
            documentsDirectory: documentsDir
        )

        XCTAssertEqual(result.copiedFiles, 3)

        // Verify sparse indices exist in canonical
        for idx in [0, 5, 10] {
            let url = canonicalDir.appendingPathComponent("frame_\(idx).png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testUnrelatedLegacyFilesPreserved() throws {
        let frameData = "frame".data(using: .utf8)!
        let metadataData = "{ \"custom\": true }".data(using: .utf8)!
        let notesData = "my notes".data(using: .utf8)!

        try frameData.write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try metadataData.write(to: legacyDir.appendingPathComponent("metadata.json"))
        try notesData.write(to: legacyDir.appendingPathComponent("notes.txt"))

        let result = try migration.migrate(
            projectID: "test_project",
            documentsDirectory: documentsDir
        )

        XCTAssertEqual(result.copiedFiles, 3)
        // All files preserved, not just frames
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("metadata.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("notes.txt").path))
    }

    func testSourceNeverOverwrittenOrDeleted() throws {
        let data = "original".data(using: .utf8)!
        try data.write(to: legacyDir.appendingPathComponent("frame_0.png"))

        _ = try migration.migrate(
            projectID: "test_project",
            documentsDirectory: documentsDir
        )

        // Source still exists and is unchanged
        let sourceData = try Data(contentsOf: legacyDir.appendingPathComponent("frame_0.png"))
        XCTAssertEqual(sourceData, data)
    }

    func testConflictPreservesSourceBytes() throws {
        let sourceData = "source_v1".data(using: .utf8)!
        let destData = "dest_v1".data(using: .utf8)!

        try sourceData.write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try destData.write(to: canonicalDir.appendingPathComponent("frame_0.png"))

        _ = try migration.migrate(
            projectID: "test_project",
            documentsDirectory: documentsDir
        )

        // Source is untouched
        let sourceAfter = try Data(contentsOf: legacyDir.appendingPathComponent("frame_0.png"))
        XCTAssertEqual(sourceAfter, sourceData)
    }
}
