import Foundation

/// Canonical project model persisted by StudioStorage.
public struct StudioProject: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var fps: Int
    public var frames: [AnimationFrame]
    public var layers: [CanvasLayer]
    public var activeLayerID: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        canvasWidth: Int = 1080,
        canvasHeight: Int = 1080,
        fps: Int = 12,
        frames: [AnimationFrame] = [AnimationFrame()],
        layers: [CanvasLayer] = [CanvasLayer.defaultLayer()],
        activeLayerID: String = CanvasLayer.defaultLayerID,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.fps = fps
        self.frames = frames
        self.layers = layers
        self.activeLayerID = activeLayerID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
