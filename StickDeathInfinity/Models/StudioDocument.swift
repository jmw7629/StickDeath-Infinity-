import Foundation

/// Editable Studio content. CanvasLayer is the sole layer identity and ordering model.
struct StudioDocument: Codable, Equatable {
    var schemaVersion = 1
    let id: UUID
    var name: String
    var width: Int
    var height: Int
    var fps: Int
    var frames: [AnimationFrame]
    var layers: [CanvasLayer] // Front to back, matching the layer panel.
    var activeFrameID: String
    var activeLayerID: String
    var audioClips: [AudioClip] = []
    var gridEnabled = false
    var onionEnabled = false
    var createdAt: Date
    var modifiedAt: Date
    var revision = 0

    static func new(name: String, width: Int, height: Int, fps: Int, id: UUID = UUID()) throws -> Self {
        let layer = CanvasLayer(id: UUID().uuidString, name: "Layer 1")
        let frame = AnimationFrame(id: UUID().uuidString, elements: [])
        let date = Date()
        let value = Self(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), width: width, height: height,
                         fps: fps, frames: [frame], layers: [layer], activeFrameID: frame.id, activeLayerID: layer.id,
                         createdAt: date, modifiedAt: date)
        try value.validate()
        return value
    }

    var referencedAudioAssetIDs: Set<UUID> { Set(audioClips.compactMap(\.assetID)) }

    func validate() throws {
        guard schemaVersion == 1 else { throw StudioDocumentError.invalid("This project version is not supported. The original has not been changed.") }
        guard !name.isEmpty, name.count <= 120, (16...4096).contains(width), (16...4096).contains(height),
              (1...60).contains(fps), (1...1000).contains(frames.count), (1...128).contains(layers.count),
              revision >= 0, revision < Int.max - 1 else { throw StudioDocumentError.invalid("Project dimensions, timing, name or size are invalid.") }
        let layerIDs = Set(layers.map(\.id)); let frameIDs = Set(frames.map(\.id))
        guard layerIDs.count == layers.count, frameIDs.count == frames.count,
              layerIDs.contains(activeLayerID), frameIDs.contains(activeFrameID),
              !layerIDs.contains(""), !frameIDs.contains("") else { throw StudioDocumentError.invalid("Project identities or selection are invalid.") }
        for layer in layers {
            guard !layer.name.isEmpty, layer.name.count <= 120, layer.opacity.isFinite, (0...1).contains(layer.opacity) else {
                throw StudioDocumentError.invalid("A layer has invalid settings.")
            }
        }
        var elementIDs = Set<String>(); var pointCount = 0
        for frame in frames {
            if frame.rasterAssetID != nil {
                guard frame.rasterLayerID.map(layerIDs.contains) == true else { throw StudioDocumentError.invalid("An imported image has an invalid layer reference.") }
            }
            guard frame.elements.count <= 20000 else { throw StudioDocumentError.invalid("This frame exceeds the editable element limit.") }
            for element in frame.elements {
                guard !element.id.isEmpty, elementIDs.insert(element.id).inserted,
                      element.layerID.map(layerIDs.contains) == true,
                      element.width.isFinite, (0.1...1024).contains(element.width),
                      element.opacity.isFinite, (0...1).contains(element.opacity), element.points.count <= 100000 else {
                    throw StudioDocumentError.invalid("A drawing has invalid geometry or layer identity.")
                }
                pointCount += element.points.count
                guard pointCount <= 1_000_000 else { throw StudioDocumentError.invalid("This project exceeds the editable point limit.") }
                for point in element.points {
                    guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 100000, abs(point.y) <= 100000,
                          point.pressure.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                          point.timestamp.map(\.isFinite) ?? true else { throw StudioDocumentError.invalid("A drawing contains invalid coordinates.") }
                }
            }
        }
        guard Set(audioClips.map(\.id)).count == audioClips.count else { throw StudioDocumentError.invalid("Audio clip identities are invalid.") }
        guard audioClips.filter({ $0.assetID != nil }).count <= 128 else { throw StudioDocumentError.invalid("This project exceeds the 128 imported audio clip limit.") }
        for clip in audioClips {
            if clip.assetID != nil {
                guard !clip.id.isEmpty, clip.id.count <= 120, !clip.soundName.isEmpty, clip.soundName.count <= 120,
                      (1...4).contains(clip.track), clip.duration > 0, clip.duration <= 300,
                      clip.startTime <= 1000, (clip.startTime + clip.duration).isFinite else {
                    throw StudioDocumentError.invalid("An imported audio clip has invalid identity, track or timing.")
                }
            }
            guard clip.startTime.isFinite, clip.duration.isFinite, clip.volume.isFinite,
                  clip.startTime >= 0, clip.duration >= 0, (0...1).contains(clip.volume), clip.track >= 0 else {
                throw StudioDocumentError.invalid("An audio clip has invalid timing.")
            }
        }
    }
}

