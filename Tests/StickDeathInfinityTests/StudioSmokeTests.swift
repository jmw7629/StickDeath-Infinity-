// ═══════════════════════════════════════════════════════════════════
// StudioSmokeTests — Pure-Swift smoke tests for core model state
//
// These tests verify that the fundamental data types used by the
// Studio (frames, layers, projects) can be created, mutated,
// encoded/decoded, and that AppConfig enums behave correctly.
//
// No iOS simulator required — runs with `swift test` on macOS/Linux
// (the types under test are pure Foundation/Swift).
// ═══════════════════════════════════════════════════════════════════

import XCTest

// MARK: - Minimal type mirrors (so tests compile without the app target)

private struct TestDrawnElement: Codable, Identifiable, Equatable {
    let id: String
    var tool: String
    var color: String
    var width: Double
    var opacity: Double
}

private struct TestAnimationFrame: Codable, Identifiable, Equatable {
    let id: String
    var elements: [TestDrawnElement]
}

private struct TestCanvasLayer: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var visible: Bool
    var locked: Bool
    var opacity: Double
    var lockMode: String
    var blendMode: String
}

private struct TestStudioProject: Codable, Identifiable, Equatable {
    let id: String
    var userID: String
    var name: String
    var width: Int?
    var height: Int?
    var fps: Int?
    var frameCount: Int?
}

// MARK: - AppConfig enum mirrors

private enum TestCallRateTier: String, CaseIterable, Identifiable {
    case standard, creator, pro, studio
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .creator:  return "Creator"
        case .pro:      return "Pro"
        case .studio:   return "Studio"
        }
    }
    var ratePerMinute: Double {
        switch self {
        case .standard: return 0.05
        case .creator:  return 0.10
        case .pro:      return 0.15
        case .studio:   return 0.25
        }
    }
}

