import XCTest
@testable import SDCore

final class LayerCommandsTests: XCTestCase {
    var tempDir: URL!
    var store: LocalProjectStore!
    var coordinator: SDCoreCoordinator!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = LocalProjectStore(baseDirectory: tempDir)
        coordinator = SDCoreCoordinator(store: store)
        _ = try! coordinator.createProject(name: "Layer Test")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Active layer

    func testSetActiveLayer() throws {
        let project = try coordinator.layerCommands.addLayer(name: "Layer 2")
        let layer2ID = project.layers[0].id

        _ = try coordinator.layerCommands.setActiveLayer(id: layer2ID)
        XCTAssertEqual(coordinator.activeProject?.activeLayerID, layer2ID)
    }

    func testSetActiveLayerNotFoundThrows() {
        XCTAssertThrowsError(try coordinator.layerCommands.setActiveLayer(id: "nonexistent")) { error in
            XCTAssertEqual(error as? LayerError, .layerNotFound)
        }
    }

    // MARK: - Visibility

    func testToggleVisibility() throws {
        let project = try coordinator.layerCommands.toggleVisibility(id: coordinator.activeProject!.layers[0].id)
        XCTAssertFalse(project.layers[0].visible)

        let project2 = try coordinator.layerCommands.toggleVisibility(id: coordinator.activeProject!.layers[0].id)
        XCTAssertTrue(project2.layers[0].visible)
    }

    // MARK: - Lock mode

    func testSetLockMode() throws {
        let layerID = coordinator.activeProject!.layers[0].id
        let project = try coordinator.layerCommands.setLockMode(id: layerID, mode: "full")
        XCTAssertEqual(project.layers[0].lockMode, "full")

        let project2 = try coordinator.layerCommands.setLockMode(id: layerID, mode: "position")
        XCTAssertEqual(project2.layers[0].lockMode, "position")
    }

    // MARK: - Opacity

    func testSetOpacityClamps() throws {
        let layerID = coordinator.activeProject!.layers[0].id
        let project = try coordinator.layerCommands.setOpacity(id: layerID, opacity: 1.5)
        XCTAssertEqual(project.layers[0].opacity, 1.0)

        let project2 = try coordinator.layerCommands.setOpacity(id: layerID, opacity: -0.5)
        XCTAssertEqual(project2.layers[0].opacity, 0.0)

        let project3 = try coordinator.layerCommands.setOpacity(id: layerID, opacity: 0.7)
        XCTAssertEqual(project3.layers[0].opacity, 0.7)
    }

    // MARK: - Blend mode

    func testSetBlendMode() throws {
        let layerID = coordinator.activeProject!.layers[0].id
        let project = try coordinator.layerCommands.setBlendMode(id: layerID, mode: "multiply")
        XCTAssertEqual(project.layers[0].blendMode, "multiply")
    }

    // MARK: - Glow

    func testSetGlowEnabled() throws {
        let layerID = coordinator.activeProject!.layers[0].id
        let project = try coordinator.layerCommands.setGlowEnabled(id: layerID, enabled: true)
        XCTAssertTrue(project.layers[0].glowEnabled)
    }

    func testSetGlowColor() throws {
        let layerID = coordinator.activeProject!.layers[0].id
        let project = try coordinator.layerCommands.setGlowColor(id: layerID, color: "#FF00FF")
        XCTAssertEqual(project.layers[0].glowColor, "#FF00FF")
    }

    // MARK: - Color label

    func testSetColorLabel() throws {
        let layerID = coordinator.activeProject!.layers[0].id
        let project = try coordinator.layerCommands.setColorLabel(id: layerID, color: "#00FF00")
        XCTAssertEqual(project.layers[0].colorLabel, "#00FF00")
    }

    // MARK: - Rename

    func testRename() throws {
        let layerID = coordinator.activeProject!.layers[0].id
        let project = try coordinator.layerCommands.rename(id: layerID, name: "My Layer")
        XCTAssertEqual(project.layers[0].name, "My Layer")
    }

    // MARK: - Add

