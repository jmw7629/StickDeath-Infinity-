import Foundation

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
