import XCTest
@testable import SDCore

final class CoordinatorIntegrationTests: XCTestCase {
    var tempDir: URL!
    var store: LocalProjectStore!
    var coordinator: SDCoreCoordinator!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = LocalProjectStore(baseDirectory: tempDir)
        coordinator = SDCoreCoordinator(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Every remote call receives real project ID

    func testEveryRemoteCallReceivesRealProjectID() throws {
        let project = try coordinator.createProject(name: "Remote ID Test")
        XCTAssertNotNil(UUID(uuidString: project.id))
        XCTAssertFalse(project.id.isEmpty)
        XCTAssertEqual(project.id.count, 36) // UUID string length
    }

    // MARK: - Full lifecycle: create -> save -> list -> reopen

    func testFullLifecycle() throws {
        let project = try coordinator.createProject(name: "Full Lifecycle")
        let projectID = project.id

        try coordinator.save()

        let projects = try coordinator.loadProjects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.id, projectID)

        let reopened = try coordinator.openProject(id: projectID)
        XCTAssertNotNil(reopened)
        XCTAssertEqual(reopened?.id, projectID)
        XCTAssertEqual(reopened?.name, "Full Lifecycle")
    }

    // MARK: - Frames/elements/layers round-trip

    func testFullRoundTrip() throws {
        let project = try coordinator.createProject(name: "RoundTrip")
        var updated = project

        let layer1ID = updated.layers[0].id

        let element1 = DrawnElement(
            tool: .brush,
            points: [StrokePoint(x: 10, y: 20, pressure: 0.5, timestamp: 1.0)],
            color: "#FF0000",
            width: 5.0,
            opacity: 0.9,
            layerID: layer1ID
        )
        updated.frames[0].elements.append(element1)

        let newLayer = CanvasLayer(id: UUID().uuidString, name: "Layer 2", visible: true, locked: false, opacity: 0.7, lockMode: "full", blendMode: "multiply")
        updated.layers.append(newLayer)
        updated.activeLayerID = newLayer.id

        try coordinator.repository.save(updated)

        let reopened = try coordinator.openProject(id: project.id)
        XCTAssertNotNil(reopened)

        XCTAssertEqual(reopened?.frames[0].elements.count, 1)
        XCTAssertEqual(reopened?.frames[0].elements[0].tool, .brush)
        XCTAssertEqual(reopened?.frames[0].elements[0].points[0].pressure, 0.5)
        XCTAssertEqual(reopened?.layers.count, 2)
        XCTAssertEqual(reopened?.layers[1].name, "Layer 2")
        XCTAssertEqual(reopened?.layers[1].lockMode, "full")
        XCTAssertEqual(reopened?.layers[1].blendMode, "multiply")
        XCTAssertEqual(reopened?.activeLayerID, newLayer.id)
    }

    // MARK: - Layer commands integration

    func testLayerCommandsIntegration() throws {
        _ = try coordinator.createProject(name: "Layer Int")

        let layer1 = coordinator.activeProject!.layers[0].id
        _ = try coordinator.layerCommands.setLockMode(id: layer1, mode: "alpha")
        _ = try coordinator.layerCommands.setOpacity(id: layer1, opacity: 0.5)
        _ = try coordinator.layerCommands.setGlowEnabled(id: layer1, enabled: true)
        _ = try coordinator.layerCommands.setGlowColor(id: layer1, color: "#00FF00")
        _ = try coordinator.layerCommands.setColorLabel(id: layer1, color: "#FF0000")
        _ = try coordinator.layerCommands.rename(id: layer1, name: "Renamed")

        _ = try coordinator.layerCommands.addLayer(name: "Second")
        _ = try coordinator.layerCommands.addLayer(name: "Third")

        let project = coordinator.activeProject!
        XCTAssertEqual(project.layers.count, 3)

        _ = try coordinator.layerCommands.deleteLayer(id: project.layers[0].id)
        XCTAssertEqual(coordinator.activeProject!.layers.count, 2)

        let savedID = coordinator.activeProject!.id
        let reopened = try coordinator.openProject(id: savedID)
        XCTAssertEqual(reopened?.layers.count, 2)

        let renamed = reopened?.layers.first(where: { $0.name == "Renamed" })
        XCTAssertNotNil(renamed)
        XCTAssertEqual(renamed?.lockMode, "alpha")
        XCTAssertEqual(renamed?.opacity, 0.5)
        XCTAssertTrue(renamed?.glowEnabled ?? false)
        XCTAssertEqual(renamed?.glowColor, "#00FF00")
        XCTAssertEqual(renamed?.colorLabel, "#FF0000")
    }

    // MARK: - Migration integration with reopen

    func testReopenWithMigration() throws {
        let project = try coordinator.createProject(name: "Migrate Me")
        let projectID = project.id

        let legacyDir = tempDir.appendingPathComponent("Animations/\(projectID)")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try Data([0x01, 0x02]).write(to: legacyDir.appendingPathComponent("frame_0.png"))
        try Data([0x03]).write(to: legacyDir.appendingPathComponent("audio_0.mp3"))

        let result = try coordinator.reopenProject(id: projectID, legacyDir: legacyDir)

        XCTAssertEqual(result.migrationResult?.migratedAssetCount, 3) // 2 assets + project.json
        XCTAssertEqual(result.project.name, "Migrate Me")
    }

    // MARK: - Delete project

    func testDeleteProject() throws {
        let project = try coordinator.createProject(name: "To Delete")
        try coordinator.save()

        var projects = try coordinator.loadProjects()
        XCTAssertEqual(projects.count, 1)

        try coordinator.repository.deleteProject(id: project.id)
        projects = try coordinator.loadProjects()
        XCTAssertEqual(projects.count, 0)
    }
}
