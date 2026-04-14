// EditorViewModel.swift
// Main view model for the animation studio
// v3: PlacedObject support, sound timeline, offline save, performance-optimized state

import SwiftUI
import Combine

enum EditorMode { case pose, move, draw }

@MainActor
class EditorViewModel: ObservableObject {
    // Project
    @Published var project: StudioProject
    @Published var isSaving = false

    // Figures
    @Published var figures: [StickFigure] = [StickFigure.newFigure()]
    @Published var selectedFigureId: UUID?
    @Published var selectedJoint: String?

    // Frames / Timeline
    @Published var frames: [AnimationFrame] = []
    @Published var currentFrameIndex = 0

    // Sound timeline
    @Published var soundClips: [SoundClip] = []

    // Editor state
    @Published var mode: EditorMode = .pose
    @Published var canvasOffset: CGSize = .zero
    @Published var canvasScale: CGFloat = 1.0
    @Published var showOnionSkin = true
    @Published var isPlaying = false
    @Published var showLayers = false
    @Published var showProperties = false
    @Published var showTimeline = true
    @Published var showAssetBrowser = false

    // Undo (bounded ring buffer — never grows unbounded)
    @Published var undoStack: [AnimationData] = []
    @Published var redoStack: [AnimationData] = []
    private let maxUndoSteps = 50

    // Drawing
    @Published var drawState = DrawingState()
    @Published var showBrushSizePopover = false

    // AI
    @Published var aiSuggestion: String?
    @Published var showAIPanel = false

    // Auto-save timer
    private var autoSaveTask: Task<Void, Never>?
    private var isDirty = false

    var selectedFigure: StickFigure? {
        figures.first { $0.id == selectedFigureId }
    }

    init(project: StudioProject) {
        self.project = project
        // Create initial frame with empty placedObjects
        let initialFrame = AnimationFrame(
            id: UUID(),
            figureStates: figures.map { fig in
                FigureState(id: UUID(), figureId: fig.id, joints: fig.joints, visible: true)
            },
            duration: 1.0 / Double(project.fps ?? 24),
            placedObjects: []
        )
        self.frames = [initialFrame]
        startAutoSave()
    }

    deinit {
        autoSaveTask?.cancel()
    }

