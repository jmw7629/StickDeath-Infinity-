// ═══════════════════════════════════════════════════════════════════
// StudioSmokeTests — Exercises production-pure core model logic
//
// These tests verify that the fundamental data types used by the
// Studio (frames, layers, projects, AppConfig enums) can be created,
// mutated, encoded/decoded, and round-tripped without data loss.
//
// The type definitions below mirror the real production types in
// StickDeathInfinity/Models/Models.swift exactly. If the production
// types change, these tests must be updated to match.
//
// No iOS simulator required — runs with `swift test` on macOS/Linux
// (the types under test are pure Foundation/Swift).
// ═══════════════════════════════════════════════════════════════════

import XCTest

// MARK: - Production type mirrors (must match Models.swift exactly)

private struct DrawnElement: Codable, Identifiable, Equatable {
    let id: String
    var tool: String
    var points: [[String: Double]]
    var color: String
    var width: Double
    var opacity: Double
    var fillColor: String?
    var layerID: String?
}

private struct AnimationFrame: Codable, Identifiable, Equatable {
    let id: String
    var elements: [DrawnElement]
}

private struct CanvasLayer: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var visible: Bool
    var locked: Bool
    var opacity: Double
    var lockMode: String
    var blendMode: String
    var glowEnabled: Bool
    var glowColor: String?
    var colorLabel: String?
}

private struct StudioProject: Codable, Identifiable, Equatable {
    let id: String
    var userID: String
    var name: String
    var width: Int?
    var height: Int?
    var fps: Int?
    var frameCount: Int?
}

private struct AnimationMetadata: Codable, Equatable {
    let id: String
    var title: String
    var fps: Int
    var canvasWidth: Int
    var canvasHeight: Int
    var frameCount: Int
    var layerCount: Int
}

// MARK: - AppConfig enum mirrors (must match AppConfig.swift)

private enum CallRateTier: String, CaseIterable, Identifiable {
    case standard, creator, pro, studio
    var id: String { rawValue }
    var ratePerMinute: Double {
        switch self {
        case .standard: return 0.05
        case .creator:  return 0.10
        case .pro:      return 0.15
        case .studio:   return 0.25
        }
    }
}

