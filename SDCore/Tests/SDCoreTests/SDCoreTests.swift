import XCTest
@testable import SDCore

final class SDCoreTests: XCTestCase {

    // MARK: - DrawnElement round trip

    func testDrawnElementRoundTrip() throws {
        let element = DrawnElement(
            id: "elem-1",
            tool: .brush,
            points: [
                StrokePoint(x: 10.5, y: 20.3, pressure: 0.8, timestamp: 1.0),
                StrokePoint(x: 30.1, y: 40.7, pressure: 0.6, timestamp: 2.0),
            ],
            color: "#FF0000",
            width: 3.0,
            opacity: 1.0,
            fillColor: "#00FF00",
            layerID: "layer-1"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(element)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DrawnElement.self, from: data)

        XCTAssertEqual(decoded.id, "elem-1")
        XCTAssertEqual(decoded.tool, .brush)
        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertEqual(decoded.points[0].x, 10.5, accuracy: 0.001)
        XCTAssertEqual(decoded.points[0].y, 20.3, accuracy: 0.001)
        XCTAssertEqual(decoded.points[0].pressure, 0.8, accuracy: 0.001)
        XCTAssertEqual(decoded.color, "#FF0000")
        XCTAssertEqual(decoded.width, 3.0, accuracy: 0.001)
        XCTAssertEqual(decoded.fillColor, "#00FF00")
        XCTAssertEqual(decoded.layerID, "layer-1")
    }

    // MARK: - AnimationFrame round trip with non-empty elements

    func testAnimationFrameRoundTrip() throws {
        let elements = [
            DrawnElement(
                id: "e1", tool: .pen,
                points: [StrokePoint(x: 1, y: 2), StrokePoint(x: 3, y: 4)],
                color: "#FF0000", width: 2.0, opacity: 1.0
            ),
            DrawnElement(
                id: "e2", tool: .fill,
                points: [StrokePoint(x: 5, y: 6, pressure: 0.9)],
                color: "#0000FF", width: 0.0, opacity: 0.8, fillColor: "#FFFF00"
            ),
        ]
        let frame = AnimationFrame(id: "frame-1", elements: elements)

        let encoder = JSONEncoder()
        let data = try encoder.encode(frame)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnimationFrame.self, from: data)

