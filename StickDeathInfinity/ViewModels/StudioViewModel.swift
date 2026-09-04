// ═══════════════════════════════════════════════════════════════════
// StudioViewModel — Full animation studio state (MVVM)
// Replaces: StudioScreen.tsx's 6,378 lines of inline state
// Manages: frames, layers, tools, undo/redo, playback, audio, export
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import Supabase

@MainActor
final class StudioViewModel: ObservableObject {
    // MARK: - Project List
    @Published var savedProjects: [StudioProject] = []
    @Published var currentProjectID: String?

    // MARK: - Project
    @Published var projectName = "Untitled Animation"
    @Published var canvasWidth = 1080
    @Published var canvasHeight = 1080
    @Published var fps = 12

    // MARK: - Frames
    @Published var frames: [AnimationFrame] = [
        AnimationFrame(id: UUID().uuidString, elements: [])
    ]
    @Published var currentFrameIndex = 0

    var currentFrame: AnimationFrame {
        get { frames[safe: currentFrameIndex] ?? frames[0] }
    }

    var previousFrame: AnimationFrame? {
        guard currentFrameIndex > 0 else { return nil }
        return frames[currentFrameIndex - 1]
    }

    // MARK: - Layers (single source of truth: studioLayers)
    @Published var studioLayers: [StudioLayer] = [
        StudioLayer(name: "Layer 1")
    ]
    @Published var layers: [CanvasLayer] = [
        CanvasLayer(id: UUID().uuidString, name: "Layer 1", visible: true, locked: false, opacity: 1.0)
    ]
    @Published var activeLayerID: String = ""
    @Published var currentLayerIndex: Int = 0

    // MARK: - Element Selection
    @Published var selectedElementIDs: Set<String> = []

    var hasSelection: Bool { !selectedElementIDs.isEmpty }

    var selectedElements: [DrawnElement] {
        currentFrame.elements.filter { selectedElementIDs.contains($0.id) }
    }

    // MARK: - Clipboard
    @Published var clipboardElements: [DrawnElement] = []
    var canPaste: Bool { !clipboardElements.isEmpty }

    // MARK: - Tool State
    @Published var selectedTool: DrawingTool = .brush
    @Published var strokeColor: Color = .red
    @Published var strokeWidth: Double = 3
    @Published var strokeOpacity: Double = 1.0
    @Published var toolOpacity: Double = 1.0
    @Published var smoothing: Double = 3
    @Published var pressureSensitivity: Bool = true
    @Published var showOnionSkin = false
    @Published var gridEnabled = false

    // Eraser settings
    @Published var eraserType: EraserType = .hard

    // Text settings
    @Published var textFontSize: Double = 24
    @Published var textAlignment: DrawnElement.TextAlignment = .left
    @Published var textBold: Bool = false
    @Published var textItalic: Bool = false

    // Smudge settings
    @Published var smudgeStrength: Double = 50

    // Shape settings
    @Published var shapeCornerRadius: Double = 0

    // Lasso settings
    @Published var lassoMode: LassoMode = .freehand
    @Published var lassoFeather: Double = 0
    @Published var lassoSmoothness: Double = 3

    // Move tool settings
    @Published var selectionMode: SelectionMode = .new

    // Fill tool properties (GREEN theme in preview)
    @Published var fillTolerance: Double = 32
    @Published var fillExpand: Double = 0
    @Published var fillGapClose: Double = 0
    @Published var fillContiguous: Bool = true
    @Published var fillAntiAlias: Bool = true
    @Published var fillSampleAll: Bool = false

