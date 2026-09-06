// ═══════════════════════════════════════════════════════════════════
// CanvasModels — Foundation-only drawing and layer types for SDCore
// All coordinates use Double (NOT CGFloat) for Linux compatibility.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Studio Project (persisted)

public struct StudioProject: Codable, Identifiable, Sendable {
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

    public enum CodingKeys: String, CodingKey {
        case id, name, width, height, fps
        case userID = "user_id"
        case frameCount = "frame_count"
        case thumbnailURL = "thumbnail_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        userID: String = "",
        name: String = "Untitled Animation",
        width: Int? = 1080,
        height: Int? = 1080,
        fps: Int? = 12,
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

// MARK: - Canonical Project (local file format)

public struct SDProject: Codable, Sendable {
    public var projectID: String
    public var name: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var frames: [SDFrame]
    public var layers: [CanvasLayer]
    public var activeLayerID: String
    public var audioClips: [SDAudioClip]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        projectID: String = UUID().uuidString,
        name: String = "Untitled Animation",
        width: Int = 1080,
        height: Int = 1080,
        fps: Int = 12,
        frames: [SDFrame] = [SDFrame()],
        layers: [CanvasLayer] = [CanvasLayer()],
        activeLayerID: String = "",
        audioClips: [SDAudioClip] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.projectID = projectID
        self.name = name
        self.width = width
        self.height = height
        self.fps = fps
        self.frames = frames
        self.layers = layers
        self.activeLayerID = activeLayerID.isEmpty ? (layers.first?.id ?? "") : activeLayerID
        self.audioClips = audioClips
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Frame

public struct SDFrame: Codable, Identifiable, Sendable {
    public let id: String
    public var elements: [DrawnElement]

    public init(id: String = UUID().uuidString, elements: [DrawnElement] = []) {
        self.id = id
        self.elements = elements
    }
}

// MARK: - Drawing Types

public struct DrawnElement: Codable, Identifiable, Sendable {
    public let id: String
    public var tool: DrawingTool
    public var points: [StrokePoint]
    public var color: String
    public var width: Double
    public var opacity: Double
    public var fillColor: String?
    public var layerID: String?

    public init(
        id: String = UUID().uuidString,
        tool: DrawingTool = .pen,
        points: [StrokePoint] = [],
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

public struct StrokePoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var pressure: Double?
    public var timestamp: TimeInterval?

    public init(x: Double = 0, y: Double = 0, pressure: Double? = nil, timestamp: TimeInterval? = nil) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.timestamp = timestamp
    }
}

public enum DrawingTool: String, Codable, CaseIterable, Sendable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, move, hand, zoom
}

// MARK: - Canvas Layer (String ID = sole mutable/persisted truth)

public struct CanvasLayer: Codable, Identifiable, Sendable, Equatable {
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
        name: String = "Layer 1",
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

// MARK: - Lock Mode

public enum LayerLockMode: String, Codable, CaseIterable, Sendable {
    case free, full, position, alpha
}

// MARK: - Blend Mode

public enum SDBlendMode: String, CaseIterable, Sendable {
    case normal = "Normal"
    case multiply = "Multiply"
    case screen = "Screen"
    case overlay = "Overlay"
    case darken = "Darken"
    case lighten = "Lighten"
    case colorDodge = "Color Dodge"
    case colorBurn = "Color Burn"
}

// MARK: - Audio Clip

public struct SDAudioClip: Codable, Identifiable, Sendable {
    public let id: String
    public var soundName: String
    public var track: Int
    public var startTime: Double
    public var duration: Double
    public var volume: Double

    public init(
        id: String = UUID().uuidString,
        soundName: String = "",
        track: Int = 0,
        startTime: Double = 0,
        duration: Double = 0,
        volume: Double = 0.8
    ) {
        self.id = id
        self.soundName = soundName
        self.track = track
        self.startTime = startTime
        self.duration = duration
        self.volume = volume
    }
}

// MARK: - Export Types

public enum ExportFormat: String, CaseIterable, Sendable {
    case mp4 = "MP4"
    case gif = "GIF"
    case png = "PNG"
    case spritesheet = "Spritesheet"
}

public enum ExportQuality: String, CaseIterable, Sendable {
    case standard = "Standard"
    case hd = "HD"
    case fullHD = "Full HD"
}
