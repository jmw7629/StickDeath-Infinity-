import XCTest
@testable import SDCore

final class LayerMutationTests: XCTestCase {

    func testToggleVisibility() {
        var layers = [CanvasLayer(id: "a", visible: true)]
        XCTAssertTrue(LayerMutationHelpers.toggleVisibility(layers: &layers, id: "a"))
        XCTAssertFalse(layers[0].visible)
        XCTAssertTrue(LayerMutationHelpers.toggleVisibility(layers: &layers, id: "a"))
        XCTAssertTrue(layers[0].visible)
    }

    func testToggleVisibilityUnknownID() {
        var layers = [CanvasLayer(id: "a")]
        XCTAssertFalse(LayerMutationHelpers.toggleVisibility(layers: &layers, id: "b"))
    }

    func testToggleLock() {
        var layers = [CanvasLayer(id: "a", locked: false)]
        XCTAssertTrue(LayerMutationHelpers.toggleLock(layers: &layers, id: "a"))
        XCTAssertTrue(layers[0].locked)
    }

    func testSetLockMode() {
        var layers = [CanvasLayer(id: "a")]
        XCTAssertTrue(LayerMutationHelpers.setLockMode(layers: &layers, id: "a", mode: "full"))
        XCTAssertEqual(layers[0].lockMode, "full")
    }

    func testSetOpacity() {
        var layers = [CanvasLayer(id: "a")]
        XCTAssertTrue(LayerMutationHelpers.setOpacity(layers: &layers, id: "a", opacity: 0.5))
        XCTAssertEqual(layers[0].opacity, 0.5, accuracy: 0.001)
    }

    func testSetOpacityClamps() {
        var layers = [CanvasLayer(id: "a")]
        XCTAssertTrue(LayerMutationHelpers.setOpacity(layers: &layers, id: "a", opacity: 2.0))
        XCTAssertEqual(layers[0].opacity, 1.0)
        XCTAssertTrue(LayerMutationHelpers.setOpacity(layers: &layers, id: "a", opacity: -0.5))
        XCTAssertEqual(layers[0].opacity, 0.0)
    }

    func testSetColorLabel() {
        var layers = [CanvasLayer(id: "a")]
        XCTAssertTrue(LayerMutationHelpers.setColorLabel(layers: &layers, id: "a", colorLabel: "#FF0000"))
        XCTAssertEqual(layers[0].colorLabel, "#FF0000")
        XCTAssertTrue(LayerMutationHelpers.setColorLabel(layers: &layers, id: "a", colorLabel: nil))
        XCTAssertNil(layers[0].colorLabel)
    }

    func testSetBlendMode() {
        var layers = [CanvasLayer(id: "a")]
        XCTAssertTrue(LayerMutationHelpers.setBlendMode(layers: &layers, id: "a", blendMode: "multiply"))
        XCTAssertEqual(layers[0].blendMode, "multiply")
    }

    func testAddLayer() {
        var layers = [CanvasLayer(id: "existing")]
        let newLayer = LayerMutationHelpers.addLayer(layers: &layers)
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers[0].id, newLayer.id)
        XCTAssertEqual(newLayer.name, "Layer 2")
    }

    func testAddLayerAtIndex() {
        var layers = [CanvasLayer(id: "a"), CanvasLayer(id: "b")]
        let newLayer = LayerMutationHelpers.addLayer(layers: &layers, name: "Middle", at: 1)
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(layers[1].id, newLayer.id)
        XCTAssertEqual(newLayer.name, "Middle")
    }

    func testDuplicateLayer() {
        var layers = [CanvasLayer(id: "a", name: "Original", visible: false, opacity: 0.5)]
        let dup = LayerMutationHelpers.duplicateLayer(layers: &layers, id: "a")
        XCTAssertNotNil(dup)
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(dup!.name, "Original Copy")
        XCTAssertFalse(dup!.visible)
        XCTAssertEqual(dup!.opacity, 0.5)
        XCTAssertEqual(layers[1].id, dup!.id)
    }

    func testDuplicateUnknownLayer() {
        var layers = [CanvasLayer(id: "a")]
        let result = LayerMutationHelpers.duplicateLayer(layers: &layers, id: "b")
        XCTAssertNil(result)
        XCTAssertEqual(layers.count, 1)
    }

    func testDeleteLayer() {
        var layers = [CanvasLayer(id: "a"), CanvasLayer(id: "b")]
        XCTAssertTrue(LayerMutationHelpers.deleteLayer(layers: &layers, id: "a"))
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].id, "b")
    }

    func testDeleteUnknownLayer() {
        var layers = [CanvasLayer(id: "a")]
        XCTAssertFalse(LayerMutationHelpers.deleteLayer(layers: &layers, id: "b"))
    }

    func testMoveUp() {
        var layers = [CanvasLayer(id: "a"), CanvasLayer(id: "b"), CanvasLayer(id: "c")]
        XCTAssertTrue(LayerMutationHelpers.moveUp(layers: &layers, id: "b"))
        XCTAssertEqual(layers.map(\.id), ["b", "a", "c"])
    }

    func testMoveUpAtTop() {
        var layers = [CanvasLayer(id: "a"), CanvasLayer(id: "b")]
        XCTAssertFalse(LayerMutationHelpers.moveUp(layers: &layers, id: "a"))
    }

    func testMoveDown() {
        var layers = [CanvasLayer(id: "a"), CanvasLayer(id: "b"), CanvasLayer(id: "c")]
        XCTAssertTrue(LayerMutationHelpers.moveDown(layers: &layers, id: "b"))
        XCTAssertEqual(layers.map(\.id), ["a", "c", "b"])
    }

    func testMoveDownAtBottom() {
        var layers = [CanvasLayer(id: "a"), CanvasLayer(id: "b")]
        XCTAssertFalse(LayerMutationHelpers.moveDown(layers: &layers, id: "b"))
    }

    func testValidateActiveLayerID() {
        let layers = [CanvasLayer(id: "a"), CanvasLayer(id: "b")]
        XCTAssertEqual(LayerMutationHelpers.validateActiveLayerID(layers: layers, activeID: "b"), "b")
        XCTAssertEqual(LayerMutationHelpers.validateActiveLayerID(layers: layers, activeID: "missing"), "a")
        XCTAssertEqual(LayerMutationHelpers.validateActiveLayerID(layers: [], activeID: "x"), "")
    }
}
