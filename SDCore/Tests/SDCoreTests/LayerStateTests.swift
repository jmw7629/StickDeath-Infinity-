import XCTest
@testable import SDCore

final class LayerStateTests: XCTestCase {

    // MARK: - Deterministic IDs

    func testDeterministicIDFromInput() {
        XCTAssertEqual(LayerState.deterministicID(from: "my_layer"), "my_layer")
        XCTAssertEqual(LayerState.deterministicID(from: "layer_default"), "layer_default")
        XCTAssertEqual(LayerState.deterministicID(from: ""), "layer_default")
        XCTAssertEqual(LayerState.deterministicID(from: "abc123-def456"), "abc123-def456")
    }

    func testNewLayerIDIsUUID() {
        let id = LayerState.newLayerID()
        XCTAssertNotNil(UUID(uuidString: id))
    }

    func testArbitraryStringIDsRoundTrip() {
        let layer = CanvasLayer(id: "some_random_string", name: "Test")
        XCTAssertEqual(layer.id, "some_random_string")

        let encoded = try! JSONEncoder().encode(layer)
        let decoded = try! JSONDecoder().decode(CanvasLayer.self, from: encoded)
        XCTAssertEqual(decoded.id, "some_random_string")
    }

    func testUUIDLookingStringIDsRoundTrip() {
        let uuidStr = UUID().uuidString
        let layer = CanvasLayer(id: uuidStr, name: "Test")
        let encoded = try! JSONEncoder().encode(layer)
        let decoded = try! JSONDecoder().decode(CanvasLayer.self, from: encoded)
        XCTAssertEqual(decoded.id, uuidStr)
    }

    func testDefaultLayerIDRoundTrips() {
        let layer = CanvasLayer(id: "layer_default", name: "Default")
        let encoded = try! JSONEncoder().encode(layer)
        let decoded = try! JSONDecoder().decode(CanvasLayer.self, from: encoded)
        XCTAssertEqual(decoded.id, "layer_default")
    }

    // MARK: - Init

    func testInitEmpty() {
        let state = LayerState()
        XCTAssertEqual(state.layers.count, 0)
        XCTAssertEqual(state.activeLayerID, "")
    }

    func testInitWithLayers() {
        let layers = [
            CanvasLayer(id: "a", name: "Layer A"),
            CanvasLayer(id: "b", name: "Layer B")
        ]
        let state = LayerState(layers: layers)
        XCTAssertEqual(state.layers.count, 2)
        XCTAssertEqual(state.activeLayerID, "a")
    }

    // MARK: - Visibility Mutations

