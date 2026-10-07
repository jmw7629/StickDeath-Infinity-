import Foundation

/// Editable Studio content. CanvasLayer is the sole layer identity and ordering model.
struct StudioDocument: Codable, Equatable {
    static let supportedSchemaVersions = 1...27
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
    var gridSettings: StudioGridSettings?
    var onionEnabled = false
    var onionSettings: StudioOnionSettings?
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

    /// Preserve every editable setting while allocating a new project identity.
    func duplicated(name: String, id: UUID = UUID(), date: Date = Date()) throws -> Self {
        let copy = Self(schemaVersion: schemaVersion, id: id, name: name,
            width: width, height: height, fps: fps, frames: frames, layers: layers,
            activeFrameID: activeFrameID, activeLayerID: activeLayerID,
            audioClips: audioClips, mutedAudioTracks: mutedAudioTracks, audioTrackVolumes: audioTrackVolumes,
            gridEnabled: gridEnabled, gridSettings: gridSettings, onionEnabled: onionEnabled,
            onionSettings: onionSettings, createdAt: date, modifiedAt: date, revision: 0)
        try copy.validate()
        return copy
    }

    var totalTimelineTicks: Int { frames.reduce(0) { $0 + $1.durationTicks } }
    var durationSeconds: Double { Double(totalTimelineTicks) / Double(max(1, fps)) }
    func startTick(ofFrame index: Int) -> Int {
        frames.prefix(max(0, min(index, frames.count))).reduce(0) { $0 + $1.durationTicks }
    }
    func frameIndex(atTick tick: Int) -> Int {
        var remaining = max(0, tick)
        for (index, frame) in frames.enumerated() {
            if remaining < frame.durationTicks { return index }
            remaining -= frame.durationTicks
        }
        return max(0, frames.count - 1)
    }

    var onionGhosts: [StudioOnionGhost] {
        let settings = onionSettings ?? .init()
        guard onionEnabled, settings.isValid, let index = frames.firstIndex(where: { $0.id == activeFrameID }) else { return [] }
        var result: [StudioOnionGhost] = []
        for offset: Int in [-2, 2, -1, 1] {
            let requested = offset < 0 ? -offset <= settings.previousCount : offset <= settings.nextCount
            guard requested, frames.indices.contains(index + offset) else { continue }
            result.append(StudioOnionGhost(frame: frames[index + offset], opacity: settings.opacity / Double(abs(offset)), previous: offset < 0, tinted: settings.tinted))
        }
        return result
    }

    var referencedAudioAssetIDs: Set<UUID> { Set(audioClips.compactMap(\.assetID)) }
    func isAudioTrackMuted(_ track: Int) -> Bool { mutedAudioTracks?.contains(track) == true }
    func audioTrackVolume(_ track: Int) -> Double {
        guard (1...4).contains(track), let audioTrackVolumes, audioTrackVolumes.count == 4 else { return 1 }
        return audioTrackVolumes[track - 1]
    }
    var referencedRasterAssetIDs: Set<String> { Set(frames.compactMap(\.rasterAssetID)) }

