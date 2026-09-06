// ═══════════════════════════════════════════════════════════════════
// StudioViewModel — Full animation studio state (MVVM)
// Replaces: StudioScreen.tsx's 6,378 lines of inline state
// Manages: frames, layers, tools, undo/redo, playback, audio, export
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import Supabase
import SDCore

@MainActor
final class StudioViewModel: ObservableObject {
    // MARK: - SDCore Coordinator
    let coordinator: SDCoreCoordinator

    // MARK: - Project List
    @Published var savedProjects: [StudioProject] = []
    @Published var currentProjectID: String?

    // MARK: - Project
    @Published var projectName = "Untitled Animation"
    @Published var canvasWidth = 1080
    @Published var canvasHeight = 1080
    @Published var fps = 12

    // MARK: - Frames (app-local mirrors; canonical source is coordinator)
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

    // MARK: - Canonical layers (SDCore CanvasLayer by String ID)
    @Published var layers: [CanvasLayer] = [
        CanvasLayer(id: UUID().uuidString, name: "Layer 1", visible: true, locked: false, opacity: 1.0)
    ]
    @Published var activeLayerID: String = ""
    @Published var currentLayerIndex: Int = 0

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

    init(coordinator: SDCoreCoordinator? = nil) {
        let store = LocalProjectStore(
            baseDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("StudioProjects")
        )
        self.coordinator = coordinator ?? SDCoreCoordinator(store: store)
        activeLayerID = layers.first?.id ?? ""
        Task { await loadProjects() }
    }

    // MARK: - Project List Operations

    func loadProjects() async {
        // 1. Local first — always returns local projects
        do {
            let localProjects = try coordinator.loadProjects()
            savedProjects = localProjects.map { StudioProject(from: $0) }
        } catch {
            print("[Studio] Local load error: \(error)")
        }

        // 2. Optional remote reconciliation after local success
        guard let userId = AuthService.shared.userId else { return }
        let supabase = SupabaseManager.shared.client
        do {
            let remoteProjects: [StudioProject] = try await supabase
                .from("studio_projects")
                .select("*")
                .eq("user_id", value: userId)
                .order("updated_at", ascending: false)
                .execute()
                .value
            // Merge: remote projects not in local are added
            let localIDs = Set(savedProjects.map(\.id))
            for rp in remoteProjects where !localIDs.contains(rp.id) {
                savedProjects.append(rp)
            }
        } catch {
            print("[Studio] Remote reconciliation skipped: \(error)")
        }
    }

    func createProject(name: String, width: Int, height: Int, fps: Int) {
        do {
            let project = try coordinator.createProject(name: name, width: width, height: height, fps: fps)
            currentProjectID = project.id
            projectName = project.name
            canvasWidth = project.width
            canvasHeight = project.height
            self.fps = project.fps
            frames = project.frames
            layers = project.layers
            activeLayerID = project.activeLayerID
            currentFrameIndex = project.activeFrameIndex
            currentLayerIndex = 0
            undoStack.removeAll()
            redoStack.removeAll()
            audioClips.removeAll()
        } catch {
            print("[Studio] Create project error: \(error)")
        }
    }

    func openProject(_ project: StudioProject) {
        do {
            guard let opened = try coordinator.openProject(id: project.id) else { return }
            currentProjectID = opened.id
            projectName = opened.name
            canvasWidth = opened.width
            canvasHeight = opened.height
            fps = opened.fps
            frames = opened.frames
            layers = opened.layers
            activeLayerID = opened.activeLayerID
            currentFrameIndex = opened.activeFrameIndex
            currentLayerIndex = 0
        } catch {
            print("[Studio] Open project error: \(error)")
        }
    }

    func reopenProject(id: String, legacyDir: URL? = nil) {
        do {
            let result = try coordinator.reopenProject(id: id, legacyDir: legacyDir)
            let project = result.project
            currentProjectID = project.id
            projectName = project.name
            canvasWidth = project.width
            canvasHeight = project.height
            fps = project.fps
            frames = project.frames
            layers = project.layers
            activeLayerID = project.activeLayerID
            currentFrameIndex = project.activeFrameIndex
            currentLayerIndex = 0
            if let migration = result.migrationResult {
                print("[Studio] Migration: \(migration.migratedAssetCount) assets, \(migration.conflicts.count) conflicts")
            }
        } catch {
            print("[Studio] Reopen project error: \(error)")
        }
    }