    // MARK: - Auto-save (every 30s if dirty — non-blocking)
    private func startAutoSave() {
        autoSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                guard let self = self, self.isDirty else { continue }
                await self.saveProject()
                self.isDirty = false
            }
        }
    }

    private func markDirty() { isDirty = true }

    // MARK: - Load from Supabase (with offline fallback)
    func loadProject() async {
        // Try offline cache first for instant load (5-second rule)
        if let cached = OfflineManager.shared.loadCachedProject(projectId: project.id) {
            if let data = try? JSONDecoder().decode(AnimationData.self, from: cached) {
                applyAnimationData(data)
            }
        }

        // Then fetch latest from server (will update if newer)
        if let data = try? await ProjectService.shared.loadLatestVersion(projectId: project.id) {
            applyAnimationData(data)
            // Cache for offline
            if let encoded = try? JSONEncoder().encode(data) {
                OfflineManager.shared.cacheProject(encoded, projectId: project.id)
            }
        }
    }

    private func applyAnimationData(_ data: AnimationData) {
        self.frames = data.frames
        self.figures = data.figures
        self.soundClips = data.soundTimeline ?? []
        if !figures.isEmpty { selectedFigureId = figures[0].id }
    }

    // MARK: - Save to Supabase (with offline queuing)
    func saveProject() async {
        isSaving = true
        let data = AnimationData(frames: frames, figures: figures, soundTimeline: soundClips)

        // Always cache locally first (instant)
        if let encoded = try? JSONEncoder().encode(data) {
            OfflineManager.shared.cacheProject(encoded, projectId: project.id)
        }

        // Try server save
        if OfflineManager.shared.isOnline {
            _ = try? await ProjectService.shared.saveVersion(projectId: project.id, data: data)
        } else {
            // Queue for later sync
            if let payload = try? JSONEncoder().encode(["projectId": project.id]) {
                OfflineManager.shared.enqueue(type: .saveProject, payload: payload)
            }
        }
        isSaving = false
    }

    // MARK: - Undo / Redo (ring buffer, never allocates > 50)
    func pushUndo() {
        let snapshot = AnimationData(frames: frames, figures: figures, soundTimeline: soundClips)
        undoStack.append(snapshot)
        if undoStack.count > maxUndoSteps { undoStack.removeFirst() }
        redoStack.removeAll()
        markDirty()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(AnimationData(frames: frames, figures: figures, soundTimeline: soundClips))
        applyAnimationData(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(AnimationData(frames: frames, figures: figures, soundTimeline: soundClips))
        applyAnimationData(next)
    }

    // MARK: - Figures
    func addFigure() {
        pushUndo()
        let count = figures.count + 1
        let fig = StickFigure.newFigure(name: "Figure \(count)", color: figureColor(count))
        figures.append(fig)
        selectedFigureId = fig.id
        // Add figure state to all existing frames
        for i in frames.indices {
            frames[i].figureStates.append(
                FigureState(id: UUID(), figureId: fig.id, joints: fig.joints, visible: true)
            )
        }
    }

    func deleteFigure(_ id: UUID) {
        pushUndo()
        figures.removeAll { $0.id == id }
        for i in frames.indices {
            frames[i].figureStates.removeAll { $0.figureId == id }
        }
        if selectedFigureId == id { selectedFigureId = figures.first?.id }
    }

    private func figureColor(_ index: Int) -> Color {
        let colors: [Color] = [.white, .cyan, .green, .yellow, .pink, .purple, .red, .mint]
        return colors[index % colors.count]
    }

    // MARK: - Frames
    func addFrame() {
        pushUndo()
        let newFrame = AnimationFrame(
            id: UUID(),
            figureStates: figures.map { fig in
                let currentState = frames[safe: currentFrameIndex]?.figureStates.first { $0.figureId == fig.id }
                return FigureState(
                    id: UUID(),
                    figureId: fig.id,
                    joints: currentState?.joints ?? fig.joints,
                    visible: currentState?.visible ?? true
                )
            },
            duration: 1.0 / Double(project.fps ?? 24),
            placedObjects: frames[safe: currentFrameIndex]?.placedObjects ?? []
        )
        frames.insert(newFrame, at: currentFrameIndex + 1)
        currentFrameIndex += 1
        HapticManager.shared.frameSwitched()
    }

    func duplicateFrame() {
        guard let current = frames[safe: currentFrameIndex] else { return }
        pushUndo()
        let dup = AnimationFrame(
            id: UUID(),
            figureStates: current.figureStates.map {
                FigureState(id: UUID(), figureId: $0.figureId, joints: $0.joints, visible: $0.visible)
            },
            duration: current.duration,
            placedObjects: current.placedObjects.map {
                PlacedObject(id: UUID(), assetId: $0.assetId, sfSymbol: $0.sfSymbol, name: $0.name,
                            position: $0.position, size: $0.size, rotation: $0.rotation,
                            opacity: $0.opacity, tint: $0.tint, zIndex: $0.zIndex, locked: $0.locked)
            }
        )
        frames.insert(dup, at: currentFrameIndex + 1)
        currentFrameIndex += 1
        HapticManager.shared.frameSwitched()
    }

    func deleteFrame() {
        guard frames.count > 1 else { return }
        pushUndo()
        frames.remove(at: currentFrameIndex)
        currentFrameIndex = min(currentFrameIndex, frames.count - 1)
        HapticManager.shared.frameSwitched()
    }

    // MARK: - Joint Dragging (minimal state mutation for zero-lag)
    func moveJoint(_ joint: String, to point: CGPoint, figureId: UUID) {
        guard frames.indices.contains(currentFrameIndex),
              let stateIdx = frames[currentFrameIndex].figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }
        frames[currentFrameIndex].figureStates[stateIdx].joints[joint] = point
        HapticManager.shared.jointDrag()
    }

    // MARK: - Placed Objects (from Asset Library)
    func addPlacedObject(asset: StudioAsset) {
        pushUndo()
        guard frames.indices.contains(currentFrameIndex) else { return }
        let obj = PlacedObject(
            id: UUID(),
            assetId: asset.id,
            sfSymbol: symbolForCategory(asset.category),
            name: asset.name,
            position: .zero,
            size: 32,
            rotation: 0,
            opacity: 1.0,
            tint: "#FFFFFF",
            zIndex: frames[currentFrameIndex].placedObjects.count,
            locked: false
        )
        frames[currentFrameIndex].placedObjects.append(obj)
        HapticManager.shared.objectPlaced()
    }

    func removePlacedObject(_ id: UUID) {
        pushUndo()
        guard frames.indices.contains(currentFrameIndex) else { return }
        frames[currentFrameIndex].placedObjects.removeAll { $0.id == id }
    }

    func movePlacedObject(_ id: UUID, to position: CGPoint) {
        guard frames.indices.contains(currentFrameIndex),
              let idx = frames[currentFrameIndex].placedObjects.firstIndex(where: { $0.id == id }) else { return }
        frames[currentFrameIndex].placedObjects[idx].position = position
    }

    private func symbolForCategory(_ cat: String) -> String {
        switch cat {
        case "weapons": return "shield.slash.fill"
        case "vehicles": return "car.fill"
        case "environments": return "building.2.fill"
        case "effects": return "sparkle"
        case "furniture": return "sofa.fill"
        case "clothing": return "tshirt.fill"
        case "food": return "fork.knife"
        case "sports": return "sportscourt.fill"
        case "animals": return "hare.fill"
        case "tech": return "cpu.fill"
        case "text": return "textformat.abc"
        default: return "cube.fill"
        }
    }

    // MARK: - Sound Clips
    func addSoundClip(asset: StudioAsset) {
        pushUndo()
        let clip = SoundClip(
            id: UUID(),
            assetId: asset.id,
            name: asset.name,
            startFrame: currentFrameIndex,
            durationFrames: min(12, max(1, frames.count - currentFrameIndex)),
            volume: 0.8,
            category: asset.category
        )
        soundClips.append(clip)
    }

    func removeSoundClip(_ id: UUID) {
        pushUndo()
        soundClips.removeAll { $0.id == id }
    }

    // MARK: - Playback (high-precision timer)
    func togglePlay() {
        isPlaying.toggle()
        if isPlaying { playLoop() }
    }

    private func playLoop() {
        guard isPlaying else { return }
        let fps = project.fps ?? 24
        let delay = 1.0 / Double(fps)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if isPlaying {
                currentFrameIndex = (currentFrameIndex + 1) % frames.count
                if currentFrameIndex == 0 && !isPlaying { return } // Stop at end
                playLoop()
            }
        }
    }

    // MARK: - AI Assist
    func requestAIAssist(prompt: String) async {
        do {
            let suggestion = try await AIService.shared.getAssist(
                prompt: prompt,
                context: "Frame \(currentFrameIndex + 1) of \(frames.count), \(figures.count) figures, \(soundClips.count) sound clips"
            )
            aiSuggestion = suggestion
        } catch {
            aiSuggestion = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Apply Template
    func applyTemplate(_ template: AnimationTemplate) {
        pushUndo()

        figures = (0..<template.figureCount).map { i in
            StickFigure.newFigure(name: "Figure \(i + 1)", color: figureColor(i))
        }
        selectedFigureId = figures.first?.id

        let fps = Double(project.fps ?? 24)
        frames = (0..<template.frameCount).map { frameIdx in
            let progress = Double(frameIdx) / Double(template.frameCount)
            let sway = sin(progress * .pi * 2)

            return AnimationFrame(
                id: UUID(),
                figureStates: figures.map { fig in
                    var joints = StickFigure.defaultJoints

                    switch template.category {
                    case "Action":
                        joints["leftHand"] = CGPoint(x: -50 + sway * 20, y: 5 - abs(sway) * 15)
                        joints["rightHand"] = CGPoint(x: 50 - sway * 20, y: 5 - abs(sway) * 15)
                        joints["leftFoot"] = CGPoint(x: -20 + sway * 10, y: 60)
                        joints["rightFoot"] = CGPoint(x: 20 - sway * 10, y: 60)
                    case "Dance":
                        joints["leftHand"] = CGPoint(x: -50 + sway * 25, y: -10 + sway * 20)
                        joints["rightHand"] = CGPoint(x: 50 - sway * 25, y: -10 - sway * 20)
                        joints["hip"] = CGPoint(x: sway * 5, y: 0)
                    default:
                        joints["leftFoot"] = CGPoint(x: -20 + sway * 15, y: 60)
                        joints["rightFoot"] = CGPoint(x: 20 - sway * 15, y: 60)
                        joints["leftHand"] = CGPoint(x: -50 - sway * 10, y: 5)
                        joints["rightHand"] = CGPoint(x: 50 + sway * 10, y: 5)
                    }

                    return FigureState(id: UUID(), figureId: fig.id, joints: joints, visible: true)
                },
                duration: 1.0 / fps,
                placedObjects: []
            )
        }
        currentFrameIndex = 0
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