    func testToggleVisibility() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1", visible: true)])
        state.toggleVisibility("1")
        XCTAssertFalse(state.layers[0].visible)
        state.toggleVisibility("1")
        XCTAssertTrue(state.layers[0].visible)
    }

    func testToggleVisibilityNonexistentID() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.toggleVisibility("nonexistent")
        XCTAssertTrue(state.layers[0].visible)
    }

    // MARK: - Lock Mode

    func testSetLockMode() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.setLockMode("1", mode: .full)
        XCTAssertEqual(state.layers[0].lockMode, "full")
        state.setLockMode("1", mode: .position)
        XCTAssertEqual(state.layers[0].lockMode, "position")
    }

    // MARK: - Opacity

    func testSetOpacity() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.setOpacity("1", opacity: 0.5)
        XCTAssertEqual(state.layers[0].opacity, 0.5)
    }

    func testSetOpacityClamps() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.setOpacity("1", opacity: 1.5)
        XCTAssertEqual(state.layers[0].opacity, 1.0)
        state.setOpacity("1", opacity: -0.5)
        XCTAssertEqual(state.layers[0].opacity, 0.0)
    }

    // MARK: - Blend Mode

    func testSetBlendMode() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.setBlendMode("1", blendMode: "multiply")
        XCTAssertEqual(state.layers[0].blendMode, "multiply")
    }

    // MARK: - Glow

    func testToggleGlow() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.toggleGlow("1")
        XCTAssertTrue(state.layers[0].glowEnabled)
        state.toggleGlow("1")
        XCTAssertFalse(state.layers[0].glowEnabled)
    }

    func testSetGlowColor() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.setGlowColor("1", color: "#FF0000")
        XCTAssertEqual(state.layers[0].glowColor, "#FF0000")
        state.setGlowColor("1", color: nil)
        XCTAssertNil(state.layers[0].glowColor)
    }

    // MARK: - Color Label

    func testSetColorLabel() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.setColorLabel("1", color: "#00FF00")
        XCTAssertEqual(state.layers[0].colorLabel, "#00FF00")
    }

    // MARK: - Add Layer

    func testAddLayer() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        let newLayer = state.addLayer(name: "Custom")
        XCTAssertEqual(state.layers.count, 2)
        XCTAssertEqual(state.layers[0].name, "Custom")
        XCTAssertEqual(state.layers[0].id, newLayer.id)
        XCTAssertEqual(state.activeLayerID, newLayer.id)
    }

    func testAddLayerAutoName() {
        let state = LayerState()
        state.addLayer()
        XCTAssertEqual(state.layers[0].name, "Layer 1")
        state.addLayer()
        XCTAssertEqual(state.layers[0].name, "Layer 2")
    }

    // MARK: - Duplicate

    func testDuplicateLayer() {
        let state = LayerState(layers: [
            CanvasLayer(id: "1", name: "Original", opacity: 0.5)
        ])
        let copy = state.duplicateLayer("1")
        XCTAssertNotNil(copy)
        XCTAssertEqual(state.layers.count, 2)
        XCTAssertEqual(state.layers[1].name, "Original Copy")
        XCTAssertEqual(state.layers[1].opacity, 0.5)
        XCTAssertNotEqual(state.layers[0].id, state.layers[1].id)
    }

    func testDuplicateNonexistentID() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        let result = state.duplicateLayer("nonexistent")
        XCTAssertNil(result)
        XCTAssertEqual(state.layers.count, 1)
    }

    // MARK: - Delete

    func testDeleteLayer() {
        let state = LayerState(layers: [
            CanvasLayer(id: "1", name: "L1"),
            CanvasLayer(id: "2", name: "L2")
        ])
        state.deleteLayer("1")
        XCTAssertEqual(state.layers.count, 1)
        XCTAssertEqual(state.activeLayerID, "2")
    }

    func testDeleteLastLayerIsNoOp() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.deleteLayer("1")
        XCTAssertEqual(state.layers.count, 1)
    }

    func testDeleteActiveLayerFallsBack() {
        let state = LayerState(layers: [
            CanvasLayer(id: "1", name: "L1"),
            CanvasLayer(id: "2", name: "L2")
        ])
        state.activeLayerID = "1"
        state.deleteLayer("1")
        XCTAssertEqual(state.activeLayerID, "2")
    }

    // MARK: - Reorder

    func testMoveLayerUp() {
        let state = LayerState(layers: [
            CanvasLayer(id: "1", name: "L1"),
            CanvasLayer(id: "2", name: "L2"),
            CanvasLayer(id: "3", name: "L3")
        ])
        state.moveLayerUp("3")
        XCTAssertEqual(state.layers.map(\.id), ["1", "3", "2"])
    }

    func testMoveLayerUpAtTop() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.moveLayerUp("1")
        XCTAssertEqual(state.layers.map(\.id), ["1"])
    }

    func testMoveLayerDown() {
        let state = LayerState(layers: [
            CanvasLayer(id: "1", name: "L1"),
            CanvasLayer(id: "2", name: "L2"),
            CanvasLayer(id: "3", name: "L3")
        ])
        state.moveLayerDown("1")
        XCTAssertEqual(state.layers.map(\.id), ["2", "1", "3"])
    }

    func testMoveLayerDownAtBottom() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.moveLayerDown("1")
        XCTAssertEqual(state.layers.map(\.id), ["1"])
    }

    // MARK: - Active Layer

    func testSetActiveLayer() {
        let state = LayerState(layers: [
            CanvasLayer(id: "1", name: "L1"),
            CanvasLayer(id: "2", name: "L2")
        ])
        state.setActiveLayer("2")
        XCTAssertEqual(state.activeLayerID, "2")
    }

    func testSetActiveLayerInvalidID() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        state.setActiveLayer("nonexistent")
        XCTAssertEqual(state.activeLayerID, "1")
    }

    // MARK: - Layer by ID

    func testLayerByID() {
        let state = LayerState(layers: [CanvasLayer(id: "1", name: "L1")])
        XCTAssertNotNil(state.layer(withID: "1"))
        XCTAssertNil(state.layer(withID: "nonexistent"))
    }

    func testLayerIndex() {
        let state = LayerState(layers: [
            CanvasLayer(id: "1", name: "L1"),
            CanvasLayer(id: "2", name: "L2")
        ])
        XCTAssertEqual(state.layerIndex("1"), 0)
        XCTAssertEqual(state.layerIndex("2"), 1)
        XCTAssertNil(state.layerIndex("nonexistent"))
    }

    // MARK: - Reset

    func testReset() {
        let state = LayerState(layers: [
            CanvasLayer(id: "1", name: "L1"),
            CanvasLayer(id: "2", name: "L2")
        ])
        state.reset()
        XCTAssertEqual(state.layers.count, 1)
        XCTAssertEqual(state.layers[0].name, "Layer 1")
        XCTAssertEqual(state.activeLayerID, state.layers[0].id)
    }

    // MARK: - All mutations persist canonical state only

    func testAllMutationsPersistOnCanonicalLayers() {
        let state = LayerState(layers: [
            CanvasLayer(id: "1", name: "L1"),
            CanvasLayer(id: "2", name: "L2")
        ])

        state.toggleVisibility("1")
        XCTAssertFalse(state.layers[0].visible)

        state.setLockMode("1", mode: .full)
        XCTAssertEqual(state.layers[0].lockMode, "full")

        state.setOpacity("1", opacity: 0.3)
        XCTAssertEqual(state.layers[0].opacity, 0.3)

        state.setBlendMode("1", blendMode: "screen")
        XCTAssertEqual(state.layers[0].blendMode, "screen")

        state.toggleGlow("1")
        XCTAssertTrue(state.layers[0].glowEnabled)

        state.setGlowColor("1", color: "#FFF")
        XCTAssertEqual(state.layers[0].glowColor, "#FFF")

        state.setColorLabel("1", color: "#00F")
        XCTAssertEqual(state.layers[0].colorLabel, "#00F")

        let newLayer = state.addLayer(name: "L3")
        XCTAssertEqual(state.layers.count, 3)
        XCTAssertEqual(state.layers[0].id, newLayer.id)

        state.moveLayerDown(newLayer.id)
        XCTAssertEqual(state.layers.map(\.id), ["1", newLayer.id, "2"])

        let copy = state.duplicateLayer("1")
        XCTAssertEqual(state.layers.count, 4)

        state.deleteLayer(copy!.id)
        XCTAssertEqual(state.layers.count, 3)
    }

    // MARK: - Codable round-trip for full state

    func testLayerStateCodableRoundTrip() throws {
        let state = LayerState(layers: [
            CanvasLayer(id: "a", name: "Background", visible: true, opacity: 1.0),
            CanvasLayer(id: "b", name: "Foreground", visible: false, opacity: 0.5, lockMode: "full")
        ])

        let encoder = JSONEncoder()
        let data = try encoder.encode(state.layers)
        let decoded = try JSONDecoder().decode([CanvasLayer].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].id, "a")
        XCTAssertEqual(decoded[0].name, "Background")
        XCTAssertEqual(decoded[1].id, "b")
        XCTAssertFalse(decoded[1].visible)
        XCTAssertEqual(decoded[1].lockMode, "full")
    }
}