/// Raster references point into the same atomic AnimationProject snapshot.
/// They never describe raster artwork as editable vector strokes.
struct StudioDocumentArchive: Codable {
    var document: StudioDocument
    var rasterFrameIndices: [String: Int]

    func encoded() throws -> Data {
        try document.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 32 * 1024 * 1024 else { throw StudioDocumentError.invalid("The editable project exceeds the 32 MB storage limit.") }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1024 * 1024 else { throw StudioDocumentError.invalid("The editable project exceeds the storage limit.") }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        try archive.document.validate()
        guard archive.rasterFrameIndices.values.allSatisfy({ $0 >= 0 }) else { throw StudioDocumentError.invalid("A raster reference is invalid.") }
        return archive
    }
}

enum StudioDocumentError: LocalizedError {
    case invalid(String), unavailable(String), locked
    var errorDescription: String? {
        switch self {
        case .invalid(let text), .unavailable(let text): return text
        case .locked: return "Choose a visible, unlocked layer before editing."
        }
    }
}

/// Production commands used by the UI and suitable for validated Spatter commands.
/// A failed command leaves the entire document and undo history unchanged.
struct StudioDocumentEditor {
    private(set) var document: StudioDocument
    private var undoDocuments: [StudioDocument] = []
    private var redoDocuments: [StudioDocument] = []
    private var clipboard: AnimationFrame?
    var selectedElementIDs = Set<String>()
    var canUndo: Bool { !undoDocuments.isEmpty }
    var canRedo: Bool { !redoDocuments.isEmpty }
    var canPaste: Bool { clipboard != nil }
    /// Asset lifetime follows the actual full-document history, never a mirror.
    var referencedAudioAssetIDsIncludingHistory: Set<UUID> {
        (undoDocuments + redoDocuments).reduce(into: document.referencedAudioAssetIDs) { $0.formUnion($1.referencedAudioAssetIDs) }
    }

    init(document: StudioDocument) throws { try document.validate(); self.document = document }

    mutating func change(_ operation: (inout StudioDocument) throws -> Void) throws {
        let previous = document
        var next = document
        try operation(&next)
        try next.validate()
        guard next != previous else { return }
        next.revision = previous.revision + 1; next.modifiedAt = Date()
        undoDocuments.append(previous)
        trimHistory()
        redoDocuments.removeAll(); document = next
    }