    // MARK: - Frame Operations
    func addFrame() {
        pushUndo()
        let newFrame = AnimationFrame(id: UUID().uuidString, elements: [])
        frames.insert(newFrame, at: currentFrameIndex + 1)
        currentFrameIndex += 1
        lastSaveTime = Date()
        syncToCoordinator()
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
                    layerID: el.layerID
                )
            }
        )
        frames.insert(dupe, at: currentFrameIndex + 1)
        currentFrameIndex += 1
        lastSaveTime = Date()
        syncToCoordinator()
    }

    func deleteFrame() {
        guard frames.count > 1 else { return }
        pushUndo()
        frames.remove(at: currentFrameIndex)
        currentFrameIndex = min(currentFrameIndex, frames.count - 1)
        lastSaveTime = Date()
        syncToCoordinator()
    }

    func nextFrame() {
        if currentFrameIndex < frames.count - 1 { currentFrameIndex += 1 }
    }

    func prevFrame() {
        if currentFrameIndex > 0 { currentFrameIndex -= 1 }
    }

    // MARK: - Element Operations
    func commitElement(_ element: DrawnElement) {
        pushUndo()
        frames[currentFrameIndex].elements.append(element)
        lastSaveTime = Date()
        syncToCoordinator()
    }

    func deleteSelected() {
        guard !frames[currentFrameIndex].elements.isEmpty else { return }
        pushUndo()
        frames[currentFrameIndex].elements.removeLast()
        lastSaveTime = Date()
        syncToCoordinator()
    }

    func clearCanvas() {
        pushUndo()
        frames[currentFrameIndex].elements.removeAll()
        lastSaveTime = Date()
        syncToCoordinator()
    }

    // MARK: - Layer Operations (canonical String IDs via SDCore)

    func toggleLayerVisibility(_ id: String) {
        do {
            let project = try coordinator.layerCommands.toggleVisibility(id: id)
            layers = project.layers
        } catch {
            print("[Studio] toggleVisibility error: \(error)")
        }
    }

    func toggleLayerLock(_ id: String) {
        do {
            let currentMode = layers.first(where: { $0.id == id })?.lockMode ?? "free"
            let newMode = currentMode == "full" ? "free" : "full"
            let project = try coordinator.layerCommands.setLockMode(id: id, mode: newMode)
            layers = project.layers
        } catch {
            print("[Studio] toggleLayerLock error: \(error)")
        }
    }

    func setLayerLockMode(_ id: String, mode: String) {
        do {
            let project = try coordinator.layerCommands.setLockMode(id: id, mode: mode)
            layers = project.layers
        } catch {
            print("[Studio] setLockMode error: \(error)")
        }
    }

    func setLayerOpacity(_ id: String, opacity: Double) {
        do {
            let project = try coordinator.layerCommands.setOpacity(id: id, opacity: opacity)
            layers = project.layers
        } catch {
            print("[Studio] setLayerOpacity error: \(error)")
        }
    }

    func setLayerBlendMode(_ id: String, mode: String) {
        do {
            let project = try coordinator.layerCommands.setBlendMode(id: id, mode: mode)
            layers = project.layers
        } catch {
            print("[Studio] setLayerBlendMode error: \(error)")
        }
    }

    func setLayerGlowEnabled(_ id: String, enabled: Bool) {
        do {
            let project = try coordinator.layerCommands.setGlowEnabled(id: id, enabled: enabled)
            layers = project.layers
        } catch {
            print("[Studio] setLayerGlowEnabled error: \(error)")
        }
    }

    func setLayerGlowColor(_ id: String, color: String) {
        do {
            let project = try coordinator.layerCommands.setGlowColor(id: id, color: color)
            layers = project.layers
        } catch {
            print("[Studio] setLayerGlowColor error: \(error)")
        }
    }

    func setLayerColorLabel(_ id: String, color: String) {
        do {
            let project = try coordinator.layerCommands.setColorLabel(id: id, color: color)
            layers = project.layers
        } catch {
            print("[Studio] setColorLabel error: \(error)")
        }
    }

    func renameLayer(_ id: String, name: String) {
        do {
            let project = try coordinator.layerCommands.rename(id: id, name: name)
            layers = project.layers
        } catch {
            print("[Studio] renameLayer error: \(error)")
        }
    }

    func addLayer() {
        do {
            let project = try coordinator.layerCommands.addLayer()
            layers = project.layers
            activeLayerID = project.activeLayerID
            currentLayerIndex = 0
        } catch {
            print("[Studio] addLayer error: \(error)")
        }
    }

    func duplicateLayer(_ id: String) {
        do {
            let project = try coordinator.layerCommands.duplicateLayer(id: id)
            layers = project.layers
        } catch {
            print("[Studio] duplicateLayer error: \(error)")
        }
    }

    func deleteLayer(_ id: String) {
        do {
            let project = try coordinator.layerCommands.deleteLayer(id: id)
            layers = project.layers
            activeLayerID = project.activeLayerID
        } catch {
            print("[Studio] deleteLayer error: \(error)")
        }
    }

    func moveLayerUp(_ id: String) {
        do {
            let project = try coordinator.layerCommands.moveLayerUp(id: id)
            layers = project.layers
        } catch {
            print("[Studio] moveLayerUp error: \(error)")
        }
    }

    func moveLayerDown(_ id: String) {
        do {
            let project = try coordinator.layerCommands.moveLayerDown(id: id)
            layers = project.layers
        } catch {
            print("[Studio] moveLayerDown error: \(error)")
        }
    }

    func setActiveLayer(_ id: String) {
        do {
            let project = try coordinator.layerCommands.setActiveLayer(id: id)
            activeLayerID = project.activeLayerID
        } catch {
            print("[Studio] setActiveLayer error: \(error)")
        }
    }

    // MARK: - Canvas Controls
    func zoomIn() { canvasScale = min(canvasScale * 1.25, 5.0) }
    func zoomOut() { canvasScale = max(canvasScale / 1.25, 0.25) }
    func zoomFit() { canvasScale = 1.0; canvasOffset = .zero }

    // MARK: - Audio Operations
    func addAudioClip(sound: SoundEffect, track: Int) {
        let durValue = Double(sound.duration.replacingOccurrences(of: "s", with: "")) ?? 0.5
        let clip = SDCore.AudioClip(
            id: UUID().uuidString,
            soundName: sound.name,
            track: track,
            startTime: audioPlayheadTime,
            duration: durValue
        )
        audioClips.append(AudioClip(from: clip))
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

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(frames)
        frames = prev
        currentFrameIndex = min(currentFrameIndex, frames.count - 1)
        syncToCoordinator()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(frames)
        frames = next
        currentFrameIndex = min(currentFrameIndex, frames.count - 1)
        syncToCoordinator()
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
        // 1. Local save first (canonical)
        do {
            syncToCoordinator()
            try coordinator.save()
            lastSaveTime = Date()
            print("[Studio] Local save: \(frames.count) frames, \(layers.count) layers")
        } catch {
            print("[Studio] Local save error: \(error)")
            return
        }

        // 2. Remote sync only after local success
        guard let userId = AuthService.shared.userId else { return }
        let supabase = SupabaseManager.shared.client
        do {
            let encoder = JSONEncoder()
            let frameData = try encoder.encode(frames)
            let frameJSON = String(data: frameData, encoding: .utf8) ?? "[]"
            let projectID = currentProjectID ?? ""

            try await supabase.from("studio_project_versions").insert([
                "project_id": .string(projectID),
                "frame_data": .string(frameJSON),
                "user_id": .string(userId),
            ]).execute()

            print("[Studio] Remote sync OK for project \(projectID)")
        } catch {
            // Remote failure must never erase local state
            print("[Studio] Remote sync skipped (local preserved): \(error)")
        }
    }

    // MARK: - Private helpers

    private func syncToCoordinator() {
        guard var project = coordinator.activeProject else { return }
        project.frames = frames
        project.layers = layers
        project.activeLayerID = activeLayerID
        project.activeFrameIndex = currentFrameIndex
        do {
            try coordinator.repository.save(project)
        } catch {
            print("[Studio] syncToCoordinator error: \(error)")
        }
    }
}

// MARK: - Studio Project ↔ SDCore mapping

extension StudioProject {
    init(from project: SDCore.Project) {
        self.init(
            id: project.id,
            userID: "",
            name: project.name,
            width: project.width,
            height: project.height,
            fps: project.fps,
            frameCount: project.frames.count,
            thumbnailURL: nil,
            createdAt: ISO8601DateFormatter().string(from: project.createdAt),
            updatedAt: ISO8601DateFormatter().string(from: project.updatedAt)
        )
    }
}

// MARK: - App AudioClip ↔ SDCore AudioClip bridging

extension StudioViewModel.AudioClip {
    init(from clip: SDCore.AudioClip) {
        self.init(
            id: clip.id,
            soundName: clip.soundName,
            track: clip.track,
            startTime: clip.startTime,
            duration: clip.duration
        )
    }
}

// StudioViewModel.AudioClip local mirror (not the SDCore one)
extension StudioViewModel {
    struct AudioClip: Identifiable {
        let id: String
        var soundName: String
        var track: Int
        var startTime: Double
        var duration: Double
        var volume: Double = 0.8
    }
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
