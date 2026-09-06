import Foundation

public final class LayerCommands {
    private let project: () -> Project?
    private let save: (Project) throws -> Project

    public init(project: @escaping () -> Project?, save: @escaping (Project) throws -> Project) {
        self.project = project
        self.save = save
    }

    private var current: Project? { project() }

    @discardableResult
    public func setActiveLayer(id: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard p.layers.contains(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        p.activeLayerID = id
        return try save(p)
    }

    @discardableResult
    public func toggleVisibility(id: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        p.layers[idx].visible.toggle()
        return try save(p)
    }

    @discardableResult
    public func setLockMode(id: String, mode: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        p.layers[idx].lockMode = mode
        return try save(p)
    }

    @discardableResult
    public func setOpacity(id: String, opacity: Double) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        p.layers[idx].opacity = min(max(opacity, 0), 1)
        return try save(p)
    }

    @discardableResult
    public func setBlendMode(id: String, mode: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        p.layers[idx].blendMode = mode
        return try save(p)
    }

    @discardableResult
    public func setGlowEnabled(id: String, enabled: Bool) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        p.layers[idx].glowEnabled = enabled
        return try save(p)
    }

    @discardableResult
    public func setGlowColor(id: String, color: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        p.layers[idx].glowColor = color
        return try save(p)
    }

    @discardableResult
    public func setColorLabel(id: String, color: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        p.layers[idx].colorLabel = color
        return try save(p)
    }

    @discardableResult
    public func rename(id: String, name: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        p.layers[idx].name = name
        return try save(p)
    }

    @discardableResult
    public func addLayer(name: String? = nil) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        let newName = name ?? "Layer \(p.layers.count + 1)"
        let newLayer = CanvasLayer(id: UUID().uuidString, name: newName)
        p.layers.insert(newLayer, at: 0)
        p.activeLayerID = newLayer.id
        return try save(p)
    }

    @discardableResult
    public func duplicateLayer(id: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        let original = p.layers[idx]
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
        p.layers.insert(newLayer, at: idx + 1)
        return try save(p)
    }

    @discardableResult
    public func deleteLayer(id: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard p.layers.count > 1 else { throw LayerError.cannotDeleteLastLayer }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        p.layers.remove(at: idx)
        if p.activeLayerID == id {
            p.activeLayerID = p.layers[min(idx, p.layers.count - 1)].id
        }
        return try save(p)
    }

    @discardableResult
    public func moveLayer(id: String, to destinationIndex: Int) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }) else { throw LayerError.layerNotFound }
        let clampedIndex = min(max(destinationIndex, 0), p.layers.count - 1)
        let layer = p.layers.remove(at: idx)
        p.layers.insert(layer, at: clampedIndex)
        return try save(p)
    }

    @discardableResult
    public func moveLayerUp(id: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }), idx > 0 else { throw LayerError.layerNotFound }
        return try moveLayer(id: id, to: idx - 1)
    }

    @discardableResult
    public func moveLayerDown(id: String) throws -> Project {
        guard var p = current else { throw LayerError.noProject }
        guard let idx = p.layers.firstIndex(where: { $0.id == id }), idx < p.layers.count - 1 else { throw LayerError.layerNotFound }
        return try moveLayer(id: id, to: idx + 1)
    }
}

public enum LayerError: LocalizedError {
    case noProject
    case layerNotFound
    case cannotDeleteLastLayer

    public var errorDescription: String? {
        switch self {
        case .noProject: return "No project loaded"
        case .layerNotFound: return "Layer not found"
        case .cannotDeleteLastLayer: return "Cannot delete the last layer"
        }
    }
}