    static func validatedProjectName(_ proposed: String) throws -> String {
        let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, title.utf8.count <= 480,
              title.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw StudioDocumentError.invalid("Use a project name of 1–120 characters without control characters.")
        }
        return title
    }

    func validate() throws {
        guard gridSettings?.isValid ?? true else { throw StudioDocumentError.invalid("Grid spacing must be 8–160 canvas points and opacity 5–60%.") }
        guard onionSettings?.isValid ?? true else { throw StudioDocumentError.invalid("Onion skin needs 0–2 frames on each side and 5–80% opacity.") }
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
        var effectCount = 0; var effectSamples = 0
        guard totalTimelineTicks <= fps * 3600 else { throw StudioDocumentError.invalid("Animation duration exceeds one hour.") }
        for frame in frames {
            if let hold = frame.holdTicks {
                guard schemaVersion >= 21, (2...600).contains(hold) else { throw StudioDocumentError.invalid("A frame exposure is invalid.") }
            }
            try StudioSmudgeDescriptor.validateFrame(frame, width: width, height: height)
            if let aliases = frame.rasterAliases, !aliases.isEmpty {
                guard schemaVersion >= 27, aliases.count <= 127, frame.rasterAssetID != nil else {
                    throw StudioDocumentError.invalid("Linked images require version 27 and at most 128 image layers.")
                }
            }
            if frame.rasterAssetID != nil {
                guard frame.rasterLayerID.map(layerIDs.contains) == true else { throw StudioDocumentError.invalid("An imported image has an invalid layer reference.") }
            } else {
                guard frame.rasterAliases?.isEmpty ?? true else { throw StudioDocumentError.invalid("Linked images have no source.") }
            }
            let instances = frame.rasterLayerInstances
            guard instances.count <= 128, Set(instances.map(\.layerID)).count == instances.count,
                  instances.allSatisfy({ layerIDs.contains($0.layerID) && ($0.placement == nil) == (frame.rasterPlacement == nil) }) else {
                throw StudioDocumentError.invalid("Linked images have duplicate or invalid layer ownership.")
            }
            // Validate orphan singular geometry too: legacy rejection is unchanged.
            let geometryInstances = instances.isEmpty ? [StudioRasterLayerInstance(layerID: frame.rasterLayerID ?? "",
                placement: frame.rasterPlacement, reflection: frame.rasterReflection,
                quarterTurns: frame.rasterQuarterTurns, crop: frame.rasterCrop)] : instances
            for instance in geometryInstances {
            if let rect = instance.placement {
                guard schemaVersion >= 3, let asset = frame.rasterAssetID, !asset.isEmpty, asset.utf8.count <= 120,
                      rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite,
                      rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
                      rect.x + rect.width <= Double(width) + 0.000001,
                      rect.y + rect.height <= Double(height) + 0.000001 else {
                    throw StudioDocumentError.invalid("An imported still has invalid placement or document version.")
                }
            }
            if let crop = instance.crop {
                guard schemaVersion >= 22, instance.placement != nil else {
                    throw StudioDocumentError.invalid("An image crop has invalid document metadata.")
                }
                try crop.validate()
            }
            if let turns = instance.quarterTurns {
                guard schemaVersion >= 16, instance.placement != nil, (1...3).contains(turns) else {
                    throw StudioDocumentError.invalid("An imported image has invalid rotation metadata. The original has not changed.")
                }
            }
            if let reflection = instance.reflection {
                guard schemaVersion >= 15, instance.placement != nil,
                      reflection.horizontal || reflection.vertical else {
                    throw StudioDocumentError.invalid("An imported image has invalid reflection metadata. The original has not changed.")
                }
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
                if let family = element.brush?.family, [.airbrush, .watercolor, .neon].contains(family) {
                    guard schemaVersion >= 25 else { throw StudioDocumentError.invalid("This brush family requires project version25.") }
                }
                if let preserveAlpha = element.preservesLayerAlpha {
                    guard schemaVersion >= 24, preserveAlpha, element.brush != nil,
                          [.pencil, .pen, .brush, .marker, .crayon].contains(element.tool),
                          element.eraser == nil, element.fillMask == nil, element.shape == nil,
                          element.text == nil, !element.hasPixelEffect else {
                        throw StudioDocumentError.invalid("Alpha-preserving paint requires a supported brush and project version24.")
                    }
                }
                if element.tool == .dodge || element.tool == .burn {
                    guard element.dodgeBurn != nil else { throw StudioDodgeBurn.Failure.invalidSettings }
                }
                if element.hasPixelEffect {
                    let required = element.dodgeBurn != nil ? 20 : (element.sharpen != nil ? 19 : (element.blur != nil ? 18 : 17))
                    guard schemaVersion >= required else { throw StudioDocumentError.invalid("This editable effect requires project version \(required).") }
                    effectCount += 1; effectSamples += element.points.count
                    guard effectCount <= 256, effectSamples <= 65_536 else { throw StudioSmudge.Failure.workLimit }
                }
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
                    if element.tool == .line { guard schemaVersion >= 26 else { throw StudioShapeDescriptor.Failure.invalid } }
                }
                guard !element.id.isEmpty, elementIDs.insert(element.id).inserted,
                      element.layerID.map(layerIDs.contains) == true,
                      element.width.isFinite, (0.1...1024).contains(element.width),
                      element.opacity.isFinite, (0...1).contains(element.opacity), element.points.count <= 100000 else {
                    throw StudioDocumentError.invalid("A drawing has invalid geometry or layer identity.")
                }
                pointCount += element.points.count
                guard pointCount <= 1_000_000 else { throw StudioDocumentError.invalid("This project exceeds the editable point limit.") }
                if element.brush?.tiltEnabled == true || element.points.contains(where: { $0.tilt != nil }) {
                    guard schemaVersion >= 23 else { throw StudioDocumentError.invalid("Pencil tilt requires project version 23. The original has not changed.") }
                }
                for point in element.points {
                    guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 100000, abs(point.y) <= 100000,
                          point.pressure.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                          point.timestamp.map(\.isFinite) ?? true, point.tilt?.isValid ?? true else { throw StudioDocumentError.invalid("A drawing contains invalid coordinates.") }
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

// Settings remain a standalone Codable transport model. Editor validation
// belongs here so native model/storage stages do not depend on the editor.
extension AudioClip {
    struct SplitTiming: Equatable { let boundary: Double; let rightSourceOffset: Double }
    /// Preserve the manual split's exact 48 kHz timeline/source phase calculation.
    func splitTiming(at seconds: Double) throws -> SplitTiming {
        let rate = StudioAudioTimelineGeometry.sampleRate
        guard assetID != nil, seconds.isFinite, startTime.isFinite, duration.isFinite, sourceOffset.isFinite,
              startTime >= 0, startTime <= 1000, duration > 0, duration <= 300, (0...300).contains(sourceOffset) else {
            throw StudioDocumentError.invalid("Choose a playable clip and a finite split time inside it.")
        }
        let startFrame = (startTime * rate).rounded(), endFrame = ((startTime + duration) * rate).rounded()
        let cutFrame = (seconds * rate).rounded(), boundary = cutFrame / rate
        let left = boundary - startTime, right = duration - left
        let offset = ((sourceOffset * rate).rounded() + cutFrame - startFrame) / rate
        guard boundary.isFinite, offset.isFinite, cutFrame > startFrame, cutFrame < endFrame,
              left >= 1 / rate, right >= 1 / rate else {
            throw StudioDocumentError.invalid("Split inside the clip with at least one audio sample on each side.")
        }
        return .init(boundary: boundary, rightSourceOffset: offset)
    }
}

extension StudioAudioClipSettings {
    func applying(to clip: AudioClip) throws -> AudioClip {
        guard clip.assetID != nil else {
            throw StudioDocumentError.unavailable("This clip has no managed audio source. Import playable audio before editing its settings.")
        }
        guard trim != nil || placement != nil || volume != nil || isMuted != nil || fades != nil else {
            throw StudioDocumentError.invalid("Specify an audio setting to change.")
        }
        var result = clip
        if let trim {
            guard trim.sourceOffset.isFinite, (0...300).contains(trim.sourceOffset),
                  trim.duration.isFinite, (1 / 48_000.0...300).contains(trim.duration),
                  (trim.sourceOffset + trim.duration).isFinite else {
                throw StudioDocumentError.invalid("Use a finite source offset and at least one audio sample within the source file.")
            }
            // Preserve the envelope's original source coordinates; trimming never restarts its phase.
            result.sourceOffset = trim.sourceOffset; result.duration = trim.duration
        }
        if let placement {
            guard placement.startTime.isFinite, (0...1000).contains(placement.startTime),
                  (1...4).contains(placement.track), result.duration.isFinite, result.duration > 0,
                  result.duration <= 300, (placement.startTime + result.duration).isFinite else {
                throw StudioDocumentError.invalid("Choose a finite clip start from 0–1,000 seconds and track 1–4.")
            }
            result.startTime = placement.startTime; result.track = placement.track
        }
        if let volume {
            guard volume.isFinite, (0...1).contains(volume) else {
                throw StudioDocumentError.invalid("Clip volume must be between 0% and 100%.")
            }
            result.volume = volume
        }
        if let isMuted { result.isMuted = isMuted }
        if let fades {
            let incoming = fades.fadeIn, outgoing = fades.fadeOut
            guard incoming.isFinite, outgoing.isFinite, incoming >= 0, outgoing >= 0,
                  result.duration.isFinite, result.duration > 0, result.duration <= 300,
                  result.startTime.isFinite, (0...1000).contains(result.startTime),
                  result.sourceOffset.isFinite, (0...300).contains(result.sourceOffset),
                  incoming <= result.duration, outgoing <= result.duration,
                  incoming + outgoing <= result.duration else { throw AudioFadeEnvelope.Failure.invalid }
            let rate = StudioAudioTimelineGeometry.sampleRate
            let start = Int((result.sourceOffset * rate).rounded())
            let count = Int(((result.startTime + result.duration) * rate).rounded() - (result.startTime * rate).rounded())
            let inFrames = Int((incoming * rate).rounded()), outFrames = Int((outgoing * rate).rounded())
            result.fadeEnvelope = inFrames == 0 && outFrames == 0 ? nil : .init(
                sourceStartFrame: start, frameCount: count, fadeInFrames: inFrames, fadeOutFrames: outFrames)
            try result.fadeEnvelope?.validate()
        }
        return result
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
        guard previous.revision < Int.max - 2 else {
            throw StudioDocumentError.invalid("This project has reached its edit revision limit. No changes were made.")
        }
        var next = document
        try operation(&next)
        guard next != previous else { return }
        next.revision = previous.revision + 1; next.modifiedAt = Date()
        try next.validate()
        undoDocuments.append(previous)
        trimHistory()
        redoDocuments.removeAll(); document = next
    }

    mutating func renameProject(_ proposed: String) throws {
        let title = try StudioDocument.validatedProjectName(proposed)
        guard title != document.name else { return }
        try change { $0.name = title }
    }

    @discardableResult
    mutating func splitAudioClip(_ id: String, at seconds: Double, newClipID: String) throws -> AudioClip {
        guard let index = document.audioClips.firstIndex(where: { $0.id == id }),
              !newClipID.isEmpty, newClipID.count <= 120,
              !newClipID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !document.audioClips.contains(where: { $0.id == newClipID }) else {
            throw StudioDocumentError.invalid("Choose an existing clip and a new unique right-half identity.")
        }
        let original = document.audioClips[index], timing = try original.splitTiming(at: seconds)
        var left = original; left.duration = timing.boundary - original.startTime
        let right = AudioClip(id: newClipID, soundName: original.soundName, track: original.track,
            startTime: timing.boundary, duration: original.duration - left.duration, volume: original.volume,
            assetID: original.assetID, sourceOffset: timing.rightSourceOffset,
            isMuted: original.isMuted, fadeEnvelope: original.fadeEnvelope)
        try change { value in
            value.schemaVersion = max(value.schemaVersion, 4)
            value.audioClips[index] = left; value.audioClips.insert(right, at: index + 1)
        }
        return right
    }
    mutating func deleteAudioClip(_ id: String) throws {
        guard let index = document.audioClips.firstIndex(where: { $0.id == id }) else {
            throw StudioDocumentError.invalid("Choose an existing audio clip to delete.")
        }
        try change { $0.audioClips.remove(at: index) }
    }

    /// Reuse the original managed source and envelope, placing the copy at its end.
    /// The supplied destination ID is generated once when the request is prepared.
    @discardableResult
    mutating func duplicateAudioClip(_ id: String, newClipID: String) throws -> AudioClip {
        guard let original = document.audioClips.first(where: { $0.id == id }), original.assetID != nil,
              !newClipID.isEmpty, newClipID.count <= 120,
              !newClipID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !document.audioClips.contains(where: { $0.id == newClipID }) else {
            throw StudioDocumentError.invalid("Choose a managed source clip and a new unique clip identity.")
        }
        let duplicate = AudioClip(id: newClipID, soundName: original.soundName,
            track: original.track, startTime: original.startTime + original.duration,
            duration: original.duration, volume: original.volume, assetID: original.assetID,
            sourceOffset: original.sourceOffset, isMuted: original.isMuted, fadeEnvelope: original.fadeEnvelope)
        try change { $0.audioClips.append(duplicate) }
        return duplicate
    }

    /// Shared by manual controls and the bounded assistant command transport.
    /// The host validates real asset bytes before publishing this staged editor.
    mutating func updateAudioClip(_ id: String, settings: StudioAudioClipSettings) throws {
        guard !id.isEmpty, id.count <= 120,
              let index = document.audioClips.firstIndex(where: { $0.id == id }) else {
            throw StudioDocumentError.invalid("Choose an existing audio clip in this project.")
        }
        let original = document.audioClips[index], updated = try settings.applying(to: original)
        guard updated != original else { return }
        try change { value in
            value.schemaVersion = max(value.schemaVersion, original.fadeEnvelope != updated.fadeEnvelope ? 14 : 4)
            value.audioClips[index] = updated
        }
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
    /// Plain assistant geometry uses one validated mutation, not one document
    /// copy/validation per limb. Rich drawing and effect semantics remain in commit.
    mutating func commitCommandPrimitives(_ elements: [DrawnElement], frameID: String,
                                         checkCancellation: () throws -> Void) throws {
        guard (2...32).contains(elements.count) else { throw StudioDocumentError.invalid("Invalid primitive batch size.") }
        for element in elements {
            try checkCancellation()
            guard (element.tool == .line || element.tool == .circle), element.brush == nil,
                  element.shape == nil, element.fillColor == nil, element.fillMask == nil,
                  element.translation == nil, element.reflection == nil, element.eraser == nil,
                  element.text == nil, element.transform == nil, element.smudge == nil,
                  element.blur == nil, element.sharpen == nil, element.dodgeBurn == nil,
                  element.preservesLayerAlpha == nil, element.points.count == 2,
                  element.points.allSatisfy({ $0.pressure == nil && $0.tilt == nil }) else { throw StudioDocumentError.invalid("Only plain primitive geometry can be batched.") }
        }
        try change { value in
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }) else {
                throw StudioDocumentError.invalid("The drawing frame is unavailable.")
            }
            for element in elements {
                try checkCancellation()
                guard let layer = value.layers.first(where: { $0.id == element.layerID }),
                      layer.visible, !layer.isFullyLocked,
                      layer.lockMode == "free" || layer.lockMode == "position" else { throw StudioDocumentError.locked }
                value.frames[index].elements.append(element)
            }
            try checkCancellation()
        }
    }

    mutating func commitMirroredStroke(_ elements: [DrawnElement], frameID: String) throws {
        guard (1...4).contains(elements.count), Set(elements.map(\.id)).count == elements.count else {
            throw StudioDocumentError.invalid("The mirror stroke is invalid.")
        }
        var staged = self
        for element in elements { try staged.commit(element, frameID: frameID) }
        // Publish the complete validated group as one history/revision change.
        try change { $0 = staged.document }
    }
    mutating func commit(_ element: DrawnElement, frameID: String) throws {
        var element = element
        if document.layers.first(where: { $0.id == element.layerID })?.lockMode == "alpha" {
            guard element.brush != nil, [.pencil, .pen, .brush, .marker, .crayon].contains(element.tool),
                  element.eraser == nil, !element.hasPixelEffect else {
                throw StudioDocumentError.unavailable("Alpha lock supports brush painting. Unlock the layer before filling, erasing or adding other content; nothing changed.")
            }
            element.preservesLayerAlpha = true
        }
        if element.tool == .smudge {
            guard element.smudge != nil, selectedElementIDs.isEmpty,
                  frameID == document.activeFrameID, element.layerID == document.activeLayerID else {
                throw StudioDocumentError.unavailable("Smudge requires the active unselected layer and a validated color-drag operation. Nothing changed.")
            }
        }
        if element.tool == .blur {
            guard element.blur != nil, selectedElementIDs.isEmpty,
                  frameID == document.activeFrameID, element.layerID == document.activeLayerID else {
                throw StudioDocumentError.unavailable("Blur requires the active unselected layer and a validated operation. Nothing changed.")
            }
        }
        if element.tool == .sharpen {
            guard element.sharpen != nil, selectedElementIDs.isEmpty,
                  frameID == document.activeFrameID, element.layerID == document.activeLayerID else {
                throw StudioDocumentError.unavailable("Sharpen requires the active unselected layer and a validated operation. Nothing changed.")
            }
        }
        if element.tool == .dodge || element.tool == .burn {
            guard element.dodgeBurn != nil, selectedElementIDs.isEmpty,
                  frameID == document.activeFrameID, element.layerID == document.activeLayerID else {
                throw StudioDocumentError.unavailable("Dodge and Burn require the active unselected layer and a validated exposure operation. Nothing changed.")
            }
        }
        if element.tool == .eraser, !selectedElementIDs.isEmpty {
            throw StudioDocumentError.unavailable("Erasing within a selection is unfinished. Deselect before erasing the active layer; nothing changed.")
        }
        try change { value in
            guard let layer = value.layers.first(where: { $0.id == element.layerID }), layer.visible, !layer.isFullyLocked else { throw StudioDocumentError.locked }
            if element.tool == .eraser || element.hasPixelEffect {
                guard layer.opacity > 0, layer.lockMode == "free" else { throw StudioDocumentError.locked }
            }
            guard layer.lockMode == "free" || layer.lockMode == "position" ||
                    (layer.lockMode == "alpha" && layer.opacity > 0 && element.preservesLayerAlpha == true) else {
                throw StudioDocumentError.locked
            }
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }) else { throw StudioDocumentError.invalid("The drawing frame is unavailable.") }
            value.frames[index].elements.append(element)
            if element.preservesLayerAlpha == true { value.schemaVersion = max(value.schemaVersion, 24) }
            if element.brush != nil { value.schemaVersion = max(value.schemaVersion, 2) }
            if let family = element.brush?.family, [.airbrush, .watercolor, .neon].contains(family) { value.schemaVersion = max(value.schemaVersion, 25) }
            if element.brush?.tiltEnabled == true || element.points.contains(where: { $0.tilt != nil }) {
                value.schemaVersion = max(value.schemaVersion, 23)
            }
            if element.shape != nil { value.schemaVersion = max(value.schemaVersion, element.tool == .line ? 26 : 5) }
            if element.fillMask != nil { value.schemaVersion = max(value.schemaVersion, 6) }
            if element.translation != nil { value.schemaVersion = max(value.schemaVersion, 7) }
            if element.reflection != nil { value.schemaVersion = max(value.schemaVersion, 8) }
            if element.eraser != nil { value.schemaVersion = max(value.schemaVersion, 9) }
            if element.text != nil { value.schemaVersion = max(value.schemaVersion, 10) }
            if element.transform != nil { value.schemaVersion = max(value.schemaVersion, 11) }
            if element.smudge != nil { value.schemaVersion = max(value.schemaVersion, 17) }
            if element.blur != nil { value.schemaVersion = max(value.schemaVersion, 18) }
            if element.sharpen != nil { value.schemaVersion = max(value.schemaVersion, 19) }
            if element.dodgeBurn != nil { value.schemaVersion = max(value.schemaVersion, 20) }
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
    /// Capture a specific timeline frame without changing active selection,
    /// document revision or history. Rejected stale targets retain the clipboard.
    mutating func copyFrame(_ id: String) throws {
        guard let frame = document.frames.first(where: { $0.id == id }) else {
            throw StudioDocumentError.invalid("The selected frame is no longer available to copy.")
        }
        clipboard = .frame(frame); clipboardVersion = UUID()
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
                guard !element.hasPixelEffect else {
                    throw StudioDocumentError.unavailable("Copy the whole frame to preserve a pixel effect and its source artwork.")
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
                    translation: element.translation, reflection: element.reflection, eraser: element.eraser, text: element.text, transform: element.transform, smudge: element.smudge, blur: element.blur, sharpen: element.sharpen, dodgeBurn: element.dodgeBurn, preservesLayerAlpha: element.preservesLayerAlpha))
                ids.insert(id)
                if element.preservesLayerAlpha == true { value.schemaVersion = max(value.schemaVersion, 24) }
                if element.brush != nil { value.schemaVersion = max(value.schemaVersion, 2) }
            if let family = element.brush?.family, [.airbrush, .watercolor, .neon].contains(family) { value.schemaVersion = max(value.schemaVersion, 25) }
            if element.brush?.tiltEnabled == true || element.points.contains(where: { $0.tilt != nil }) {
                value.schemaVersion = max(value.schemaVersion, 23)
            }
                if element.shape != nil { value.schemaVersion = max(value.schemaVersion, element.tool == .line ? 26 : 5) }
                if element.fillMask != nil { value.schemaVersion = max(value.schemaVersion, 6) }
                if element.translation != nil { value.schemaVersion = max(value.schemaVersion, 7) }
                if element.reflection != nil { value.schemaVersion = max(value.schemaVersion, 8) }
                if element.eraser != nil { value.schemaVersion = max(value.schemaVersion, 9) }
                if element.text != nil { value.schemaVersion = max(value.schemaVersion, 10) }
                if element.transform != nil { value.schemaVersion = max(value.schemaVersion, 11) }
            if element.smudge != nil { value.schemaVersion = max(value.schemaVersion, 17) }
            if element.blur != nil { value.schemaVersion = max(value.schemaVersion, 18) }
            if element.sharpen != nil { value.schemaVersion = max(value.schemaVersion, 19) }
            if element.dodgeBurn != nil { value.schemaVersion = max(value.schemaVersion, 20) }
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
                             brush: element.brush, shape: element.shape, fillMask: element.fillMask, translation: element.translation, reflection: element.reflection, eraser: element.eraser, text: element.text, transform: element.transform, smudge: element.smudge, blur: element.blur, sharpen: element.sharpen, dodgeBurn: element.dodgeBurn, preservesLayerAlpha: element.preservesLayerAlpha)
            }
            let frame = AnimationFrame(id: UUID().uuidString, elements: elements, rasterAssetID: source.rasterAssetID, rasterLayerID: source.rasterLayerID, rasterPlacement: source.rasterPlacement, rasterReflection: source.rasterReflection, rasterQuarterTurns: source.rasterQuarterTurns, holdTicks: source.holdTicks, rasterCrop: source.rasterCrop, rasterAliases: source.rasterAliases)
            value.frames.insert(frame, at: index + 1); value.activeFrameID = frame.id
            if elements.contains(where: { $0.brush != nil }) { value.schemaVersion = max(value.schemaVersion, 2) }
            if elements.contains(where: { $0.shape != nil }) { value.schemaVersion = max(value.schemaVersion, 5) }
            if elements.contains(where: { $0.brush?.tiltEnabled == true || $0.points.contains(where: { $0.tilt != nil }) }) {
                value.schemaVersion = max(value.schemaVersion, 23)
            }
            if elements.contains(where: { $0.preservesLayerAlpha == true }) { value.schemaVersion = max(value.schemaVersion, 24) }
            if elements.contains(where: { $0.brush.map { [.airbrush, .watercolor, .neon].contains($0.family) } ?? false }) {
                value.schemaVersion = max(value.schemaVersion, 25)
            }
            if elements.contains(where: { $0.tool == .line && $0.shape != nil }) { value.schemaVersion = max(value.schemaVersion, 26) }
            if elements.contains(where: { $0.fillMask != nil }) { value.schemaVersion = max(value.schemaVersion, 6) }
            if elements.contains(where: { $0.translation != nil }) { value.schemaVersion = max(value.schemaVersion, 7) }
            if elements.contains(where: { $0.reflection != nil }) { value.schemaVersion = max(value.schemaVersion, 8) }
            if elements.contains(where: { $0.eraser != nil }) { value.schemaVersion = max(value.schemaVersion, 9) }
            if elements.contains(where: { $0.text != nil }) { value.schemaVersion = max(value.schemaVersion, 10) }
            if elements.contains(where: { $0.transform != nil }) { value.schemaVersion = max(value.schemaVersion, 11) }
            if elements.contains(where: { $0.smudge != nil }) { value.schemaVersion = max(value.schemaVersion, 17) }
            if elements.contains(where: { $0.blur != nil }) { value.schemaVersion = max(value.schemaVersion, 18) }
            if elements.contains(where: { $0.sharpen != nil }) { value.schemaVersion = max(value.schemaVersion, 19) }
            if elements.contains(where: { $0.dodgeBurn != nil }) { value.schemaVersion = max(value.schemaVersion, 20) }
            if source.rasterPlacement != nil { value.schemaVersion = max(value.schemaVersion, 3) }
            if source.rasterReflection != nil { value.schemaVersion = max(value.schemaVersion, 15) }
            if source.rasterQuarterTurns != nil { value.schemaVersion = max(value.schemaVersion, 16) }
            if source.holdTicks != nil { value.schemaVersion = max(value.schemaVersion, 21) }
            if source.rasterCrop != nil { value.schemaVersion = max(value.schemaVersion, 22) }
            if source.rasterAliases?.isEmpty == false { value.schemaVersion = max(value.schemaVersion, 27) }
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
                              layerID: String? = nil, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        try change { value in
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }),
                  value.frames[index].rasterAssetID == assetID,
                  let selected = Self.imageInstance(in: value.frames[index], layerID: layerID),
                  selected.placement != nil else {
                throw StudioDocumentError.invalid("The selected image is unavailable. Nothing changed.")
            }
            guard let layer = value.layers.first(where: { $0.id == selected.layerID }),
                  layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else {
                throw StudioDocumentError.locked
            }
            try checkCancellation()
            // Only this explicit managed picture reference is removed. Keep
            // frame/layer identity, drawings, other frames and immutable assets.
            try value.frames[index].removeRasterInstance(on: selected.layerID)
            try checkCancellation()
        }
    }

    /// Toggle one explicit managed image around its own center, preserving the
    /// placement, drawings, asset identity and immutable source data.
    mutating func reflectImage(frameID: String, assetID: String, axis: StudioReflectionAxis,
                              layerID: String? = nil, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        try change { value in
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }),
                  value.frames[index].rasterAssetID == assetID,
                  var selected = Self.imageInstance(in: value.frames[index], layerID: layerID),
                  selected.placement != nil else {
                throw StudioDocumentError.invalid("The selected image is unavailable. Nothing changed.")
            }
            guard let layer = value.layers.first(where: { $0.id == selected.layerID }),
                  layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else {
                throw StudioDocumentError.locked
            }
            try checkCancellation()
            var reflection = selected.reflection ?? StudioRasterReflection()
            switch axis {
            case .horizontal: reflection.horizontal.toggle()
            case .vertical: reflection.vertical.toggle()
            }
            selected.reflection = reflection.horizontal || reflection.vertical ? reflection : nil
            try value.frames[index].updateRasterInstance(selected)
            value.schemaVersion = max(value.schemaVersion, 15)
            try checkCancellation()
        }
    }

    /// A real quarter turn preserves image scale and source bytes. Rotate about
    /// the placed center, then shift only as needed to keep the whole image in
    /// the canvas. Oversized results reject instead of silently shrinking/cropping.
    mutating func rotateImage(frameID: String, assetID: String, direction: StudioImageQuarterTurn,
                             layerID: String? = nil, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        try change { value in
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }),
                  value.frames[index].rasterAssetID == assetID,
                  var selected = Self.imageInstance(in: value.frames[index], layerID: layerID),
                  let placement = selected.placement else {
                throw StudioDocumentError.invalid("The selected image is unavailable. Nothing changed.")
            }
            guard let layer = value.layers.first(where: { $0.id == selected.layerID }),
                  layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else {
                throw StudioDocumentError.locked
            }
            guard placement.height <= Double(value.width), placement.width <= Double(value.height) else {
                throw StudioDocumentError.invalid("This rotated image would be larger than the canvas. Make it smaller with Position image, then rotate again. Nothing changed.")
            }
            try checkCancellation()
            let previousTurns: Int = selected.quarterTurns ?? 0
            let turns: Int = (previousTurns + direction.offset + 4) % 4
            selected.quarterTurns = turns == 0 ? nil : turns
            let centerX: Double = placement.x + placement.width / 2
            let centerY: Double = placement.y + placement.height / 2
            let x: Double = min(max(0, centerX - placement.height / 2), Double(value.width) - placement.height)
            let y: Double = min(max(0, centerY - placement.width / 2), Double(value.height) - placement.width)
            selected.placement = StudioRasterPlacement(x: x, y: y, width: placement.height, height: placement.width)
            // H/V flips are relative to canvas axes. A quarter turn carries the
            // existing reflection with the picture instead of changing its look.
            if let reflection = selected.reflection {
                selected.reflection = .init(horizontal: reflection.vertical, vertical: reflection.horizontal)
            }
            try value.frames[index].updateRasterInstance(selected)
            value.schemaVersion = max(value.schemaVersion, 16)
            try checkCancellation()
        }
    }

    mutating func cropImage(frameID: String, assetID: String, crop: StudioImageCrop,
                            layerID: String? = nil, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation(); try crop.validate()
        try change { value in
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }),
                  value.frames[index].rasterAssetID == assetID,
                  var selected = Self.imageInstance(in: value.frames[index], layerID: layerID),
                  let placement = selected.placement else { throw StudioDocumentError.invalid("Select an imported image before cropping.") }
            guard let layer = value.layers.first(where: { $0.id == selected.layerID }),
                  layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { throw StudioDocumentError.locked }
            let old = selected.crop ?? .full
            guard old != crop else { return }
            let odd = (selected.quarterTurns ?? 0) % 2 != 0
            let proposedWidth = placement.width * (odd ? crop.height / old.height : crop.width / old.width)
            let proposedHeight = placement.height * (odd ? crop.width / old.width : crop.height / old.height)
            let fit = min(1, min(Double(value.width) / proposedWidth, Double(value.height) / proposedHeight))
            let width = min(Double(value.width), proposedWidth * fit), height = min(Double(value.height), proposedHeight * fit)
            let x = min(max(0, placement.x + placement.width / 2 - width / 2), Double(value.width) - width)
            let y = min(max(0, placement.y + placement.height / 2 - height / 2), Double(value.height) - height)
            selected.placement = .init(x: x, y: y, width: width, height: height)
            selected.crop = crop == .full ? nil : crop
            try value.frames[index].updateRasterInstance(selected)
            value.schemaVersion = max(22, value.schemaVersion)
            try checkCancellation()
        }
    }

    mutating func updateImagePlacement(frameID: String, assetID: String,
                                      placement: StudioRasterPlacement,
                                      layerID: String? = nil, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        try change { value in
            guard let index = value.frames.firstIndex(where: { $0.id == frameID }),
                  value.frames[index].rasterAssetID == assetID,
                  var selected = Self.imageInstance(in: value.frames[index], layerID: layerID),
                  selected.placement != nil else {
                throw StudioDocumentError.invalid("The selected image is unavailable. Nothing changed.")
            }
            guard let layer = value.layers.first(where: { $0.id == selected.layerID }),
                  layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else {
                throw StudioDocumentError.locked
            }
            try checkCancellation()
            selected.placement = placement
            try value.frames[index].updateRasterInstance(selected)
            // change validates the full document before a single history commit.
        }
    }

    private static func imageInstance(in frame: AnimationFrame, layerID: String?) -> StudioRasterLayerInstance? {
        if let layerID { return frame.rasterInstance(on: layerID) }
        let instances = frame.rasterLayerInstances
        return instances.count == 1 ? instances[0] : nil
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
                guard let layer = value.layers.first(where: { $0.id == element.layerID }), layer.visible,
                      !layer.isFullyLocked, layer.lockMode != "alpha" else { throw StudioDocumentError.locked }
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
                if value.frames[frame].rasterInstance(on: id) != nil {
                    try value.frames[frame].removeRasterInstance(on: id)
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
            guard value.layers.count < 128 else { throw StudioDocumentError.invalid("This project already has 128 layers.") }
            let original = value.layers[index]
            let layer = CanvasLayer(id: UUID().uuidString, name: String((original.name + " Copy").prefix(120)), visible: original.visible,
                                    locked: original.locked, opacity: original.opacity, lockMode: original.lockMode,
                                    blendMode: original.blendMode, glowEnabled: original.glowEnabled, glowColor: original.glowColor, colorLabel: original.colorLabel)
            value.layers.insert(layer, at: index); value.activeLayerID = layer.id
            for frameIndex in value.frames.indices {
                let copies = value.frames[frameIndex].elements.filter { $0.layerID == id }.map { element in
                    DrawnElement(id: UUID().uuidString, tool: element.tool, points: element.points, color: element.color,
                                 width: element.width, opacity: element.opacity, fillColor: element.fillColor, layerID: layer.id,
                                 brush: element.brush, shape: element.shape, fillMask: element.fillMask, translation: element.translation, reflection: element.reflection, eraser: element.eraser, text: element.text, transform: element.transform, smudge: element.smudge, blur: element.blur, sharpen: element.sharpen, dodgeBurn: element.dodgeBurn, preservesLayerAlpha: element.preservesLayerAlpha)
                }
                value.frames[frameIndex].elements.append(contentsOf: copies)
                if var instance = value.frames[frameIndex].rasterInstance(on: id) {
                    instance.layerID = layer.id
                    value.frames[frameIndex].rasterAliases = (value.frames[frameIndex].rasterAliases ?? []) + [instance]
                    value.schemaVersion = max(value.schemaVersion, 27)
                }
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
        guard document.revision < Int.max - 2, var previous = undoDocuments.popLast() else { return }
        redoDocuments.append(document); previous.revision = document.revision + 1; previous.modifiedAt = Date()
        document = previous; selectedElementIDs.removeAll()
    }
    mutating func redo() {
        guard document.revision < Int.max - 2, var next = redoDocuments.popLast() else { return }
        undoDocuments.append(document); next.revision = document.revision + 1; next.modifiedAt = Date()
        document = next; selectedElementIDs.removeAll()
    }
    private mutating func trimHistory() {
        func cost(_ value: StudioDocument) -> Int {
            var bytes = value.layers.count * 512 + value.audioClips.count * 512
            for frame in value.frames {
                bytes += (frame.rasterAliases?.count ?? 0) * 512
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

/// Additive editor-only metadata. Old archives keep the original one-frame,
/// untinted 20% preview; export never consumes these ghost descriptors.
struct StudioOnionSettings: Codable, Equatable {
    var previousCount = 1
    var nextCount = 0
    var opacity = 0.2
    var tinted = false
    var isValid: Bool { (0...2).contains(previousCount) && (0...2).contains(nextCount) && opacity.isFinite && (0.05...0.8).contains(opacity) }
}
struct StudioOnionGhost {
    let frame: AnimationFrame
    let opacity: Double
    let previous: Bool
    let tinted: Bool
}

struct StudioGridSettings: Codable, Equatable {
    enum Tint: String, Codable, CaseIterable { case blue, gray, red }
    var spacing = 40.0
    var opacity = 0.1
    var tint: Tint = .blue
    var isValid: Bool { spacing.isFinite && (8...160).contains(spacing) && opacity.isFinite && (0.05...0.6).contains(opacity) }
    func positions(length: Double) -> [Double] {
        guard isValid, length.isFinite, (0...8192).contains(length) else { return [] }
        let count = min(1025, Int(floor(length / spacing)) + 1)
        return (0..<count).map { Double($0) * spacing }
    }
}

/// Deliberately non-overshooting timing for editable, baked in-between frames.
enum StudioTweenEasing: String, Codable, CaseIterable, Identifiable {
    case linear, easeIn, easeOut, easeInOut
    var id: String { rawValue }
    var title: String {
        switch self { case .linear: return "Linear"; case .easeIn: return "Ease in"
        case .easeOut: return "Ease out"; case .easeInOut: return "Ease in/out" }
    }
    func progress(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        switch self {
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return t * (2 - t)
        case .easeInOut: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        }
    }
}

extension StudioDocumentEditor {
    /// Endpoint drawings pair in their existing order. Equal styles and sample
    /// topology make this explicit interpolation, never guessed object tracking.
    @discardableResult
    mutating func tweenFrames(after frameID: String, to nextFrameID: String,
                              inbetweenCount: Int, easing: StudioTweenEasing,
                              checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> [String] {
        try checkCancellation()
        guard (1...24).contains(inbetweenCount), document.frames.count <= 1000 - inbetweenCount,
              let index = document.frames.firstIndex(where: { $0.id == frameID }),
              index + 1 < document.frames.count, document.frames[index + 1].id == nextFrameID else {
            throw StudioDocumentError.invalid("Choose adjacent endpoint frames and 1–24 in-betweens within the 1,000-frame limit.")
        }
        let start = document.frames[index], end = document.frames[index + 1]
        guard start.rasterAssetID == nil, end.rasterAssetID == nil,
              !start.elements.isEmpty, start.elements.count == end.elements.count,
              start.elements.count <= 1024 else {
            throw StudioDocumentError.unavailable("Tween needs matching ordered drawings in both frames. Raster references and empty or unequal drawing sets are unsupported; nothing changed.")
        }
        let totalPoints = start.elements.reduce(0) { $0 + $1.points.count + ($1.fillMask?.spans.count ?? 0) + ($1.text?.content.utf8.count ?? 0) }
        guard totalPoints <= 65_536 / inbetweenCount,
              start.elements.count <= 1024 / inbetweenCount else {
            throw StudioDocumentError.unavailable("Tween is limited to 65,536 generated points and 1,024 generated drawings. Use fewer in-betweens or simpler poses.")
        }
        for (a, b) in zip(start.elements, end.elements) {
            try checkCancellation()
            guard let layer = document.layers.first(where: { $0.id == a.layerID }), layer.visible,
                  layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { throw StudioDocumentError.locked }
            guard a.layerID == b.layerID, a.tool == b.tool, a.color == b.color, a.width == b.width,
                  a.opacity == b.opacity, a.fillColor == b.fillColor, a.brush == b.brush, a.shape == b.shape,
                  a.fillMask == b.fillMask, a.reflection == b.reflection, a.text == b.text,
                  a.tool != .eraser, a.eraser == nil, b.eraser == nil,
                  !a.hasPixelEffect, !b.hasPixelEffect,
                  a.preservesLayerAlpha != true, b.preservesLayerAlpha != true,
                  !a.points.isEmpty, a.points.count == b.points.count,
                  (a.brush == nil || zip(a.points, b.points).allSatisfy({ pair in pair.0.pressure == pair.1.pressure && pair.0.timestamp == pair.1.timestamp && pair.0.tilt == pair.1.tilt })),
                  a.fillMask == nil || a.points == b.points else {
                throw StudioDocumentError.unavailable("Pair the same drawing order, tools, styles and sample counts on the same layers. Text content, brush samples, fill coverage and reflections must match. Erasers, alpha paint and pixel effects cannot tween.")
            }
        }
        var generated: [AnimationFrame] = []
        for step in 1...inbetweenCount {
            try checkCancellation()
            let t = easing.progress(Double(step) / Double(inbetweenCount + 1))
            var elements: [DrawnElement] = []
            for (a, b) in zip(start.elements, end.elements) {
                try checkCancellation()
                let points = zip(a.points, b.points).map { from, to -> StrokePoint in
                    var p = from
                    p.x += (to.x - from.x) * CGFloat(t); p.y += (to.y - from.y) * CGFloat(t)
                    return p
                }
                let transform = try StudioTweenAffine.interpolate(a, b, progress: t)
                elements.append(DrawnElement(id: UUID().uuidString, tool: a.tool, points: points,
                    color: a.color, width: a.width, opacity: a.opacity, fillColor: a.fillColor, layerID: a.layerID,
                    brush: a.brush, shape: a.shape, fillMask: a.fillMask, reflection: a.reflection,
                    text: a.text, transform: transform))
            }
            generated.append(AnimationFrame(id: UUID().uuidString, elements: elements))
        }
        let ids = generated.map(\.id)
        try checkCancellation()
        try change { value in
            value.schemaVersion = max(value.schemaVersion, 11)
            value.frames.insert(contentsOf: generated, at: index + 1)
            value.activeFrameID = ids[0]
        }
        selectedElementIDs.removeAll()
        return ids
    }
}

private enum StudioTweenAffine {
    /// QR decomposition avoids singular matrix-lerp at a half-turn. Keep handedness,
    /// interpolate scale/shear and shortest-arc rotation; validate every result.
    static func interpolate(_ from: DrawnElement, _ to: DrawnElement, progress t: Double) throws -> StudioElementTransform {
        func placement(_ element: DrawnElement) -> StudioElementTransform {
            (element.transform ?? .init()).after(.init(tx: element.translation?.x ?? 0, ty: element.translation?.y ?? 0))
        }
        func components(_ m: StudioElementTransform) throws -> (Double, Double, Double, Double) {
            try m.validate()
            let sx = hypot(m.a, m.b), rotation = atan2(m.b, m.a)
            return (sx, (m.a * m.d - m.b * m.c) / sx, (m.a * m.c + m.b * m.d) / sx, rotation)
        }
        let a = placement(from), b = placement(to)
        let x = try components(a), y = try components(b)
        guard x.1 * y.1 > 0 else {
            throw StudioDocumentError.unavailable("A tween cannot cross a reflection that collapses the artwork. Keep endpoint handedness the same.")
        }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        var angle = (y.3 - x.3).truncatingRemainder(dividingBy: 2 * .pi)
        if angle > .pi { angle -= 2 * .pi }; if angle < -.pi { angle += 2 * .pi }
        let rotation = x.3 + angle * t, c = cos(rotation), s = sin(rotation)
        let sx = mix(x.0, y.0), sy = mix(x.1, y.1), shear = mix(x.2, y.2)
        let result = StudioElementTransform(a: c * sx, b: s * sx, c: c * shear - s * sy,
            d: s * shear + c * sy, tx: mix(a.tx, b.tx), ty: mix(a.ty, b.ty))
        try result.validate()
        return result
    }
}