    var strokeColorHex: String {
        let uiColor = UIColor(strokeColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    // MARK: - UI State
    @Published var activePanel: StudioPanelType = .none
    @Published var showToolbar = true
    @Published var isPlaying = false
    @Published var canvasScale: CGFloat = 1.0
    @Published var canvasOffset: CGSize = .zero
    @Published var lastSaveTime: Date = Date()

    // MARK: - Audio State
    @Published var audioClips: [AudioClip] = []
    @Published var audioPlayheadTime: Double = 0
    @Published var audioDuration: Double = 5.0
    @Published var snapEnabled: Bool = true
    @Published var selectedAudioClip: AudioClip?

    // MARK: - Export State
    @Published var exportFormat: ExportFormat = .mp4
    @Published var exportQuality: ExportQuality = .standard

    // MARK: - Drawing State
    @Published var currentStroke: [StrokePoint] = []

    // MARK: - Undo/Redo
    private var undoStack: [[AnimationFrame]] = []
    private var redoStack: [[AnimationFrame]] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Playback
    private var playbackTimer: Timer?

    var saveTimeAgo: String {
        let seconds = Int(-lastSaveTime.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    init() {
        activeLayerID = layers.first?.id ?? ""
        Task { await loadProjects() }
    }

    // MARK: - Project List Operations
    func loadProjects() async {
        guard let userId = AuthService.shared.userId else { return }
        let supabase = SupabaseManager.shared.client
        do {
            let projects: [StudioProject] = try await supabase
                .from("studio_projects")
                .select("*")
                .eq("user_id", value: userId)
                .order("updated_at", ascending: false)
                .execute()
                .value
            savedProjects = projects
        } catch {
            print("[Studio] Load projects error: \(error)")
        }
    }

    func createProject(name: String, width: Int, height: Int, fps: Int) {
        projectName = name
        canvasWidth = width
        canvasHeight = height
        self.fps = fps
        frames = [AnimationFrame(id: UUID().uuidString, elements: [])]
        layers = [CanvasLayer(id: UUID().uuidString, name: "Layer 1", visible: true, locked: false, opacity: 1.0)]
        studioLayers = [StudioLayer(name: "Layer 1")]
        activeLayerID = layers.first?.id ?? ""
        currentFrameIndex = 0
        currentLayerIndex = 0
        selectedElementIDs.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        audioClips.removeAll()
    }

    func openProject(_ project: StudioProject) {
        currentProjectID = project.id
        projectName = project.name
        canvasWidth = project.width ?? 1080
        canvasHeight = project.height ?? 1080
        fps = project.fps ?? 12
    }

    // MARK: - Frame Operations
    func addFrame() {
        pushUndo()
        let newFrame = AnimationFrame(id: UUID().uuidString, elements: [])
        frames.insert(newFrame, at: currentFrameIndex + 1)
        currentFrameIndex += 1
        lastSaveTime = Date()
    }

    func duplicateFrame() {
        pushUndo()
        let current = currentFrame
        let dupe = AnimationFrame(
            id: UUID().uuidString,
            elements: current.elements.map { el in
                DrawnElement(
                    id: UUID().uuidString,
                    tool: el.tool,
                    points: el.points,
                    color: el.color,
                    width: el.width,
                    opacity: el.opacity,
                    fillColor: el.fillColor,
                    layerID: el.layerID,
                    cornerRadius: el.cornerRadius,
                    textContent: el.textContent,
                    fontSize: el.fontSize,
                    textAlignment: el.textAlignment,
                    isBold: el.isBold,
                    isItalic: el.isItalic,
                    isFlippedH: el.isFlippedH,
                    isFlippedV: el.isFlippedV,
                    locked: el.locked
                )
            },
            backgroundColor: current.backgroundColor,
            backgroundGradientColors: current.backgroundGradientColors
        )
        frames.insert(dupe, at: currentFrameIndex + 1)
        currentFrameIndex += 1
        lastSaveTime = Date()
    }

    func deleteFrame() {
        guard frames.count > 1 else { return }
        pushUndo()
        frames.remove(at: currentFrameIndex)
        currentFrameIndex = min(currentFrameIndex, frames.count - 1)
        lastSaveTime = Date()
    }

    func nextFrame() {
        if currentFrameIndex < frames.count - 1 { currentFrameIndex += 1 }
        selectedElementIDs.removeAll()
    }

    func prevFrame() {
        if currentFrameIndex > 0 { currentFrameIndex -= 1 }
        selectedElementIDs.removeAll()
    }

    // MARK: - Element Operations
    func commitElement(_ element: DrawnElement) {
        pushUndo()
        frames[currentFrameIndex].elements.append(element)
        lastSaveTime = Date()
    }

    func deleteSelected() {
        guard hasSelection else {
            guard !frames[currentFrameIndex].elements.isEmpty else { return }
            pushUndo()
            frames[currentFrameIndex].elements.removeLast()
            selectedElementIDs.removeAll()
            lastSaveTime = Date()
            return
        }
        pushUndo()
        frames[currentFrameIndex].elements.removeAll { selectedElementIDs.contains($0.id) }
        selectedElementIDs.removeAll()
        lastSaveTime = Date()
    }

    func clearCanvas() {
        pushUndo()
        frames[currentFrameIndex].elements.removeAll()
        selectedElementIDs.removeAll()
        lastSaveTime = Date()
    }

    // MARK: - Element Selection
    func selectElement(id: String, addToSelection: Bool = false) {
        if addToSelection {
            if selectedElementIDs.contains(id) {
                selectedElementIDs.remove(id)
            } else {
                selectedElementIDs.insert(id)
            }
        } else {
            selectedElementIDs = [id]
        }
    }

    func deselectAll() {
        selectedElementIDs.removeAll()
    }

    func selectAll() {
        selectedElementIDs = Set(currentFrame.elements.map { $0.id })
    }

    // MARK: - Clipboard
    func copySelected() {
        guard hasSelection else { return }
        clipboardElements = currentFrame.elements.filter { selectedElementIDs.contains($0.id) }
    }

    func copyAll() {
        clipboardElements = currentFrame.elements
    }

    func cutSelected() {
        copySelected()
        deleteSelected()
    }

    func paste() {
        guard canPaste else { return }
        pushUndo()
        let newElements = clipboardElements.map { el in
            DrawnElement(
                id: UUID().uuidString,
                tool: el.tool,
                points: el.points.map { StrokePoint(x: $0.x + 20, y: $0.y + 20, pressure: $0.pressure, timestamp: $0.timestamp) },
                color: el.color,
                width: el.width,
                opacity: el.opacity,
                fillColor: el.fillColor,
                layerID: el.layerID,
                cornerRadius: el.cornerRadius,
                textContent: el.textContent,
                fontSize: el.fontSize,
                textAlignment: el.textAlignment,
                isBold: el.isBold,
                isItalic: el.isItalic,
                isFlippedH: el.isFlippedH,
                isFlippedV: el.isFlippedV,
                locked: el.locked
            )
        }
        frames[currentFrameIndex].elements.append(contentsOf: newElements)
        selectedElementIDs = Set(newElements.map { $0.id })
        lastSaveTime = Date()
    }

    // MARK: - Element Transform (Move tool)
    func moveSelectedBy(dx: CGFloat, dy: CGFloat) {
        guard hasSelection else { return }
        for id in selectedElementIDs {
            if let idx = frames[currentFrameIndex].elements.firstIndex(where: { $0.id == id }) {
                for pi in frames[currentFrameIndex].elements[idx].points.indices {
                    frames[currentFrameIndex].elements[idx].points[pi].x += dx
                    frames[currentFrameIndex].elements[idx].points[pi].y += dy
                }
            }
        }
    }

    func flipSelected(horizontal: Bool) {
        guard hasSelection else { return }
        pushUndo()
        for id in selectedElementIDs {
            if let idx = frames[currentFrameIndex].elements.firstIndex(where: { $0.id == id }) {
                frames[currentFrameIndex].elements[idx].isFlippedH.toggle()
            }
        }
        lastSaveTime = Date()
    }

    func flipSelectedVertical() {
        guard hasSelection else { return }
        pushUndo()
        for id in selectedElementIDs {
            if let idx = frames[currentFrameIndex].elements.firstIndex(where: { $0.id == id }) {
                frames[currentFrameIndex].elements[idx].isFlippedV.toggle()
            }
        }
        lastSaveTime = Date()
    }

    func lockSelected() {
        guard hasSelection else { return }
        pushUndo()
        for id in selectedElementIDs {
            if let idx = frames[currentFrameIndex].elements.firstIndex(where: { $0.id == id }) {
                frames[currentFrameIndex].elements[idx].locked = true
            }
        }
        selectedElementIDs.removeAll()
        lastSaveTime = Date()
    }

    func bringSelectedForward() {
        guard hasSelection else { return }
        pushUndo()
        var els = frames[currentFrameIndex].elements
        for i in stride(from: els.count - 2, through: 0, by: -1) {
            if selectedElementIDs.contains(els[i].id) {
                els.swapAt(i, i + 1)
            }
        }
        frames[currentFrameIndex].elements = els
        lastSaveTime = Date()
    }

    func sendSelectedBackward() {
        guard hasSelection else { return }
        pushUndo()
        var els = frames[currentFrameIndex].elements
        for i in 1..<els.count {
            if selectedElementIDs.contains(els[i].id) {
                els.swapAt(i, i - 1)
            }
        }
        frames[currentFrameIndex].elements = els
        lastSaveTime = Date()
    }

    func deleteSelectionClear() {
        guard hasSelection else { return }
        pushUndo()
        frames[currentFrameIndex].elements.removeAll { selectedElementIDs.contains($0.id) }
        selectedElementIDs.removeAll()
        lastSaveTime = Date()
    }

    // MARK: - Layer Operations
    func toggleLayerVisibility(_ id: String) {
        if let idx = layers.firstIndex(where: { $0.id == id }) {
            layers[idx].visible.toggle()
            syncStudioLayersFromLayers()
        }
    }

    func toggleLayerLock(_ id: String) {
        if let idx = layers.firstIndex(where: { $0.id == id }) {
            layers[idx].locked.toggle()
            syncStudioLayersFromLayers()
        }
    }

    func toggleLayerVisibility(_ id: UUID) {
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            studioLayers[idx].visible.toggle()
            syncLayersFromStudioLayers()
        }
    }

    func setLayerLockMode(_ id: UUID, mode: LayerLockMode) {
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            studioLayers[idx].lockMode = mode
            syncLayersFromStudioLayers()
        }
    }

    func setLayerOpacity(_ id: UUID, opacity: Double) {
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            studioLayers[idx].opacity = opacity
            syncLayersFromStudioLayers()
        }
    }

    func setLayerBlendMode(_ id: UUID, blendMode: String) {
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            studioLayers[idx].blendMode = blendMode
            syncLayersFromStudioLayers()
        }
    }

