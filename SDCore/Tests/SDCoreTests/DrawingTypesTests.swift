import XCTest
@testable import SDCore

final class DrawingTypesTests: XCTestCase {

    // MARK: - StrokePoint Codable Round-Trip

    func testStrokePointCodableRoundTrip() throws {
        let point = StrokePoint(x: 12.5, y: 34.0, pressure: 0.75, timestamp: 1000.0)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(StrokePoint.self, from: data)
        XCTAssertEqual(point, decoded)
    }

    func testStrokePointWithNilOptionals() throws {
        let point = StrokePoint(x: 1, y: 2)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(StrokePoint.self, from: data)
        XCTAssertNil(decoded.pressure)
        XCTAssertNil(decoded.timestamp)
        XCTAssertEqual(decoded.x, 1)
        XCTAssertEqual(decoded.y, 2)
    }

    // MARK: - DrawingTool

    func testDrawingToolAllCasesCodable() throws {
        for tool in DrawingTool.allCases {
            let data = try JSONEncoder().encode(tool)
            let decoded = try JSONDecoder().decode(DrawingTool.self, from: data)
            XCTAssertEqual(tool, decoded)
        }
    }

    func testDrawingToolRawValues() {
        XCTAssertEqual(DrawingTool.pen.rawValue, "pen")
        XCTAssertEqual(DrawingTool.eraser.rawValue, "eraser")
        XCTAssertEqual(DrawingTool.zoom.rawValue, "zoom")
        XCTAssertEqual(DrawingTool.allCases.count, 27)
    }

    // MARK: - DrawnElement Codable Round-Trip

    func testDrawnElementCodableRoundTrip() throws {
        let element = DrawnElement(
            id: "elem-1",
            tool: .brush,
            points: [
                StrokePoint(x: 0, y: 0),
                StrokePoint(x: 10, y: 10, pressure: 0.5)
            ],
            color: "#FF0000",
            width: 3.0,
            opacity: 0.8,
            fillColor: "#00FF00",
            layerID: "layer-1"
        )
        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(DrawnElement.self, from: data)
        XCTAssertEqual(element, decoded)
    }

    func testDrawnElementEquatableIgnoresNoOptional() throws {
        let a = DrawnElement(id: "1", tool: .pen, points: [], color: "#000", width: 1, opacity: 1)
        let b = DrawnElement(id: "1", tool: .pen, points: [], color: "#000", width: 1, opacity: 1, fillColor: nil, layerID: nil)
        XCTAssertEqual(a, b)
    }

    // MARK: - AnimationFrame Codable Round-Trip

    func testAnimationFrameCodableRoundTrip() throws {
        let frame = AnimationFrame(id: "frame-1", elements: [
            DrawnElement(id: "e1", tool: .pen, points: [StrokePoint(x: 0, y: 0)], color: "#FFF", width: 2, opacity: 1)
        ])
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(AnimationFrame.self, from: data)
        XCTAssertEqual(frame, decoded)
    }

    func testEmptyAnimationFrame() throws {
        let frame = AnimationFrame(id: "empty")
        XCTAssertEqual(frame.elements.count, 0)
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(AnimationFrame.self, from: data)
        XCTAssertEqual(decoded.elements.count, 0)
    }

    // MARK: - CanvasLayer Codable Round-Trip

    func testCanvasLayerCodableRoundTrip() throws {
        let layer = CanvasLayer(
            id: "layer-abc",
            name: "Background",
            visible: true,
            locked: false,
            opacity: 0.75,
            lockMode: "position",
            blendMode: "multiply",
            glowEnabled: true,
            glowColor: "#FF0000",
            colorLabel: "#00FF00"
        )
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(CanvasLayer.self, from: data)
        XCTAssertEqual(layer, decoded)
    }

    func testCanvasLayerDefaults() {
        let layer = CanvasLayer(id: "default", name: "Test")
        XCTAssertTrue(layer.visible)
        XCTAssertFalse(layer.locked)
        XCTAssertEqual(layer.opacity, 1.0)
        XCTAssertEqual(layer.lockMode, "free")
        XCTAssertEqual(layer.blendMode, "normal")
        XCTAssertFalse(layer.glowEnabled)
        XCTAssertNil(layer.glowColor)
        XCTAssertNil(layer.colorLabel)
    }

    func testCanvasLayerTypedLockMode() {
        let free = CanvasLayer(id: "1", name: "A", lockMode: "free")
        XCTAssertEqual(free.typedLockMode, .free)

        let full = CanvasLayer(id: "2", name: "B", lockMode: "full")
        XCTAssertEqual(full.typedLockMode, .full)

        let position = CanvasLayer(id: "3", name: "C", lockMode: "position")
        XCTAssertEqual(position.typedLockMode, .position)

        let alpha = CanvasLayer(id: "4", name: "D", lockMode: "alpha")
        XCTAssertEqual(alpha.typedLockMode, .alpha)

        let unknown = CanvasLayer(id: "5", name: "E", lockMode: "invalid")
        XCTAssertEqual(unknown.typedLockMode, .free)
    }

    // MARK: - LayerLockMode

    func testLayerLockModeAllCasesCodable() throws {
        for mode in LayerLockMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(LayerLockMode.self, from: data)
            XCTAssertEqual(mode, decoded)
        }
    }

    func testLayerLockModeRawValues() {
        XCTAssertEqual(LayerLockMode.free.rawValue, "free")
        XCTAssertEqual(LayerLockMode.full.rawValue, "full")
        XCTAssertEqual(LayerLockMode.position.rawValue, "position")
        XCTAssertEqual(LayerLockMode.alpha.rawValue, "alpha")
    }

    // MARK: - StudioProjectRecord Codable Round-Trip

    func testStudioProjectRecordCodableRoundTrip() throws {
        let project = StudioProjectRecord(
            id: "proj-1",
            name: "Test Animation",
            width: 1920,
            height: 1080,
            fps: 24,
            frameCount: 12,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-02T00:00:00Z"
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(StudioProjectRecord.self, from: data)
        XCTAssertEqual(project, decoded)
    }
}
