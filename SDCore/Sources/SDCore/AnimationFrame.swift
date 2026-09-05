import Foundation

public struct AnimationFrame: Codable, Identifiable, Sendable {
    public let id: String
    public var elements: [DrawnElement]

    public init(id: String = UUID().uuidString, elements: [DrawnElement] = []) {
        self.id = id
        self.elements = elements
    }
}