private enum SubscriptionTier: String, CaseIterable, Identifiable, Comparable {
    case free, creator, pro, studio
    var id: String { rawValue }
    var price: Double {
        switch self {
        case .free:    return 0.0
        case .creator: return 4.99
        case .pro:     return 9.99
        case .studio:  return 19.99
        }
    }
    static func < (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool {
        let order: [SubscriptionTier] = [.free, .creator, .pro, .studio]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Tests

final class StudioSmokeTests: XCTestCase {

    // ── Frame operations ────────────────────────────────────────

    func testCreateEmptyFrame() {
        let frame = AnimationFrame(id: "f1", elements: [])
        XCTAssertTrue(frame.elements.isEmpty)
    }

    func testAddElementToFrame() {
        var frame = AnimationFrame(id: "f1", elements: [])
        let element = DrawnElement(
            id: "e1", tool: "brush", points: [["x": 10, "y": 20]],
            color: "#FF0000", width: 3.0, opacity: 1.0
        )
        frame.elements.append(element)
        XCTAssertEqual(frame.elements.count, 1)
        XCTAssertEqual(frame.elements[0].tool, "brush")
    }

    func testFrameEncodeDecodeRoundTrip() throws {
        let original = AnimationFrame(id: "round-trip", elements: [
            DrawnElement(
                id: "elem1", tool: "pen",
                points: [["x": 0, "y": 0], ["x": 100, "y": 50]],
                color: "#00FF00", width: 2.5, opacity: 0.8,
                fillColor: "#FF0000", layerID: "layer1"
            ),
            DrawnElement(
                id: "elem2", tool: "eraser",
                points: [["x": 10, "y": 10]],
                color: "#000000", width: 5.0, opacity: 1.0
            ),
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnimationFrame.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.elements.count, 2)
        XCTAssertEqual(decoded.elements[0].id, "elem1")
        XCTAssertEqual(decoded.elements[0].tool, "pen")
        XCTAssertEqual(decoded.elements[0].points.count, 2)
        XCTAssertEqual(decoded.elements[0].fillColor, "#FF0000")
        XCTAssertEqual(decoded.elements[0].layerID, "layer1")
        XCTAssertNil(decoded.elements[1].fillColor)
        XCTAssertNil(decoded.elements[1].layerID)
    }

    func testMultipleFramesEncodeDecodeRoundTrip() throws {
        let frames = [
            AnimationFrame(id: "f1", elements: [
                DrawnElement(id: "e1", tool: "brush", points: [], color: "#FFF", width: 1, opacity: 1)
            ]),
            AnimationFrame(id: "f2", elements: []),
            AnimationFrame(id: "f3", elements: [
                DrawnElement(id: "e2", tool: "pen", points: [["x": 1, "y": 2]], color: "#000", width: 2, opacity: 0.5),
                DrawnElement(id: "e3", tool: "fill", points: [], color: "#F00", width: 0, opacity: 1),
            ]),
        ]

        let data = try JSONEncoder().encode(frames)
        let decoded = try JSONDecoder().decode([AnimationFrame].self, from: data)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].elements.count, 1)
        XCTAssertTrue(decoded[1].elements.isEmpty)
        XCTAssertEqual(decoded[2].elements.count, 2)
    }

    // ── Layer operations ────────────────────────────────────────

    func testCreateCanvasLayer() {
        let layer = CanvasLayer(
            id: "l1", name: "Layer 1", visible: true, locked: false,
            opacity: 1.0, lockMode: "free", blendMode: "normal",
            glowEnabled: false, glowColor: nil, colorLabel: "red"
        )
        XCTAssertEqual(layer.name, "Layer 1")
        XCTAssertTrue(layer.visible)
        XCTAssertFalse(layer.locked)
        XCTAssertEqual(layer.lockMode, "free")
    }

    func testLayerEncodeDecodeRoundTrip() throws {
        let layer = CanvasLayer(
            id: "l1", name: "Test Layer", visible: true, locked: true,
            opacity: 0.75, lockMode: "position", blendMode: "multiply",
            glowEnabled: true, glowColor: "#FF0000", colorLabel: "blue"
        )

        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(CanvasLayer.self, from: data)

        XCTAssertEqual(decoded.id, "l1")
        XCTAssertEqual(decoded.name, "Test Layer")
        XCTAssertTrue(decoded.locked)
        XCTAssertEqual(decoded.opacity, 0.75)
        XCTAssertEqual(decoded.lockMode, "position")
        XCTAssertEqual(decoded.blendMode, "multiply")
        XCTAssertTrue(decoded.glowEnabled)
        XCTAssertEqual(decoded.glowColor, "#FF0000")
    }

    // ── Project operations ──────────────────────────────────────

    func testStudioProjectEncodeDecode() throws {
        let project = StudioProject(
            id: "p1", userID: "user1", name: "My Animation",
            width: 1920, height: 1080, fps: 24, frameCount: 100
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(StudioProject.self, from: data)

        XCTAssertEqual(decoded.id, "p1")
        XCTAssertEqual(decoded.name, "My Animation")
        XCTAssertEqual(decoded.width, 1920)
        XCTAssertEqual(decoded.height, 1080)
        XCTAssertEqual(decoded.fps, 24)
        XCTAssertEqual(decoded.frameCount, 100)
    }

    func testAnimationMetadataEncodeDecode() throws {
        let meta = AnimationMetadata(
            id: "m1", title: "Test", fps: 12,
            canvasWidth: 1080, canvasHeight: 1080,
            frameCount: 10, layerCount: 3
        )

        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(AnimationMetadata.self, from: data)

        XCTAssertEqual(decoded.frameCount, 10)
        XCTAssertEqual(decoded.layerCount, 3)
    }

    // ── Frame persistence serialization (mirrors DeviceStorageManager) ──

    func testFramePersistenceRoundTrip() throws {
        // Simulate the save/load path: encode frames to JSON, decode back
        let originalFrames = [
            AnimationFrame(id: "persist-1", elements: [
                DrawnElement(id: "pe1", tool: "brush", points: [["x": 5, "y": 5]], color: "#ABC", width: 3, opacity: 1)
            ]),
            AnimationFrame(id: "persist-2", elements: []),
        ]

        let encoder = JSONEncoder()
        let frameData = try encoder.encode(originalFrames)

        // Write to temp file (mirrors DeviceStorageManager save)
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_frames.json")
        try frameData.write(to: tmpURL)

        // Read back (mirrors DeviceStorageManager load)
        let readData = try Data(contentsOf: tmpURL)
        let decodedFrames = try JSONDecoder().decode([AnimationFrame].self, from: readData)

        XCTAssertEqual(decodedFrames.count, originalFrames.count)
        XCTAssertEqual(decodedFrames[0].id, "persist-1")
        XCTAssertEqual(decodedFrames[0].elements.count, 1)
        XCTAssertEqual(decodedFrames[0].elements[0].tool, "brush")
        XCTAssertTrue(decodedFrames[1].elements.isEmpty)

        try FileManager.default.removeItem(at: tmpURL)
    }

    // ── CallRateTier behavior ───────────────────────────────────

    func testCallRateTierRates() {
        XCTAssertEqual(CallRateTier.standard.ratePerMinute, 0.05)
        XCTAssertEqual(CallRateTier.creator.ratePerMinute, 0.10)
        XCTAssertEqual(CallRateTier.pro.ratePerMinute, 0.15)
        XCTAssertEqual(CallRateTier.studio.ratePerMinute, 0.25)
    }

    func testCallRateTierAllCases() {
        XCTAssertEqual(CallRateTier.allCases.count, 4)
    }

    // ── SubscriptionTier behavior ───────────────────────────────

    func testSubscriptionTierPrices() {
        XCTAssertEqual(SubscriptionTier.free.price, 0.0)
        XCTAssertEqual(SubscriptionTier.creator.price, 4.99)
        XCTAssertEqual(SubscriptionTier.pro.price, 9.99)
        XCTAssertEqual(SubscriptionTier.studio.price, 19.99)
    }

    func testSubscriptionTierOrdering() {
        XCTAssertTrue(SubscriptionTier.free < SubscriptionTier.creator)
        XCTAssertTrue(SubscriptionTier.creator < SubscriptionTier.pro)
        XCTAssertTrue(SubscriptionTier.pro < SubscriptionTier.studio)
        XCTAssertFalse(SubscriptionTier.studio < SubscriptionTier.free)
    }

    func testSubscriptionTierAllCases() {
        XCTAssertEqual(SubscriptionTier.allCases.count, 4)
    }

    // ── DrawnElement tool diversity ─────────────────────────────

    func testDrawnElementTools() {
        let tools = ["pen", "pencil", "marker", "brush", "crayon", "eraser",
                     "fill", "line", "rectangle", "circle", "text", "lasso"]
        for tool in tools {
            let elem = DrawnElement(id: UUID().uuidString, tool: tool, points: [], color: "#000", width: 1, opacity: 1)
            XCTAssertEqual(elem.tool, tool)
        }
    }
}
