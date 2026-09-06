import Foundation

public struct StrokePoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var pressure: Double?
    public var timestamp: Double?

    public init(x: Double, y: Double, pressure: Double? = nil, timestamp: Double? = nil) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.timestamp = timestamp
    }
}

public enum DrawingTool: String, Codable, CaseIterable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, move, hand, zoom
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
        tool: DrawingTool = .brush,
        points: [StrokePoint] = [],
        color: String = "#FF0000",
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

public struct AnimationFrame: Codable, Identifiable, Equatable {
    public let id: String
    public var elements: [DrawnElement]

    public init(id: String = UUID().uuidString, elements: [DrawnElement] = []) {
        self.id = id
        self.elements = elements
    }
}

public struct AudioClip: Codable, Identifiable, Equatable {
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
        duration: Double = 0.5,
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