    @discardableResult
    mutating func selectFrame(_ id: String) -> Bool {
        guard document.activeFrameID != id, document.frames.contains(where: { $0.id == id }), document.revision < Int.max - 2 else { return false }
        document.activeFrameID = id; selectedElementIDs.removeAll()
        document.revision += 1; document.modifiedAt = Date()
        return true
    }
    @discardableResult
    mutating func selectLayer(_ id: String) -> Bool {
        guard document.activeLayerID != id, document.layers.contains(where: { $0.id == id }), document.revision < Int.max - 2 else { return false }
        document.activeLayerID = id; selectedElementIDs.removeAll()
        document.revision += 1; document.modifiedAt = Date()
        return true
    }
    mutating func commit(_ element: DrawnElement, frameID: String) throws {
        try change { value in
            guard let layer = value.layers.first(where: { $0.id == element.layerID }), layer.visible, !layer.isFullyLocked else { throw StudioDocumentError.locked }
            guard layer.lockMode == "free" || layer.lockMode == "position" else {
                throw StudioDocumentError.unavailable("Alpha-lock painting is unfinished. Choose Free to draw; this layer has not changed.")
            }
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }) else { throw StudioDocumentError.invalid("The drawing frame is unavailable.") }
            value.frames[index].elements.append(element)
        }
    }
    mutating func addFrame() throws {
        try change { value in
            let index = value.frames.firstIndex(where: { $0.id == value.activeFrameID })!
            let frame = AnimationFrame(id: UUID().uuidString, elements: [])
            value.frames.insert(frame, at: index + 1); value.activeFrameID = frame.id
        }
    }
    mutating func copyFrame() { clipboard = document.frames.first { $0.id == document.activeFrameID } }
    mutating func pasteFrame() throws {
        guard let source = clipboard else { return }
        try insertCopy(source)
    }
    mutating func duplicateFrame() throws {
        guard let source = document.frames.first(where: { $0.id == document.activeFrameID }) else { return }
        try insertCopy(source)
    }
    private mutating func insertCopy(_ source: AnimationFrame) throws {
        try change { value in
            let index = value.frames.firstIndex(where: { $0.id == value.activeFrameID })!
            let elements = source.elements.map { element in
                DrawnElement(id: UUID().uuidString, tool: element.tool, points: element.points, color: element.color,
                             width: element.width, opacity: element.opacity, fillColor: element.fillColor, layerID: element.layerID)
            }
            let frame = AnimationFrame(id: UUID().uuidString, elements: elements, rasterAssetID: source.rasterAssetID, rasterLayerID: source.rasterLayerID)
            value.frames.insert(frame, at: index + 1); value.activeFrameID = frame.id
        }
    }
    mutating func deleteFrame(_ id: String) throws {
        try change { value in
            guard value.frames.count > 1, let index = value.frames.firstIndex(where: { $0.id == id }) else { return }
            value.frames.remove(at: index)
            if value.activeFrameID == id { value.activeFrameID = value.frames[min(index, value.frames.count - 1)].id }
        }
    }
    mutating func moveFrame(_ id: String, offset: Int) throws {
        try change { value in
            guard let index = value.frames.firstIndex(where: { $0.id == id }), value.frames.indices.contains(index + offset) else { return }
            value.frames.swapAt(index, index + offset)
        }
    }
    mutating func deleteSelected() throws {
        let selection = selectedElementIDs
        guard !selection.isEmpty else { return }
        try change { value in
            let index = value.frames.firstIndex(where: { $0.id == value.activeFrameID })!
            let affected = value.frames[index].elements.filter { selection.contains($0.id) }
            for element in affected {
                guard let layer = value.layers.first(where: { $0.id == element.layerID }), layer.visible, !layer.isFullyLocked else { throw StudioDocumentError.locked }
            }
            value.frames[index].elements.removeAll { selection.contains($0.id) }
        }
        selectedElementIDs.removeAll()
    }
    mutating func addLayer() throws {
        try change { value in
            let layer = CanvasLayer(id: UUID().uuidString, name: "Layer \(value.layers.count + 1)")
            value.layers.insert(layer, at: 0); value.activeLayerID = layer.id
        }
    }
    mutating func updateLayer(_ id: String, _ operation: (inout CanvasLayer) throws -> Void) throws {
        try change { value in
            guard let index = value.layers.firstIndex(where: { $0.id == id }) else { throw StudioDocumentError.invalid("The layer is unavailable.") }
            try operation(&value.layers[index])
        }
    }
    mutating func duplicateLayer(_ id: String) throws {
        try change { value in
            guard let index = value.layers.firstIndex(where: { $0.id == id }) else { return }
            guard !value.frames.contains(where: { $0.rasterLayerID == id }) else {
                throw StudioDocumentError.unavailable("Duplicating a flattened imported image layer is unfinished. Its original has not changed.")
            }
            let original = value.layers[index]
            let layer = CanvasLayer(id: UUID().uuidString, name: String((original.name + " Copy").prefix(120)), visible: original.visible,
                                    locked: original.locked, opacity: original.opacity, lockMode: original.lockMode,
                                    blendMode: original.blendMode, glowEnabled: original.glowEnabled, glowColor: original.glowColor, colorLabel: original.colorLabel)
            value.layers.insert(layer, at: index); value.activeLayerID = layer.id
            for frameIndex in value.frames.indices {
                let copies = value.frames[frameIndex].elements.filter { $0.layerID == id }.map { element in
                    DrawnElement(id: UUID().uuidString, tool: element.tool, points: element.points, color: element.color,
                                 width: element.width, opacity: element.opacity, fillColor: element.fillColor, layerID: layer.id)
                }
                value.frames[frameIndex].elements.append(contentsOf: copies)
            }
        }
    }
    mutating func moveLayer(_ id: String, offset: Int) throws {
        try change { value in
            guard let index = value.layers.firstIndex(where: { $0.id == id }), value.layers.indices.contains(index + offset) else { return }
            value.layers.swapAt(index, index + offset)
        }
    }
    mutating func undo() {
        guard var previous = undoDocuments.popLast() else { return }
        redoDocuments.append(document); previous.revision = document.revision + 1; previous.modifiedAt = Date()
        document = previous; selectedElementIDs.removeAll()
    }
    mutating func redo() {
        guard var next = redoDocuments.popLast() else { return }
        undoDocuments.append(document); next.revision = document.revision + 1; next.modifiedAt = Date()
        document = next; selectedElementIDs.removeAll()
    }
    private mutating func trimHistory() {
        func cost(_ value: StudioDocument) -> Int {
            value.frames.reduce(0) { sum, frame in sum + frame.elements.reduce(0) { $0 + 256 + $1.points.count * 40 } }
                + value.layers.count * 512 + value.audioClips.count * 512
        }
        var bytes = undoDocuments.reduce(0) { $0 + cost($1) }
        while undoDocuments.count > 50 || (bytes > 32 * 1024 * 1024 && undoDocuments.count > 1) {
            bytes -= cost(undoDocuments.removeFirst())
        }
    }
}
