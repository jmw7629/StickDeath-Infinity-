import Foundation

public struct CanvasLayer: Codable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var visible: Bool
    public var locked: Bool
    public var opacity: Double
    public var lockMode: String
    public var blendMode: String
    public var glowEnabled: Bool
    public var glowColor: String?
    public var colorLabel: String?

    public init(
        id: String = UUID().uuidString,
        name: String = "Layer 1",
        visible: Bool = true,
        locked: Bool = false,
        opacity: Double = 1.0,
        lockMode: String = "free",
        blendMode: String = "normal",
        glowEnabled: Bool = false,
        glowColor: String? = nil,
        colorLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.visible = visible
        self.locked = locked
        self.opacity = opacity
        self.lockMode = lockMode
        self.blendMode = blendMode
        self.glowEnabled = glowEnabled
        self.glowColor = glowColor
        self.colorLabel = colorLabel
    }
}

extension CanvasLayer {
    public func withID(_ newID: String) -> CanvasLayer {
        CanvasLayer(
            id: newID, name: name, visible: visible, locked: locked,
            opacity: opacity, lockMode: lockMode, blendMode: blendMode,
            glowEnabled: glowEnabled, glowColor: glowColor, colorLabel: colorLabel
        )
    }
}