    func setLayerColor(_ id: UUID, color: Color) {
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            studioLayers[idx].labelColor = color
        }
    }

    func duplicateLayer(_ id: UUID) {
        pushUndo()
        guard let idx = studioLayers.firstIndex(where: { $0.id == id }) else { return }
        let original = studioLayers[idx]
        let newLayer = StudioLayer(
            name: "\(original.name) Copy",
            visible: original.visible,
            opacity: original.opacity,
            lockMode: original.lockMode,
            blendMode: original.blendMode,
            labelColor: original.labelColor
        )
        studioLayers.insert(newLayer, at: idx + 1)
        let canvasLayer = CanvasLayer(
            id: newLayer.id.uuidString, name: newLayer.name,
            visible: newLayer.visible, locked: newLayer.lockMode == .full,
            opacity: newLayer.opacity, lockMode: newLayer.lockMode.rawValue,
            blendMode: newLayer.blendMode
        )
        layers.insert(canvasLayer, at: idx + 1)
        lastSaveTime = Date()
    }

    func moveLayerUp(_ id: UUID) {
        pushUndo()
        guard let idx = studioLayers.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        studioLayers.swapAt(idx, idx - 1)
        syncLayersFromStudioLayers()
        lastSaveTime = Date()
    }

    func moveLayerDown(_ id: UUID) {
        pushUndo()
        guard let idx = studioLayers.firstIndex(where: { $0.id == id }), idx < studioLayers.count - 1 else { return }
        studioLayers.swapAt(idx, idx + 1)
        syncLayersFromStudioLayers()
        lastSaveTime = Date()
    }

    func addLayer() {
        pushUndo()
        let num = studioLayers.count + 1
        let newLayer = StudioLayer(name: "Layer \(num)")
        studioLayers.insert(newLayer, at: 0)
        let canvasLayer = CanvasLayer(
            id: newLayer.id.uuidString, name: newLayer.name,
            visible: true, locked: false, opacity: 1.0
        )
        layers.insert(canvasLayer, at: 0)
        activeLayerID = canvasLayer.id
        currentLayerIndex = 0
        lastSaveTime = Date()
    }

    func renameLayer(_ id: UUID, name: String) {
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            studioLayers[idx].name = name
            syncLayersFromStudioLayers()
        }
    }

    func deleteLayer(_ id: UUID) {
        guard studioLayers.count > 1 else { return }
        pushUndo()
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            let layerID = studioLayers[idx].id.uuidString
            studioLayers.remove(at: idx)
            layers.removeAll { $0.id == layerID }
            if activeLayerID == layerID {
                activeLayerID = layers.first?.id ?? ""
            }
            lastSaveTime = Date()
        }
    }

    func setActiveLayer(_ id: UUID) {
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            currentLayerIndex = idx
            activeLayerID = studioLayers[idx].id.uuidString
        }
    }

    // MARK: - Layer Sync
    func syncLayersFromStudioLayers() {
        layers = studioLayers.map { sl in
            CanvasLayer(
                id: sl.id.uuidString,
                name: sl.name,
                visible: sl.visible,
                locked: sl.lockMode == .full,
                opacity: sl.opacity,
                lockMode: sl.lockMode.rawValue,
                blendMode: sl.blendMode
            )
        }
    }

    func syncStudioLayersFromLayers() {
        for cl in layers {
            if let idx = studioLayers.firstIndex(where: { $0.id.uuidString == cl.id }) {
                studioLayers[idx].visible = cl.visible
                studioLayers[idx].opacity = cl.opacity
                if cl.locked { studioLayers[idx].lockMode = .full }
            }
        }
    }

    func isLayerLocked(_ layerID: String) -> Bool {
        if let cl = layers.first(where: { $0.id == layerID }) {
            return cl.locked
        }
        if let sl = studioLayers.first(where: { $0.id.uuidString == layerID }) {
            return sl.lockMode == .full
        }
        return false
    }

    func isLayerVisible(_ layerID: String) -> Bool {
        if let cl = layers.first(where: { $0.id == layerID }) {
            return cl.visible
        }
        if let sl = studioLayers.first(where: { $0.id.uuidString == layerID }) {
            return sl.visible
        }
        return true
    }

    // MARK: - Canvas Controls
    func zoomIn() { canvasScale = min(canvasScale * 1.25, 5.0) }
    func zoomOut() { canvasScale = max(canvasScale / 1.25, 0.25) }
    func zoomFit() { canvasScale = 1.0; canvasOffset = .zero }

    // MARK: - Audio Operations
    func addAudioClip(sound: SoundEffect, track: Int) {
        let durValue = Double(sound.duration.replacingOccurrences(of: "s", with: "")) ?? 0.5
        let clip = AudioClip(
            id: UUID().uuidString,
            soundName: sound.name,
            track: track,
            startTime: audioPlayheadTime,
            duration: durValue
        )
        audioClips.append(clip)
    }

    func deleteAudioClip(_ id: String) {
        audioClips.removeAll { $0.id == id }
        if selectedAudioClip?.id == id { selectedAudioClip = nil }
    }

    // MARK: - Undo/Redo
    private func pushUndo() {
        undoStack.append(frames)
        redoStack.removeAll()
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    /// Push undo state from external gesture handlers (canvas drag)
    func pushUndoDirect() {
        pushUndo()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(frames)
        frames = prev
        currentFrameIndex = min(currentFrameIndex, frames.count - 1)
        selectedElementIDs.removeAll()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(frames)
        frames = next
        currentFrameIndex = min(currentFrameIndex, frames.count - 1)
        selectedElementIDs.removeAll()
    }

    // MARK: - Playback
    func togglePlayback() {
        if isPlaying { stopPlayback() } else { startPlayback() }
    }

    private func startPlayback() {
        guard frames.count > 1 else { return }
        isPlaying = true
        let interval = 1.0 / Double(fps)
        playbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.currentFrameIndex = (self.currentFrameIndex + 1) % self.frames.count
            }
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    // MARK: - Save/Load
    func save() async {
        guard let userId = AuthService.shared.userId else { return }
        let supabase = SupabaseManager.shared.client
        do {
            let encoder = JSONEncoder()
            let frameData = try encoder.encode(frames)
            let frameJSON = String(data: frameData, encoding: .utf8) ?? "[]"

            try await supabase.from("studio_project_versions").insert([
                "project_id": AnyJSON.null,
                "frame_data": .string(frameJSON),
                "user_id": .string(userId),
            ]).execute()

            lastSaveTime = Date()
            print("[Studio] Saved \(frames.count) frames")
        } catch {
            print("[Studio] Save error: \(error)")
        }
    }
}

// MARK: - Enums
enum EraserType: String, CaseIterable {
    case hard, soft
}

enum LassoMode: String, CaseIterable {
    case freehand, polygon, magnetic, smart
}

enum SelectionMode: String, CaseIterable {
    case new, add, sub
}

// MARK: - Studio Panel Types
enum StudioPanelType: String {
    case none, colorPicker, toolSettings, projectSettings
    case layers, export, framesViewer, audioTimeline
    case soundLibrary, stickerEmoji, addImage, backgroundLibrary
    case menu, aiVoice, spatterAI, magicCut, rotoscope
}

// MARK: - Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
