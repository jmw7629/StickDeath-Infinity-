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
    private var savedRevision: Int?
    private let storage: DeviceStorageManager
    private var retainedRasterFrames: [String: StoredAnimationFrame] = [:]
    private var retainedAudioTracks: [AudioTrack] = []
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
    var canUndo: Bool { editor.canUndo }
    var canRedo: Bool { editor.canRedo }
    var canPaste: Bool { editor.canPaste }
    var canDeleteSelected: Bool { !editor.selectedElementIDs.isEmpty }
    var selectedElementIDs: Set<String> { editor.selectedElementIDs }
    var isDirty: Bool { savedRevision != document.revision }
    var saveTimeAgo: String { isSaving ? "Saving…" : isDirty ? "Unsaved" : "Saved" }

    @Published var selectedTool: DrawingTool = .brush
    @Published var strokeColor: Color = .red
    @Published var strokeWidth: Double = 3
    @Published var strokeOpacity: Double = 1
    var toolOpacity: Double { get { strokeOpacity } set { strokeOpacity = min(1, max(0, newValue)) } }
    @Published var smoothing: Double = 3
    @Published var pressureSensitivity = true
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
    var audioDuration: Double { Double(frames.count) / Double(fps) }
    var strokeColorHex: String { Self.hex(strokeColor) }

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
        guard !isEditing else { message = "Save and return to projects before creating another animation."; return false }
        do {
            editor = try StudioDocumentEditor(document: .new(name: name, width: width, height: height, fps: fps))
            retainedRasterFrames.removeAll(); retainedAudioTracks.removeAll()
            savedRevision = nil; lastSaveTime = nil; resetSession(); isEditing = true
            return await save()
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult
    func openProject(_ metadata: AnimationMetadata) async -> Bool {
        guard !isEditing else { message = "Save and return to projects before opening another animation."; return false }
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
                for frame in decoded.frames where frame.rasterAssetID != nil {
                    guard rasters[frame.rasterAssetID!] != nil else { throw StudioDocumentError.invalid("An imported image reference is missing.") }
                }
            } else {
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
            let nextEditor = try StudioDocumentEditor(document: decoded)
            editor = nextEditor; retainedRasterFrames = rasters; retainedAudioTracks = stored.audioTracks
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
            var indices: [String: Int] = [:]
            let storedFrames: [StoredAnimationFrame] = try snapshot.frames.enumerated().map { index, frame in
                guard let asset = frame.rasterAssetID else { return StoredAnimationFrame(imageData: nil, layerData: nil) }
                guard let original = retainedRasterFrames[asset] else { throw StudioDocumentError.invalid("An original image is unavailable; no save was made.") }
                indices[asset] = index; return original
            }
            let metadata = AnimationMetadata(id: snapshot.id, title: snapshot.name, fps: snapshot.fps,
                canvasWidth: snapshot.width, canvasHeight: snapshot.height, frameCount: snapshot.frames.count,
                layerCount: snapshot.layers.count, createdAt: snapshot.createdAt, modifiedAt: snapshot.modifiedAt, thumbnailData: nil)
            let payload = try StudioDocumentArchive(document: snapshot, rasterFrameIndices: indices).encoded()
            try storage.saveAnimation(AnimationProject(id: snapshot.id, metadata: metadata, frames: storedFrames,
                audioTracks: retainedAudioTracks, editableDocumentData: payload))
            savedRevision = snapshot.revision; lastSaveTime = Date(); message = nil
            await loadProjects()
            return true
        } catch { message = "Save failed. Your edits are still open: \(error.localizedDescription)"; return false }
    }
    func backToProjects() async {
        stopPlayback()
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
            _ = await self.save()
        }
    }
    private func command(_ operation: (inout StudioDocumentEditor) throws -> Void) {
        do { try operation(&editor); scheduleSave() } catch { message = error.localizedDescription }
    }
    private func change(_ operation: (inout StudioDocument) throws -> Void) { command { try $0.change(operation) } }
    func addFrame() { stopPlayback(); command { try $0.addFrame() } }
    func duplicateFrame() { stopPlayback(); command { try $0.duplicateFrame() } }
    func copyFrame() { editor.copyFrame() }
    func pasteFrame() { stopPlayback(); command { try $0.pasteFrame() } }
    func deleteFrame(_ id: String) { stopPlayback(); command { try $0.deleteFrame(id) } }
    func moveFrame(_ id: String, offset: Int) { stopPlayback(); command { try $0.moveFrame(id, offset: offset) } }
    func nextFrame() { if currentFrameIndex + 1 < frames.count { currentFrameIndex += 1 } }
    func prevFrame() { if currentFrameIndex > 0 { currentFrameIndex -= 1 } }
    func commitElement(_ element: DrawnElement, frameID: String? = nil) {
        let target = frameID ?? document.activeFrameID
        command { try $0.commit(element, frameID: target) }
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
    func deleteAudioClip(_ id: String) { change { $0.audioClips.removeAll { $0.id == id } }; selectedAudioClip = nil }
    func rasterData(_ assetID: String?) -> Data? { assetID.flatMap { retainedRasterFrames[$0]?.imageData } }
    func undo() { stopPlayback(); editor.undo(); scheduleSave() }
    func redo() { stopPlayback(); editor.redo(); scheduleSave() }
    func togglePlayback() { if isPlaying { stopPlayback() } else { startPlayback() } }
    private func startPlayback() {
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
