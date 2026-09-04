// ═══════════════════════════════════════════════════════════════════
// ProductionCoreTests — Tests the production Codable/state logic
//
// These tests import the EXACT ProductionCore module compiled by the
// application. No mirror/test-only model definitions exist here.
// Tests fail when production Codable logic breaks.
//
// Run on Linux: swift test
// ═══════════════════════════════════════════════════════════════════

import Testing
@testable import ProductionCore

// MARK: - DrawnElement Codable Round-Trip

@Suite("DrawnElement Codable")
struct DrawnElementCodableTests {

    @Test("Encode and decode DrawnElement preserves all fields")
    func roundTripDrawnElement() throws {
        let element = SDDrawnElement(
            id: "elem-001",
            tool: .brush,
            points: [
                SDStrokePoint(x: 10.5, y: 20.3, pressure: 0.8, timestamp: 1.0),
                SDStrokePoint(x: 30.7, y: 40.1, pressure: 0.6, timestamp: 1.5)
            ],
            color: "#FF0000",
            width: 5.0,
            opacity: 0.9,
            fillColor: "#00FF00",
            layerID: "layer-1"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(element)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SDDrawnElement.self, from: data)

        #expect(decoded.id == "elem-001")
        #expect(decoded.tool == .brush)
        #expect(decoded.points.count == 2)
        #expect(decoded.points[0].x == 10.5)
        #expect(decoded.points[0].pressure == 0.8)
        #expect(decoded.color == "#FF0000")
        #expect(decoded.width == 5.0)
        #expect(decoded.opacity == 0.9)
        #expect(decoded.fillColor == "#00FF00")
        #expect(decoded.layerID == "layer-1")
    }

    @Test("DrawnElement with nil optional fields round-trips correctly")
    func roundTripDrawnElementNilOptionals() throws {
        let element = SDDrawnElement(
            id: "elem-002",
            tool: .pen,
            points: [SDStrokePoint(x: 0, y: 0)],
            color: "#000000",
            width: 2.0,
            opacity: 1.0,
            fillColor: nil,
            layerID: nil
        )

        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(SDDrawnElement.self, from: data)

        #expect(decoded.fillColor == nil)
        #expect(decoded.layerID == nil)
    }
}

// MARK: - AnimationFrame Codable Round-Trip

@Suite("AnimationFrame Codable")
struct AnimationFrameCodableTests {

    @Test("Encode and decode AnimationFrame with vector elements")
    func roundTripAnimationFrame() throws {
        let frame = SDAnimationFrame(
            id: "frame-001",
            elements: [
                SDDrawnElement(
                    id: "e1",
                    tool: .line,
                    points: [
                        SDStrokePoint(x: 0, y: 0),
                        SDStrokePoint(x: 100, y: 100)
                    ],
                    color: "#FFFFFF",
                    width: 3.0,
                    opacity: 1.0
                )
            ]
        )

        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(SDAnimationFrame.self, from: data)

        #expect(decoded.id == "frame-001")
        #expect(decoded.elements.count == 1)
        #expect(decoded.elements[0].tool == .line)
        #expect(decoded.elements[0].points.count == 2)
        #expect(decoded.legacyRasterFramePath == nil)
    }

    @Test("AnimationFrame with legacy raster path preserves it")
    func roundTripAnimationFrameWithLegacyRaster() throws {
        let frame = SDAnimationFrame(
            id: "frame-legacy-001",
            elements: [],
            legacyRasterFramePath: "projects/my-project/frames/frame_001.png"
        )

        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(SDAnimationFrame.self, from: data)

        #expect(decoded.legacyRasterFramePath == "projects/my-project/frames/frame_001.png")
        #expect(decoded.elements.isEmpty)
    }
}

// MARK: - CanvasLayer Codable Round-Trip

@Suite("CanvasLayer Codable")
struct CanvasLayerCodableTests {

    @Test("Encode and decode CanvasLayer preserves all fields")
    func roundTripCanvasLayer() throws {
        let layer = SDCanvasLayer(
            id: "layer-001",
            name: "Background",
            visible: true,
            locked: false,
            opacity: 0.8,
            lockMode: "position",
            blendMode: "multiply",
            glowEnabled: true,
            glowColor: "#FF00FF",
            colorLabel: "#0000FF"
        )

        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(SDCanvasLayer.self, from: data)

        #expect(decoded.id == "layer-001")
        #expect(decoded.name == "Background")
        #expect(decoded.visible == true)
        #expect(decoded.locked == false)
        #expect(decoded.opacity == 0.8)
        #expect(decoded.lockMode == "position")
        #expect(decoded.blendMode == "multiply")
        #expect(decoded.glowEnabled == true)
        #expect(decoded.glowColor == "#FF00FF")
        #expect(decoded.colorLabel == "#0000FF")
    }
}

