import Foundation

public struct ProjectMetadata: Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var frameCount: Int
    public var layerCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var userID: String?

    public init(
        id: String = UUID().uuidString,
        name: String = "Untitled Animation",
        width: Int = 1080,
        height: Int = 1080,
        fps: Int = 12,
        frameCount: Int = 1,
        layerCount: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        userID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.fps = fps
        self.frameCount = frameCount
        self.layerCount = layerCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.userID = userID
    }
}
