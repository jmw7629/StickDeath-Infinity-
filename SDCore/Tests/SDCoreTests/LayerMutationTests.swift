import XCTest
@testable import SDCore

final class LayerMutationTests: XCTestCase {

    private func makeLayers() -> [CanvasLayer] {
        [
            CanvasLayer(id: "layer_1", name: "Background", visible: true, locked: false, opacity: 1.0),
            CanvasLayer(id: "layer_2", name: "Foreground", visible: true, locked: false, opacity: 0.8),
            CanvasLayer(id: "layer_3", name: "Overlay", visible: false, locked: true, opacity: 0.5),
        ]
    }

    // MARK: - Deterministic identity

    func testDeterministicLayerID() {
        let a = CanvasLayer.deterministic(id: "layer_custom_1", name: "Test")
        let b = CanvasLayer.deterministic(id: "layer_custom_1", name: "Test")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.id, "layer_custom_1")
    }

    func testAddLayerReturnsID() {
        var layers = makeLayers()
        let newLayer = LayerMutationHelpers.addLayer(layers: &layers, name: "New")
        XCTAssertFalse(newLayer.id.isEmpty)
        XCTAssertEqual(newLayer.name, "New")
        XCTAssertEqual(layers.count, 4)
        XCTAssertEqual(layers[0].id, newLayer.id)
    }

    // MARK: - Visibility

    func testToggleVisibility() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.toggleVisibility(layers: &layers, id: "layer_1")
        XCTAssertFalse(layers[0].visible)
        try LayerMutationHelpers.toggleVisibility(layers: &layers, id: "layer_1")
        XCTAssertTrue(layers[0].visible)
    }

    func testToggleVisibilityNotFound() {
        var layers = makeLayers()
        XCTAssertThrowsError(try LayerMutationHelpers.toggleVisibility(layers: &layers, id: "nonexistent"))
    }

    // MARK: - Lock mode

    func testSetLockMode() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.setLockMode(layers: &layers, id: "layer_1", mode: .full)
        XCTAssertEqual(layers[0].lockMode, "full")
        XCTAssertTrue(layers[0].locked)

        try LayerMutationHelpers.setLockMode(layers: &layers, id: "layer_1", mode: .free)
        XCTAssertEqual(layers[0].lockMode, "free")
        XCTAssertFalse(layers[0].locked)
    }

    func testSetLockModePosition() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.setLockMode(layers: &layers, id: "layer_2", mode: .position)
        XCTAssertEqual(layers[1].lockMode, "position")
        XCTAssertTrue(layers[1].locked)
    }

    func testSetLockModeAlpha() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.setLockMode(layers: &layers, id: "layer_2", mode: .alpha)
        XCTAssertEqual(layers[1].lockMode, "alpha")
        XCTAssertTrue(layers[1].locked)
    }

    // MARK: - Opacity

    func testSetOpacity() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.setOpacity(layers: &layers, id: "layer_1", opacity: 0.42)
        XCTAssertEqual(layers[0].opacity, 0.42, accuracy: 0.001)
    }

    func testSetOpacityClamps() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.setOpacity(layers: &layers, id: "layer_1", opacity: 1.5)
        XCTAssertEqual(layers[0].opacity, 1.0)
        try LayerMutationHelpers.setOpacity(layers: &layers, id: "layer_1", opacity: -0.5)
        XCTAssertEqual(layers[0].opacity, 0.0)
    }

    // MARK: - Blend mode

    func testSetBlendMode() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.setBlendMode(layers: &layers, id: "layer_1", blendMode: "multiply")
        XCTAssertEqual(layers[0].blendMode, "multiply")
    }

    // MARK: - Color label

    func testSetColorLabel() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.setColorLabel(layers: &layers, id: "layer_1", colorLabel: "#FF0000")
        XCTAssertEqual(layers[0].colorLabel, "#FF0000")
        try LayerMutationHelpers.setColorLabel(layers: &layers, id: "layer_1", colorLabel: nil)
        XCTAssertNil(layers[0].colorLabel)
    }

    // MARK: - Glow

    func testSetGlowEnabled() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.setGlowEnabled(layers: &layers, id: "layer_1", enabled: true)
        XCTAssertTrue(layers[0].glowEnabled)
        try LayerMutationHelpers.setGlowEnabled(layers: &layers, id: "layer_1", enabled: false)
        XCTAssertFalse(layers[0].glowEnabled)
    }

    func testSetGlowColor() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.setGlowColor(layers: &layers, id: "layer_1", color: "#00FF00")
        XCTAssertEqual(layers[0].glowColor, "#00FF00")
        try LayerMutationHelpers.setGlowColor(layers: &layers, id: "layer_1", color: nil)
        XCTAssertNil(layers[0].glowColor)
    }

    // MARK: - Add

    func testAddLayerAtBeginning() {
        var layers = makeLayers()
        let added = LayerMutationHelpers.addLayer(layers: &layers, name: "New Top")
        XCTAssertEqual(layers.count, 4)
        XCTAssertEqual(layers[0].id, added.id)
        XCTAssertEqual(layers[0].name, "New Top")
    }

    func testAddLayerAtSpecificIndex() {
        var layers = makeLayers()
        let added = LayerMutationHelpers.addLayer(layers: &layers, name: "Middle", at: 1)
        XCTAssertEqual(layers.count, 4)
        XCTAssertEqual(layers[1].id, added.id)
        XCTAssertEqual(layers[1].name, "Middle")
    }

    // MARK: - Duplicate

    func testDuplicateLayer() throws {
        var layers = makeLayers()
        let dup = try LayerMutationHelpers.duplicateLayer(layers: &layers, id: "layer_2")
        XCTAssertEqual(layers.count, 4)
        XCTAssertEqual(dup.name, "Foreground Copy")
        XCTAssertEqual(dup.visible, true)
        XCTAssertEqual(dup.opacity, 0.8)
        XCTAssertEqual(layers[2].id, dup.id)
    }

    func testDuplicatePreservesAllProperties() throws {
        var layers = makeLayers()
        layers[1].lockMode = "position"
        layers[1].blendMode = "screen"
        layers[1].glowEnabled = true
        layers[1].glowColor = "#FF00FF"
        layers[1].colorLabel = "#00FF00"

        let dup = try LayerMutationHelpers.duplicateLayer(layers: &layers, id: "layer_2")
        XCTAssertEqual(dup.lockMode, "position")
        XCTAssertEqual(dup.blendMode, "screen")
        XCTAssertTrue(dup.glowEnabled)
        XCTAssertEqual(dup.glowColor, "#FF00FF")
        XCTAssertEqual(dup.colorLabel, "#00FF00")
    }

    // MARK: - Delete

    func testDeleteLayer() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.deleteLayer(layers: &layers, id: "layer_2")
        XCTAssertEqual(layers.count, 2)
        XCTAssertFalse(layers.contains(where: { $0.id == "layer_2" }))
    }

    func testDeleteLastLayerIsNoop() throws {
        var layers = [CanvasLayer(id: "only", name: "Only")]
        try LayerMutationHelpers.deleteLayer(layers: &layers, id: "only")
        XCTAssertEqual(layers.count, 1)
    }

    func testDeleteNotFound() {
        var layers = makeLayers()
        XCTAssertThrowsError(try LayerMutationHelpers.deleteLayer(layers: &layers, id: "nonexistent"))
    }

    // MARK: - Reorder

    func testMoveUp() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.moveUp(layers: &layers, id: "layer_2")
        XCTAssertEqual(layers[0].id, "layer_2")
        XCTAssertEqual(layers[1].id, "layer_1")
    }

    func testMoveUpFirstIsNoop() {
        var layers = makeLayers()
        XCTAssertThrowsError(try LayerMutationHelpers.moveUp(layers: &layers, id: "layer_1"))
    }

    func testMoveDown() throws {
        var layers = makeLayers()
        try LayerMutationHelpers.moveDown(layers: &layers, id: "layer_1")
        XCTAssertEqual(layers[0].id, "layer_2")
        XCTAssertEqual(layers[1].id, "layer_1")
    }

    func testMoveDownLastIsNoop() {
        var layers = makeLayers()
        XCTAssertThrowsError(try LayerMutationHelpers.moveDown(layers: &layers, id: "layer_3"))
    }

    // MARK: - Active layer selection

    func testSelectLayer() throws {
        var layers = makeLayers()
        var activeID = "layer_1"
        try LayerMutationHelpers.selectLayer(id: "layer_3", activeLayerID: &activeID, layers: layers)
        XCTAssertEqual(activeID, "layer_3")
    }

    func testSelectNonexistentLayer() {
        var layers = makeLayers()
        var activeID = "layer_1"
        XCTAssertThrowsError(
            try LayerMutationHelpers.selectLayer(id: "nonexistent", activeLayerID: &activeID, layers: layers)
        )
    }
}
