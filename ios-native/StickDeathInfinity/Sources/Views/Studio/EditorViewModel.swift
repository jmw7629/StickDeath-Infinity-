// EditorViewModel.swift
// Main view model for the animation studio

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

    // Editor state
    @Published var mode: EditorMode = .pose
    @Published var canvasOffset: CGSize = .zero
    @Published var canvasScale: CGFloat = 1.0
    @Published var showOnionSkin = true
    @Published var isPlaying = false
    @Published var showLayers = false
    @Published var showProperties = false
    @Published var showTimeline = true

    // Undo
    @Published var undoStack: [AnimationData] = []
    @Published var redoStack: [AnimationData] = []
    private let maxUndoSteps = 50

    // AI
    @Published var aiSuggestion: String?
    @Published var showAIPanel = false

    var selectedFigure: StickFigure? {
        figures.first { $0.id == selectedFigureId }
    }

    init(project: StudioProject) {
        self.project = project
        // Create initial frame
        let initialFrame = AnimationFrame(
            id: UUID(),
            figureStates: figures.map { fig in
                FigureState(id: UUID(), figureId: fig.id, joints: fig.joints, visible: true)
            },
            duration: 1.0 / Double(project.fps ?? 24)
        )
        self.frames = [initialFrame]
    }

    // MARK: - Load from Supabase
    func loadProject() async {
        if let data = try? await ProjectService.shared.loadLatestVersion(projectId: project.id) {
            self.frames = data.frames
            self.figures = data.figures
            if !figures.isEmpty {
                selectedFigureId = figures[0].id
            }
        }
    }

    // MARK: - Save to Supabase
    func saveProject() async {
        isSaving = true
        let data = AnimationData(frames: frames, figures: figures)
        try? await ProjectService.shared.saveVersion(projectId: project.id, data: data)
        isSaving = false
    }

    // MARK: - Auto-save snapshot for undo
    func pushUndo() {
        let snapshot = AnimationData(frames: frames, figures: figures)
        undoStack.append(snapshot)
        if undoStack.count > maxUndoSteps { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(AnimationData(frames: frames, figures: figures))
        frames = prev.frames
        figures = prev.figures
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(AnimationData(frames: frames, figures: figures))
        frames = next.frames
        figures = next.figures
    }

    // MARK: - Figures
    func addFigure() {
        pushUndo()
        let count = figures.count + 1
        let fig = StickFigure.newFigure(name: "Figure \(count)", color: figureColor(count))
        figures.append(fig)
        selectedFigureId = fig.id
    }

    func deleteFigure(_ id: UUID) {
        pushUndo()
        figures.removeAll { $0.id == id }
        if selectedFigureId == id { selectedFigureId = figures.first?.id }
    }

    private func figureColor(_ index: Int) -> Color {
        let colors: [Color] = [.white, .cyan, .green, .yellow, .pink, .purple]
        return colors[index % colors.count]
    }

    // MARK: - Frames
    func addFrame() {
        pushUndo()
        let newFrame = AnimationFrame(
            id: UUID(),
            figureStates: figures.map { fig in
                // Copy current frame's state
                let currentState = frames[safe: currentFrameIndex]?.figureStates.first { $0.figureId == fig.id }
                return FigureState(
                    id: UUID(),
                    figureId: fig.id,
                    joints: currentState?.joints ?? fig.joints,
                    visible: currentState?.visible ?? true
                )
            },
            duration: 1.0 / Double(project.fps ?? 24)
        )
        frames.insert(newFrame, at: currentFrameIndex + 1)
        currentFrameIndex += 1
    }

    func duplicateFrame() {
        guard let current = frames[safe: currentFrameIndex] else { return }
        pushUndo()
        let dup = AnimationFrame(
            id: UUID(),
            figureStates: current.figureStates.map {
                FigureState(id: UUID(), figureId: $0.figureId, joints: $0.joints, visible: $0.visible)
            },
            duration: current.duration
        )
        frames.insert(dup, at: currentFrameIndex + 1)
        currentFrameIndex += 1
    }

    func deleteFrame() {
        guard frames.count > 1 else { return }
        pushUndo()
        frames.remove(at: currentFrameIndex)
        currentFrameIndex = min(currentFrameIndex, frames.count - 1)
    }

    // MARK: - Joint Dragging
    func moveJoint(_ joint: String, to point: CGPoint, figureId: UUID) {
        guard let frameIdx = frames.indices.first(where: { $0 == currentFrameIndex }),
              let stateIdx = frames[frameIdx].figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }
        frames[frameIdx].figureStates[stateIdx].joints[joint] = point
    }

    // MARK: - Playback
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
                playLoop()
            }
        }
    }

    // MARK: - AI Assist
    func requestAIAssist(prompt: String) async {
        do {
            let suggestion = try await AIService.shared.getAssist(
                prompt: prompt,
                context: "Frame \(currentFrameIndex + 1) of \(frames.count), \(figures.count) figures"
            )
            aiSuggestion = suggestion
        } catch {
            aiSuggestion = "Error: \(error.localizedDescription)"
        }
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
