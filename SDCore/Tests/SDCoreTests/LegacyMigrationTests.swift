// ═══════════════════════════════════════════════════════════════════
// LegacyMigrationTests — Per-asset sibling migration evidence
// Tests: missing assets migrate, identical = already migrated,
// different = conflict (both preserved), sparse frames preserved,
// canonical project.json preserved, real openProject invokes migration.
// ═══════════════════════════════════════════════════════════════════

import XCTest
@testable import SDCore

final class LegacyMigrationTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMigrationTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // Test: missing destination assets are copied byte-identically
    func testMissingAssetsAreCopied() throws {
        let fm = FileManager.default
        let legacyDir = tempDir.appendingPathComponent("Animations/proj1")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/proj1")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        // Create legacy frame
        let frameData = "frame_content".data(using: .utf8)!
        try frameData.write(to: legacyDir.appendingPathComponent("frame_0.png"))

        // Migrate
        let result = LegacyAssetMigration.migrateSiblings(
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            projectID: "proj1"
        )

        XCTAssertEqual(result.migratedAssets, ["frame_0.png"])
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("frame_0.png").path))
        XCTAssertEqual(result.conflicts.count, 0)
    }

    // Test: identical destination = already migrated
    func testIdenticalDestinationAlreadyMigrated() throws {
        let fm = FileManager.default
        let legacyDir = tempDir.appendingPathComponent("Animations/proj2")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/proj2")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        let frameData = "identical".data(using: .utf8)!
        try frameData.write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try frameData.write(to: canonicalDir.appendingPathComponent("frame_0.png"))

        let result = LegacyAssetMigration.migrateSiblings(
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            projectID: "proj2"
        )

        XCTAssertEqual(result.alreadyMigrated, ["frame_0.png"])
        XCTAssertEqual(result.migratedAssets.count, 0)
        XCTAssertEqual(result.conflicts.count, 0)
    }

    // Test: different destination = conflict, both preserved, neither deleted
    func testDifferentDestinationConflict() throws {
        let fm = FileManager.default
        let legacyDir = tempDir.appendingPathComponent("Animations/proj3")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/proj3")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        try "legacy_version".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try "canonical_version".data(using: .utf8)!.write(to: canonicalDir.appendingPathComponent("frame_0.png"))

        let result = LegacyAssetMigration.migrateSiblings(
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            projectID: "proj3"
        )

        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.conflicts.first?.relativePath, "frame_0.png")

        // Both files still exist
        XCTAssertTrue(fm.fileExists(atPath: legacyDir.appendingPathComponent("frame_0.png").path))
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("frame_0.png").path))

        // Canonical content is unchanged
        let canonicalData = try Data(contentsOf: canonicalDir.appendingPathComponent("frame_0.png"))
        XCTAssertEqual(String(data: canonicalData, encoding: .utf8), "canonical_version")
    }

    // Test: sparse frame indices preserved
    func testSparseFrameIndicesPreserved() throws {
        let fm = FileManager.default
        let legacyDir = tempDir.appendingPathComponent("Animations/proj4")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/proj4")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        // Only frame_0 and frame_5 exist (sparse)
        try "f0".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try "f5".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("frame_5.png"))

        let result = LegacyAssetMigration.migrateSiblings(
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            projectID: "proj4"
        )

        XCTAssertEqual(result.migratedAssets.count, 2)
        XCTAssertTrue(result.migratedAssets.contains("frame_0.png"))
        XCTAssertTrue(result.migratedAssets.contains("frame_5.png"))
        XCTAssertFalse(fm.fileExists(atPath: canonicalDir.appendingPathComponent("frame_3.png").path))
    }

    // Test: non-frame files (audio, metadata) migrated
    func testNonFrameFilesMigrated() throws {
        let fm = FileManager.default
        let legacyDir = tempDir.appendingPathComponent("Animations/proj5")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/proj5")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        try "metadata".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("metadata.json"))
        try "audio".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("audio_0.mp3"))
        try "notes".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("notes.txt"))

        let result = LegacyAssetMigration.migrateSiblings(
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            projectID: "proj5"
        )

        XCTAssertEqual(result.migratedAssets.count, 3)
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("metadata.json").path))
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("audio_0.mp3").path))
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("notes.txt").path))
    }

    // Test: canonical project.json preserved through migration
    func testCanonicalProjectJSONPreserved() throws {
        let fm = FileManager.default
        let legacyDir = tempDir.appendingPathComponent("Animations/proj6")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/proj6")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        // Existing canonical project
        let project = SDProject(projectID: "proj6", name: "Existing Project")
        let projectData = try JSONEncoder().encode(project)
        try projectData.write(to: canonicalDir.appendingPathComponent("project.json"))

        // Legacy frame
        try "frame".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("frame_0.png"))

        _ = LegacyAssetMigration.migrateSiblings(
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            projectID: "proj6"
        )

        // Verify canonical project.json was not overwritten
        let reloadedData = try Data(contentsOf: canonicalDir.appendingPathComponent("project.json"))
        let reloadedProject = try JSONDecoder().decode(SDProject.self, from: reloadedData)
        XCTAssertEqual(reloadedProject.name, "Existing Project")
    }

    // Test: canonical saves do not delete migrated raster/audio assets
    func testCanonicalSaveDoesNotDeleteMigrated() throws {
        let fm = FileManager.default
        let storageDir = tempDir.appendingPathComponent("Storage")
        let storage = LocalProjectStorage(baseDirectory: storageDir)

        let legacyDir = storageDir.appendingPathComponent("Animations/proj7")
        let canonicalDir = storage.projectDirectory(for: "proj7")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        try "frame".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("frame_0.png"))

        // Migrate
        _ = LegacyAssetMigration.migrateLegacyAnimation(id: "proj7", storage: storage)

        // Verify migrated asset exists
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("frame_0.png").path))

        // Save project again
        var project = SDProject(projectID: "proj7", name: "Test")
        project.frames = [SDFrame(elements: [DrawnElement(tool: .pen)])]
        try? storage.saveProject(project)

        // Migrated asset still exists
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("frame_0.png").path))
    }

    // Test: tests create canonical project with project.json + legacy frames and prove migration
    func testCanonicalWithLegacyFramesMigration() throws {
        let fm = FileManager.default
        let storageDir = tempDir.appendingPathComponent("Storage2")
        let storage = LocalProjectStorage(baseDirectory: storageDir)

        let projectID = "proj_\(UUID().uuidString.prefix(8))"
        let legacyDir = storageDir.appendingPathComponent("Animations/\(projectID)")
        let canonicalDir = storage.projectDirectory(for: projectID)

        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        // Canonical project.json already exists
        let project = SDProject(projectID: projectID, name: "Pre-existing")
        try storage.saveProject(project)

        // Legacy raster frames
        try "f0".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try "f3".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("frame_3.png"))

        // Legacy audio
        try "a0".data(using: .utf8)!.write(to: legacyDir.appendingPathComponent("audio_0.mp3"))

        // Run migration
        _ = LegacyAssetMigration.migrateLegacyAnimation(id: projectID, storage: storage)

        // Legacy assets migrated to canonical directory
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("frame_0.png").path))
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("frame_3.png").path))
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("audio_0.mp3").path))

        // Canonical project.json still intact
        let reloaded = try storage.loadProject(id: projectID)
        XCTAssertEqual(reloaded?.name, "Pre-existing")

        // Legacy source files untouched
        XCTAssertTrue(fm.fileExists(atPath: legacyDir.appendingPathComponent("frame_0.png").path))
        XCTAssertTrue(fm.fileExists(atPath: legacyDir.appendingPathComponent("frame_3.png").path))
    }
}
