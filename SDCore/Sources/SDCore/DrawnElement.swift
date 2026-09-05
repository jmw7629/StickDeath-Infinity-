import Foundation

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
