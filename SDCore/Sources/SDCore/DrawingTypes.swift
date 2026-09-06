import Foundation

public enum DrawingTool: String, Codable, CaseIterable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, move, hand, zoom
}

public struct StrokePoint: Codable, Equatable {
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

public struct DrawnElement: Codable, Identifiable, Equatable {
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
        width: Double = 3,
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

public struct AnimationFrame: Codable, Identifiable, Equatable {
    public let id: String
    public var elements: [DrawnElement]

    public init(id: String = UUID().uuidString, elements: [DrawnElement] = []) {
        self.id = id
        self.elements = elements
    }
}

public struct Project: Codable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var frames: [AnimationFrame]
    public var layers: [CanvasLayer]
    public var activeLayerID: String
    public var activeFrameIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String = "Untitled Animation",
        width: Int = 1080,
        height: Int = 1080,
        fps: Int = 12,
        frames: [AnimationFrame] = [AnimationFrame()],
        layers: [CanvasLayer] = [CanvasLayer()],
        activeLayerID: String = "",
        activeFrameIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.fps = fps
        self.frames = frames
        self.layers = layers
        self.activeLayerID = activeLayerID.isEmpty ? (layers.first?.id ?? "") : activeLayerID
        self.activeFrameIndex = activeFrameIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
