import XCTest
@testable import SDCore

final class CanvasLayerTests: XCTestCase {

    func testDefaultLayerHasStableID() {
        let layer = CanvasLayer.defaultLayer()
        XCTAssertEqual(layer.id, "layer_default")
        XCTAssertEqual(layer.name, "Layer 1")
        XCTAssertTrue(layer.visible)
        XCTAssertFalse(layer.locked)
        XCTAssertEqual(layer.opacity, 1.0)
    }

    func testNewLayerDeterministicID() {
        let layer0 = CanvasLayer.newLayer(index: 0)
        let layer1 = CanvasLayer.newLayer(index: 1)
        let layer5 = CanvasLayer.newLayer(index: 5)

        XCTAssertEqual(layer0.id, "layer_0")
        XCTAssertEqual(layer1.id, "layer_1")
        XCTAssertEqual(layer5.id, "layer_5")
    }

    func testNewLayerCustomName() {
        let layer = CanvasLayer.newLayer(index: 2, name: "Background")
        XCTAssertEqual(layer.id, "layer_2")
        XCTAssertEqual(layer.name, "Background")
    }

    func testLayerDeterministicIDNeverRandomUUID() {
        // IDs must be stable string patterns, never UUID()
        for i in 0..<100 {
            let layer = CanvasLayer.newLayer(index: i)
            XCTAssertEqual(layer.id, "layer_\(i)")
        }
    }

    func testLayerMutations() {
        var layer = CanvasLayer.defaultLayer()

        // Visibility toggle
        layer.visible = false
        XCTAssertFalse(layer.visible)
        layer.visible = true
        XCTAssertTrue(layer.visible)

        // Lock
        layer.locked = true
        XCTAssertTrue(layer.locked)

        // Opacity
        layer.opacity = 0.5
        XCTAssertEqual(layer.opacity, 0.5)

        // Lock mode
        layer.lockMode = "full"
        XCTAssertEqual(layer.lockMode, "full")

        // Blend mode
        layer.blendMode = "multiply"
        XCTAssertEqual(layer.blendMode, "multiply")

        // Glow
        layer.glowEnabled = true
        layer.glowColor = "#FF0000"
        XCTAssertTrue(layer.glowEnabled)
        XCTAssertEqual(layer.glowColor, "#FF0000")

        // Color label
        layer.colorLabel = "red"
        XCTAssertEqual(layer.colorLabel, "red")
    }

    func testLayerCodableRoundTrip() throws {
        var layer = CanvasLayer.defaultLayer()
        layer.visible = false
        layer.locked = true
        layer.opacity = 0.75
        layer.lockMode = "position"
        layer.blendMode = "screen"
        layer.glowEnabled = true
        layer.glowColor = "#00FF00"
        layer.colorLabel = "blue"

        let encoder = JSONEncoder()
        let data = try encoder.encode(layer)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CanvasLayer.self, from: data)

        XCTAssertEqual(decoded.id, layer.id)
        XCTAssertEqual(decoded.name, layer.name)
        XCTAssertEqual(decoded.visible, layer.visible)
        XCTAssertEqual(decoded.locked, layer.locked)
        XCTAssertEqual(decoded.opacity, layer.opacity)
        XCTAssertEqual(decoded.lockMode, layer.lockMode)
        XCTAssertEqual(decoded.blendMode, layer.blendMode)
        XCTAssertEqual(decoded.glowEnabled, layer.glowEnabled)
        XCTAssertEqual(decoded.glowColor, layer.glowColor)
        XCTAssertEqual(decoded.colorLabel, layer.colorLabel)
    }
}
