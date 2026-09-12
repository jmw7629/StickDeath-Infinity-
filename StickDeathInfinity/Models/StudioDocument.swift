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
    var referencedRasterAssetIDs: Set<String> { Set(frames.compactMap(\.rasterAssetID)) }

    func validate() throws {
        guard (1...4).contains(schemaVersion) else { throw StudioDocumentError.invalid("This project version is not supported. The original has not been changed.") }
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
            if let rect = frame.rasterPlacement {
                guard schemaVersion >= 3, let asset = frame.rasterAssetID, !asset.isEmpty, asset.utf8.count <= 120,
                      rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite,
                      rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
                      rect.x + rect.width <= Double(width) + 0.000001,
                      rect.y + rect.height <= Double(height) + 0.000001 else {
                    throw StudioDocumentError.invalid("An imported still has invalid placement or document version.")
                }
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
            guard clip.sourceOffset.isFinite, clip.sourceOffset >= 0, clip.sourceOffset <= 300,
                  (clip.sourceOffset + clip.duration).isFinite,
                  (clip.sourceOffset == 0 && !clip.isMuted) || schemaVersion >= 4 else {
                throw StudioDocumentError.invalid("An audio clip has invalid source timing or unsupported edit metadata.")
            }
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
        try StudioBrushGeometryCache.validate(document: self)
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
    var referencedRasterAssetIDsIncludingHistoryAndClipboard: Set<String> {
        var ids = (undoDocuments + redoDocuments).reduce(into: document.referencedRasterAssetIDs) { $0.formUnion($1.referencedRasterAssetIDs) }
        if let id = clipboard?.rasterAssetID { ids.insert(id) }
        return ids
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
            if element.brush != nil { value.schemaVersion = max(value.schemaVersion, 2) }
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
                             width: element.width, opacity: element.opacity, fillColor: element.fillColor, layerID: element.layerID,
                             brush: element.brush)
            }
            let frame = AnimationFrame(id: UUID().uuidString, elements: elements, rasterAssetID: source.rasterAssetID, rasterLayerID: source.rasterLayerID, rasterPlacement: source.rasterPlacement)
            value.frames.insert(frame, at: index + 1); value.activeFrameID = frame.id
            if elements.contains(where: { $0.brush != nil }) { value.schemaVersion = max(value.schemaVersion, 2) }
            if source.rasterPlacement != nil { value.schemaVersion = max(value.schemaVersion, 3) }
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
                                 width: element.width, opacity: element.opacity, fillColor: element.fillColor, layerID: layer.id,
                                 brush: element.brush)
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

/// Bounded cache of immutable, validated brush geometry. Keys retain the full
/// element for equality checking, so reused IDs or hash collisions cannot reuse
/// another drawing's marks. Sample/key storage is included in the byte budget.
enum StudioBrushGeometryCache {
    static let maximumStrokePoints = 8_192
    static let maximumStrokeMarks = 32_768
    static let maximumFrameMarks = 131_072
    static let maximumDocumentMarks = 262_144
    static let maximumDocumentPoints = 100_000
    static let maximumDocumentElements = 2_048
    static let maximumCacheBytes = 24 * 1024 * 1024
    static let maximumCacheEntries = 2_048
    private struct Entry {
        let element: DrawnElement
        let geometry: StudioBrushRenderer.Geometry
        let bytes: Int
        var used: UInt64
    }
    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]
    private static var bytes = 0
    private static var clock: UInt64 = 0

    static var footprint: (entries: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (entries.count, bytes)
    }

    static func color(_ hex: String) throws -> StudioBrushColor {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.utf8.count == 6,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let rgb = UInt32(value, radix: 16) else {
            throw StudioBrushError.invalidSettings("This brush requires a valid RGB color.")
        }
        return StudioBrushColor(red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    static func geometry(for element: DrawnElement) throws -> StudioBrushRenderer.Geometry {
        guard let brush = element.brush else { throw StudioBrushError.invalidSettings("This drawing uses the historical renderer.") }
        guard !element.id.isEmpty, element.id.utf8.count <= 120,
              [.pencil, .pen, .brush, .marker, .crayon].contains(element.tool),
              element.points.count <= maximumStrokePoints, element.fillColor == nil,
              (element.layerID?.utf8.count ?? 0) <= 120 else {
            throw StudioBrushError.workLimit("This brush stroke exceeds the 8,192 sample limit or has an unsupported identity/tool. Draw a shorter stroke.")
        }
        let settings = try brush.settings(width: element.width, opacity: element.opacity)
        _ = try color(element.color)
        lock.lock()
        if var hit = entries[element.id], hit.element == element {
            clock &+= 1; hit.used = clock; entries[element.id] = hit
            lock.unlock(); return hit.geometry
        }
        lock.unlock()
        // Validation is synchronous and deterministic. Callers owning async jobs
        // check cancellation around this bounded operation, never during drawing.
        let result = try StudioBrushRenderer.geometry(points: element.points, settings: settings, seed: brush.seed,
            checkCancellation: {})
        guard result.marks.count <= maximumStrokeMarks else {
            throw StudioBrushError.workLimit("This stroke exceeds the 32,768 brush mark limit. Increase size, reduce texture, or draw a shorter stroke.")
        }
        let cost = result.marks.count * MemoryLayout<StudioBrushRenderer.Mark>.stride
            + element.points.count * MemoryLayout<StrokePoint>.stride
            + element.id.utf8.count + element.color.utf8.count + (element.layerID?.utf8.count ?? 0) + 1024
        guard cost <= maximumCacheBytes else { throw StudioBrushError.workLimit("This brush stroke exceeds the rendering memory budget.") }
        lock.lock(); defer { lock.unlock() }
        if let prior = entries.removeValue(forKey: element.id) { bytes -= prior.bytes }
        while bytes + cost > maximumCacheBytes || entries.count >= maximumCacheEntries {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used }) else { break }
            bytes -= oldest.value.bytes; entries.removeValue(forKey: oldest.key)
        }
        clock &+= 1
        entries[element.id] = Entry(element: element, geometry: result, bytes: cost, used: clock)
        bytes += cost
        return result
    }

    static func validate(document: StudioDocument) throws {
        var marks = 0, points = 0, elements = 0
        for frame in document.frames {
            var frameMarks = 0
            for element in frame.elements where element.brush != nil {
                elements += 1
                guard elements <= maximumDocumentElements else {
                    throw StudioBrushError.workLimit("This project exceeds 2,048 styled brush elements. Undo or remove selected content before adding more.")
                }
                guard (2...4).contains(document.schemaVersion) else {
                    throw StudioBrushError.invalidSettings("Brush documents require version 2. The original project has not changed.")
                }
                points += element.points.count
                guard points <= maximumDocumentPoints else {
                    throw StudioBrushError.workLimit("This project exceeds 100,000 styled brush samples. Undo or remove selected content before adding more.")
                }
                let count = try geometry(for: element).marks.count
                frameMarks += count; marks += count
                guard frameMarks <= maximumFrameMarks, marks <= maximumDocumentMarks else {
                    throw StudioBrushError.workLimit("This project exceeds its brush rendering budget (131,072 marks per frame; 262,144 per project). Undo or remove selected content before adding more.")
                }
            }
        }
    }
}
