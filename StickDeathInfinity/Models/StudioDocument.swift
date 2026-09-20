import Foundation

/// Editable Studio content. CanvasLayer is the sole layer identity and ordering model.
struct StudioDocument: Codable, Equatable {
    static let supportedSchemaVersions = 1...14
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
    // Additive metadata: older documents decode with no muted tracks. Keep
    // per-clip mute independent so a track toggle never destroys that choice.
    var mutedAudioTracks: [Int]?
    // Four numbered bus levels, independent of each clip's own gain/mute.
    // Absent in historical projects means unity gain on every track.
    var audioTrackVolumes: [Double]?
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
    func isAudioTrackMuted(_ track: Int) -> Bool { mutedAudioTracks?.contains(track) == true }
    func audioTrackVolume(_ track: Int) -> Double {
        guard (1...4).contains(track), let audioTrackVolumes, audioTrackVolumes.count == 4 else { return 1 }
        return audioTrackVolumes[track - 1]
    }
    var referencedRasterAssetIDs: Set<String> { Set(frames.compactMap(\.rasterAssetID)) }

    func validate() throws {
        guard Self.supportedSchemaVersions.contains(schemaVersion) else { throw StudioDocumentError.invalid("This project version is not supported. The original has not been changed.") }
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
        var fillSpanCount = 0
        var eraserCount = 0; var eraserSamples = 0
        var textBytes = 0
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
            guard frame.elements.filter({ $0.eraser != nil }).count <= 256 else {
                throw StudioDocumentError.invalid("This frame exceeds the 256 styled eraser stroke limit.")
            }
            guard frame.elements.filter({ $0.text != nil }).count <= 256 else {
                throw StudioDocumentError.invalid("This frame exceeds its 256 text-box limit.")
            }
            for element in frame.elements {
                if let transform = element.transform {
                    guard schemaVersion >= 11 else { throw StudioDocumentError.invalid("Transformed drawings require project version 11.") }
                    try transform.validate()
                }
                if let text = element.text {
                    guard schemaVersion >= 10 else { throw StudioTextDescriptor.Failure.invalid }
                    try text.validate(element: element)
                    textBytes += text.content.utf8.count
                    guard textBytes <= 262_144 else { throw StudioDocumentError.invalid("This project exceeds its editable text budget.") }
                }
                if let eraser = element.eraser {
                    guard schemaVersion >= 9 else { throw StudioDocumentError.invalid("Styled erasers require project version9. The original has not changed.") }
                    try eraser.validate(element: element)
                    eraserCount += 1; eraserSamples += element.points.count
                    guard eraserCount <= 1_024, eraserSamples <= 65_536 else {
                        throw StudioDocumentError.invalid("This project exceeds its styled eraser rendering budget.")
                    }
                }
                if let reflection = element.reflection {
                    guard schemaVersion >= 8 else { throw StudioDocumentError.invalid("Reflected artwork requires a newer project version. The original has not changed.") }
                    try reflection.validate()
                }
                if let translation = element.translation {
                    guard schemaVersion >= 7 else { throw StudioDocumentError.invalid("Moved artwork requires a newer project version. The original has not changed.") }
                    try translation.validate()
                }
                if let mask = element.fillMask {
                    guard schemaVersion >= 6, element.tool == .fill, element.brush == nil, element.shape == nil,
                          mask.width == width, mask.height == height, element.points.count == 2 else {
                        throw StudioFillMask.Failure.invalid
                    }
                    try mask.validate()
                    try StudioShapeDescriptor(fillColor: element.color).validate(tool: .rectangle)
                    guard mask.spans.count <= StudioFillMask.maximumDocumentSpans - fillSpanCount else {
                        throw StudioFillMask.Failure.invalid
                    }
                    fillSpanCount += mask.spans.count
                }
                if let shape = element.shape {
                    guard schemaVersion >= 5, element.brush == nil, element.points.count == 2 else {
                        throw StudioShapeDescriptor.Failure.invalid
                    }
                    try shape.validate(tool: element.tool)
                }
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
        if let mutedAudioTracks {
            guard schemaVersion >= 12, mutedAudioTracks.count <= 4,
                  mutedAudioTracks.allSatisfy({ (1...4).contains($0) }),
                  mutedAudioTracks == Array(Set(mutedAudioTracks)).sorted() else {
                throw StudioDocumentError.invalid("Audio track mute settings are invalid or need a newer project version.")
            }
        }
        if let audioTrackVolumes {
            guard schemaVersion >= 13, audioTrackVolumes.count == 4,
                  audioTrackVolumes.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw StudioDocumentError.invalid("Audio track volumes are invalid or need a newer project version.")
            }
        }
        guard Set(audioClips.map(\.id)).count == audioClips.count else { throw StudioDocumentError.invalid("Audio clip identities are invalid.") }
        guard audioClips.filter({ $0.assetID != nil }).count <= 128 else { throw StudioDocumentError.invalid("This project exceeds the 128 imported audio clip limit.") }
        for clip in audioClips {
            if let envelope = clip.fadeEnvelope {
                guard schemaVersion >= 14, clip.assetID != nil else {
                    throw StudioDocumentError.invalid("Audio fades require managed audio and project version14.")
                }
                try envelope.validate()
            }
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
    private enum Clipboard { case frame(AnimationFrame), elements([DrawnElement]) }
    private var clipboard: Clipboard?
    private(set) var clipboardVersion = UUID()
    var selectedElementIDs = Set<String>()
    var canUndo: Bool { !undoDocuments.isEmpty }
    var canRedo: Bool { !redoDocuments.isEmpty }
    var canPaste: Bool { clipboard != nil }
    var clipboardElements: [DrawnElement]? {
        guard case .elements(let values) = clipboard else { return nil }
        return values
    }
    var clipboardElementCount: Int { clipboardElements?.count ?? 0 }
    /// Preserve staged clipboard changes when a typed batch is coalesced into
    /// one document/history edit. This never imports another project's files.
    mutating func adoptClipboard(from source: Self) throws {
        guard source.document.id == document.id else { throw StudioDocumentError.invalid("The clipboard belongs to another project.") }
        clipboard = source.clipboard; clipboardVersion = source.clipboardVersion
    }
    /// Asset lifetime follows the actual full-document history, never a mirror.
    var referencedAudioAssetIDsIncludingHistory: Set<UUID> {
        (undoDocuments + redoDocuments).reduce(into: document.referencedAudioAssetIDs) { $0.formUnion($1.referencedAudioAssetIDs) }
    }
    var referencedRasterAssetIDsIncludingHistoryAndClipboard: Set<String> {
        var ids = (undoDocuments + redoDocuments).reduce(into: document.referencedRasterAssetIDs) { $0.formUnion($1.referencedRasterAssetIDs) }
        if case .frame(let frame) = clipboard, let id = frame.rasterAssetID { ids.insert(id) }
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
        if element.tool == .eraser, !selectedElementIDs.isEmpty {
            throw StudioDocumentError.unavailable("Erasing within a selection is unfinished. Deselect before erasing the active layer; nothing changed.")
        }
        try change { value in
            guard let layer = value.layers.first(where: { $0.id == element.layerID }), layer.visible, !layer.isFullyLocked else { throw StudioDocumentError.locked }
            if element.tool == .eraser {
                guard layer.opacity > 0, layer.lockMode == "free" else { throw StudioDocumentError.locked }
            }
            guard layer.lockMode == "free" || layer.lockMode == "position" else {
                throw StudioDocumentError.unavailable("Alpha-lock painting is unfinished. Choose Free to draw; this layer has not changed.")
            }
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }) else { throw StudioDocumentError.invalid("The drawing frame is unavailable.") }
            value.frames[index].elements.append(element)
            if element.brush != nil { value.schemaVersion = max(value.schemaVersion, 2) }
            if element.shape != nil { value.schemaVersion = max(value.schemaVersion, 5) }
            if element.fillMask != nil { value.schemaVersion = max(value.schemaVersion, 6) }
            if element.translation != nil { value.schemaVersion = max(value.schemaVersion, 7) }
            if element.reflection != nil { value.schemaVersion = max(value.schemaVersion, 8) }
            if element.eraser != nil { value.schemaVersion = max(value.schemaVersion, 9) }
            if element.text != nil { value.schemaVersion = max(value.schemaVersion, 10) }
            if element.transform != nil { value.schemaVersion = max(value.schemaVersion, 11) }
        }
    }
    mutating func updateText(frameID: String, elementID: String, text: StudioTextDescriptor, color: String, opacity: Double) throws {
        try change { value in
            guard let fi = value.frames.firstIndex(where: { $0.id == frameID }),
                  let ei = value.frames[fi].elements.firstIndex(where: { $0.id == elementID }),
                  value.frames[fi].elements[ei].tool == .text,
                  value.frames[fi].elements[ei].text != nil else { throw StudioTextDescriptor.Failure.invalid }
            let original = value.frames[fi].elements[ei]
            guard let layer = value.layers.first(where: { $0.id == original.layerID }),
                  layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { throw StudioDocumentError.locked }
            value.frames[fi].elements[ei].text = text
            value.frames[fi].elements[ei].color = color
            value.frames[fi].elements[ei].opacity = opacity
        }
    }
    mutating func addFrame() throws {
        try change { value in
            let index = value.frames.firstIndex(where: { $0.id == value.activeFrameID })!
            let frame = AnimationFrame(id: UUID().uuidString, elements: [])
            value.frames.insert(frame, at: index + 1); value.activeFrameID = frame.id
        }
    }
    mutating func copyFrame() {
        if let frame = document.frames.first(where: { $0.id == document.activeFrameID }) { clipboard = .frame(frame); clipboardVersion = UUID() }
    }
    mutating func pasteFrame() throws {
        guard case .frame(let source) = clipboard else { return }
        try insertCopy(source)
    }
    /// The selection clipboard is an immutable, bounded snapshot. Copy changes
    /// neither document revision nor undo history and never uses the OS clipboard.
    mutating func copyElements(frameID: String, ids: Set<String>,
                              checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        guard !ids.isEmpty, ids.count <= 1024,
              let frame = document.frames.first(where: { $0.id == frameID }),
              ids.isSubset(of: Set(frame.elements.map(\.id))) else {
            throw StudioDocumentError.invalid("Select between 1 and 1,024 existing drawings before copying.")
        }
        try checkCancellation()
        var values: [DrawnElement] = [], points = 0, bytes = 0
        // Flatten the selected drawings in the same back-to-front order as the
        // canonical renderer; paste uses the destination layer's own appearance.
        for layer in document.layers.reversed() {
            for element in frame.elements where ids.contains(element.id) && element.layerID == layer.id {
                try checkCancellation()
                guard layer.visible, layer.opacity > 0, !layer.isFullyLocked else { throw StudioDocumentError.locked }
                guard element.points.count <= 65_536 - points else {
                    throw StudioDocumentError.unavailable("Copy is limited to 65,536 drawing points. Copy a smaller selection.")
                }
                points += element.points.count
                let geometryCost = element.points.count * 40 + (element.fillMask?.spans.count ?? 0) * MemoryLayout<StudioFillMask.Span>.stride
                let identityCost = element.id.utf8.count + element.color.utf8.count + (element.layerID?.utf8.count ?? 0)
                let textCost = element.text?.content.utf8.count ?? 0
                let cost = 1024 + geometryCost + identityCost + textCost
                guard cost <= 8 * 1024 * 1024 - bytes else {
                    throw StudioDocumentError.unavailable("The drawing clipboard is limited to 8 MB. Copy a smaller selection.")
                }
                bytes += cost; values.append(element)
            }
        }
        guard values.count == ids.count else { throw StudioDocumentError.invalid("The selected drawings are unavailable.") }
        try checkCancellation()
        clipboard = .elements(values)
        clipboardVersion = UUID()
    }
    @discardableResult
    mutating func pasteElements(frameID: String, layerID: String,
                               checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Set<String> {
        guard let source = clipboardElements, !source.isEmpty else {
            throw StudioDocumentError.unavailable("Copy selected drawings before pasting artwork.")
        }
        try checkCancellation()
        var ids = Set<String>()
        try change { value in
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }),
                  let layer = value.layers.first(where: { $0.id == layerID }) else {
                throw StudioDocumentError.invalid("The paste destination is unavailable. Nothing changed.")
            }
            guard layer.visible, layer.opacity > 0, !layer.isFullyLocked,
                  layer.lockMode == "free" || layer.lockMode == "position" else { throw StudioDocumentError.locked }
            guard source.count <= 20_000 - value.frames[index].elements.count else {
                throw StudioDocumentError.invalid("This paste exceeds the frame's drawing limit.")
            }
            for element in source {
                try checkCancellation()
                let id = UUID().uuidString
                value.frames[index].elements.append(DrawnElement(id: id, tool: element.tool, points: element.points,
                    color: element.color, width: element.width, opacity: element.opacity, fillColor: element.fillColor,
                    layerID: layerID, brush: element.brush, shape: element.shape, fillMask: element.fillMask,
                    translation: element.translation, reflection: element.reflection, eraser: element.eraser, text: element.text, transform: element.transform))
                ids.insert(id)
                if element.brush != nil { value.schemaVersion = max(value.schemaVersion, 2) }
                if element.shape != nil { value.schemaVersion = max(value.schemaVersion, 5) }
                if element.fillMask != nil { value.schemaVersion = max(value.schemaVersion, 6) }
                if element.translation != nil { value.schemaVersion = max(value.schemaVersion, 7) }
                if element.reflection != nil { value.schemaVersion = max(value.schemaVersion, 8) }
                if element.eraser != nil { value.schemaVersion = max(value.schemaVersion, 9) }
                if element.text != nil { value.schemaVersion = max(value.schemaVersion, 10) }
                if element.transform != nil { value.schemaVersion = max(value.schemaVersion, 11) }
            }
            try checkCancellation()
        }
        return ids
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
                             brush: element.brush, shape: element.shape, fillMask: element.fillMask, translation: element.translation, reflection: element.reflection, eraser: element.eraser, text: element.text, transform: element.transform)
            }
            let frame = AnimationFrame(id: UUID().uuidString, elements: elements, rasterAssetID: source.rasterAssetID, rasterLayerID: source.rasterLayerID, rasterPlacement: source.rasterPlacement)
            value.frames.insert(frame, at: index + 1); value.activeFrameID = frame.id
            if elements.contains(where: { $0.brush != nil }) { value.schemaVersion = max(value.schemaVersion, 2) }
            if elements.contains(where: { $0.shape != nil }) { value.schemaVersion = max(value.schemaVersion, 5) }
            if elements.contains(where: { $0.fillMask != nil }) { value.schemaVersion = max(value.schemaVersion, 6) }
            if elements.contains(where: { $0.translation != nil }) { value.schemaVersion = max(value.schemaVersion, 7) }
            if elements.contains(where: { $0.reflection != nil }) { value.schemaVersion = max(value.schemaVersion, 8) }
            if elements.contains(where: { $0.eraser != nil }) { value.schemaVersion = max(value.schemaVersion, 9) }
            if elements.contains(where: { $0.text != nil }) { value.schemaVersion = max(value.schemaVersion, 10) }
            if elements.contains(where: { $0.transform != nil }) { value.schemaVersion = max(value.schemaVersion, 11) }
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
    /// One reversible edit; original geometry and fill pixels are never cropped.
    /// Placement edits retain the immutable image identity and original bytes.
    /// Historical full-canvas raster records are deliberately not converted here.
    mutating func deleteImage(frameID: String, assetID: String,
                              checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        try change { value in
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }),
                  value.frames[index].rasterAssetID == assetID,
                  value.frames[index].rasterPlacement != nil else {
                throw StudioDocumentError.invalid("The selected image is unavailable. Nothing changed.")
            }
            guard let layer = value.layers.first(where: { $0.id == value.frames[index].rasterLayerID }),
                  layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else {
                throw StudioDocumentError.locked
            }
            try checkCancellation()
            // Only this explicit managed picture reference is removed. Keep
            // frame/layer identity, drawings, other frames and immutable assets.
            value.frames[index].rasterAssetID = nil
            value.frames[index].rasterLayerID = nil
            value.frames[index].rasterPlacement = nil
            try checkCancellation()
        }
    }

    mutating func updateImagePlacement(frameID: String, assetID: String,
                                      placement: StudioRasterPlacement,
                                      checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        try change { value in
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }),
                  value.frames[index].rasterAssetID == assetID,
                  value.frames[index].rasterPlacement != nil else {
                throw StudioDocumentError.invalid("The selected image is unavailable. Nothing changed.")
            }
            guard let layer = value.layers.first(where: { $0.id == value.frames[index].rasterLayerID }),
                  layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else {
                throw StudioDocumentError.locked
            }
            try checkCancellation()
            value.frames[index].rasterPlacement = placement
            // change validates the full document before a single history commit.
        }
    }

    mutating func translateElements(frameID: String, ids: Set<String>, dx: Double, dy: Double,
                                   checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        guard !ids.isEmpty, ids.count <= 1024 else { throw StudioDocumentError.invalid("Select between 1 and 1,024 drawing elements before moving artwork.") }
        try StudioElementTranslation(x: dx, y: dy).validate()
        try checkCancellation()
        try change { value in
            guard let frame = value.frames.firstIndex(where: { $0.id == frameID }) else { throw StudioDocumentError.invalid("The selected frame is unavailable. Nothing moved.") }
            let existing = Set(value.frames[frame].elements.map(\.id))
            guard ids.isSubset(of: existing) else { throw StudioDocumentError.invalid("The selection contains unavailable artwork. Nothing moved.") }
            for index in value.frames[frame].elements.indices where ids.contains(value.frames[frame].elements[index].id) {
                try checkCancellation()
                let element = value.frames[frame].elements[index]
                guard let layer = value.layers.first(where: { $0.id == element.layerID }), layer.visible,
                      !layer.isFullyLocked, layer.lockMode == "free" else { throw StudioDocumentError.locked }
                if dx == 0 && dy == 0 { continue }
                if let prior = element.transform {
                    let moved = StudioElementTransform(tx: dx, ty: dy).after(prior)
                    try moved.validate(); value.frames[frame].elements[index].transform = moved
                    continue
                }
                let moved = StudioElementTranslation(x: (element.translation?.x ?? 0) + dx,
                                                     y: (element.translation?.y ?? 0) + dy)
                try moved.validate()
                value.frames[frame].elements[index].translation = moved.x == 0 && moved.y == 0 ? nil : moved
                value.schemaVersion = max(value.schemaVersion, 7)
            }
            try checkCancellation()
        }
    }
    /// Scale/rotate around the explicit group's current world-space center.
    /// One change stages every member before validation/history commit.
    mutating func transformElements(frameID: String, ids: Set<String>, scaleX: Double, scaleY: Double, rotation: Double,
                                   checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        guard !ids.isEmpty, ids.count <= 1024 else { throw StudioDocumentError.invalid("Select 1–1,024 drawings or text boxes before transforming.") }
        try checkCancellation()
        try change { value in
            guard let fi=value.frames.firstIndex(where:{$0.id==frameID}),
                  ids.isSubset(of:Set(value.frames[fi].elements.map(\.id))) else { throw StudioDocumentError.invalid("The selected artwork is unavailable. Nothing changed.") }
            var bounds=CGRect.null
            var selectedBounds: [String: CGRect] = [:]
            for e in value.frames[fi].elements where ids.contains(e.id) {
                try checkCancellation()
                guard let layer=value.layers.first(where:{$0.id==e.layerID}),layer.visible,layer.opacity>0,
                      !layer.isFullyLocked,layer.lockMode=="free" else { throw StudioDocumentError.locked }
                guard e.tool != .eraser else { throw StudioDocumentError.unavailable("Select drawings or text without eraser masks before transforming.") }
                let rect: CGRect?
                if e.brush != nil {
                    var r=try StudioBrushGeometryCache.geometry(for:e).bounds
                    if e.reflection?.horizontal == true { r.origin.x = -r.maxX }
                    if e.reflection?.vertical == true { r.origin.y = -r.maxY }
                    r=r.offsetBy(dx:e.translation?.x ?? 0,dy:e.translation?.y ?? 0)
                    rect=e.transform?.bounds(r) ?? r
                } else { rect=e.selectionBounds }
                guard let rect,!rect.isNull,rect.width>0,rect.height>0,
                      [rect.minX,rect.maxX,rect.minY,rect.maxY].allSatisfy({$0.isFinite && abs($0)<=100_000}) else {
                    throw StudioDocumentError.invalid("The selected artwork has unsupported transform bounds.")
                }
                selectedBounds[e.id] = rect
                bounds=bounds.union(rect)
            }
            let operation=try StudioElementTransform.scaleRotation(x:scaleX,y:scaleY,degrees:rotation,
                center:CGPoint(x:bounds.midX,y:bounds.midY))
            if scaleX==1 && scaleY==1 && rotation==0 { return }
            for i in value.frames[fi].elements.indices where ids.contains(value.frames[fi].elements[i].id) {
                try checkCancellation()
                let element = value.frames[fi].elements[i]
                guard let before = selectedBounds[element.id] else { throw StudioDocumentError.invalid("The selected artwork changed. Nothing changed.") }
                let after = operation.bounds(before)
                guard [after.minX, after.maxX, after.minY, after.maxY].allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else {
                    throw StudioElementTransform.Failure.limits
                }
                let transformed=operation.after(element.transform ?? .init())
                try transformed.validate();value.frames[fi].elements[i].transform=transformed
            }
            value.schemaVersion=max(value.schemaVersion,11);try checkCancellation()
        }
    }
    /// Reflect the group around its combined document-space bounds. Original
    /// geometry, IDs, ordering and fill masks remain unchanged.
    mutating func reflectElements(frameID: String, ids: Set<String>, axis: StudioReflectionAxis,
                                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        guard !ids.isEmpty, ids.count <= 1024 else { throw StudioDocumentError.invalid("Select between 1 and 1,024 drawing elements before flipping artwork.") }
        try checkCancellation()
        try change { value in
            guard let frame = value.frames.firstIndex(where: { $0.id == frameID }) else { throw StudioDocumentError.invalid("The selected frame or artwork is unavailable. Nothing flipped.") }
            let elements = value.frames[frame].elements
            guard ids.isSubset(of: Set(elements.map(\.id))) else { throw StudioDocumentError.invalid("The selected frame or artwork is unavailable. Nothing flipped.") }
            var bounds = CGRect.null
            for element in elements where ids.contains(element.id) {
                try checkCancellation()
                guard let layer = value.layers.first(where: { $0.id == element.layerID }), layer.visible, layer.opacity > 0,
                      !layer.isFullyLocked, layer.lockMode == "free" else { throw StudioDocumentError.locked }
                guard let rect = element.selectionBounds, !rect.isNull,
                      rect.minX.isFinite, rect.maxX.isFinite, rect.minY.isFinite, rect.maxY.isFinite else {
                    throw StudioDocumentError.invalid("The selected artwork has invalid reflection bounds.")
                }
                bounds = bounds.union(rect)
            }
            guard !bounds.isNull else { throw StudioDocumentError.invalid("Select between 1 and 1,024 drawing elements before flipping artwork.") }
            for index in elements.indices where ids.contains(elements[index].id) {
                try checkCancellation()
                if let prior = elements[index].transform {
                    let flip = axis == .horizontal
                        ? StudioElementTransform(a: -1, tx: bounds.minX+bounds.maxX)
                        : StudioElementTransform(d: -1, ty: bounds.minY+bounds.maxY)
                    let transformed = flip.after(prior); try transformed.validate()
                    value.frames[frame].elements[index].transform = transformed
                    continue
                }
                var translation = elements[index].translation ?? .init(x: 0, y: 0)
                var reflection = elements[index].reflection ?? .init()
                switch axis {
                case .horizontal: translation.x = bounds.minX + bounds.maxX - translation.x; reflection.horizontal.toggle()
                case .vertical: translation.y = bounds.minY + bounds.maxY - translation.y; reflection.vertical.toggle()
                }
                try translation.validate()
                value.frames[frame].elements[index].translation = translation.x == 0 && translation.y == 0 ? nil : translation
                value.frames[frame].elements[index].reflection = reflection.horizontal || reflection.vertical ? reflection : nil
            }
            value.schemaVersion = max(value.schemaVersion, 8)
            try checkCancellation()
        }
    }
    /// Move each explicitly selected element by one unselected neighbor within
    /// its own layer. Relative selection order and layer stacking stay intact.
    mutating func orderElements(frameID: String, ids: Set<String>, forward: Bool,
                               checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        guard !ids.isEmpty, ids.count <= 1024 else { throw StudioDocumentError.invalid("Select between 1 and 1,024 drawing elements before changing their order.") }
        try checkCancellation()
        try change { value in
            guard let frame = value.frames.firstIndex(where: { $0.id == frameID }) else { throw StudioDocumentError.invalid("The selected frame or artwork is unavailable. Its order has not changed.") }
            let elements = value.frames[frame].elements
            guard ids.isSubset(of: Set(elements.map(\.id))) else { throw StudioDocumentError.invalid("The selected frame or artwork is unavailable. Its order has not changed.") }
            let selected = elements.filter { ids.contains($0.id) }
            guard selected.allSatisfy({ $0.layerID != nil }) else { throw StudioDocumentError.invalid("The selected frame or artwork is unavailable. Its order has not changed.") }
            let layerIDs = Set(selected.compactMap(\.layerID))
            for id in layerIDs {
                try checkCancellation()
                guard let layer = value.layers.first(where: { $0.id == id }), layer.visible, layer.opacity > 0,
                      !layer.isFullyLocked, layer.lockMode == "free" else { throw StudioDocumentError.locked }
            }
            var positions: [String: [Int]] = [:]
            for index in elements.indices {
                try checkCancellation()
                if let layer = elements[index].layerID, layerIDs.contains(layer) { positions[layer, default: []].append(index) }
            }
            for layer in value.layers where layerIDs.contains(layer.id) {
                let indices = positions[layer.id] ?? []
                guard indices.count > 1 else { continue }
                let order = forward ? Array((0..<(indices.count - 1)).reversed()) : Array(1..<indices.count)
                for position in order {
                    try checkCancellation()
                    let current = indices[position], neighbor = indices[position + (forward ? 1 : -1)]
                    if ids.contains(value.frames[frame].elements[current].id),
                       !ids.contains(value.frames[frame].elements[neighbor].id) {
                        value.frames[frame].elements.swapAt(current, neighbor)
                    }
                }
            }
            try checkCancellation()
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
    /// An explicit layer target removes only its content across frames. Original
    /// raster references remain in full-document Undo/Redo and clipboard history.
    mutating func deleteLayer(_ id: String, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try change { value in
            try checkCancellation()
            guard let index = value.layers.firstIndex(where: { $0.id == id }) else {
                throw StudioDocumentError.invalid("The selected layer is unavailable. Nothing was deleted.")
            }
            guard value.layers.count > 1 else {
                throw StudioDocumentError.unavailable("The last layer cannot be deleted. Nothing changed.")
            }
            let layer = value.layers[index]
            guard !layer.isFullyLocked, layer.lockMode == "free" else { throw StudioDocumentError.locked }
            for frame in value.frames.indices {
                try checkCancellation()
                value.frames[frame].elements.removeAll { $0.layerID == id }
                if value.frames[frame].rasterLayerID == id {
                    value.frames[frame].rasterAssetID = nil
                    value.frames[frame].rasterLayerID = nil
                    value.frames[frame].rasterPlacement = nil
                }
            }
            value.layers.remove(at: index)
            if value.activeLayerID == id {
                value.activeLayerID = value.layers[min(index, value.layers.count - 1)].id
            }
            try checkCancellation()
        }
        let remaining = Set(document.frames.first { $0.id == document.activeFrameID }!.elements.map(\.id))
        selectedElementIDs.formIntersection(remaining)
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
                                 brush: element.brush, shape: element.shape, fillMask: element.fillMask, translation: element.translation, reflection: element.reflection, eraser: element.eraser, text: element.text, transform: element.transform)
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
            var bytes = value.layers.count * 512 + value.audioClips.count * 512
            for frame in value.frames {
                for element in frame.elements {
                    bytes += 256 + element.points.count * 40
                    if let mask = element.fillMask {
                        bytes += mask.spans.count * MemoryLayout<StudioFillMask.Span>.stride
                    }
                }
            }
            return bytes
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
        // Translation is applied by the shared renderer after geometry creation.
        // Keep the same deterministic geometry in cache throughout a drag.
        var geometryElement = element; geometryElement.translation = nil; geometryElement.reflection = nil; geometryElement.transform = nil
        lock.lock()
        if var hit = entries[element.id], hit.element == geometryElement {
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
        entries[element.id] = Entry(element: geometryElement, geometry: result, bytes: cost, used: clock)
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
                guard document.schemaVersion >= 2, StudioDocument.supportedSchemaVersions.contains(document.schemaVersion) else {
                    throw StudioBrushError.invalidSettings("Styled brushes require a supported project format, version 2 or later. The original project has not changed.")
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
