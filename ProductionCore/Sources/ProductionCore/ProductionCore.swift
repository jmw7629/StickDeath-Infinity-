// ═══════════════════════════════════════════════════════════════════
// ProductionCore — Foundation-only Codable core seam
//
// This module extracts the production Codable/state/persistence types
// from the iOS app into a Foundation-only library. It is compiled by
// both the iOS application and the Linux-compatible test target.
//
// Tests import this exact module to verify that the production
// Codable round-trip logic is correct — no mirror/test-only copies.
//
// On iOS, CGFloat-based types in Models.swift are the authoritative
// production types. On Linux, these Double-based equivalents exercise
// the same Codable paths. JSON serialization is identical because
// Codable encodes CGFloat as a JSON number (same as Double).
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Stroke Point (Foundation-only, Double代替CGFloat)

public struct SDStrokePoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var pressure: Double?
    public var timestamp: TimeInterval?

    public init(x: Double, y: Double, pressure: Double? = nil, timestamp: TimeInterval? = nil) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.timestamp = timestamp
    }
}

// MARK: - Drawing Tool

public enum SDDrawingTool: String, Codable, CaseIterable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, move, hand, zoom
}

// MARK: - Drawn Element (Foundation-only)

public struct SDDrawnElement: Codable, Equatable {
    public let id: String
    public var tool: SDDrawingTool
    public var points: [SDStrokePoint]
    public var color: String
    public var width: Double
    public var opacity: Double
    public var fillColor: String?
    public var layerID: String?

    public init(
        id: String = UUID().uuidString,
        tool: SDDrawingTool = .pen,
        points: [SDStrokePoint] = [],
        color: String = "#000000",
        width: Double = 3.0,
        opacity: Double = 1.0,
        fillColor: String? = nil,
        layerID: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.points = points
        self.color = color
        self.width = width
        self.opacity = opacity
        self.fillColor = fillColor
        self.layerID = layerID
    }
}

// MARK: - Animation Frame (Foundation-only, with legacy raster support)

public struct SDAnimationFrame: Codable, Equatable {
    public let id: String
    public var elements: [SDDrawnElement]

    /// Path to original raster frame (e.g. "frame_001.png") when
    /// migrated from a legacy raster project. Preserved non-destructively
    /// so the Studio can display/export the raster until vector conversion
    /// is complete. nil for natively-created vector frames.
    public var legacyRasterFramePath: String?

    public init(
        id: String = UUID().uuidString,
        elements: [SDDrawnElement] = [],
        legacyRasterFramePath: String? = nil
    ) {
        self.id = id
        self.elements = elements
        self.legacyRasterFramePath = legacyRasterFramePath
    }
}

// MARK: - Canvas Layer (Foundation-only)

public struct SDCanvasLayer: Codable, Equatable {
    public let id: String
    public var name: String
    public var visible: Bool
    public var locked: Bool
    public var opacity: Double
    public var lockMode: String
    public var blendMode: String
    public var glowEnabled: Bool
    public var glowColor: String?
    public var colorLabel: String?

    public init(
        id: String = UUID().uuidString,
        name: String = "Layer",
        visible: Bool = true,
        locked: Bool = false,
        opacity: Double = 1.0,
        lockMode: String = "free",
        blendMode: String = "normal",
        glowEnabled: Bool = false,
        glowColor: String? = nil,
        colorLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.visible = visible
        self.locked = locked
        self.opacity = opacity
        self.lockMode = lockMode
        self.blendMode = blendMode
        self.glowEnabled = glowEnabled
        self.glowColor = glowColor
        self.colorLabel = colorLabel
    }
}

// MARK: - Studio Project (Foundation-only, with legacy migration metadata)

public struct SDStudioProject: Codable, Equatable {
    public let id: String
    public var userID: String
    public var name: String
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var frameCount: Int?
    public var thumbnailURL: String?
    public var createdAt: String?
    public var updatedAt: String?

    /// Non-destructive legacy migration metadata.
    /// When a project is imported from raster frame_N.png files,
    /// this preserves the original asset paths so no user content is lost.
    public var legacyMigrationSource: String?

    enum CodingKeys: String, CodingKey {
        case id, name, width, height, fps
        case userID = "user_id"
        case frameCount = "frame_count"
        case thumbnailURL = "thumbnail_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case legacyMigrationSource = "legacy_migration_source"
    }

    public init(
        id: String = UUID().uuidString,
        userID: String = "",
        name: String = "Untitled",
        width: Int? = 1920,
        height: Int? = 1080,
        fps: Int? = 12,
        frameCount: Int? = nil,
        thumbnailURL: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        legacyMigrationSource: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.width = width
        self.height = height
        self.fps = fps
        self.frameCount = frameCount
        self.thumbnailURL = thumbnailURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.legacyMigrationSource = legacyMigrationSource
    }
}

// MARK: - AppConfig (Foundation-only, public/publishable config)

public enum SDAppConfig {
    public static let supabaseURL = "https://placeholder.supabase.co"
    public static let supabaseAnonKey = "placeholder-anon-key"
    public static let liveKitWSURL = "wss://placeholder.livekit.cloud"
    public static let openAIAPIKey = ""
    public static let openAIModel = "gpt-4o"
    public static let geminiAPIKey = ""

    public enum SubscriptionTier: String, CaseIterable, Codable {
        case free, creator, pro, studio
    }

    public enum CallRateTier: String, CaseIterable, Codable {
        case standard, creator, pro, studio

        public var ratePerMinute: Double {
            switch self {
            case .standard: return 0.05
            case .creator:  return 0.10
            case .pro:      return 0.15
            case .studio:   return 0.25
            }
        }
    }
}
