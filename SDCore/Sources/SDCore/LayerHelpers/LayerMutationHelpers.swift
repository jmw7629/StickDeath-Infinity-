import Foundation

public enum LayerMutationError: LocalizedError, Sendable {
    case layerNotFound(String)
    case invalidIndex

    public var errorDescription: String? {
        switch self {
        case .layerNotFound(let id): return "Layer not found: \(id)"
        case .invalidIndex: return "Invalid layer index"
        }
    }
}

public struct LayerMutationHelpers {

    // MARK: - Visibility

    public static func toggleVisibility(
        layers: inout [CanvasLayer], id: String
    ) throws {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerMutationError.layerNotFound(id)
        }
        layers[idx].visible.toggle()
    }

    // MARK: - Lock mode

    public static func setLockMode(
        layers: inout [CanvasLayer], id: String, mode: LayerLockMode
    ) throws {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerMutationError.layerNotFound(id)
        }
        layers[idx].lockMode = mode.rawValue
        layers[idx].locked = (mode != .free)
    }

    // MARK: - Opacity

    public static func setOpacity(
        layers: inout [CanvasLayer], id: String, opacity: Double
    ) throws {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerMutationError.layerNotFound(id)
        }
        layers[idx].opacity = min(max(opacity, 0), 1)
    }

    // MARK: - Blend mode

    public static func setBlendMode(
        layers: inout [CanvasLayer], id: String, blendMode: String
    ) throws {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerMutationError.layerNotFound(id)
        }
        layers[idx].blendMode = blendMode
    }

    // MARK: - Color label

    public static func setColorLabel(
        layers: inout [CanvasLayer], id: String, colorLabel: String?
    ) throws {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerMutationError.layerNotFound(id)
        }
        layers[idx].colorLabel = colorLabel
    }

    // MARK: - Glow

    public static func setGlowEnabled(
        layers: inout [CanvasLayer], id: String, enabled: Bool
    ) throws {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerMutationError.layerNotFound(id)
        }
        layers[idx].glowEnabled = enabled
    }

    public static func setGlowColor(
        layers: inout [CanvasLayer], id: String, color: String?
    ) throws {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerMutationError.layerNotFound(id)
        }
        layers[idx].glowColor = color
    }

    // MARK: - Add

    @discardableResult
    public static func addLayer(
        layers: inout [CanvasLayer], name: String? = nil, at index: Int? = nil
    ) -> CanvasLayer {
        let newID = "layer_\(UUID().uuidString.prefix(8))"
        let count = layers.count + 1
        let layer = CanvasLayer(id: newID, name: name ?? "Layer \(count)")
        if let index, index >= 0 && index <= layers.count {
            layers.insert(layer, at: index)
        } else {
            layers.insert(layer, at: 0)
        }
        return layer
    }

    // MARK: - Duplicate

    @discardableResult
    public static func duplicateLayer(
        layers: inout [CanvasLayer], id: String
    ) throws -> CanvasLayer {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerMutationError.layerNotFound(id)
        }
        let original = layers[idx]
        let newID = "layer_\(UUID().uuidString.prefix(8))"
        let duplicate = CanvasLayer(
            id: newID,
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
        layers.insert(duplicate, at: idx + 1)
        return duplicate
    }

    // MARK: - Delete

    public static func deleteLayer(
        layers: inout [CanvasLayer], id: String
    ) throws {
        guard layers.count > 1 else { return }
        guard let idx = layers.firstIndex(where: { $0.id == id }) else {
            throw LayerMutationError.layerNotFound(id)
        }
        layers.remove(at: idx)
    }

    // MARK: - Reorder

    public static func moveUp(
        layers: inout [CanvasLayer], id: String
    ) throws {
        guard let idx = layers.firstIndex(where: { $0.id == id }), idx > 0 else {
            throw LayerMutationError.invalidIndex
        }
        layers.swapAt(idx, idx - 1)
    }

    public static func moveDown(
        layers: inout [CanvasLayer], id: String
    ) throws {
        guard let idx = layers.firstIndex(where: { $0.id == id }),
              idx < layers.count - 1 else {
            throw LayerMutationError.invalidIndex
        }
        layers.swapAt(idx, idx + 1)
    }

    // MARK: - Active layer selection

    public static func selectLayer(
        id: String, activeLayerID: inout String, layers: [CanvasLayer]
    ) throws {
        guard layers.contains(where: { $0.id == id }) else {
            throw LayerMutationError.layerNotFound(id)
        }
        activeLayerID = id
    }
}
