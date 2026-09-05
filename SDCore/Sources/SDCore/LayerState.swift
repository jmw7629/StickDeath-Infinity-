// ═══════════════════════════════════════════════════════════════════
// SDCore LayerState — Canonical, deterministic layer management.
// Single mutable/persisted layer source of truth.
// UI presentation is derived, not owned.
// ═══════════════════════════════════════════════════════════════════

import Foundation

public final class LayerState: ObservableObject, Sendable {
    @Published public var layers: [CanvasLayer] = []
    @Published public var activeLayerID: String = ""

    public init() {}

    public init(layers: [CanvasLayer]) {
        self.layers = layers
        self.activeLayerID = layers.first?.id ?? ""
    }

    // MARK: - Deterministic ID Generation

    public static func deterministicID(from input: String) -> String {
        guard !input.isEmpty else { return "layer_default" }
        return input
    }

    public static func newLayerID() -> String {
        UUID().uuidString
    }

    // MARK: - Visibility

    public func toggleVisibility(_ id: String) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].visible.toggle()
    }

    // MARK: - Lock Mode

    public func setLockMode(_ id: String, mode: LayerLockMode) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].lockMode = mode.rawValue
    }

    // MARK: - Opacity

    public func setOpacity(_ id: String, opacity: Double) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].opacity = max(0, min(1, opacity))
    }

    // MARK: - Blend Mode

    public func setBlendMode(_ id: String, blendMode: String) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].blendMode = blendMode
    }

    // MARK: - Glow

    public func toggleGlow(_ id: String) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].glowEnabled.toggle()
    }

    public func setGlowColor(_ id: String, color: String?) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].glowColor = color
    }

    // MARK: - Color Label

    public func setColorLabel(_ id: String, color: String?) {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[idx].colorLabel = color
    }

    // MARK: - Add

    @discardableResult
    public func addLayer(name: String? = nil) -> CanvasLayer {
        let num = layers.count + 1
        let id = Self.newLayerID()
        let layer = CanvasLayer(
            id: id,
            name: name ?? "Layer \(num)"
        )
        layers.insert(layer, at: 0)
        activeLayerID = id
        return layer
    }

    // MARK: - Duplicate

    @discardableResult
    public func duplicateLayer(_ id: String) -> CanvasLayer? {
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return nil }
        let original = layers[idx]
        let newID = Self.newLayerID()
        let copy = CanvasLayer(
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
        layers.insert(copy, at: idx + 1)
        return copy
    }

    // MARK: - Delete

    public func deleteLayer(_ id: String) {
        guard layers.count > 1 else { return }
        guard let idx = layers.firstIndex(where: { $0.id == id }) else { return }
        layers.remove(at: idx)
        if activeLayerID == id {
            activeLayerID = layers.first?.id ?? ""
        }
    }

    // MARK: - Reorder

    public func moveLayerUp(_ id: String) {
        guard let idx = layers.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        layers.swapAt(idx, idx - 1)
    }

    public func moveLayerDown(_ id: String) {
        guard let idx = layers.firstIndex(where: { $0.id == id }), idx < layers.count - 1 else { return }
        layers.swapAt(idx, idx + 1)
    }

    // MARK: - Active Layer

    public func setActiveLayer(_ id: String) {
        guard layers.contains(where: { $0.id == id }) else { return }
        activeLayerID = id
    }

    // MARK: - Layer by ID

    public func layer(withID id: String) -> CanvasLayer? {
        layers.first(where: { $0.id == id })
    }

    public func layerIndex(_ id: String) -> Int? {
        layers.firstIndex(where: { $0.id == id })
    }

    // MARK: - Reset

    public func reset() {
        layers = [CanvasLayer(id: Self.newLayerID(), name: "Layer 1")]
        activeLayerID = layers.first?.id ?? ""
    }
}