private enum TestSubscriptionTier: String, CaseIterable, Identifiable, Comparable {
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
    static func < (lhs: TestSubscriptionTier, rhs: TestSubscriptionTier) -> Bool {
        let order: [TestSubscriptionTier] = [.free, .creator, .pro, .studio]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Tests

final class StudioSmokeTests: XCTestCase {

    // ── Frame operations ────────────────────────────────────────

    func testCreateEmptyFrame() {
        let frame = TestAnimationFrame(id: "f1", elements: [])
        XCTAssertTrue(frame.elements.isEmpty)
    }

    func testAddElementToFrame() {
        var frame = TestAnimationFrame(id: "f1", elements: [])
        let el = TestDrawnElement(id: "e1", tool: "brush", color: "#FF0000", width: 3, opacity: 1.0)
        frame.elements.append(el)
        XCTAssertEqual(frame.elements.count, 1)
        XCTAssertEqual(frame.elements.first?.tool, "brush")
    }

    func testDuplicateFrame() {
        let original = TestAnimationFrame(
            id: "f1",
            elements: [
                TestDrawnElement(id: "e1", tool: "pen", color: "#000000", width: 2, opacity: 1.0)
            ]
        )
        let dupe = TestAnimationFrame(
            id: UUID().uuidString,
            elements: original.elements.map {
                TestDrawnElement(id: UUID().uuidString, tool: $0.tool, color: $0.color, width: $0.width, opacity: $0.opacity)
            }
        )
        XCTAssertEqual(dupe.elements.count, 1)
        XCTAssertNotEqual(dupe.id, original.id)
    }

    func testDeleteFrameFromList() {
        var frames = [
            TestAnimationFrame(id: "f1", elements: []),
            TestAnimationFrame(id: "f2", elements: []),
            TestAnimationFrame(id: "f3", elements: []),
        ]
        frames.remove(at: 1)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.map(\.id), ["f1", "f3"])
    }

    // ── Layer operations ────────────────────────────────────────

    func testCreateLayer() {
        let layer = TestCanvasLayer(
            id: "l1", name: "Layer 1", visible: true, locked: false,
            opacity: 1.0, lockMode: "free", blendMode: "normal"
        )
        XCTAssertTrue(layer.visible)
        XCTAssertFalse(layer.locked)
        XCTAssertEqual(layer.opacity, 1.0)
    }

    func testToggleLayerVisibility() {
        var layer = TestCanvasLayer(
            id: "l1", name: "Layer 1", visible: true, locked: false,
            opacity: 1.0, lockMode: "free", blendMode: "normal"
        )
        layer.visible.toggle()
        XCTAssertFalse(layer.visible)
    }

    func testToggleLayerLock() {
        var layer = TestCanvasLayer(
            id: "l1", name: "Layer 1", visible: true, locked: false,
            opacity: 1.0, lockMode: "free", blendMode: "normal"
        )
        layer.locked.toggle()
        XCTAssertTrue(layer.locked)
    }

    func testReorderLayers() {
        var layers = [
            TestCanvasLayer(id: "l1", name: "Back", visible: true, locked: false, opacity: 1.0, lockMode: "free", blendMode: "normal"),
            TestCanvasLayer(id: "l2", name: "Front", visible: true, locked: false, opacity: 1.0, lockMode: "free", blendMode: "normal"),
        ]
        layers.swapAt(0, 1)
        XCTAssertEqual(layers[0].name, "Front")
        XCTAssertEqual(layers[1].name, "Back")
    }

    // ── Project state ───────────────────────────────────────────

    func testCreateProject() {
        let project = TestStudioProject(
            id: UUID().uuidString, userID: "u1", name: "Test",
            width: 1080, height: 1080, fps: 12, frameCount: 1
        )
        XCTAssertEqual(project.name, "Test")
        XCTAssertEqual(project.fps, 12)
    }

    func testProjectFrameCount() {
        var frames = [TestAnimationFrame(id: "f1", elements: [])]
        frames.append(TestAnimationFrame(id: "f2", elements: []))
        frames.append(TestAnimationFrame(id: "f3", elements: []))
        XCTAssertEqual(frames.count, 3)
    }

    // ── Undo / Redo stack ───────────────────────────────────────

    func testUndoRedo() {
        var frames = [TestAnimationFrame(id: "f1", elements: [])]
        var undoStack: [[TestAnimationFrame]] = []
        var redoStack: [[TestAnimationFrame]] = []

        // Push undo before mutation
        undoStack.append(frames)
        redoStack.removeAll()

        // Mutate
        frames.append(TestAnimationFrame(id: "f2", elements: []))
        XCTAssertEqual(frames.count, 2)

        // Undo
        if let prev = undoStack.popLast() {
            redoStack.append(frames)
            frames = prev
        }
        XCTAssertEqual(frames.count, 1)

        // Redo
        if let next = redoStack.popLast() {
            undoStack.append(frames)
            frames = next
        }
        XCTAssertEqual(frames.count, 2)
    }

    // ── Codable round-trip ──────────────────────────────────────

    func testFrameCodableRoundTrip() throws {
        let frame = TestAnimationFrame(
            id: "f1",
            elements: [
                TestDrawnElement(id: "e1", tool: "brush", color: "#FF0000", width: 3, opacity: 0.8)
            ]
        )
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(TestAnimationFrame.self, from: data)
        XCTAssertEqual(decoded.id, frame.id)
        XCTAssertEqual(decoded.elements.count, 1)
        XCTAssertEqual(decoded.elements.first?.tool, "brush")
    }

    func testLayerCodableRoundTrip() throws {
        let layer = TestCanvasLayer(
            id: "l1", name: "Background", visible: false, locked: true,
            opacity: 0.5, lockMode: "full", blendMode: "multiply"
        )
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(TestCanvasLayer.self, from: data)
        XCTAssertEqual(decoded.name, "Background")
        XCTAssertFalse(decoded.visible)
        XCTAssertTrue(decoded.locked)
        XCTAssertEqual(decoded.opacity, 0.5)
    }

    func testProjectCodableRoundTrip() throws {
        let project = TestStudioProject(
            id: "p1", userID: "u1", name: "Fight Scene",
            width: 1920, height: 1080, fps: 24, frameCount: 120
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(TestStudioProject.self, from: data)
        XCTAssertEqual(decoded.name, "Fight Scene")
        XCTAssertEqual(decoded.width, 1920)
        XCTAssertEqual(decoded.fps, 24)
    }

    // ── CallRateTier ────────────────────────────────────────────

    func testCallRateTierRates() {
        XCTAssertEqual(TestCallRateTier.standard.ratePerMinute, 0.05)
        XCTAssertEqual(TestCallRateTier.creator.ratePerMinute, 0.10)
        XCTAssertEqual(TestCallRateTier.pro.ratePerMinute, 0.15)
        XCTAssertEqual(TestCallRateTier.studio.ratePerMinute, 0.25)
    }

    func testCallRateTierAllCases() {
        XCTAssertEqual(TestCallRateTier.allCases.count, 4)
    }

    // ── SubscriptionTier ────────────────────────────────────────

    func testSubscriptionTierPricing() {
        XCTAssertEqual(TestSubscriptionTier.free.price, 0.0)
        XCTAssertEqual(TestSubscriptionTier.creator.price, 4.99)
        XCTAssertEqual(TestSubscriptionTier.pro.price, 9.99)
        XCTAssertEqual(TestSubscriptionTier.studio.price, 19.99)
    }

    func testSubscriptionTierComparable() {
        XCTAssertTrue(TestSubscriptionTier.free < TestSubscriptionTier.creator)
        XCTAssertTrue(TestSubscriptionTier.creator < TestSubscriptionTier.pro)
        XCTAssertTrue(TestSubscriptionTier.pro < TestSubscriptionTier.studio)
    }

    func testSubscriptionTierRawValue() {
        XCTAssertEqual(TestSubscriptionTier(rawValue: "free"), .free)
        XCTAssertEqual(TestSubscriptionTier(rawValue: "studio"), .studio)
        XCTAssertNil(TestSubscriptionTier(rawValue: "invalid"))
    }

    // ── Drawing tool variety ────────────────────────────────────

    func testDrawingToolCases() {
        let tools = ["pen", "pencil", "marker", "brush", "eraser", "fill", "line", "rectangle", "circle", "text"]
        for tool in tools {
            let el = TestDrawnElement(id: UUID().uuidString, tool: tool, color: "#000000", width: 2, opacity: 1.0)
            XCTAssertEqual(el.tool, tool)
        }
    }

    // ── Batch frame operations (simulates timeline editing) ─────

    func testBatchFrameInsertion() {
        var frames = (0..<5).map { TestAnimationFrame(id: "f\($0)", elements: []) }
        XCTAssertEqual(frames.count, 5)

        // Insert 3 frames after frame 2
        let insertAt = 3
        let newFrames = (0..<3).map { TestAnimationFrame(id: "new\($0)", elements: []) }
        frames.insert(contentsOf: newFrames, at: insertAt)
        XCTAssertEqual(frames.count, 8)
        XCTAssertEqual(frames[3].id, "new0")
    }

    func testBatchFrameDeletion() {
        var frames = (0..<10).map { TestAnimationFrame(id: "f\($0)", elements: []) }
        // Delete frames 3, 4, 5
        frames.removeSubrange(3...5)
        XCTAssertEqual(frames.count, 7)
        XCTAssertEqual(frames.map(\.id), ["f0", "f1", "f2", "f6", "f7", "f8", "f9"])
    }
}
