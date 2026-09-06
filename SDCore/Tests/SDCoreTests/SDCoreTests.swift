import XCTest
@testable import SDCore

final class SDCoreTests: XCTestCase {

    // MARK: - CanvasLayer deterministic IDs

    func testDefaultLayerHasDeterministicID() {
        let layer = CanvasLayer.defaultLayer()
        XCTAssertEqual(layer.id, "layer_default")
    }

    func testCanvasLayerCustomIDPreserved() {
        let layer = CanvasLayer(id: "custom_123", name: "Custom")
        XCTAssertEqual(layer.id, "custom_123")
    }

    func testCanvasLayerPersistenceRoundTrip() throws {
        let original = CanvasLayer(
            id: "test_layer",
            name: "Test Layer",
            visible: false,
            locked: true,
            opacity: 0.5,
            lockMode: "full",
            blendMode: "Multiply",
            glowEnabled: true,
            glowColor: "#FF0000",
            colorLabel: "#00FF00"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CanvasLayer.self, from: data)
        XCTAssertEqual(decoded.id, "test_layer")
        XCTAssertEqual(decoded.name, "Test Layer")
        XCTAssertFalse(decoded.visible)
        XCTAssertTrue(decoded.locked)
        XCTAssertEqual(decoded.opacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(decoded.lockMode, "full")
        XCTAssertEqual(decoded.blendMode, "Multiply")
        XCTAssertTrue(decoded.glowEnabled)
        XCTAssertEqual(decoded.glowColor, "#FF0000")
        XCTAssertEqual(decoded.colorLabel, "#00FF00")
    }

    // MARK: - CanvasLayer mutations

    func testToggleVisibility() {
        var layer = CanvasLayer.defaultLayer()
        XCTAssertTrue(layer.visible)
        layer.visible.toggle()
        XCTAssertFalse(layer.visible)
        layer.visible.toggle()
        XCTAssertTrue(layer.visible)
    }

    func testSetLockMode() {
        var layer = CanvasLayer.defaultLayer()
        XCTAssertEqual(layer.lockMode, "free")
        layer.lockMode = "full"
        XCTAssertEqual(layer.lockMode, "full")
        layer.lockMode = "position"
        XCTAssertEqual(layer.lockMode, "position")
        layer.lockMode = "alpha"
        XCTAssertEqual(layer.lockMode, "alpha")
    }

    func testSetOpacity() {
        var layer = CanvasLayer.defaultLayer()
        layer.opacity = 0.3
        XCTAssertEqual(layer.opacity, 0.3, accuracy: 0.001)
    }

    func testSetBlendMode() {
        var layer = CanvasLayer.defaultLayer()
        layer.blendMode = "Multiply"
        XCTAssertEqual(layer.blendMode, "Multiply")
    }

    func testSetGlow() {
        var layer = CanvasLayer.defaultLayer()
        XCTAssertFalse(layer.glowEnabled)
        layer.glowEnabled = true
        layer.glowColor = "#FF0000"
        XCTAssertTrue(layer.glowEnabled)
        XCTAssertEqual(layer.glowColor, "#FF0000")
    }

    func testSetColorLabel() {
        var layer = CanvasLayer.defaultLayer()
        layer.colorLabel = "#00FF00"
        XCTAssertEqual(layer.colorLabel, "#00FF00")
    }

    func testSetLayerName() {
        var layer = CanvasLayer.defaultLayer()
        layer.name = "Background"
        XCTAssertEqual(layer.name, "Background")
    }

    func testSetLocked() {
        var layer = CanvasLayer.defaultLayer()
        layer.locked = true
        XCTAssertTrue(layer.locked)
    }

    // MARK: - CanvasTypes round-trip

    func testAnimationFrameRoundTrip() throws {
        let element = DrawnElement(
            id: "el1",
            tool: .brush,
            points: [StrokePoint(x: 10, y: 20, pressure: 0.5, timestamp: 1.0)],
            color: "#FF0000",
            width: 3.0,
            opacity: 0.8,
            fillColor: "#00FF00",
            layerID: "layer_default"
        )
        let frame = AnimationFrame(id: "frame1", elements: [element])
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(AnimationFrame.self, from: data)
        XCTAssertEqual(decoded.id, "frame1")
        XCTAssertEqual(decoded.elements.count, 1)
        XCTAssertEqual(decoded.elements[0].id, "el1")
        XCTAssertEqual(decoded.elements[0].tool, .brush)
        XCTAssertEqual(decoded.elements[0].points[0].x, 10, accuracy: 0.001)
        XCTAssertEqual(decoded.elements[0].layerID, "layer_default")
    }

    func testSDProjectRoundTrip() throws {
        let project = SDProject(
            id: "proj1",
            name: "Test Project",
            canvasWidth: 1920,
            canvasHeight: 1080,
            fps: 24,
            frames: [AnimationFrame(id: "f1")],
            layers: [CanvasLayer.defaultLayer()],
            activeLayerID: "layer_default",
            audioClips: []
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(SDProject.self, from: data)
        XCTAssertEqual(decoded.id, "proj1")
        XCTAssertEqual(decoded.name, "Test Project")
        XCTAssertEqual(decoded.canvasWidth, 1920)
        XCTAssertEqual(decoded.canvasHeight, 1080)
        XCTAssertEqual(decoded.fps, 24)
        XCTAssertEqual(decoded.layers.count, 1)
        XCTAssertEqual(decoded.layers[0].id, "layer_default")
    }

    // MARK: - StudioStorage

    func testStudioStorageCreateAndLoad() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTest_\(UUID().uuidString)")
        let storage = StudioStorage(baseDirectory: tmpDir)

        let project = SDProject(id: "test_proj", name: "Test")
        try storage.createProject(project)

        let loaded = try storage.loadProject(id: "test_proj")
        XCTAssertEqual(loaded.id, "test_proj")
        XCTAssertEqual(loaded.name, "Test")

        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testStudioStorageListProjects() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTestList_\(UUID().uuidString)")
        let storage = StudioStorage(baseDirectory: tmpDir)

        try storage.createProject(SDProject(id: "p1", name: "First"))
        try storage.createProject(SDProject(id: "p2", name: "Second"))

        let list = storage.listProjects()
        XCTAssertEqual(list.count, 2)

        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testStudioStorageSaveOverwrite() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTestSave_\(UUID().uuidString)")
        let storage = StudioStorage(baseDirectory: tmpDir)

        var project = SDProject(id: "save_proj", name: "Original")
        try storage.createProject(project)

        project.name = "Updated"
        project.layers.append(CanvasLayer(id: "new_layer", name: "Layer 2"))
        try storage.saveProject(project)

        let loaded = try storage.loadProject(id: "save_proj")
        XCTAssertEqual(loaded.name, "Updated")
        XCTAssertEqual(loaded.layers.count, 2)

        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testStudioStorageDeleteProject() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTestDelete_\(UUID().uuidString)")
        let storage = StudioStorage(baseDirectory: tmpDir)

        try storage.createProject(SDProject(id: "del_proj", name: "Delete Me"))
        try storage.deleteProject(id: "del_proj")

        XCTAssertThrowsError(try storage.loadProject(id: "del_proj"))

        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testStudioStorageLoadNotFound() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTestNotFound_\(UUID().uuidString)")
        let storage = StudioStorage(baseDirectory: tmpDir)

        XCTAssertThrowsError(try storage.loadProject(id: "nonexistent"))

        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - LegacyMigrationManager

    func testDiscoverLegacyIDs() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTestMigration_\(UUID().uuidString)")
        let animDir = tmpDir.appendingPathComponent("Animations/legacy_001", isDirectory: true)
        try FileManager.default.createDirectory(at: animDir, withIntermediateDirectories: true)
        try "test".data(using: .utf8)!.write(to: animDir.appendingPathComponent("metadata.json"))

        let migration = LegacyMigrationManager()
        let ids = migration.discoverLegacyIDs(documentsDir: tmpDir)
        XCTAssertEqual(ids, ["legacy_001"])

        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testMigrateLegacyAnimationCopiesBytes() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTestMigrateCopy_\(UUID().uuidString)")
        let sourceDir = tmpDir.appendingPathComponent("Animations/src_001", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let frameData = "frame_data_bytes".data(using: .utf8)!
        try frameData.write(to: sourceDir.appendingPathComponent("frame_0.png"))
        try "meta".data(using: .utf8)!.write(to: sourceDir.appendingPathComponent("metadata.json"))

        let migration = LegacyMigrationManager()
        let result = migration.migrateLegacyAnimation(id: "src_001", documentsDir: tmpDir)

        XCTAssertEqual(result, .migrated)

        let destDir = tmpDir.appendingPathComponent("StudioProjects/src_001", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("frame_0.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("metadata.json").path))

        // Source preserved
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceDir.path))

        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testMigrateAlreadyMigrated() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTestMigrateAlready_\(UUID().uuidString)")
        let sourceDir = tmpDir.appendingPathComponent("Animations/dup_001", isDirectory: true)
        let destDir = tmpDir.appendingPathComponent("StudioProjects/dup_001", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let data = "identical".data(using: .utf8)!
        try data.write(to: sourceDir.appendingPathComponent("frame_0.png"))
        try data.write(to: destDir.appendingPathComponent("frame_0.png"))

        let migration = LegacyMigrationManager()
        let result = migration.migrateLegacyAnimation(id: "dup_001", documentsDir: tmpDir)
        XCTAssertEqual(result, .alreadyMigrated)

        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testMigrateConflictPreservesBoth() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDCoreTestMigrateConflict_\(UUID().uuidString)")
        let sourceDir = tmpDir.appendingPathComponent("Animations/conf_001", isDirectory: true)
        let destDir = tmpDir.appendingPathComponent("StudioProjects/conf_001", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try "source_data".data(using: .utf8)!.write(to: sourceDir.appendingPathComponent("frame_0.png"))
        try "dest_data_different".data(using: .utf8)!.write(to: destDir.appendingPathComponent("frame_0.png"))

        let migration = LegacyMigrationManager()
        let result = migration.migrateLegacyAnimation(id: "conf_001", documentsDir: tmpDir)

        if case .conflict(let srcRetained, let dstRetained) = result {
            XCTAssertTrue(srcRetained)
            XCTAssertTrue(dstRetained)
        } else {
            XCTFail("Expected conflict result, got \(result)")
        }

        // Both directories still exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.path))

        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - SpatterBackendClient gates

    func testBackendNoTransportWhenDisabled() async throws {
        let config = BackendConfig.unavailable
        let provider = MockAuthTokenProvider(token: "valid_token", authenticated: true)
        let client = SpatterBackendClient(config: config, authProvider: provider)

        XCTAssertFalse(client.canMakeTransportCalls)
        let result = try await client.chat(messages: [("user", "hello")])
        XCTAssertNil(result)
        XCTAssertEqual(client.transportCallCount, 0)
    }

    func testBackendNoTransportWhenNotAuthenticated() async throws {
        let config = BackendConfig(baseURL: "https://api.example.com", isEnabled: true)
        let provider = MockAuthTokenProvider(token: nil, authenticated: false)
        let client = SpatterBackendClient(config: config, authProvider: provider)

        XCTAssertFalse(client.canMakeTransportCalls)
        let result = try await client.chat(messages: [("user", "hello")])
        XCTAssertNil(result)
        XCTAssertEqual(client.transportCallCount, 0)
    }

    func testBackendNoTransportWhenTokenMissing() async throws {
        let config = BackendConfig(baseURL: "https://api.example.com", isEnabled: true)
        let provider = MockAuthTokenProvider(token: nil, authenticated: true)
        let client = SpatterBackendClient(config: config, authProvider: provider)

        XCTAssertFalse(client.canMakeTransportCalls)
        let result = try await client.chat(messages: [("user", "hello")])
        XCTAssertNil(result)
        XCTAssertEqual(client.transportCallCount, 0)
    }

    func testBackendConfiguredAndAuthenticatedAllowsTransport() async throws {
        let config = BackendConfig(baseURL: "https://api.example.com", isEnabled: true)
        let provider = MockAuthTokenProvider(token: "valid_token", authenticated: true)
        let client = SpatterBackendClient(config: config, authProvider: provider)

        XCTAssertTrue(client.canMakeTransportCalls)
        // Note: actual HTTP call will fail in tests, but the gate logic is proven
    }
}

// MARK: - Mock

struct MockAuthTokenProvider: AuthTokenProvider {
    let token: String?
    let isAuthenticated: Bool
}
