// ═══════════════════════════════════════════════════════════════════
// SDCore — Production Codable drawing/persistence types
// Single source of truth for both iOS app and tests.
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
    public var color: String
    public var width: Double
    public var opacity: Double
    public var fillColor: String?
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

    public init(id: String, elements: [DrawnElement] = []) {
        self.id = id
        self.elements = elements
    }
}

// MARK: - Layer Lock Mode

public enum LayerLockMode: String, Codable, CaseIterable, Sendable {
    case free, full, position, alpha
}

// MARK: - Canvas Layer (canonical — String ID, no UUID)

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

    public var typedLockMode: LayerLockMode {
        LayerLockMode(rawValue: lockMode) ?? .free
    }
}

// MARK: - Studio Project (canonical local persistence model)

public struct StudioProjectRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var frameCount: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        width: Int = 1080,
        height: Int = 1080,
        fps: Int = 12,
        frameCount: Int = 1,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        updatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.fps = fps
        self.frameCount = frameCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