        XCTAssertEqual(decoded.id, "frame-1")
        XCTAssertEqual(decoded.elements.count, 2)
        XCTAssertEqual(decoded.elements[0].tool, .pen)
        XCTAssertEqual(decoded.elements[1].tool, .fill)
        XCTAssertEqual(decoded.elements[1].fillColor, "#FFFF00")
    }

    // MARK: - CanvasLayer round trip

    func testCanvasLayerRoundTrip() throws {
        let layer = CanvasLayer(
            id: "layer-1", name: "Background", visible: true,
            locked: false, opacity: 0.9, lockMode: "position",
            blendMode: "multiply", glowEnabled: true,
            glowColor: "#FF00FF", colorLabel: "#00FF00"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(layer)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CanvasLayer.self, from: data)

        XCTAssertEqual(decoded.id, "layer-1")
        XCTAssertEqual(decoded.name, "Background")
        XCTAssertTrue(decoded.visible)
        XCTAssertFalse(decoded.locked)
        XCTAssertEqual(decoded.opacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(decoded.lockMode, "position")
        XCTAssertEqual(decoded.blendMode, "multiply")
        XCTAssertTrue(decoded.glowEnabled)
        XCTAssertEqual(decoded.glowColor, "#FF00FF")
        XCTAssertEqual(decoded.colorLabel, "#00FF00")
    }

    // MARK: - SubscriptionTier / CallRateTier round trip

    func testSubscriptionTierCodable() throws {
        for tier in SubscriptionTier.allCases {
            let data = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(SubscriptionTier.self, from: data)
            XCTAssertEqual(decoded, tier)
        }
    }

    func testCallRateTierCodable() throws {
        for tier in CallRateTier.allCases {
            let data = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(CallRateTier.self, from: data)
            XCTAssertEqual(decoded, tier)
        }
    }

    // MARK: - AnimationProject round trip (device storage persistence)

    func testAnimationProjectRoundTrip() throws {
        let projectID = UUID()
        let metadata = AnimationMetadata(
            id: projectID, title: "Test Animation", fps: 12,
            canvasWidth: 1080, canvasHeight: 1080,
            frameCount: 2, layerCount: 1,
            createdAt: Date(timeIntervalSince1970: 1000000),
            modifiedAt: Date(timeIntervalSince1970: 1000001)
        )
        let rasterData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header bytes
        let frames = [
            StoredAnimationFrame(imageData: rasterData, layerData: nil),
            StoredAnimationFrame(imageData: nil, layerData: [
                LayerData(id: UUID(), name: "L1", opacity: 1.0, blendMode: "normal", locked: false, visible: true)
            ]),
        ]
        let project = AnimationProject(id: projectID, metadata: metadata, frames: frames, audioTracks: [])

        let encoder = JSONEncoder()
        let data = try encoder.encode(project)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnimationProject.self, from: data)

        XCTAssertEqual(decoded.id, projectID)
        XCTAssertEqual(decoded.metadata.title, "Test Animation")
        XCTAssertEqual(decoded.metadata.fps, 12)
        XCTAssertEqual(decoded.frames.count, 2)
        XCTAssertEqual(decoded.frames[0].imageData, rasterData)
        XCTAssertNil(decoded.frames[0].layerData)
        XCTAssertNil(decoded.frames[1].imageData)
        XCTAssertEqual(decoded.frames[1].layerData?.count, 1)
        XCTAssertEqual(decoded.frames[1].layerData?.first?.name, "L1")
    }

    // MARK: - Legacy raster frame reference preservation test

    func testLegacyRasterReferencePreservedAcrossSaveLoad() throws {
        let projectID = UUID()
        let rasterPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG magic bytes

        let metadata = AnimationMetadata(
            id: projectID, title: "Legacy Raster Project", fps: 12,
            canvasWidth: 800, canvasHeight: 600,
            frameCount: 3, layerCount: 1,
            createdAt: Date(timeIntervalSince1970: 900000),
            modifiedAt: Date(timeIntervalSince1970: 900001)
        )

        // Simulate legacy project with raster frames only
        let frames = [
            StoredAnimationFrame(imageData: rasterPNG),
            StoredAnimationFrame(imageData: rasterPNG),
            StoredAnimationFrame(imageData: rasterPNG),
        ]
        let project = AnimationProject(id: projectID, metadata: metadata, frames: frames, audioTracks: [])

        // Encode (simulate save to JSON)
        let encoder = JSONEncoder()
        let savedData = try encoder.encode(project)

        // Decode (simulate load from JSON)
        let decoder = JSONDecoder()
        let loaded = try decoder.decode(AnimationProject.self, from: savedData)

        // Verify raster data is preserved
        XCTAssertEqual(loaded.frames.count, 3, "All 3 raster frames must survive round trip")
        for (i, frame) in loaded.frames.enumerated() {
            XCTAssertEqual(frame.imageData, rasterPNG, "Raster data for frame \(i) must be preserved intact")
        }

        // Verify metadata is preserved
        XCTAssertEqual(loaded.metadata.title, "Legacy Raster Project")
        XCTAssertEqual(loaded.metadata.frameCount, 3)
    }

    // MARK: - DrawingTool exhaustive round trip

    func testDrawingToolAllCasesRoundTrip() throws {
        for tool in DrawingTool.allCases {
            let element = DrawnElement(
                id: "test", tool: tool,
                points: [StrokePoint(x: 0, y: 0)],
                color: "#000000", width: 1.0, opacity: 1.0
            )
            let data = try JSONEncoder().encode(element)
            let decoded = try JSONDecoder().decode(DrawnElement.self, from: data)
            XCTAssertEqual(decoded.tool, tool, "Tool \(tool.rawValue) should round trip")
        }
    }
}
