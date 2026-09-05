import XCTest
@testable import SDCore

final class TypesTests: XCTestCase {

    // MARK: - StrokePoint

    func testStrokePointEquality() {
        let a = StrokePoint(x: 10, y: 20, pressure: 0.5, timestamp: 1.0)
        let b = StrokePoint(x: 10, y: 20, pressure: 0.5, timestamp: 1.0)
        XCTAssertEqual(a, b)
    }

    func testStrokePointNotEqualDifferentX() {
        let a = StrokePoint(x: 10, y: 20)
        let b = StrokePoint(x: 11, y: 20)
        XCTAssertNotEqual(a, b)
    }

    func testStrokePointCodable() throws {
        let point = StrokePoint(x: 42.5, y: 99.1, pressure: 0.8, timestamp: 1234567890.0)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(StrokePoint.self, from: data)
        XCTAssertEqual(decoded.x, 42.5)
        XCTAssertEqual(decoded.y, 99.1)
        XCTAssertEqual(decoded.pressure, 0.8)
        XCTAssertEqual(decoded.timestamp, 1234567890.0)
    }

    func testStrokePointUsesDoubleNotFloat() {
        let point = StrokePoint(x: 0.123456789012345, y: 0.987654321098765)
        let data = try! JSONEncoder().encode(point)
        let decoded = try! JSONDecoder().decode(StrokePoint.self, from: data)
        XCTAssertEqual(decoded.x, 0.123456789012345, accuracy: 0.000000000000001)
        XCTAssertEqual(decoded.y, 0.987654321098765, accuracy: 0.000000000000001)
    }

    // MARK: - DrawnElement

    func testDrawnElementCodable() throws {
        let element = DrawnElement(
            id: "elem_1",
            tool: .brush,
            points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 100, y: 100)],
            color: "#FF0000",
            width: 3.0,
            opacity: 1.0,
            fillColor: "#00FF00",
            layerID: "layer_1"
        )
        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(DrawnElement.self, from: data)
        XCTAssertEqual(decoded.id, "elem_1")
        XCTAssertEqual(decoded.tool, .brush)
        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertEqual(decoded.color, "#FF0000")
        XCTAssertEqual(decoded.width, 3.0)
        XCTAssertEqual(decoded.opacity, 1.0)
        XCTAssertEqual(decoded.fillColor, "#00FF00")
        XCTAssertEqual(decoded.layerID, "layer_1")
    }

    func testDrawnElementWidthIsDouble() {
        let element = DrawnElement(
            tool: .pen,
            points: [],
            color: "#000000",
            width: 3.14159,
            opacity: 1.0
        )
        XCTAssertEqual(element.width, 3.14159, accuracy: 0.00001)
    }

    // MARK: - DrawingTool

    func testDrawingToolAllCases() {
        XCTAssertEqual(DrawingTool.allCases.count, 30)
    }

    func testDrawingToolCodable() throws {
        let tool = DrawingTool.neon
        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(DrawingTool.self, from: data)
        XCTAssertEqual(decoded, .neon)
    }

    // MARK: - AnimationFrame

    func testAnimationFrameCodable() throws {
        let element = DrawnElement(
            tool: .pencil,
            points: [StrokePoint(x: 0, y: 0)],
            color: "#000000",
            width: 2.0,
            opacity: 0.8
        )
        let frame = AnimationFrame(id: "frame_1", elements: [element])
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(AnimationFrame.self, from: data)
        XCTAssertEqual(decoded.id, "frame_1")
        XCTAssertEqual(decoded.elements.count, 1)
        XCTAssertEqual(decoded.elements[0].tool, .pencil)
    }

    func testAnimationFrameDefaultEmptyElements() {
        let frame = AnimationFrame()
        XCTAssertTrue(frame.elements.isEmpty)
    }

    // MARK: - CanvasLayer

    func testCanvasLayerCodable() throws {
        let layer = CanvasLayer(
            id: "layer_test",
            name: "Background",
            visible: false,
            locked: true,
            opacity: 0.5,
            lockMode: "full",
            blendMode: "multiply",
            glowEnabled: true,
            glowColor: "#FF0000",
            colorLabel: "#00FF00"
        )
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(CanvasLayer.self, from: data)
        XCTAssertEqual(decoded.id, "layer_test")
        XCTAssertEqual(decoded.name, "Background")
        XCTAssertFalse(decoded.visible)
        XCTAssertTrue(decoded.locked)
        XCTAssertEqual(decoded.opacity, 0.5)
        XCTAssertEqual(decoded.lockMode, "full")
        XCTAssertEqual(decoded.blendMode, "multiply")
        XCTAssertTrue(decoded.glowEnabled)
        XCTAssertEqual(decoded.glowColor, "#FF0000")
        XCTAssertEqual(decoded.colorLabel, "#00FF00")
    }

    func testCanvasLayerDeterministicCreation() {
        let a = CanvasLayer.deterministic(id: "layer_abc", name: "Test")
        let b = CanvasLayer.deterministic(id: "layer_abc", name: "Test")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.id, "layer_abc")
    }

    // MARK: - LayerLockMode

    func testLayerLockModeAllCases() {
        XCTAssertEqual(LayerLockMode.allCases.count, 4)
    }

    func testLayerLockModeCodable() throws {
        let mode = LayerLockMode.position
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(LayerLockMode.self, from: data)
        XCTAssertEqual(decoded, .position)
    }
}