// MARK: - StudioProject Codable Round-Trip

@Suite("StudioProject Codable")
struct StudioProjectCodableTests {

    @Test("Encode and decode StudioProject with all fields")
    func roundTripStudioProject() throws {
        let project = SDStudioProject(
            id: "proj-001",
            userID: "user-abc",
            name: "My Animation",
            width: 1920,
            height: 1080,
            fps: 24,
            frameCount: 120,
            thumbnailURL: "https://example.com/thumb.png",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-02T00:00:00Z",
            legacyMigrationSource: nil
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(SDStudioProject.self, from: data)

        #expect(decoded.id == "proj-001")
        #expect(decoded.userID == "user-abc")
        #expect(decoded.name == "My Animation")
        #expect(decoded.width == 1920)
        #expect(decoded.height == 1080)
        #expect(decoded.fps == 24)
        #expect(decoded.frameCount == 120)
        #expect(decoded.thumbnailURL == "https://example.com/thumb.png")
        #expect(decoded.legacyMigrationSource == nil)
    }

    @Test("StudioProject with legacy migration source preserves it")
    func roundTripStudioProjectWithLegacyMigration() throws {
        let project = SDStudioProject(
            id: "proj-legacy-001",
            userID: "user-abc",
            name: "Imported Legacy Project",
            width: 800,
            height: 600,
            fps: 12,
            legacyMigrationSource: "frame_001.png:frame_002.png:frame_003.png"
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(SDStudioProject.self, from: data)

        #expect(decoded.legacyMigrationSource == "frame_001.png:frame_002.png:frame_003.png")
        #expect(decoded.name == "Imported Legacy Project")
    }
}

// MARK: - Production Frame Encode/Decode Round-Trip (Full Pipeline)

@Suite("Full Pipeline")
struct FullPipelineTests {

    @Test("Full project frame encode/decode preserves DrawnElement data")
    func fullProjectRoundTrip() throws {
        let project = SDStudioProject(
            id: "proj-full-001",
            userID: "user-123",
            name: "Test Animation",
            width: 1920,
            height: 1080,
            fps: 12
        )

        let frame1 = SDAnimationFrame(
            id: "frame-1",
            elements: [
                SDDrawnElement(
                    id: "e1",
                    tool: .pen,
                    points: [
                        SDStrokePoint(x: 100, y: 200, pressure: 0.5, timestamp: 0.0),
                        SDStrokePoint(x: 150, y: 250, pressure: 0.7, timestamp: 0.1)
                    ],
                    color: "#FF0000",
                    width: 3.0,
                    opacity: 1.0
                ),
                SDDrawnElement(
                    id: "e2",
                    tool: .fill,
                    points: [SDStrokePoint(x: 125, y: 225)],
                    color: "#00FF00",
                    width: 1.0,
                    opacity: 0.5,
                    fillColor: "#0000FF",
                    layerID: "layer-2"
                )
            ]
        )

        let frame2 = SDAnimationFrame(
            id: "frame-2",
            elements: [
                SDDrawnElement(
                    id: "e3",
                    tool: .circle,
                    points: [
                        SDStrokePoint(x: 300, y: 400),
                        SDStrokePoint(x: 350, y: 450)
                    ],
                    color: "#FFFF00",
                    width: 2.0,
                    opacity: 0.8
                )
            ],
            legacyRasterFramePath: "legacy/frame_002.png"
        )

        let frames = [frame1, frame2]

        // Simulate the production save path: encode frames to JSON
        let encoder = JSONEncoder()
        let frameData = try encoder.encode(frames)
        let frameJSON = String(data: frameData, encoding: .utf8) ?? "[]"

        // Simulate the production load path: decode frames from JSON
        let frameJSONData = frameJSON.data(using: .utf8)!
        let decodedFrames = try JSONDecoder().decode([SDAnimationFrame].self, from: frameJSONData)

        // Verify full round-trip
        #expect(decodedFrames.count == 2)

        // Frame 1
        #expect(decodedFrames[0].id == "frame-1")
        #expect(decodedFrames[0].elements.count == 2)
        #expect(decodedFrames[0].elements[0].tool == .pen)
        #expect(decodedFrames[0].elements[0].points[0].x == 100)
        #expect(decodedFrames[0].elements[0].points[0].pressure == 0.5)
        #expect(decodedFrames[0].elements[1].fillColor == "#0000FF")
        #expect(decodedFrames[0].elements[1].layerID == "layer-2")
        #expect(decodedFrames[0].legacyRasterFramePath == nil)

        // Frame 2 — legacy raster preserved
        #expect(decodedFrames[1].id == "frame-2")
        #expect(decodedFrames[1].elements.count == 1)
        #expect(decodedFrames[1].elements[0].tool == .circle)
        #expect(decodedFrames[1].legacyRasterFramePath == "legacy/frame_002.png")
    }

    @Test("Legacy raster project persistence preserves raster references")
    func legacyRasterPersistence() throws {
        // Simulate a project migrated from raster frames
        let project = SDStudioProject(
            id: "proj-migrated-001",
            userID: "user-456",
            name: "Migrated Legacy Project",
            width: 640,
            height: 480,
            fps: 12,
            frameCount: 3,
            legacyMigrationSource: "frame_001.png:frame_002.png:frame_003.png"
        )

        // Frames with raster paths but empty vector elements (migration in progress)
        let frames = [
            SDAnimationFrame(id: "f1", elements: [], legacyRasterFramePath: "frame_001.png"),
            SDAnimationFrame(id: "f2", elements: [], legacyRasterFramePath: "frame_002.png"),
            SDAnimationFrame(id: "f3", elements: [], legacyRasterFramePath: "frame_003.png")
        ]

        // Encode project + frames as the production save path would
        let projectData = try JSONEncoder().encode(project)
        let framesData = try JSONEncoder().encode(frames)

        // Decode — verify raster references are preserved
        let decodedProject = try JSONDecoder().decode(SDStudioProject.self, from: projectData)
        let decodedFrames = try JSONDecoder().decode([SDAnimationFrame].self, from: framesData)

        #expect(decodedProject.legacyMigrationSource == "frame_001.png:frame_002.png:frame_003.png")
        #expect(decodedFrames.count == 3)
        #expect(decodedFrames[0].legacyRasterFramePath == "frame_001.png")
        #expect(decodedFrames[1].legacyRasterFramePath == "frame_002.png")
        #expect(decodedFrames[2].legacyRasterFramePath == "frame_003.png")

        // Raster frames are NOT silently converted to empty vector frames
        // — they retain their raster path reference for later display/export
        for frame in decodedFrames {
            #expect(frame.elements.isEmpty, "Legacy raster frames should have empty elements until explicitly converted")
        }
    }
}

// MARK: - AppConfig (no secrets, no superuserEmails)

@Suite("AppConfig Safety")
struct AppConfigSafetyTests {

    @Test("AppConfig contains no secret fields")
    func noSecretsInAppConfig() {
        // Verify public config values are placeholder/safe
        #expect(SDAppConfig.supabaseURL == "https://placeholder.supabase.co")
        #expect(SDAppConfig.supabaseAnonKey == "placeholder-anon-key")
        #expect(SDAppConfig.liveKitWSURL == "wss://placeholder.livekit.cloud")

        // Verify secret fields are empty (not shipped in client)
        #expect(SDAppConfig.openAIAPIKey == "")
        #expect(SDAppConfig.geminiAPIKey == "")
    }

    @Test("SubscriptionTier cases are exhaustive")
    func subscriptionTierCases() {
        let allTiers = SDAppConfig.SubscriptionTier.allCases
        #expect(allTiers.count == 4)
        #expect(allTiers.contains(.free))
        #expect(allTiers.contains(.creator))
        #expect(allTiers.contains(.pro))
        #expect(allTiers.contains(.studio))
    }

    @Test("CallRateTier ratePerMinute values are correct")
    func callRateTierRates() {
        #expect(SDAppConfig.CallRateTier.standard.ratePerMinute == 0.05)
        #expect(SDAppConfig.CallRateTier.creator.ratePerMinute == 0.10)
        #expect(SDAppConfig.CallRateTier.pro.ratePerMinute == 0.15)
        #expect(SDAppConfig.CallRateTier.studio.ratePerMinute == 0.25)
    }
}
