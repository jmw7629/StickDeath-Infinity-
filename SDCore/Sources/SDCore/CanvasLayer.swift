import Foundation

/// Canonical layer model — single source of truth for layer state.
/// Uses String IDs that are stable and deterministic (no random UUID conversion).
public struct CanvasLayer: Codable, Identifiable, Equatable, Sendable {
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
        id: String,
        name: String,
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

    /// Deterministic default layer ID — never random.
    public static let defaultLayerID = "layer_default"

    /// Create the canonical default first layer.
    public static func defaultLayer() -> CanvasLayer {
        CanvasLayer(
            id: defaultLayerID,
            name: "Layer 1",
            visible: true,
            locked: false,
            opacity: 1.0
        )
    }

    /// Create a new layer with a stable deterministic ID based on index.
    public static func newLayer(index: Int, name: String? = nil) -> CanvasLayer {
        CanvasLayer(
            id: "layer_\(index)",
            name: name ?? "Layer \(index + 1)",
            visible: true,
            locked: false,
            opacity: 1.0
        )
    }
}
