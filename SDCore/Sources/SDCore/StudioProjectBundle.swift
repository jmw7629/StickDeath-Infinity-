import Foundation

public struct StudioProjectBundle: Codable, Equatable, Sendable {
    public var projectID: String
    public var name: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var frames: [AnimationFrame]
    public var layers: [CanvasLayer]
    public var legacyRasterReferences: [LegacyRasterReference]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        projectID: String = UUID().uuidString,
        name: String = "Untitled Animation",
        width: Int = 1080,
        height: Int = 1080,
        fps: Int = 12,
        frames: [AnimationFrame] = [AnimationFrame()],
        layers: [CanvasLayer] = [CanvasLayer(name: "Layer 1")],
        legacyRasterReferences: [LegacyRasterReference] = [],
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
        self.legacyRasterReferences = legacyRasterReferences
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
