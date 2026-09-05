import Foundation

public struct StrokePoint: Codable, Sendable {
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
