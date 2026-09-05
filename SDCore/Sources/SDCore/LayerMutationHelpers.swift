import Foundation

public enum LayerMutationHelpers {

    // MARK: - Visibility

    public static func toggleVisibility(layers: inout [CanvasLayer], id: String) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].visible.toggle()
        return true
    }

    // MARK: - Lock

    public static func toggleLock(layers: inout [CanvasLayer], id: String) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].locked.toggle()
        return true
    }

    public static func setLockMode(layers: inout [CanvasLayer], id: String, mode: String) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].lockMode = mode
        return true
    }

    // MARK: - Opacity

    public static func setOpacity(layers: inout [CanvasLayer], id: String, opacity: Double) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].opacity = max(0, min(1, opacity))
        return true
    }

    // MARK: - Color Label

    public static func setColorLabel(layers: inout [CanvasLayer], id: String, colorLabel: String?) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].colorLabel = colorLabel
        return true
    }

    // MARK: - Blend Mode

    public static func setBlendMode(layers: inout [CanvasLayer], id: String, blendMode: String) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].blendMode = blendMode
        return true
    }

    // MARK: - Add

    @discardableResult
    public static func addLayer(layers: inout [CanvasLayer], name: String? = nil, at index: Int? = nil) -> CanvasLayer {
        let num = layers.count + 1
        let newLayer = CanvasLayer(
            id: UUID().uuidString,
            name: name ?? "Layer \(num)",
            visible: true,
            locked: false,
            opacity: 1.0
        )
        if let index = index, index <= layers.count {
            layers.insert(newLayer, at: index)
        } else {
            layers.insert(newLayer, at: 0)
        }
        return newLayer
    }

    // MARK: - Duplicate

    @discardableResult
    public static func duplicateLayer(layers: inout [CanvasLayer], id: String) -> CanvasLayer? {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return nil }
        let original = layers[idx]
        let newLayer = CanvasLayer(
            id: UUID().uuidString,
            name: "\(original.name) Copy",
            visible: original.visible,
            locked: original.locked,
            opacity: original.opacity,
            lockMode: original.lockMode,
            blendMode: original.blendMode,
            glowEnabled: original.glowEnabled,
            glowColor: original.glowColor,
            colorLabel: original.colorLabel
        )
        layers.insert(newLayer, at: idx + 1)
        return newLayer
    }

    // MARK: - Delete

    @discardableResult
    public static func deleteLayer(layers: inout [CanvasLayer], id: String) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers.remove(at: idx)
        return true
    }

    // MARK: - Reorder

    public static func moveUp(layers: inout [CanvasLayer], id: String) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }), idx > 0 else { return false }
        layers.swapAt(idx, idx - 1)
        return true
    }

    public static func moveDown(layers: inout [CanvasLayer], id: String) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }), idx < layers.count - 1 else { return false }
        layers.swapAt(idx, idx + 1)
        return true
    }

    // MARK: - Active Layer

    public static func validateActiveLayerID(layers: [CanvasLayer], activeID: String) -> String {
        if layers.contains(where: { $0.id == activeID }) {
            return activeID
        }
        return layers.first?.id ?? ""
    }

    // MARK: - Resolve from UUID string

    public static func canvasLayerID(fromUUIDString uuidString: String, layers: [CanvasLayer]) -> String? {
        // Try direct match first
        if layers.contains(where: { $0.id == uuidString }) {
            return uuidString
        }
        return nil
    }
}
