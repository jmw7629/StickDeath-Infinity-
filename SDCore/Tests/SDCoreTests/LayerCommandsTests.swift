// ═══════════════════════════════════════════════════════════════════
// LayerCommandsTests — Canonical layer operation evidence
// Tests: select, visibility, lock, opacity, blend, glow, color label,
// rename, add, duplicate (new stable ID), delete (min 1 layer),
// reorder up/down, persist/reload all mutations.
// ═══════════════════════════════════════════════════════════════════

import XCTest
@testable import SDCore

final class LayerCommandsTests: XCTestCase {

    // MARK: - Helpers

    private func makeLayers(count: Int = 2) -> [CanvasLayer] {
        (1...count).map { CanvasLayer(id: "layer_\($0)", name: "Layer \($0)") }
    }

    // MARK: - Select Active Layer

    func testSelectActiveLayer() {
        var layers = makeLayers()
        var activeID = "layer_1"

        let result = LayerCommands.selectLayer(id: "layer_2", layers: &layers, activeLayerID: &activeID)
        XCTAssertTrue(result)
        XCTAssertEqual(activeID, "layer_2")
    }

    func testSelectInvalidLayerReturnsFalse() {
        var layers = makeLayers()
        var activeID = "layer_1"

        let result = LayerCommands.selectLayer(id: "nonexistent", layers: &layers, activeLayerID: &activeID)
        XCTAssertFalse(result)
        XCTAssertEqual(activeID, "layer_1")
    }

    // MARK: - Visibility

    func testToggleVisibility() {
        var layers = makeLayers()

        let result = LayerCommands.toggleVisibility(id: "layer_1", layers: &layers)
        XCTAssertTrue(result)
        XCTAssertFalse(layers[0].visible)

        _ = LayerCommands.toggleVisibility(id: "layer_1", layers: &layers)
        XCTAssertTrue(layers[0].visible)
    }

    // MARK: - Lock Mode

    func testSetLockMode() {
        var layers = makeLayers()

        _ = LayerCommands.setLockMode(id: "layer_1", mode: .full, layers: &layers)
        XCTAssertEqual(layers[0].lockMode, "full")
        XCTAssertTrue(layers[0].locked)

        _ = LayerCommands.setLockMode(id: "layer_1", mode: .position, layers: &layers)
        XCTAssertEqual(layers[0].lockMode, "position")
        XCTAssertTrue(layers[0].locked)

        _ = LayerCommands.setLockMode(id: "layer_1", mode: .free, layers: &layers)
        XCTAssertEqual(layers[0].lockMode, "free")
        XCTAssertFalse(layers[0].locked)
    }

    // MARK: - Opacity with Clamp

    func testSetOpacityClamped() {
        var layers = makeLayers()

        _ = LayerCommands.setOpacity(id: "layer_1", opacity: 0.5, layers: &layers)
        XCTAssertEqual(layers[0].opacity, 0.5)

        _ = LayerCommands.setOpacity(id: "layer_1", opacity: 2.0, layers: &layers)
        XCTAssertEqual(layers[0].opacity, 1.0, "Clamped to 1.0")

        _ = LayerCommands.setOpacity(id: "layer_1", opacity: -0.5, layers: &layers)
        XCTAssertEqual(layers[0].opacity, 0.0, "Clamped to 0.0")
    }

    // MARK: - Blend Mode

    func testSetBlendMode() {
        var layers = makeLayers()

        _ = LayerCommands.setBlendMode(id: "layer_1", blendMode: "multiply", layers: &layers)
        XCTAssertEqual(layers[0].blendMode, "multiply")
    }

    // MARK: - Glow

    func testSetGlow() {
        var layers = makeLayers()

        _ = LayerCommands.setGlow(id: "layer_1", enabled: true, color: "#FF0000", layers: &layers)
        XCTAssertTrue(layers[0].glowEnabled)
        XCTAssertEqual(layers[0].glowColor, "#FF0000")

        _ = LayerCommands.setGlow(id: "layer_1", enabled: false, layers: &layers)
        XCTAssertFalse(layers[0].glowEnabled)
    }

    // MARK: - Color Label

    func testSetColorLabel() {
        var layers = makeLayers()

        _ = LayerCommands.setColorLabel(id: "layer_1", colorLabel: "#FF0000", layers: &layers)
        XCTAssertEqual(layers[0].colorLabel, "#FF0000")

        _ = LayerCommands.setColorLabel(id: "layer_1", colorLabel: nil, layers: &layers)
        XCTAssertNil(layers[0].colorLabel)
    }

    // MARK: - Rename

    func testRename() {
        var layers = makeLayers()

        let result = LayerCommands.rename(id: "layer_1", newName: "Background", layers: &layers)
        XCTAssertTrue(result)
        XCTAssertEqual(layers[0].name, "Background")
    }

    // MARK: - Add Layer

    func testAddLayer() {
        var layers = makeLayers()
        var activeID = "layer_1"

        let newLayer = LayerCommands.addLayer(layers: &layers, activeLayerID: &activeID)
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(newLayer.name, "Layer 3")
        XCTAssertEqual(activeID, newLayer.id)
    }

