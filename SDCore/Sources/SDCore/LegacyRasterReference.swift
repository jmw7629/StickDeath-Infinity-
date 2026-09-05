import Foundation

public struct LegacyRasterReference: Codable, Equatable, Sendable {
    public let frameIndex: Int
    public let fileName: String
    public let byteCount: Int

    public init(frameIndex: Int, fileName: String, byteCount: Int) {
        self.frameIndex = frameIndex
        self.fileName = fileName
        self.byteCount = byteCount
    }
}
