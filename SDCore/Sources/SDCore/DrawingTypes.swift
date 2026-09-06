import Foundation

// MARK: - Drawing Tool

public enum DrawingTool: String, Codable, CaseIterable, Sendable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, move, hand, zoom
}

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
        id: String = UUID().uuidString,
        tool: DrawingTool,
        points: [StrokePoint],
        color: String,
        width: Double,
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

// MARK: - Animation Frame

public struct AnimationFrame: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var elements: [DrawnElement]

    public init(id: String = UUID().uuidString, elements: [DrawnElement] = []) {
        self.id = id
        self.elements = elements
    }
}