    // MARK: - Duplicate with New Stable String ID

    func testDuplicatePreservesPropertiesNewID() {
        var layers = makeLayers()
        var activeID = "layer_1"

        layers[0].opacity = 0.5
        layers[0].lockMode = "full"
        layers[0].blendMode = "multiply"
        layers[0].glowEnabled = true
        layers[0].glowColor = "#FF0000"

        let dupe = LayerCommands.duplicateLayer(id: "layer_1", layers: &layers, activeLayerID: &activeID)

        XCTAssertNotNil(dupe)
        XCTAssertNotEqual(dupe?.id, "layer_1", "Must have new stable ID")
        XCTAssertEqual(dupe?.opacity, 0.5)
        XCTAssertEqual(dupe?.lockMode, "full")
        XCTAssertEqual(dupe?.blendMode, "multiply")
        XCTAssertTrue(dupe?.glowEnabled ?? false)
        XCTAssertEqual(dupe?.glowColor, "#FF0000")
        XCTAssertEqual(dupe?.name, "Layer 1 Copy")
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(activeID, dupe?.id ?? "")
    }

    // MARK: - Delete (Cannot Leave Zero Layers)

    func testDeleteCannotLeaveZeroLayers() {
        var layers = [CanvasLayer(id: "only_layer", name: "Only")]
        var activeID = "only_layer"

        let result = LayerCommands.deleteLayer(id: "only_layer", layers: &layers, activeLayerID: &activeID)
        XCTAssertFalse(result)
        XCTAssertEqual(layers.count, 1)
    }

    func testDeleteRepairsActiveSelection() {
        var layers = makeLayers(count: 3)
        var activeID = "layer_1"

        let result = LayerCommands.deleteLayer(id: "layer_1", layers: &layers, activeLayerID: &activeID)
        XCTAssertTrue(result)
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(activeID, "layer_2", "Active selection repaired to next layer")
    }

    // MARK: - Reorder

    func testMoveUp() {
        var layers = makeLayers()

        let result = LayerCommands.moveUp(id: "layer_2", layers: &layers)
        XCTAssertTrue(result)
        XCTAssertEqual(layers[0].id, "layer_2")
        XCTAssertEqual(layers[1].id, "layer_1")
    }

    func testMoveDown() {
        var layers = makeLayers()

        let result = LayerCommands.moveDown(id: "layer_1", layers: &layers)
        XCTAssertTrue(result)
        XCTAssertEqual(layers[0].id, "layer_2")
        XCTAssertEqual(layers[1].id, "layer_1")
    }

    func testMoveUpAtTopReturnsFalse() {
        var layers = makeLayers()

        let result = LayerCommands.moveUp(id: "layer_1", layers: &layers)
        XCTAssertFalse(result)
    }

    // MARK: - Persist/Reload All Mutations

    func testPersistAndReloadAllMutations() throws {
        var layers = makeLayers()
        var activeID = "layer_1"

        // Apply all mutations
        _ = LayerCommands.selectLayer(id: "layer_2", layers: &layers, activeLayerID: &activeID)
        _ = LayerCommands.toggleVisibility(id: "layer_1", layers: &layers)
        _ = LayerCommands.setLockMode(id: "layer_2", mode: .full, layers: &layers)
        _ = LayerCommands.setOpacity(id: "layer_1", opacity: 0.5, layers: &layers)
        _ = LayerCommands.setBlendMode(id: "layer_1", blendMode: "multiply", layers: &layers)
        _ = LayerCommands.setGlow(id: "layer_2", enabled: true, color: "#FF0000", layers: &layers)
        _ = LayerCommands.setColorLabel(id: "layer_1", colorLabel: "#00FF00", layers: &layers)
        _ = LayerCommands.rename(id: "layer_1", newName: "Renamed", layers: &layers)

        // Build project with layers
        var project = SDProject()
        project.layers = layers
        project.activeLayerID = activeID

        // Encode (persist)
        let data = try JSONEncoder().encode(project)

        // Decode (reload)
        let reloaded = try JSONDecoder().decode(SDProject.self, from: data)

        // Verify all mutations survived round-trip
        XCTAssertEqual(reloaded.activeLayerID, "layer_2")
        XCTAssertEqual(reloaded.layers.count, 2)

        let l1 = reloaded.layers.first { $0.id == "layer_1" }
        XCTAssertNotNil(l1)
        XCTAssertFalse(l1?.visible ?? true)
        XCTAssertEqual(l1?.opacity, 0.5)
        XCTAssertEqual(l1?.blendMode, "multiply")
        XCTAssertEqual(l1?.colorLabel, "#00FF00")
        XCTAssertEqual(l1?.name, "Renamed")

        let l2 = reloaded.layers.first { $0.id == "layer_2" }
        XCTAssertNotNil(l2)
        XCTAssertEqual(l2?.lockMode, "full")
        XCTAssertTrue(l2?.glowEnabled ?? false)
        XCTAssertEqual(l2?.glowColor, "#FF0000")
    }
}
