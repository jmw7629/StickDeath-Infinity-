// ═══════════════════════════════════════════════════════════════════
// LayerCommands — Canonical layer operations seam
// All layer mutations go through this seam using String IDs.
// CanvasLayer String ID is the sole mutable/persisted layer truth.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Layer Commands

public struct LayerCommands {

    // MARK: - Select Active Layer

    public static func selectLayer(
        id: String,
        layers: inout [CanvasLayer],
        activeLayerID: inout String
    ) -> Bool {
        guard layers.contains(where: { $0.id == id }) else { return false }
        activeLayerID = id
        return true
    }

    // MARK: - Toggle Visibility

    public static func toggleVisibility(
        id: String,
        layers: inout [CanvasLayer]
    ) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].visible.toggle()
        return true
    }

    // MARK: - Set Lock Mode

    public static func setLockMode(
        id: String,
        mode: LayerLockMode,
        layers: inout [CanvasLayer]
    ) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].lockMode = mode.rawValue
        layers[idx].locked = (mode != .free)
        return true
    }

    // MARK: - Set Opacity (clamped 0...1)

    public static func setOpacity(
        id: String,
        opacity: Double,
        layers: inout [CanvasLayer]
    ) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].opacity = min(max(opacity, 0.0), 1.0)
        return true
    }

    // MARK: - Set Blend Mode

    public static func setBlendMode(
        id: String,
        blendMode: String,
        layers: inout [CanvasLayer]
    ) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].blendMode = blendMode
        return true
    }

    // MARK: - Set Glow

    public static func setGlow(
        id: String,
        enabled: Bool,
        color: String? = nil,
        layers: inout [CanvasLayer]
    ) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].glowEnabled = enabled
        layers[idx].glowColor = color
        return true
    }

    // MARK: - Set Color Label

    public static func setColorLabel(
        id: String,
        colorLabel: String?,
        layers: inout [CanvasLayer]
    ) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].colorLabel = colorLabel
        return true
    }

    // MARK: - Rename

    public static func rename(
        id: String,
        newName: String,
        layers: inout [CanvasLayer]
    ) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers[idx].name = newName
        return true
    }

    // MARK: - Add Layer

    public static func addLayer(
        name: String? = nil,
        layers: inout [CanvasLayer],
        activeLayerID: inout String
    ) -> CanvasLayer {
        let num = layers.count + 1
        let newLayer = CanvasLayer(
            name: name ?? "Layer \(num)",
            visible: true,
            locked: false,
            opacity: 1.0
        )
        layers.insert(newLayer, at: 0)
        activeLayerID = newLayer.id
        return newLayer
    }

    // MARK: - Duplicate Layer (new stable String ID, preserve properties)

    public static func duplicateLayer(
        id: String,
        layers: inout [CanvasLayer],
        activeLayerID: inout String
    ) -> CanvasLayer? {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return nil }
        let original = layers[idx]
        let newID = UUID().uuidString
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
        activeLayerID = newID
        return duplicate
    }

    // MARK: - Delete Layer (cannot leave zero layers; active selection repaired)

    public static func deleteLayer(
        id: String,
        layers: inout [CanvasLayer],
        activeLayerID: inout String
    ) -> Bool {
        guard layers.count > 1,
              let idx = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers.remove(at: idx)

        // Repair active selection
        if activeLayerID == id {
            let newIdx = min(idx, layers.count - 1)
            activeLayerID = layers[newIdx].id
        }
        return true
    }

    // MARK: - Reorder Up

    public static func moveUp(
        id: String,
        layers: inout [CanvasLayer]
    ) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }), idx > 0 else { return false }
        layers.swapAt(idx, idx - 1)
        return true
    }

    // MARK: - Reorder Down

    public static func moveDown(
        id: String,
        layers: inout [CanvasLayer]
    ) -> Bool {
        guard let idx = layers.firstIndex(where: { $0.id == id }),
              idx < layers.count - 1 else { return false }
        layers.swapAt(idx, idx + 1)
        return true
    }
}
