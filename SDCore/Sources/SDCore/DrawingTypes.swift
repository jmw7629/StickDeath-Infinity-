// ═══════════════════════════════════════════════════════════════════
// DrawingTypes — Production Codable model source of truth
// Uses Double for all spatial types (cross-platform compatible).
// On iOS, convert to CGFloat at the SwiftUI/CoreGraphics boundary.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Stroke Point

public struct StrokePoint: Codable, Equatable, Sendable {
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

public enum DrawingTool: String, Codable, CaseIterable, Sendable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, move, hand, zoom
}

// MARK: - Drawn Element

public struct DrawnElement: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var tool: DrawingTool
    public var points: [StrokePoint]
    public var color: String       // hex color
    public var width: Double
    public var opacity: Double
    public var fillColor: String?  // for fill tool / shape fill
    public var layerID: String?

    public init(
        id: String,
        tool: DrawingTool,
        points: [StrokePoint],
        color: String,
        width: Double,
        opacity: Double,
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

// MARK: - Animation Frame

public struct AnimationFrame: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var elements: [DrawnElement]

    public init(id: String, elements: [DrawnElement]) {
        self.id = id
        self.elements = elements
    }
}

// MARK: - Canvas Layer

public struct CanvasLayer: Codable, Identifiable, Equatable, Sendable {
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
        id: String,
        name: String,
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

// MARK: - Studio Project (persistence metadata)

public struct StudioProjectRecord: Codable, Equatable, Sendable {
    public var id: String
    public var userID: String
    public var name: String
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var frameCount: Int?
    public var thumbnailURL: String?
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        id: String,
        userID: String,
        name: String,
        width: Int? = nil,
        height: Int? = nil,
        fps: Int? = nil,
        frameCount: Int? = nil,
        thumbnailURL: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
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
    }
}
