import SwiftUI

@MainActor
final class StudioViewModel: ObservableObject {
    static let shared = StudioViewModel()
    @Published private var editor: StudioDocumentEditor
    @Published private(set) var savedProjects: [AnimationMetadata] = []
    @Published var isEditing = false
    @Published private(set) var isSaving = false
    @Published private(set) var lastSaveTime: Date?
    @Published var message: String?
    struct PendingBrushStroke {
        let projectID: UUID
        let frameID: String
        let element: DrawnElement
        let reason: String
        let inputComplete: Bool
    }
    @Published private(set) var pendingBrushStroke: PendingBrushStroke?
    @Published private(set) var activeStrokeID: String?
    private var savedRevision: Int?
    private let storage: DeviceStorageManager
    private var retainedRasterFrames: [String: StoredAnimationFrame] = [:]
    private var retainedAudioTracks: [AudioTrack] = []
    private var managedAudioTracks: [UUID: AudioTrack] = [:]
    static let maximumManagedAudioBytes = 32 * 1024 * 1024
    var managedAudioByteCount: Int { managedAudioTracks.values.reduce(0) { $0 + ($1.audioData?.count ?? 0) } }
    /// Preserved historical records plus current imported clips' immutable assets.
    var projectAudioTracks: [AudioTrack] {
        let ids = document.referencedAudioAssetIDs
        return retainedAudioTracks + managedAudioTracks.values.filter { ids.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func audioTrack(forAssetID id: UUID) -> AudioTrack? {
        managedAudioTracks[id] ?? retainedAudioTracks.first { $0.id == id }
    }
    var selectedCurrentAudioClip: AudioClip? {
        selectedAudioClip.flatMap { selected in document.audioClips.first { $0.id == selected.id } }
    }
    private var autosaveTask: Task<Void, Never>?
    private var playbackTimer: Timer?
    @Published private var playbackFrameIndex: Int?

    var document: StudioDocument { editor.document }
    var currentProjectID: String? { isEditing ? document.id.uuidString : nil }
    var projectName: String { document.name }
    var canvasWidth: Int { document.width }
    var canvasHeight: Int { document.height }
    var fps: Int { document.fps }
    var frames: [AnimationFrame] { document.frames }
    var layers: [CanvasLayer] { document.layers }
    // Compatibility projection, never a second mutable array.
    var studioLayers: [CanvasLayer] { document.layers }
    var activeLayerID: String { document.activeLayerID }
    var currentFrameIndex: Int {
        get { playbackFrameIndex ?? (frames.firstIndex { $0.id == document.activeFrameID } ?? 0) }
        set {
            guard allowDocumentEditDuringInput() else { return }
            guard frames.indices.contains(newValue) else { return }
            stopPlayback()
            if editor.selectFrame(frames[newValue].id) { scheduleSave() }
        }
    }
    var currentLayerIndex: Int {
        get { layers.firstIndex { $0.id == activeLayerID } ?? 0 }
        set { if layers.indices.contains(newValue) { selectLayer(layers[newValue].id) } }
    }
    var currentFrame: AnimationFrame { frames[currentFrameIndex] }
    var previousFrame: AnimationFrame? { currentFrameIndex > 0 ? frames[currentFrameIndex - 1] : nil }
    var canUndo: Bool { activeStrokeID == nil && editor.canUndo }
    var canRedo: Bool { activeStrokeID == nil && editor.canRedo }
    var canPaste: Bool { activeStrokeID == nil && editor.canPaste }
    var canDeleteSelected: Bool { !editor.selectedElementIDs.isEmpty }
    var selectedElementIDs: Set<String> { editor.selectedElementIDs }
    var isDirty: Bool { savedRevision != document.revision || pendingBrushStroke != nil || activeStrokeID != nil }
    var saveTimeAgo: String { activeStrokeID != nil ? "Drawing…" : isSaving ? "Saving…" : isDirty ? "Unsaved" : "Saved" }

    @Published var selectedTool: DrawingTool = .brush
    @Published var strokeColor: Color = .red
    @Published var strokeWidth: Double = 3
    @Published var strokeOpacity: Double = 1
    var toolOpacity: Double { get { strokeOpacity } set { strokeOpacity = min(1, max(0, newValue)) } }
    @Published var smoothing: Double = 3
    @Published var pressureSensitivity = false
    @Published var brushFamily: StudioBrushFamily = .round
    @Published var brushTipAngle: Double = 45
    @Published var brushTexture: Double = 0.5
    @Published var brushGrain: Double = 0.3
    @Published var brushGradientEndColor: Color = .blue
    @Published var fillTolerance: Double = 32
    @Published var fillExpand: Double = 0
    @Published var fillGapClose: Double = 0
    @Published var fillContiguous = true
    @Published var fillAntiAlias = true
    @Published var fillSampleAll = false
    @Published var activePanel: StudioPanelType = .none
    @Published var showToolbar = true
    @Published private(set) var isPlaying = false
    @Published var canvasScale: CGFloat = 1
    @Published var canvasOffset: CGSize = .zero
    @Published var audioPlayheadTime: Double = 0
    @Published var snapEnabled = true
    @Published var selectedAudioClip: AudioClip?
    @Published var exportFormat: ExportFormat = .mp4
    @Published var exportQuality: ExportQuality = .standard
    @Published var currentStroke: [StrokePoint] = []
    var showOnionSkin: Bool { get { document.onionEnabled } set { change { $0.onionEnabled = newValue } } }
    var gridEnabled: Bool { get { document.gridEnabled } set { change { $0.gridEnabled = newValue } } }
    var audioClips: [AudioClip] { get { document.audioClips } set { change { $0.audioClips = newValue } } }
    var audioDuration: Double { max(Double(frames.count) / Double(fps), document.audioClips.map { $0.startTime + $0.duration }.filter(\.isFinite).max() ?? 0) }
    var strokeColorHex: String { Self.hex(strokeColor) }
    var capturedStrokeOpacity: Double {
        #if canImport(UIKit)
        var alpha: CGFloat = 1
        UIColor(strokeColor).getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return strokeOpacity * Double(alpha)
        #else
        return strokeOpacity
        #endif
    }
    func brushDescriptor(elementID: String, seed: UInt64? = nil) throws -> StudioBrushDescriptor {
        let value = StudioBrushDescriptor(family: brushFamily, seed: seed ?? StudioBrushRenderer.seed(for: elementID),
            smoothing: smoothing, pressureEnabled: false, tipAngleDegrees: brushTipAngle,
            texture: brushTexture, grain: brushGrain,
            gradientEndColor: brushFamily == .gradient ? try StudioBrushGeometryCache.color(Self.hex(brushGradientEndColor)) : nil)
        _ = try value.settings(width: strokeWidth, opacity: capturedStrokeOpacity)
        return value
    }
    func selectDrawingTool(_ tool: DrawingTool) {
        selectedTool = tool
        switch tool {
        case .marker: brushFamily = .calligraphy
        case .crayon: brushFamily = .grain
        case .pen: brushFamily = .roughPen
        case .pencil: brushFamily = .round
        default: break
        }
    }

    /// Snapshot of this Studio route, not a claim about another foreground tab.
    /// This snapshot contains no request bodies, audio bytes, provider credentials
    /// or file paths. A future Spatter caller remains responsible for app-level
    /// visibility, authenticated transport and authorized project-context sharing.
    struct CommandScreenContext {
        enum Route: String { case library, editor }
        struct RetainedAudio {
            let id: UUID
            let name: String
            let format: String
            let startTime: Double
            let duration: Double
            let timingKnown: Bool
            let hasAudioData: Bool
        }
        let route: Route
        let activePanel: StudioPanelType
        let selectedTool: DrawingTool?
        let document: StudioCommandContext?
        let selectedElementIDs: Set<String>
        let selectedAudioClipID: String?
        let displayedFrameID: String?
        let isPlaying: Bool
        let audioPlayheadTime: Double?
        let retainedAudio: [RetainedAudio]
        let canApplyCommands: Bool
        let isDirty: Bool
        let isSaving: Bool
        let canUndo: Bool
        let canRedo: Bool
    }

    var commandScreenContext: CommandScreenContext {
        guard isEditing else {
            return .init(route: .library, activePanel: .none, selectedTool: nil, document: nil,
                selectedElementIDs: [], selectedAudioClipID: nil, displayedFrameID: nil,
                isPlaying: false, audioPlayheadTime: nil, retainedAudio: [], canApplyCommands: false,
                isDirty: false, isSaving: false, canUndo: false, canRedo: false)
        }
        return .init(route: .editor, activePanel: activePanel, selectedTool: selectedTool,
            document: StudioCommandContext(document: document), selectedElementIDs: selectedElementIDs,
            selectedAudioClipID: selectedAudioClip.flatMap { selected in
                document.audioClips.contains(where: { $0.id == selected.id }) ? selected.id : nil
            }, displayedFrameID: currentFrame.id,
            isPlaying: isPlaying, audioPlayheadTime: audioPlayheadTime,
            retainedAudio: projectAudioTracks.map {
                .init(id: $0.id, name: $0.name, format: $0.format, startTime: $0.startTime, duration: $0.duration,
                      timingKnown: $0.legacySourceFilename == nil, hasAudioData: $0.audioData != nil)
            }, canApplyCommands: !isSaving && pendingBrushStroke == nil && activeStrokeID == nil,
            isDirty: isDirty, isSaving: isSaving, canUndo: canUndo, canRedo: canRedo)
    }

    /// The returned receipt describes an in-memory edit, never a successful save,
    /// provider response, export or publication. The ordinary debounce/flush path
    /// persists the same canonical editor and retains dirty work on storage error.
    /// Local project ownership is established by the caller opening this editor;
    /// this method does not authorize a remote caller or parse natural language.
    @discardableResult
    func applyStudioCommands(_ request: StudioCommandRequest,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandReceipt {
        try checkCancellation()
        try requireOpenCommandEditor()
        try validateCommandWorkBudget(request)
        var candidate = editor
        let receipt = try StudioCommandExecutor.execute(request, editor: &candidate, checkCancellation: checkCancellation)
        try preflightRasterDocument(candidate.document)
        try checkCancellation()
        // A caller's synchronous cancellation probe may also change the live
        // editor. Recheck its ownership and revision before publishing the
        // staged copy, so that intervening edit or input can never be replaced.
        try requireOpenCommandEditor()
        guard request.projectID == document.id else { throw StudioCommandError.wrongProject }
        guard request.expectedRevision == document.revision else { throw StudioCommandError.staleRevision }
        editor = candidate
        if receipt.outcome != .unchanged {
            stopPlayback()
            pruneManagedAudio()
            scheduleSave()
        }
        return receipt
    }

    /// Untrusted wire input must use the bounded strict decoder before it reaches
    /// the identical typed execution path. No cloud request is made here.
    @discardableResult
    func applyStudioCommands(_ data: Data,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandReceipt {
        try checkCancellation()
        try requireOpenCommandEditor()
        return try applyStudioCommands(StudioCommandExecutor.decode(data), checkCancellation: checkCancellation)
    }

    private func requireOpenCommandEditor() throws {
        guard isEditing else { throw StudioDocumentError.unavailable("Open or create a project before applying Studio commands.") }
        guard !isSaving else { throw StudioDocumentError.unavailable("Wait for the current save before applying Studio commands.") }
        guard pendingBrushStroke == nil else { throw StudioDocumentError.unavailable("Retry or discard the rejected brush draft before applying Studio commands.") }
        guard activeStrokeID == nil else { throw StudioDocumentError.unavailable("Finish the current touch stroke before applying Studio commands.") }
    }

    /// The current executor validates the whole document after each staged edit.
    /// Bound that repeated work before entering its synchronous MainActor path;
    /// the wire's independent point/stroke limits alone do not bound this cost.
    /// This is a conservative operation budget, not a wall-clock guarantee.
    private func validateCommandWorkBudget(_ request: StudioCommandRequest) throws {
        guard request.schemaVersion == 1 else { throw StudioCommandError.unsupportedCommand }
        guard request.projectID == document.id else { throw StudioCommandError.wrongProject }
        guard request.expectedRevision == document.revision else { throw StudioCommandError.staleRevision }
        guard case .apply(let commands) = request.action else { return }
        guard !commands.isEmpty, commands.count <= StudioCommandExecutor.maximumCommands else { throw StudioCommandError.limitExceeded }
        let maximumWork = 2_000_000
        var units = 0, edits = 0, strokes = 0, hasDuplication = false
        func exceeded() -> StudioDocumentError {
            .unavailable("This command batch is too large for interactive editing in this project. Try a smaller batch; very complex projects may currently be unavailable for command edits. Nothing changed.")
        }
        func addUnits(_ count: Int, weight: Int = 1) throws {
            guard count <= (maximumWork - units) / weight else { throw exceeded() }
            units += count * weight
        }
        try addUnits(document.frames.count, weight: 8)
        try addUnits(document.layers.count, weight: 8)
        try addUnits(document.audioClips.count, weight: 32)
        for frame in document.frames {
            try addUnits(frame.elements.count, weight: 32)
            for element in frame.elements { try addUnits(element.points.count) }
        }
        for command in commands {
            switch command {
            case .draw(let drawing):
                guard drawing.strokes.count <= StudioCommandExecutor.maximumStrokes - strokes else { throw StudioCommandError.limitExceeded }
                strokes += drawing.strokes.count; edits += drawing.strokes.count
                try addUnits(drawing.strokes.count, weight: 32)
                for stroke in drawing.strokes { try addUnits(stroke.points.count) }
            case .duplicateFrame, .duplicateLayer:
                // Aliases may duplicate content created earlier in this batch.
                // Reserve the executor's full cumulative generated-data budget
                // rather than undercounting a reference we have not staged yet.
                hasDuplication = true; edits += 2
            case .addLayer: edits += 2; try addUnits(1, weight: 8)
            case .addFrame: edits += 2; try addUnits(1, weight: 8)
            default: edits += 1
            }
        }
        if hasDuplication {
            try addUnits(StudioCommandExecutor.maximumGeneratedPoints)
            try addUnits(StudioCommandExecutor.maximumGeneratedElements, weight: 32)
        }
        // Includes initial/final validation, comparison and final history commit.
        guard units <= maximumWork / (edits + 6) else { throw exceeded() }
    }

    private static func hex(_ color: Color) -> String {
        #if canImport(UIKit)
        let value = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        value.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #else
        return "#FF0000"
        #endif
    }
    init(storage: DeviceStorageManager = .shared) {
        self.storage = storage
        editor = try! StudioDocumentEditor(document: .new(name: "Untitled Animation", width: 1080, height: 1080, fps: 12))
    }
    func loadProjects() async {
        do {
            let listing = try storage.listAnimationsReportingFailures()
            savedProjects = listing.animations.sorted { $0.modifiedAt > $1.modifiedAt }
            if !listing.failures.isEmpty { message = "Some projects could not be read. Their original files have been preserved." }
        } catch { message = "Projects could not be listed: \(error.localizedDescription)" }
    }
    @discardableResult
    func createProject(name: String, width: Int, height: Int, fps: Int) async -> Bool {
        guard !isEditing, pendingBrushStroke == nil, activeStrokeID == nil else { message = "Finish or discard any drawing draft, then save and return to projects before creating another animation."; return false }
        do {
            editor = try StudioDocumentEditor(document: .new(name: name, width: width, height: height, fps: fps))
            retainedRasterFrames.removeAll(); retainedAudioTracks.removeAll(); managedAudioTracks.removeAll()
            savedRevision = nil; lastSaveTime = nil; resetSession(); isEditing = true
            return await save()
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult
    func openProject(_ metadata: AnimationMetadata) async -> Bool {
        guard !isEditing, pendingBrushStroke == nil, activeStrokeID == nil else { message = "Finish or discard any drawing draft, then save and return to projects before opening another animation."; return false }
        do {
            guard let stored = try storage.loadAnimation(id: metadata.id) else { throw StudioDocumentError.invalid("This project is no longer available.") }
            var decoded: StudioDocument
            var rasters: [String: StoredAnimationFrame] = [:]
            if let data = stored.editableDocumentData {
                let archive = try StudioDocumentArchive.decode(data)
                decoded = archive.document
                guard decoded.id == stored.id, decoded.frames.count == stored.metadata.frameCount,
                      decoded.layers.count == stored.metadata.layerCount, decoded.width == stored.metadata.canvasWidth,
                      decoded.height == stored.metadata.canvasHeight, decoded.fps == stored.metadata.fps else {
                    throw StudioDocumentError.invalid("Editable project metadata does not match its stored bundle.")
                }
                for (assetID, index) in archive.rasterFrameIndices {
                    guard stored.frames.indices.contains(index) else { throw StudioDocumentError.invalid("An original frame record is missing. The project was not replaced.") }
                    rasters[assetID] = stored.frames[index]
                }
                try validateManagedImageCapacity(rasters)
                guard Set(archive.rasterFrameIndices.keys) == decoded.referencedRasterAssetIDs else {
                    throw StudioDocumentError.invalid("The image archive has unaccounted references. Its original bytes were preserved.")
                }
                for (index, frame) in decoded.frames.enumerated() {
                    if let id = frame.rasterAssetID {
                        guard let record = rasters[id], stored.frames[index] == record else {
                            throw StudioDocumentError.invalid("An imported image reference is missing or its frame records disagree.")
                        }
                        try validateManagedRaster(frame: frame, record: record)
                    } else {
                        guard stored.frames[index].imageData == nil, stored.frames[index].layerData == nil,
                              stored.frames[index].sourceImage == nil else {
                            throw StudioDocumentError.invalid("An unreferenced original image record cannot be discarded.")
                        }
                    }
                }
            } else {
                guard stored.frames.allSatisfy({ $0.sourceImage == nil }) else {
                    throw StudioDocumentError.invalid("This imported image project is missing its editable placement archive. Its original bytes were preserved; recovery is required before editing.")
                }
                // Missing legacy images have unknown content. Do not compact their
                // positions, invent replacement images, or rewrite their duration.
                let sourceIndices = stored.frames.enumerated().map { $0.element.legacyFrameIndex ?? $0.offset }
                guard (1...1000).contains(stored.metadata.frameCount),
                      sourceIndices == Array(0..<stored.metadata.frameCount) else {
                    throw StudioDocumentError.unavailable("This historical project has missing or inconsistent frame positions. Recovery is required before editing; its original images, metadata and timing have not been changed.")
                }
                decoded = try StudioDocument.new(name: stored.metadata.title, width: stored.metadata.canvasWidth,
                    height: stored.metadata.canvasHeight, fps: stored.metadata.fps, id: stored.id)
                decoded.createdAt = stored.metadata.createdAt; decoded.modifiedAt = stored.metadata.modifiedAt
                let editableLayer = CanvasLayer(id: "editable-layer-\(stored.id.uuidString)", name: "Layer 1")
                let rasterLayer = CanvasLayer(id: "original-raster-\(stored.id.uuidString)", name: "Original imported image", locked: true)
                decoded.layers = [editableLayer, rasterLayer]; decoded.activeLayerID = editableLayer.id
                decoded.frames = stored.frames.enumerated().map { index, original in
                    let sourceIndex = sourceIndices[index]
                    let asset = "original-\(stored.id.uuidString)-\(sourceIndex)"
                    // Keep opaque LayerData and provenance even when no image is present.
                    rasters[asset] = original
                    return AnimationFrame(id: "legacy-frame-\(stored.id.uuidString)-\(sourceIndex)", elements: [],
                        rasterAssetID: asset, rasterLayerID: rasterLayer.id)
                }
                if decoded.frames.isEmpty { decoded.frames = [AnimationFrame(id: UUID().uuidString, elements: [])] }
                decoded.activeFrameID = decoded.frames[0].id
                try decoded.validate()
            }
            try validateManagedImageCapacity(rasters)
            let nextEditor = try StudioDocumentEditor(document: decoded)
            let importedIDs = decoded.referencedAudioAssetIDs
            // Only records explicitly referenced by the new clip schema become
            // managed; opaque historical/unrelated records remain preserved.
            let managed = stored.audioTracks.filter { importedIDs.contains($0.id) && $0.legacySourceFilename == nil }
            editor = nextEditor; retainedRasterFrames = rasters
            let managedIDs = Set(managed.map(\.id))
            retainedAudioTracks = stored.audioTracks.filter { !managedIDs.contains($0.id) }
            managedAudioTracks = Dictionary(uniqueKeysWithValues: managed.map { ($0.id, $0) })
            savedRevision = decoded.revision; lastSaveTime = decoded.modifiedAt
            resetSession(); isEditing = true
            if stored.editableDocumentData == nil { message = "Original frame records, images and audio are preserved. Imported images are flattened; metadata without image pixels stays preserved but cannot be rendered. Draw editable strokes on Layer 1. Audio playback is unfinished." }
            return true
        } catch { message = "Project could not be opened: \(error.localizedDescription)"; return false }
    }
    @discardableResult
    func save() async -> Bool {
        guard isEditing, !isSaving else { return !isDirty }
        autosaveTask?.cancel(); autosaveTask = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let snapshot = document
            try storage.saveAnimation(storageProject(snapshot, rasters: retainedRasterFrames))
            savedRevision = snapshot.revision; lastSaveTime = Date(); message = nil
            await loadProjects()
            // A save may persist prior committed work during a long stroke, but
            // must not acknowledge the uncommitted touch capture as saved.
            if activeStrokeID != nil { return false }
            if pendingBrushStroke != nil {
                message = "The committed project is saved. A rejected brush draft is still unsaved; retry or discard it before leaving."
                return false
            }
            return true
        } catch { message = "Save failed. Your edits are still open: \(error.localizedDescription)"; return false }
    }
    func backToProjects() async {
        stopPlayback()
        guard activeStrokeID == nil else { message = "Finish the current touch stroke before leaving this project."; return }
        guard pendingBrushStroke == nil else {
            message = "Retry or explicitly discard the rejected brush draft before leaving this project."
            return
        }
        guard await save(), !isDirty else { return }
        isEditing = false; activePanel = .none; await loadProjects()
    }
    func flush() async { if isEditing && isDirty { _ = await save() } }
    private func resetSession() {
        stopPlayback(); autosaveTask?.cancel(); autosaveTask = nil
        activePanel = .none; showToolbar = true; canvasScale = 1; canvasOffset = .zero
        selectedAudioClip = nil; audioPlayheadTime = 0; message = nil
    }
    private func scheduleSave() {
        guard isEditing else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            if self.activeStrokeID != nil { self.scheduleSave(); return }
            _ = await self.save()
        }
    }
    private func command(_ operation: (inout StudioDocumentEditor) throws -> Void) {
        guard allowDocumentEditDuringInput() else { return }
        do {
            var candidate = editor
            try operation(&candidate)
            try preflightRasterDocument(candidate.document)
            editor = candidate; pruneManagedAudio(); scheduleSave()
        } catch { message = error.localizedDescription }
    }
    private func allowDocumentEditDuringInput() -> Bool {
        guard activeStrokeID == nil else { message = "Finish the current touch stroke before changing the document."; return false }
        return true
    }
    private func change(_ operation: (inout StudioDocument) throws -> Void) { command { try $0.change(operation) } }
    func addFrame() { stopPlayback(); command { try $0.addFrame() } }
    func duplicateFrame() { stopPlayback(); command { try $0.duplicateFrame() } }
    func copyFrame() { if allowDocumentEditDuringInput() { editor.copyFrame(); pruneManagedImages() } }
    func pasteFrame() { stopPlayback(); command { try $0.pasteFrame() } }
    func deleteFrame(_ id: String) { stopPlayback(); command { try $0.deleteFrame(id) } }
    func moveFrame(_ id: String, offset: Int) { stopPlayback(); command { try $0.moveFrame(id, offset: offset) } }
    func nextFrame() { if currentFrameIndex + 1 < frames.count { currentFrameIndex += 1 } }
    func prevFrame() { if currentFrameIndex > 0 { currentFrameIndex -= 1 } }
    @discardableResult
    func commitElement(_ element: DrawnElement, frameID: String? = nil) -> Bool {
        guard activeStrokeID == nil || activeStrokeID == element.id else {
            message = "Finish the current touch stroke before adding another drawing."
            return false
        }
        guard pendingBrushStroke == nil || pendingBrushStroke?.element.id == element.id else {
            message = "Retry or discard the rejected drawing draft before adding another drawing."
            return false
        }
        let target = frameID ?? document.activeFrameID
        do {
            var candidate = editor
            try candidate.commit(element, frameID: target)
            try preflightRasterDocument(candidate.document)
            editor = candidate
            if pendingBrushStroke?.element.id == element.id { pendingBrushStroke = nil }
            pruneManagedAudio(); scheduleSave()
            return true
        } catch {
            if element.brush != nil { retainRejectedBrush(element, frameID: target, reason: error.localizedDescription) }
            else { message = error.localizedDescription }
            return false
        }
    }
    func retainRejectedBrush(_ element: DrawnElement, frameID: String, reason: String, inputComplete: Bool = true) {
        guard pendingBrushStroke == nil || pendingBrushStroke?.element.id == element.id else {
            message = "Resolve the existing rejected drawing draft before adding another."
            return
        }
        pendingBrushStroke = PendingBrushStroke(projectID: document.id, frameID: frameID,
            element: element, reason: reason, inputComplete: inputComplete)
        message = reason + " The rejected draft remains open. Retry with current brush settings or discard it explicitly."
    }
    func beginStrokeInput(id: String) -> Bool {
        guard isEditing, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil else { return false }
        activeStrokeID = id
        return true
    }
    func finishStrokeInput(id: String) { if activeStrokeID == id { activeStrokeID = nil } }
    func interruptStrokeInput(_ input: StudioStrokeInput, reason: String) {
        guard activeStrokeID == input.id else { return }
        activeStrokeID = nil
        guard !input.points.isEmpty else { return }
        retainRejectedBrush(input.element, frameID: input.frameID, reason: reason, inputComplete: false)
    }
    func discardRejectedBrush() { pendingBrushStroke = nil; message = nil }
    func retryRejectedBrush() {
        guard let pending = pendingBrushStroke else { return }
        guard pending.inputComplete, pending.projectID == document.id, isEditing else {
            message = "This rejected draft cannot be retried because its input is incomplete or its original project is unavailable. Discard it explicitly and draw a shorter stroke."
            return
        }
        do {
            var element = pending.element
            element.width = strokeWidth; element.color = strokeColorHex
            if element.brush != nil {
                element.opacity = capturedStrokeOpacity
                element.brush = try brushDescriptor(elementID: element.id, seed: element.brush?.seed)
            } else { element.opacity = strokeOpacity }
            _ = commitElement(element, frameID: pending.frameID)
        } catch { message = error.localizedDescription }
    }
    func deleteSelected() { command { try $0.deleteSelected() } }
    func selectElement(at point: CGPoint) {
        editor.selectedElementIDs.removeAll()
        for layer in layers where layer.visible && !layer.isFullyLocked {
            if let element = currentFrame.elements.reversed().first(where: { element in
                guard element.layerID == layer.id, let first = element.points.first else { return false }
                let xs = element.points.map(\.x), ys = element.points.map(\.y)
                let tolerance = max(12, element.width * 2)
                return point.x >= (xs.min() ?? first.x) - tolerance && point.x <= (xs.max() ?? first.x) + tolerance
                    && point.y >= (ys.min() ?? first.y) - tolerance && point.y <= (ys.max() ?? first.y) + tolerance
            }) { editor.selectedElementIDs = [element.id]; break }
        }
        message = "Move currently selects an element for deletion. Dragging selections is unfinished."
    }
    func clearCanvas() { message = "Select elements explicitly before deleting. The canvas has not changed." }
    func selectLayer(_ id: String) {
        guard allowDocumentEditDuringInput() else { return }
        stopPlayback()
        if editor.selectLayer(id) { scheduleSave() }
    }
    func toggleLayerVisibility(_ id: String) { command { try $0.updateLayer(id) { $0.visible.toggle() } } }
    func toggleLayerLock(_ id: String) { command { try $0.updateLayer(id) { layer in layer.locked.toggle(); layer.lockMode = layer.locked ? "full" : "free" } } }
    func setLayerLockMode(_ id: String, mode: LayerLockMode) {
        if mode == .alpha { message = "Alpha-lock painting is unfinished. The layer lock was not changed."; return }
        command { try $0.updateLayer(id) { $0.lockMode = mode.rawValue; $0.locked = mode == .full } }
    }
    func setLayerOpacity(_ id: String, opacity: Double) { command { try $0.updateLayer(id) { $0.opacity = opacity } } }
    func setLayerBlend(_ id: String, mode: String) { command { try $0.updateLayer(id) { $0.blendMode = mode } } }
    func setLayerGlow(_ id: String, enabled: Bool) { command { try $0.updateLayer(id) { $0.glowEnabled = enabled } } }
    func setLayerColor(_ id: String, color: Color) {
        let hex = Self.hex(color); command { try $0.updateLayer(id) { $0.colorLabel = hex } }
    }
    func duplicateLayer(_ id: String) { command { try $0.duplicateLayer(id) } }
    func moveLayerUp(_ id: String) { command { try $0.moveLayer(id, offset: -1) } }
    func moveLayerDown(_ id: String) { command { try $0.moveLayer(id, offset: 1) } }
    func addLayer() { command { try $0.addLayer() } }
    func zoomIn() { canvasScale = min(canvasScale * 1.25, 5) }
    func zoomOut() { canvasScale = max(canvasScale / 1.25, 0.25) }
    func zoomFit() { canvasScale = 1; canvasOffset = .zero }
    func addAudioClip(sound: SoundEffect, track: Int) { message = "Sound playback and licensed asset import are unfinished. No audio clip was added." }
    /// The Files session must decode with StudioAudioImportService first. These
    /// are ownership/metadata checks, not an independent codec validation claim.
    @discardableResult
    func attachImportedAudio(_ track: AudioTrack, expectedProjectID: UUID, expectedRevision: Int,
                             frameID: String, trackNumber: Int,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> String {
        try checkCancellation()
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil,
              document.id == expectedProjectID, document.revision == expectedRevision,
              document.activeFrameID == frameID, let frame = frames.firstIndex(where: { $0.id == frameID }) else {
            throw StudioDocumentError.unavailable("The project or selected frame changed. Import again in the current project.")
        }
        guard (1...4).contains(trackNumber), track.legacySourceFilename == nil,
              track.startTime == 0, track.duration.isFinite, track.duration > 0, track.duration <= 300,
              !track.name.isEmpty, track.name.count <= 120,
              !track.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ["wav", "aiff", "aifc", "caf", "m4a", "mp3", "aac"].contains(track.format),
              let bytes = track.audioData, !bytes.isEmpty, bytes.count <= 16 * 1024 * 1024,
              audioTrack(forAssetID: track.id) == nil else {
            throw StudioDocumentError.invalid("The decoded audio asset has invalid metadata or conflicts with an existing asset.")
        }
        let clip = AudioClip(id: UUID().uuidString, soundName: track.name, track: trackNumber,
            startTime: Double(frame) / Double(fps), duration: track.duration, assetID: track.id)
        var candidate = editor
        try candidate.change { $0.audioClips.append(clip) }
        let liveIDs = candidate.referencedAudioAssetIDsIncludingHistory
        var next = managedAudioTracks.filter { liveIDs.contains($0.key) }
        guard next.count < 128,
              next.values.reduce(0, { $0 + ($1.audioData?.count ?? 0) }) <= Self.maximumManagedAudioBytes - bytes.count else {
            throw StudioDocumentError.unavailable("Imported audio and its undo history are limited to 32 MB. Remove unused clips and allow their undo history to expire, or use smaller audio files.")
        }
        next[track.id] = track
        if !candidate.document.referencedRasterAssetIDs.isEmpty {
            let tracks = retainedAudioTracks + next.values.filter { candidate.document.referencedAudioAssetIDs.contains($0.id) }
            try storage.preflightAnimation(storageProject(candidate.document, rasters: retainedRasterFrames, audioTracks: tracks))
        }
        try checkCancellation()
        // Publish the bytes and the single undoable document edit together.
        managedAudioTracks = next; editor = candidate; selectedAudioClip = clip
        stopPlayback(); scheduleSave()
        return clip.id
    }
    private func audioTracksForSave(_ snapshot: StudioDocument) throws -> [AudioTrack] {
        let tracks = retainedAudioTracks + managedAudioTracks.values.filter { snapshot.referencedAudioAssetIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for clip in snapshot.audioClips where clip.assetID != nil {
            guard let asset = tracks.first(where: { $0.id == clip.assetID }), asset.audioData != nil,
                  asset.duration > 0, clip.sourceOffset + clip.duration <= asset.duration + 0.001 else {
                throw StudioDocumentError.invalid("An imported audio asset is missing or has inconsistent timing. No save was made.")
            }
        }
        return tracks
    }
    private func pruneManagedAudio() {
        let needed = editor.referencedAudioAssetIDsIncludingHistory
        managedAudioTracks = managedAudioTracks.filter { needed.contains($0.key) }
        pruneManagedImages()
    }
    /// The same command entry point is usable by Studio UI and validated assistants.
    /// Source bytes stay immutable; only a selected clip in the captured revision changes.
    func editSelectedAudioClip(_ id: String, expectedRevision: Int, edit: StudioAudioClipEdit) throws {
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil,
              document.revision == expectedRevision, selectedCurrentAudioClip?.id == id,
              let index = document.audioClips.firstIndex(where: { $0.id == id }),
              let assetID = document.audioClips[index].assetID,
              let asset = audioTrack(forAssetID: assetID), asset.audioData != nil else {
            throw StudioDocumentError.unavailable("Select a saved audio clip in the current idle project before editing it.")
        }
        var clip = document.audioClips[index]
        switch edit {
        case .place(let start, let track): clip.startTime = start; clip.track = track
        case .trim(let offset, let duration): clip.sourceOffset = offset; clip.duration = duration
        case .volume(let value): clip.volume = value
        case .mute(let value): clip.isMuted = value
        }
        guard clip.sourceOffset.isFinite, clip.duration.isFinite, clip.sourceOffset >= 0,
              clip.duration >= 1 / 48_000.0, asset.duration.isFinite,
              clip.sourceOffset + clip.duration <= asset.duration + 1 / 48_000.0 else {
            throw StudioDocumentError.invalid("The trim must contain real audio within the source file.")
        }
        guard clip != document.audioClips[index] else { return }
        var candidate = editor
        try candidate.change { value in
            value.schemaVersion = max(value.schemaVersion, 4)
            value.audioClips[index] = clip
        }
        try preflightRasterDocument(candidate.document)
        _ = try audioTracksForSave(candidate.document)
        editor = candidate; selectedAudioClip = clip; message = nil; scheduleSave()
    }
    func setAudioTrackMuted(_ track: Int, muted: Bool, expectedRevision: Int) throws {
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil,
              expectedRevision == document.revision, (1...4).contains(track) else {
            throw StudioDocumentError.unavailable("Stop playback before muting this track.")
        }
        let ids = document.audioClips.filter { $0.track == track }.map(\.id)
        guard !ids.isEmpty else { return }
        guard document.audioClips.filter({ ids.contains($0.id) }).allSatisfy({ $0.assetID != nil }) else {
            throw StudioDocumentError.unavailable("This track includes historical audio with unavailable source bytes.")
        }
        guard document.audioClips.contains(where: { ids.contains($0.id) && $0.isMuted != muted }) else { return }
        var candidate = editor
        try candidate.change { value in
            value.schemaVersion = max(value.schemaVersion, 4)
            for index in value.audioClips.indices where ids.contains(value.audioClips[index].id) {
                value.audioClips[index].isMuted = muted
            }
        }
        try preflightRasterDocument(candidate.document); _ = try audioTracksForSave(candidate.document)
        editor = candidate
        selectedAudioClip = selectedAudioClip.flatMap { selected in document.audioClips.first { $0.id == selected.id } }
        message = nil; scheduleSave()
    }
    /// Real audio-player time drives the display frame; no second animation timer.
    func displayAudioPlaybackTime(_ seconds: Double, playing: Bool) {
        guard seconds.isFinite, seconds >= 0, seconds <= audioDuration, !frames.isEmpty else { return }
        playbackTimer?.invalidate(); playbackTimer = nil
        audioPlayheadTime = seconds
        let target = min(frames.count - 1, max(0, Int((seconds * Double(fps)).rounded(.down))))
        if playing {
            playbackFrameIndex = target; isPlaying = true
        } else {
            playbackFrameIndex = nil; isPlaying = false
            guard isEditing, activeStrokeID == nil, pendingBrushStroke == nil else { return }
            if editor.selectFrame(frames[target].id) { scheduleSave() }
        }
    }
    func setAudioClipVolume(_ id: String, volume: Double) {
        guard selectedCurrentAudioClip?.id == id else { return }
        change { value in
            guard let index = value.audioClips.firstIndex(where: { $0.id == id }) else { return }
            value.audioClips[index].volume = volume
        }
        selectedAudioClip = document.audioClips.first { $0.id == id }
    }
    func deleteAudioClip(_ id: String) {
        guard selectedCurrentAudioClip?.id == id else { return }
        change { $0.audioClips.removeAll { $0.id == id } }; selectedAudioClip = nil
    }
    /// The picker/decoder owner must retain its result until this atomic handoff
    /// succeeds. No image is attached on rejection, and no save success is implied.
    @discardableResult
    func attachImportedImage(_ imported: StudioImageImportService.ImportedImage,
                             expectedProjectID: UUID, expectedRevision: Int, frameID: String, layerID: String,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> String {
        try checkCancellation()
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil,
              document.id == expectedProjectID, document.revision == expectedRevision,
              document.activeFrameID == frameID, document.activeLayerID == layerID,
              let index = document.frames.firstIndex(where: { $0.id == frameID }) else {
            throw StudioDocumentError.unavailable("The project, frame, layer, save or drawing state changed. Import again in the current editor.")
        }
        guard document.frames[index].rasterAssetID == nil else {
            throw StudioDocumentError.unavailable("This frame already contains an imported image or original record. Add a new blank frame; nothing was replaced.")
        }
        guard let layer = document.layers.first(where: { $0.id == layerID }), layer.visible, !layer.isFullyLocked else { throw StudioDocumentError.locked }
        let assetID = "image-" + imported.id.uuidString
        guard retainedRasterFrames[assetID] == nil else { throw StudioDocumentError.invalid("This image identity is already owned by the project.") }
        let source = StoredImageSource(id: imported.id, name: imported.name, container: imported.container.rawValue,
            originalData: imported.originalData, originalWidth: imported.originalWidth, originalHeight: imported.originalHeight,
            originalOrientation: imported.originalOrientation, normalizedWidth: imported.width, normalizedHeight: imported.height)
        try StudioRasterImage.validate(source: source, normalized: imported.normalizedPNG)
        let record = StoredAnimationFrame(imageData: imported.normalizedPNG, layerData: nil, sourceImage: source)
        let imageLayer = CanvasLayer(id: UUID().uuidString, name: String(("Image: " + imported.name).prefix(120)))
        let placement = StudioRasterPlacement.aspectFit(imageWidth: imported.width, imageHeight: imported.height,
            canvasWidth: document.width, canvasHeight: document.height)
        var candidate = editor
        try candidate.change { value in
            value.schemaVersion = max(value.schemaVersion, 3)
            value.layers.append(imageLayer) // Behind drawings; active drawing layer stays selected.
            value.frames[index].rasterAssetID = assetID
            value.frames[index].rasterLayerID = imageLayer.id
            value.frames[index].rasterPlacement = placement
        }
        let needed = candidate.referencedRasterAssetIDsIncludingHistoryAndClipboard
        var next = retainedRasterFrames.filter { $0.value.sourceImage == nil || needed.contains($0.key) }
        next[assetID] = record
        try validateManagedImageCapacity(next)
        try storage.preflightAnimation(storageProject(candidate.document, rasters: next))
        try checkCancellation()
        // No suspension occurs between the state guard, exact storage preflight
        // and publication of one history transaction plus its immutable bytes.
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil,
              document.id == expectedProjectID, document.revision == expectedRevision,
              document.activeFrameID == frameID, document.activeLayerID == layerID else {
            throw StudioDocumentError.unavailable("The editor changed before the image could be attached. No image was added.")
        }
        retainedRasterFrames = next; editor = candidate
        scheduleSave()
        return assetID
    }
    func originalImageSource(_ assetID: String) -> StoredImageSource? { retainedRasterFrames[assetID]?.sourceImage }
    var managedImageByteCount: Int {
        retainedRasterFrames.values.filter { $0.sourceImage != nil }.reduce(0) { $0 + ($1.imageData?.count ?? 0) + ($1.sourceImage?.originalData.count ?? 0) }
    }
    private func validateManagedImageCapacity(_ records: [String: StoredAnimationFrame]) throws {
        var bytes = 0, pixels = 0
        for record in records.values {
            guard let source = record.sourceImage else { continue }
            try source.validate()
            bytes += source.originalData.count + (record.imageData?.count ?? 0)
            pixels += source.normalizedWidth * source.normalizedHeight
            guard bytes <= StudioRasterImage.maximumManagedHistoryBytes,
                  pixels <= StudioRasterImage.maximumManagedHistoryPixels else { throw StudioRasterImage.Failure.limit }
        }
    }
    private func validateManagedRaster(frame: AnimationFrame, record: StoredAnimationFrame) throws {
        if let source = record.sourceImage {
            guard frame.rasterPlacement != nil, frame.rasterAssetID == "image-" + source.id.uuidString,
                  let normalized = record.imageData else { throw StudioRasterImage.Failure.missing }
            try StudioRasterImage.validate(source: source, normalized: normalized)
        } else if frame.rasterPlacement != nil { throw StudioRasterImage.Failure.missing }
    }
    private func storageProject(_ snapshot: StudioDocument, rasters: [String: StoredAnimationFrame],
                                audioTracks: [AudioTrack]? = nil) throws -> AnimationProject {
        var indices: [String: Int] = [:]
        let frames = try snapshot.frames.enumerated().map { index, frame -> StoredAnimationFrame in
            guard let asset = frame.rasterAssetID else { return StoredAnimationFrame(imageData: nil, layerData: nil) }
            guard let record = rasters[asset] else { throw StudioRasterImage.Failure.missing }
            // Full codec validation occurs on import/open; these immutable
            // records are identity checked during each subsequent save/preflight.
            if frame.rasterPlacement != nil {
                guard let source = record.sourceImage, record.imageData?.isEmpty == false,
                      asset == "image-" + source.id.uuidString else { throw StudioRasterImage.Failure.missing }
            }
            indices[asset] = index; return record
        }
        let metadata = AnimationMetadata(id: snapshot.id, title: snapshot.name, fps: snapshot.fps,
            canvasWidth: snapshot.width, canvasHeight: snapshot.height, frameCount: snapshot.frames.count,
            layerCount: snapshot.layers.count, createdAt: snapshot.createdAt, modifiedAt: snapshot.modifiedAt, thumbnailData: nil)
        return AnimationProject(id: snapshot.id, metadata: metadata, frames: frames,
            audioTracks: try audioTracks ?? audioTracksForSave(snapshot),
            editableDocumentData: try StudioDocumentArchive(document: snapshot, rasterFrameIndices: indices).encoded())
    }
    private func preflightRasterDocument(_ candidate: StudioDocument) throws {
        guard !candidate.referencedRasterAssetIDs.isEmpty else { return }
        try storage.preflightAnimation(storageProject(candidate, rasters: retainedRasterFrames))
    }
    private func pruneManagedImages() {
        let needed = editor.referencedRasterAssetIDsIncludingHistoryAndClipboard
        retainedRasterFrames = retainedRasterFrames.filter { $0.value.sourceImage == nil || needed.contains($0.key) }
    }
    func rasterData(_ assetID: String?) -> Data? { assetID.flatMap { retainedRasterFrames[$0]?.imageData } }
    func undo() { stopPlayback(); command { $0.undo() } }
    func redo() { stopPlayback(); command { $0.redo() } }
    func togglePlayback() { if isPlaying { stopPlayback() } else { startPlayback() } }
    private func startPlayback() {
        guard allowDocumentEditDuringInput() else { return }
        guard frames.count > 1 else { return }
        playbackFrameIndex = currentFrameIndex; isPlaying = true
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1 / Double(fps), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.advancePlaybackFrame()
            }
        }
    }
    func advancePlaybackFrame() {
        guard isPlaying else { return }
        playbackFrameIndex = (currentFrameIndex + 1) % frames.count
        audioPlayheadTime = Double(currentFrameIndex) / Double(fps)
    }
    func stopPlayback() { isPlaying = false; playbackTimer?.invalidate(); playbackTimer = nil; playbackFrameIndex = nil }
}

enum StudioPanelType: String {
    case none, colorPicker, toolSettings, projectSettings, layers, export, framesViewer, audioTimeline
    case soundLibrary, stickerEmoji, addImage, backgroundLibrary, menu, aiVoice, spatterAI, magicCut, rotoscope
}
extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