    func testAddLayer() throws {
        let project = try coordinator.layerCommands.addLayer(name: "New")
        XCTAssertEqual(project.layers.count, 2)
        XCTAssertEqual(project.layers[0].name, "New")
        XCTAssertEqual(project.activeLayerID, project.layers[0].id)
    }

    func testAddLayerAutoNames() throws {
        _ = try coordinator.layerCommands.addLayer()
        _ = try coordinator.layerCommands.addLayer()
        let project = try coordinator.layerCommands.addLayer()
        XCTAssertEqual(project.layers.count, 4)
        XCTAssertEqual(project.layers[0].name, "Layer 4")
    }

    // MARK: - Duplicate

    func testDuplicateLayer() throws {
        let originalID = coordinator.activeProject!.layers[0].id
        let project = try coordinator.layerCommands.duplicateLayer(id: originalID)
        XCTAssertEqual(project.layers.count, 2)
        XCTAssertEqual(project.layers[1].name, "Layer 1 Copy")
    }

    // MARK: - Delete

    func testDeleteLayer() throws {
        _ = try coordinator.layerCommands.addLayer(name: "ToDelete")
        let toDeleteID = coordinator.activeProject!.layers[0].id
        let project = try coordinator.layerCommands.deleteLayer(id: toDeleteID)
        XCTAssertEqual(project.layers.count, 1)
    }

    func testDeleteLastLayerThrows() {
        XCTAssertThrowsError(try coordinator.layerCommands.deleteLayer(id: coordinator.activeProject!.layers[0].id)) { error in
            XCTAssertEqual(error as? LayerError, .cannotDeleteLastLayer)
        }
    }

    func testDeleteActiveLayerRepairsActiveID() throws {
        _ = try coordinator.layerCommands.addLayer(name: "New")
        let newLayerID = coordinator.activeProject!.layers[0].id

        let project = try coordinator.layerCommands.deleteLayer(id: newLayerID)
        XCTAssertNotEqual(project.activeLayerID, newLayerID)
        XCTAssertNotNil(project.layers.first(where: { $0.id == project.activeLayerID }))
    }

    // MARK: - Move

    func testMoveLayerUp() throws {
        _ = try coordinator.layerCommands.addLayer(name: "Top")
        let topID = coordinator.activeProject!.layers[0].id

        let project = try coordinator.layerCommands.moveLayerUp(id: topID)
        let idx = project.layers.firstIndex(where: { $0.id == topID })!
        XCTAssertEqual(idx, 1)
    }

    func testMoveLayerDown() throws {
        _ = try coordinator.layerCommands.addLayer(name: "Top")
        let originalID = coordinator.activeProject!.layers[1].id

        let project = try coordinator.layerCommands.moveLayerDown(id: originalID)
        let idx = project.layers.firstIndex(where: { $0.id == originalID })!
        XCTAssertEqual(idx, 1)
    }

    // MARK: - Persistence

    func testLayerMutationsPersistOnReopen() throws {
        let layerID = coordinator.activeProject!.layers[0].id
        _ = try coordinator.layerCommands.setLockMode(id: layerID, mode: "alpha")
        _ = try coordinator.layerCommands.setOpacity(id: layerID, opacity: 0.3)
        _ = try coordinator.layerCommands.setGlowEnabled(id: layerID, enabled: true)
        _ = try coordinator.layerCommands.setGlowColor(id: layerID, color: "#00FF00")
        _ = try coordinator.layerCommands.setColorLabel(id: layerID, color: "#FF0000")
        _ = try coordinator.layerCommands.rename(id: layerID, name: "Custom")

        let projectID = coordinator.activeProject!.id
        let reopened = try coordinator.openProject(id: projectID)
        XCTAssertNotNil(reopened)

        let layer = reopened!.layers.first(where: { $0.id == layerID })!
        XCTAssertEqual(layer.lockMode, "alpha")
        XCTAssertEqual(layer.opacity, 0.3)
        XCTAssertTrue(layer.glowEnabled)
        XCTAssertEqual(layer.glowColor, "#00FF00")
        XCTAssertEqual(layer.colorLabel, "#FF0000")
        XCTAssertEqual(layer.name, "Custom")
    }
}
