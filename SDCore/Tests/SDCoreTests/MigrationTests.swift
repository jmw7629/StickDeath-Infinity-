import XCTest
@testable import SDCore

final class MigrationTests: XCTestCase {
    var tempDir: URL!
    var migration: MigrationService!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        migration = MigrationService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Basic migration

    func testMigrateLegacyAssets() throws {
        let legacyDir = tempDir.appendingPathComponent("Animations/test-id")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/test-id")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        try imageData.write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try imageData.write(to: legacyDir.appendingPathComponent("frame_1.png"))

        let project = Project(id: "test-id", name: "Migrated")
        let result = try migration.migrateLegacyAnimation(
            legacyID: "test-id",
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            project: project
        )

        XCTAssertEqual(result.migratedAssetCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("frame_0.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("frame_1.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("project.json").path))
    }

    // MARK: - Missing legacy asset => byte-identical copy

    func testMissingLegacyAssetCopied() throws {
        let legacyDir = tempDir.appendingPathComponent("Animations/abc")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/abc")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let audioData = Data([0xFF, 0xFB])
        try audioData.write(to: legacyDir.appendingPathComponent("audio_0.mp3"))

        let project = Project(id: "abc", name: "Audio Test")
        _ = try migration.migrateLegacyAnimation(
            legacyID: "abc",
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            project: project
        )

        let copiedData = try Data(contentsOf: canonicalDir.appendingPathComponent("audio_0.mp3"))
        XCTAssertEqual(copiedData, audioData)
    }

    // MARK: - Identical destination => already-migrated

    func testIdenticalDestinationSkipped() throws {
        let legacyDir = tempDir.appendingPathComponent("Animations/def")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/def")
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        let data = Data([0x01, 0x02])
        try data.write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try data.write(to: canonicalDir.appendingPathComponent("frame_0.png"))

        let project = Project(id: "def", name: "Skip Test")
        let result = try migration.migrateLegacyAnimation(
            legacyID: "def",
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            project: project
        )

        XCTAssertEqual(result.skipped, ["frame_0.png"])
        XCTAssertEqual(result.migratedAssetCount, 1) // only project.json
    }

    // MARK: - Different destination => conflict reported

    func testDifferentDestinationConflictReported() throws {
        let legacyDir = tempDir.appendingPathComponent("Animations/ghi")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/ghi")
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        try Data([0x01]).write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try Data([0x02]).write(to: canonicalDir.appendingPathComponent("frame_0.png"))

        let project = Project(id: "ghi", name: "Conflict Test")
        let result = try migration.migrateLegacyAnimation(
            legacyID: "ghi",
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            project: project
        )

        XCTAssertEqual(result.conflicts, ["frame_0.png"])
        let destData = try Data(contentsOf: canonicalDir.appendingPathComponent("frame_0.png"))
        XCTAssertEqual(destData, Data([0x02]))
    }

    // MARK: - Sparse frame indices preserved

    func testSparseFrameIndicesPreserved() throws {
        let legacyDir = tempDir.appendingPathComponent("Animations/sparse")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/sparse")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        try Data([0x01]).write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try Data([0x03]).write(to: legacyDir.appendingPathComponent("frame_2.png"))
        try Data([0x05]).write(to: legacyDir.appendingPathComponent("frame_4.png"))

        let project = Project(id: "sparse", name: "Sparse")
        let result = try migration.migrateLegacyAnimation(
            legacyID: "sparse",
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            project: project
        )

        XCTAssertEqual(result.migratedAssetCount, 4) // 3 frames + 1 project.json
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("frame_0.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("frame_2.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("frame_4.png").path))
    }

    // MARK: - Canonical saves do not delete migrated assets

    func testCanonicalSaveDoesNotDeleteMigratedAssets() throws {
        let legacyDir = tempDir.appendingPathComponent("Animations/nodelete")
        let canonicalDir = tempDir.appendingPathComponent("StudioProjects/nodelete")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        try Data([0xFF]).write(to: legacyDir.appendingPathComponent("frame_0.png"))

        let project = Project(id: "nodelete", name: "NoDelete")
        _ = try migration.migrateLegacyAnimation(
            legacyID: "nodelete",
            legacyDir: legacyDir,
            canonicalDir: canonicalDir,
            project: project
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("frame_0.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("project.json").path))
    }

    // MARK: - Find legacy animations

    func testFindLegacyAnimations() throws {
        let animDir = tempDir.appendingPathComponent("Animations")
        try FileManager.default.createDirectory(at: animDir.appendingPathComponent("id1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: animDir.appendingPathComponent("id2"), withIntermediateDirectories: true)

        let found = migration.findLegacyAnimations(in: tempDir)
        XCTAssertEqual(found.count, 2)
    }

    func testFindLegacyAnimationsEmptyDir() throws {
        let found = migration.findLegacyAnimations(in: tempDir)
        XCTAssertEqual(found.count, 0)
    }
}
