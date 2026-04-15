// EditorViewModel.swift
// Main view model for the animation studio
// v10: Rig/bone animation, IK solver, scrollable top taskbar

import SwiftUI
import Combine
import PhotosUI

enum EditorMode: Equatable { case pose, move, draw, cursor, rig }

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
    @Published var mode: EditorMode = .draw
    @Published var canvasOffset: CGSize = .zero
    @Published var canvasScale: CGFloat = 1.0
    @Published var canvasSize: CGSize = .zero
    @Published var showOnionSkin = true
    @Published var showGrid = false
    @Published var isPlaying = false
    @Published var showLayers = false
    @Published var showProperties = false
    @Published var showTimeline = true
    @Published var showAssetBrowser = false

    // Cursor/select tool
    @Published var selectedObjectBounds: CGRect?
    @Published var selectedImageId: UUID?
    @Published var selectedPlacedObjectId: UUID?

    // Undo (bounded ring buffer — never grows unbounded)
    @Published var undoStack: [AnimationData] = []
    @Published var redoStack: [AnimationData] = []
    private let maxUndoSteps = 50

    // Drawing
    @Published var drawState = DrawingState()
    @Published var showBrushSizePopover = false

    // Image import
    @Published var showImagePicker = false
    @Published var importedPhotoItem: PhotosPickerItem?

    // Project settings
    @Published var showProjectSettings = false
    @Published var showFramesViewer = false

    // AI
    @Published var aiSuggestion: String?
    @Published var showAIPanel = false

    // Rig / Bone
    @Published var rig: BoneRig = BoneRig.defaultHumanoid()
    @Published var rigSubTool: RigSubTool = .select
    @Published var selectedBoneId: UUID?
    @Published var showBoneOverlay: Bool = true
    @Published var rigDragStartJoint: String?     // For addBone: starting joint

    var selectedBone: Bone? {
        rig.bones.first { $0.id == selectedBoneId }
    }

    // Auto-save timer
    private var autoSaveTask: Task<Void, Never>?
    private var isDirty = false

    var selectedFigure: StickFigure? {
        figures.first { $0.id == selectedFigureId }
    }

    var canvasCenter: CGPoint {
        CGPoint(
            x: canvasSize.width / 2 + canvasOffset.width,
            y: canvasSize.height / 2 + canvasOffset.height
        )
    }

    init(project: StudioProject) {
        self.project = project
        let initialFrame = AnimationFrame(
            id: UUID(),
            figureStates: figures.map { fig in
                FigureState(id: UUID(), figureId: fig.id, joints: fig.joints, visible: true)
            },
            duration: 1.0 / Double(project.fps ?? 12),
            placedObjects: [],
            drawnElements: [],
            importedImages: []
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
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self = self, self.isDirty else { continue }
                await self.saveProject()
                self.isDirty = false
            }
        }
    }

    private func markDirty() { isDirty = true }

    // MARK: - Drawing Gesture Handling
    func handleDrawingBegan(at point: CGPoint) {
        let canvasPoint = screenToCanvas(point)
        drawState.currentPath = [canvasPoint]

        if drawState.tool == .text {
            drawState.textPosition = canvasPoint
            drawState.showTextInput = true
        }
    }

    func handleDrawingMoved(to point: CGPoint) {
        let canvasPoint = screenToCanvas(point)

        switch drawState.tool {
        case .pencil:
            drawState.currentPath.append(canvasPoint)
        case .line, .arrow, .rectangle, .circle:
            // Keep first point, update last
            if drawState.currentPath.count > 1 {
                drawState.currentPath[drawState.currentPath.count - 1] = canvasPoint
            } else {
                drawState.currentPath.append(canvasPoint)
            }
        case .eraser:
            eraseAt(canvasPoint)
        case .text:
            break
        }
    }

    func handleDrawingEnded(at point: CGPoint) {
        let canvasPoint = screenToCanvas(point)
        guard !drawState.currentPath.isEmpty else { return }

        if drawState.tool == .text || drawState.tool == .eraser {
            drawState.currentPath = []
            return
        }

        pushUndo()

        var element = DrawnElement(
            id: UUID(),
            tool: drawState.tool.rawValue,
            points: drawState.currentPath,
            origin: nil,
            size: nil,
            strokeColor: drawState.strokeColor.toHex(),
            strokeWidth: drawState.strokeWidth,
            fillColor: drawState.fillEnabled ? drawState.fillColor.toHex() : nil,
            text: nil,
            fontSize: nil
        )

        // For shapes, compute origin + size
        if drawState.tool == .rectangle || drawState.tool == .circle {
            if let first = drawState.currentPath.first, let last = drawState.currentPath.last {
                element.origin = CGPoint(x: min(first.x, last.x), y: min(first.y, last.y))
                element.size = CGSize(width: abs(last.x - first.x), height: abs(last.y - first.y))
            }
        }

        guard frames.indices.contains(currentFrameIndex) else { return }
        frames[currentFrameIndex].drawnElements.append(element)
        drawState.currentPath = []
        markDirty()
        HapticManager.shared.buttonTap()
    }

    func commitTextElement(_ text: String) {
        guard !text.isEmpty else { return }
        pushUndo()

        let element = DrawnElement(
            id: UUID(),
            tool: "text",
            points: [],
            origin: drawState.textPosition,
            size: nil,
            strokeColor: drawState.strokeColor.toHex(),
            strokeWidth: drawState.strokeWidth,
            fillColor: nil,
            text: text,
            fontSize: 18
        )

        guard frames.indices.contains(currentFrameIndex) else { return }
        frames[currentFrameIndex].drawnElements.append(element)
        drawState.showTextInput = false
        drawState.textInput = ""
        markDirty()
    }

    private func eraseAt(_ point: CGPoint) {
        guard frames.indices.contains(currentFrameIndex) else { return }
        let threshold: CGFloat = 15
        frames[currentFrameIndex].drawnElements.removeAll { element in
            switch element.tool {
            case "pencil":
                return element.points.contains { pt in
                    hypot(pt.x - point.x, pt.y - point.y) < threshold
                }
            case "rectangle", "circle":
                if let origin = element.origin, let size = element.size {
                    let rect = CGRect(origin: origin, size: size).insetBy(dx: -threshold, dy: -threshold)
                    return rect.contains(point)
                }
                return false
            case "text":
                if let origin = element.origin {
                    return hypot(origin.x - point.x, origin.y - point.y) < threshold * 2
                }
                return false
            default:
                if let first = element.points.first, let last = element.points.last {
                    return distanceToLineSegment(point: point, start: first, end: last) < threshold
                }
                return false
            }
        }
    }

    private func distanceToLineSegment(point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lenSq))
        let proj = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - proj.x, point.y - proj.y)
    }

    // MARK: - Cursor/Select Tool
    func handleCursorTap(at point: CGPoint) {
        let canvasPoint = screenToCanvas(point)
        guard frames.indices.contains(currentFrameIndex) else { return }
        let frame = frames[currentFrameIndex]

        // Check imported images (reverse order = topmost first)
        for img in frame.importedImages.reversed() {
            let rect = CGRect(
                x: img.position.x - img.size.width / 2,
                y: img.position.y - img.size.height / 2,
                width: img.size.width,
                height: img.size.height
            )
            if rect.contains(canvasPoint) {
                selectedImageId = img.id
                selectedPlacedObjectId = nil
                selectedObjectBounds = rect
                return
            }
        }

        // Check placed objects
        for obj in frame.placedObjects.reversed() {
            let rect = CGRect(
                x: obj.position.x - obj.size / 2,
                y: obj.position.y - obj.size / 2,
                width: obj.size, height: obj.size
            )
            if rect.contains(canvasPoint) {
                selectedPlacedObjectId = obj.id
                selectedImageId = nil
                selectedObjectBounds = rect
                return
            }
        }

        // Nothing hit — deselect
        clearSelection()
    }

    func handleCursorDrag(translation: CGSize) {
        guard frames.indices.contains(currentFrameIndex) else { return }
        let dx = translation.width / canvasScale
        let dy = translation.height / canvasScale

        if let imgId = selectedImageId,
           let idx = frames[currentFrameIndex].importedImages.firstIndex(where: { $0.id == imgId }) {
            frames[currentFrameIndex].importedImages[idx].position.x += dx
            frames[currentFrameIndex].importedImages[idx].position.y += dy
            updateSelectionBounds()
        } else if let objId = selectedPlacedObjectId,
                  let idx = frames[currentFrameIndex].placedObjects.firstIndex(where: { $0.id == objId }) {
            frames[currentFrameIndex].placedObjects[idx].position.x += dx
            frames[currentFrameIndex].placedObjects[idx].position.y += dy
            updateSelectionBounds()
        }
    }

    func deleteSelected() {
        pushUndo()
        guard frames.indices.contains(currentFrameIndex) else { return }
        if let imgId = selectedImageId {
            frames[currentFrameIndex].importedImages.removeAll { $0.id == imgId }
        }
        if let objId = selectedPlacedObjectId {
            frames[currentFrameIndex].placedObjects.removeAll { $0.id == objId }
        }
        clearSelection()
        markDirty()
    }

    func clearSelection() {
        selectedImageId = nil
        selectedPlacedObjectId = nil
        selectedObjectBounds = nil
    }

    private func updateSelectionBounds() {
        if let imgId = selectedImageId,
           let img = frames[safe: currentFrameIndex]?.importedImages.first(where: { $0.id == imgId }) {
            selectedObjectBounds = CGRect(
                x: img.position.x - img.size.width / 2,
                y: img.position.y - img.size.height / 2,
                width: img.size.width, height: img.size.height
            )
        } else if let objId = selectedPlacedObjectId,
                  let obj = frames[safe: currentFrameIndex]?.placedObjects.first(where: { $0.id == objId }) {
            selectedObjectBounds = CGRect(
                x: obj.position.x - obj.size / 2,
                y: obj.position.y - obj.size / 2,
                width: obj.size, height: obj.size
            )
        }
    }

    // MARK: - Image Import
    func importImage(_ image: UIImage) {
        pushUndo()
        guard frames.indices.contains(currentFrameIndex) else { return }

        let maxDim: CGFloat = 200
        let scale = min(maxDim / image.size.width, maxDim / image.size.height, 1.0)
        let importedImage = ImportedImage(
            id: UUID(),
            image: image,
            position: .zero,
            size: CGSize(width: image.size.width * scale, height: image.size.height * scale),
            rotation: 0,
            opacity: 1.0
        )

        frames[currentFrameIndex].importedImages.append(importedImage)

        // Auto-switch to cursor to move it
        mode = .cursor
        selectedImageId = importedImage.id
        selectedPlacedObjectId = nil
        updateSelectionBounds()

        markDirty()
        HapticManager.shared.objectPlaced()
    }

    func processPhotoPicker(item: PhotosPickerItem?) async {
        guard let item = item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let uiImage = UIImage(data: data) {
            importImage(uiImage)
        }
    }

    // MARK: - Project Settings
    func updateProjectSettings(title: String, fps: Int, canvasWidth: Int, canvasHeight: Int) {
        project = StudioProject(
            id: project.id,
            user_id: project.user_id,
            title: title,
            description: project.description,
            canvas_width: canvasWidth,
            canvas_height: canvasHeight,
            fps: fps,
            status: project.status,
            created_at: project.created_at,
            updated_at: project.updated_at,
            thumbnail_url: project.thumbnail_url,
            background_type: project.background_type,
            background_value: project.background_value
        )
        // Update frame durations
        let duration = 1.0 / Double(fps)
        for i in frames.indices {
            frames[i].duration = duration
        }
        markDirty()
    }

    // MARK: - Coordinate Conversion
    func screenToCanvas(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (screenPoint.x - canvasCenter.x) / canvasScale,
            y: (screenPoint.y - canvasCenter.y) / canvasScale
        )
    }

    // MARK: - Load from Supabase (with offline fallback)
    func loadProject() async {
        if let cached = OfflineManager.shared.loadCachedProject(projectId: project.id) {
            if let data = try? JSONDecoder().decode(AnimationData.self, from: cached) {
                applyAnimationData(data)
            }
        }

        if let data = try? await ProjectService.shared.loadLatestVersion(projectId: project.id) {
            applyAnimationData(data)
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

        if let encoded = try? JSONEncoder().encode(data) {
            OfflineManager.shared.cacheProject(encoded, projectId: project.id)
        }

        if OfflineManager.shared.isOnline {
            _ = try? await ProjectService.shared.saveVersion(projectId: project.id, data: data)
        } else {
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
            duration: 1.0 / Double(project.fps ?? 12),
            placedObjects: frames[safe: currentFrameIndex]?.placedObjects ?? [],
            drawnElements: [],
            importedImages: []
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
            },
            drawnElements: current.drawnElements,
            importedImages: current.importedImages
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

    func goToFrame(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        currentFrameIndex = index
        clearSelection()
        HapticManager.shared.frameSwitched()
    }

    // MARK: - Joint Dragging
    func moveJoint(_ joint: String, to point: CGPoint, figureId: UUID) {
        guard frames.indices.contains(currentFrameIndex),
              let stateIdx = frames[currentFrameIndex].figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }
        frames[currentFrameIndex].figureStates[stateIdx].joints[joint] = point
        HapticManager.shared.jointDrag()
    }

    // MARK: - Placed Objects
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
        mode = .cursor
        selectedPlacedObjectId = obj.id
        updateSelectionBounds()
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

    // MARK: - Playback
    func togglePlay() {
        isPlaying.toggle()
        if isPlaying { playLoop() }
    }

    private func playLoop() {
        guard isPlaying else { return }
        let fps = project.fps ?? 12
        let delay = 1.0 / Double(fps)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if isPlaying {
                currentFrameIndex = (currentFrameIndex + 1) % frames.count
                if currentFrameIndex == 0 && !isPlaying { return }
                playLoop()
            }
        }
    }

    // MARK: - Drawing Undo (per-frame)
    func undoLastDrawnElement() {
        guard frames.indices.contains(currentFrameIndex),
              !frames[currentFrameIndex].drawnElements.isEmpty else { return }
        pushUndo()
        frames[currentFrameIndex].drawnElements.removeLast()
    }

    func clearDrawnElements() {
        guard frames.indices.contains(currentFrameIndex),
              !frames[currentFrameIndex].drawnElements.isEmpty else { return }
        pushUndo()
        frames[currentFrameIndex].drawnElements.removeAll()
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

    // MARK: - Rig / Bone Operations

    /// Move joint with IK awareness (when in rig mode with IK sub-tool)
    func moveJointWithIK(_ jointName: String, to target: CGPoint, figureId: UUID) {
        guard frames.indices.contains(currentFrameIndex),
              let stateIdx = frames[currentFrameIndex].figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }

        if mode == .rig && rigSubTool == .ikDrag {
            // Find IK chain containing this joint
            if let chain = rig.ikChains.first(where: { $0.jointNames.contains(jointName) }) {
                var joints = frames[currentFrameIndex].figureStates[stateIdx].joints
                let constraints = Dictionary(
                    uniqueKeysWithValues: rig.bones.compactMap { bone -> (String, AngleConstraint)? in
                        guard let c = bone.angleConstraint else { return nil }
                        return (bone.jointB, c)
                    }
                )
                IKSolver.solve(chain: chain, target: target, joints: &joints, constraints: constraints)
                IKSolver.enforceLengths(bones: rig.bones, joints: &joints)
                frames[currentFrameIndex].figureStates[stateIdx].joints = joints
            } else {
                // No IK chain — direct move
                frames[currentFrameIndex].figureStates[stateIdx].joints[jointName] = target
            }
        } else {
            frames[currentFrameIndex].figureStates[stateIdx].joints[jointName] = target
        }
        HapticManager.shared.jointDrag()
    }

    /// Add a new bone between two joints
    func addBone(from jointA: String, to position: CGPoint) {
        pushUndo()
        guard let figureId = selectedFigureId,
              frames.indices.contains(currentFrameIndex),
              let stateIdx = frames[currentFrameIndex].figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }

        // Create new joint name
        let jointName = "custom_\(UUID().uuidString.prefix(6))"

        // Add joint position to current frame
        frames[currentFrameIndex].figureStates[stateIdx].joints[jointName] = position

        // Also add to all other frames (copy position)
        for i in frames.indices where i != currentFrameIndex {
            if let idx = frames[i].figureStates.firstIndex(where: { $0.figureId == figureId }) {
                frames[i].figureStates[idx].joints[jointName] = position
            }
        }

        // Add to custom joints
        rig.customJoints[jointName] = position

        // Create bone
        let parentBone = rig.bones.first { $0.jointB == jointA }
        let length = hypot(position.x - (frames[currentFrameIndex].figureStates[stateIdx].joints[jointA]?.x ?? 0),
                          position.y - (frames[currentFrameIndex].figureStates[stateIdx].joints[jointA]?.y ?? 0))
        let bone = Bone(
            id: UUID(),
            name: "\(jointA)→\(jointName)",
            parentId: parentBone?.id ?? rig.bones.first(where: { $0.jointB == jointA })?.id,
            jointA: jointA,
            jointB: jointName,
            length: max(10, length),
            thickness: 2.5,
            color: "#FFFFFF",
            locked: false,
            angleConstraint: nil,
            style: .stick
        )
        rig.bones.append(bone)
        selectedBoneId = bone.id
        markDirty()
        HapticManager.shared.objectPlaced()
    }

    /// Split a bone (add joint in the middle)
    func splitBone(_ boneId: UUID) {
        guard let boneIdx = rig.bones.firstIndex(where: { $0.id == boneId }),
              let figureId = selectedFigureId,
              frames.indices.contains(currentFrameIndex),
              let stateIdx = frames[currentFrameIndex].figureStates.firstIndex(where: { $0.figureId == figureId }) else { return }

        pushUndo()
        let bone = rig.bones[boneIdx]
        let joints = frames[currentFrameIndex].figureStates[stateIdx].joints
        guard let posA = joints[bone.jointA], let posB = joints[bone.jointB] else { return }

        let midName = "mid_\(UUID().uuidString.prefix(6))"
        let midPos = CGPoint(x: (posA.x + posB.x) / 2, y: (posA.y + posB.y) / 2)

        // Add mid joint to all frames
        for i in frames.indices {
            if let idx = frames[i].figureStates.firstIndex(where: { $0.figureId == figureId }) {
                let ja = frames[i].figureStates[idx].joints[bone.jointA] ?? posA
                let jb = frames[i].figureStates[idx].joints[bone.jointB] ?? posB
                frames[i].figureStates[idx].joints[midName] = CGPoint(x: (ja.x + jb.x) / 2, y: (ja.y + jb.y) / 2)
            }
        }
        rig.customJoints[midName] = midPos

        // Create two new bones
        let boneA = Bone(id: UUID(), name: "\(bone.jointA)→\(midName)", parentId: bone.parentId,
                         jointA: bone.jointA, jointB: midName, length: bone.length / 2,
                         thickness: bone.thickness, color: bone.color, locked: bone.locked,
                         angleConstraint: nil, style: bone.style)
        let boneB = Bone(id: UUID(), name: "\(midName)→\(bone.jointB)", parentId: boneA.id,
                         jointA: midName, jointB: bone.jointB, length: bone.length / 2,
                         thickness: bone.thickness, color: bone.color, locked: bone.locked,
                         angleConstraint: bone.angleConstraint, style: bone.style)

        // Re-parent children
        for i in rig.bones.indices {
            if rig.bones[i].parentId == bone.id {
                rig.bones[i].parentId = boneB.id
            }
        }

        // Replace original
        rig.bones.remove(at: boneIdx)
        rig.bones.append(boneA)
        rig.bones.append(boneB)

        selectedBoneId = boneA.id
        markDirty()
    }

    /// Delete a bone (and optionally its child joints)
    func deleteBone(_ boneId: UUID) {
        guard let boneIdx = rig.bones.firstIndex(where: { $0.id == boneId }) else { return }
        pushUndo()
        let bone = rig.bones[boneIdx]

        // Re-parent children to this bone's parent
        for i in rig.bones.indices {
            if rig.bones[i].parentId == bone.id {
                rig.bones[i].parentId = bone.parentId
            }
        }

        rig.bones.remove(at: boneIdx)
        if selectedBoneId == boneId { selectedBoneId = nil }
        markDirty()
    }

    /// Select bone at tap location
    func selectBoneAt(_ canvasPoint: CGPoint, joints: [String: CGPoint]) {
        let threshold: CGFloat = 12

        for bone in rig.bones {
            guard let posA = joints[bone.jointA],
                  let posB = joints[bone.jointB] else { continue }
            let dist = distanceToLineSegment(point: canvasPoint, start: posA, end: posB)
            if dist < threshold {
                selectedBoneId = bone.id
                HapticManager.shared.buttonTap()
                return
            }
        }
        selectedBoneId = nil
    }

    /// Update bone visual properties
    func updateSelectedBoneStyle(_ style: BoneStyle) {
        guard let id = selectedBoneId,
              let idx = rig.bones.firstIndex(where: { $0.id == id }) else { return }
        rig.bones[idx].style = style
    }

    func updateSelectedBoneColor(_ hex: String) {
        guard let id = selectedBoneId,
              let idx = rig.bones.firstIndex(where: { $0.id == id }) else { return }
        rig.bones[idx].color = hex
    }

    func updateSelectedBoneThickness(_ thickness: CGFloat) {
        guard let id = selectedBoneId,
              let idx = rig.bones.firstIndex(where: { $0.id == id }) else { return }
        rig.bones[idx].thickness = thickness
    }

    func updateSelectedBoneLocked(_ locked: Bool) {
        guard let id = selectedBoneId,
              let idx = rig.bones.firstIndex(where: { $0.id == id }) else { return }
        rig.bones[idx].locked = locked
    }

    func toggleBoneVisibility() {
        showBoneOverlay.toggle()
    }

    func toggleIKChainPin(chainId: UUID, pinned: Bool) {
        guard let idx = rig.ikChains.firstIndex(where: { $0.id == chainId }) else { return }
        rig.ikChains[idx].pinned = pinned
    }

    /// Apply rig template (replaces current figure with template skeleton)
    func applyRigTemplate(_ template: RigTemplate) {
        pushUndo()

        // Replace figure joints
        let figure = StickFigure(
            id: UUID(),
            name: template.name,
            color: CodableColor(.white),
            lineWidth: 3,
            headRadius: template.id == "humanoid" ? 12 : 6,
            joints: template.joints
        )

        figures = [figure]
        selectedFigureId = figure.id

        // Build rig from template
        var bones: [Bone] = template.bones.map { pair in
            let posA = template.joints[pair.0] ?? .zero
            let posB = template.joints[pair.1] ?? .zero
            return Bone(
                id: UUID(),
                name: "\(pair.0)→\(pair.1)",
                parentId: nil,
                jointA: pair.0,
                jointB: pair.1,
                length: hypot(posB.x - posA.x, posB.y - posA.y),
                thickness: 2.5,
                color: "#FFFFFF",
                locked: false,
                angleConstraint: nil,
                style: .stick
            )
        }

        // Resolve parent IDs
        for i in bones.indices {
            let parentJoint = bones[i].jointA
            bones[i].parentId = bones.first(where: { $0.jointB == parentJoint })?.id
        }

        rig = BoneRig(bones: bones, customJoints: [:], ikChains: [])

        // Reset frames
        frames = [AnimationFrame(
            id: UUID(),
            figureStates: [FigureState(id: UUID(), figureId: figure.id, joints: template.joints, visible: true)],
            duration: 1.0 / Double(project.fps ?? 12),
            placedObjects: [],
            drawnElements: [],
            importedImages: []
        )]
        currentFrameIndex = 0
        markDirty()
    }

    // MARK: - Rig Gesture Handling

    func handleRigTap(at point: CGPoint) {
        guard let figureId = selectedFigureId,
              frames.indices.contains(currentFrameIndex),
              let state = frames[currentFrameIndex].figureStates.first(where: { $0.figureId == figureId }) else { return }

        let canvasPoint = screenToCanvas(point)

        switch rigSubTool {
        case .select:
            selectBoneAt(canvasPoint, joints: state.joints)

        case .addJoint:
            // Find closest bone and split it
            let threshold: CGFloat = 15
            for bone in rig.bones {
                guard let posA = state.joints[bone.jointA],
                      let posB = state.joints[bone.jointB] else { continue }
                let dist = distanceToLineSegment(point: canvasPoint, start: posA, end: posB)
                if dist < threshold {
                    splitBone(bone.id)
                    return
                }
            }

        case .deleteBone:
            let threshold: CGFloat = 15
            for bone in rig.bones {
                guard let posA = state.joints[bone.jointA],
                      let posB = state.joints[bone.jointB] else { continue }
                let dist = distanceToLineSegment(point: canvasPoint, start: posA, end: posB)
                if dist < threshold {
                    deleteBone(bone.id)
                    return
                }
            }

        case .pinJoint:
            // Find closest joint
            let threshold: CGFloat = 15
            for (name, pos) in state.joints {
                if hypot(canvasPoint.x - pos.x, canvasPoint.y - pos.y) < threshold {
                    // Toggle pin on IK chains containing this joint
                    for i in rig.ikChains.indices {
                        if rig.ikChains[i].jointNames.contains(name) {
                            rig.ikChains[i].pinned.toggle()
                        }
                    }
                    return
                }
            }

        default: break
        }
    }

    func handleRigDragBegan(at point: CGPoint) {
        let canvasPoint = screenToCanvas(point)
        guard let figureId = selectedFigureId,
              frames.indices.contains(currentFrameIndex),
              let state = frames[currentFrameIndex].figureStates.first(where: { $0.figureId == figureId }) else { return }

        if rigSubTool == .addBone {
            // Find closest joint to start from
            let threshold: CGFloat = 20
            for (name, pos) in state.joints {
                if hypot(canvasPoint.x - pos.x, canvasPoint.y - pos.y) < threshold {
                    rigDragStartJoint = name
                    return
                }
            }
        } else if rigSubTool == .select || rigSubTool == .ikDrag {
            // Find closest joint to drag
            let threshold: CGFloat = 15
            for (name, pos) in state.joints {
                if hypot(canvasPoint.x - pos.x, canvasPoint.y - pos.y) < threshold {
                    selectedJoint = name
                    return
                }
            }
        }
    }

    func handleRigDragMoved(to point: CGPoint) {
        let canvasPoint = screenToCanvas(point)
        guard let figureId = selectedFigureId else { return }

        if rigSubTool == .select || rigSubTool == .ikDrag {
            guard let jointName = selectedJoint else { return }
            moveJointWithIK(jointName, to: canvasPoint, figureId: figureId)
        }
        // addBone: live preview line drawn in CanvasView
    }

    func handleRigDragEnded(at point: CGPoint) {
        let canvasPoint = screenToCanvas(point)

        if rigSubTool == .addBone, let startJoint = rigDragStartJoint {
            addBone(from: startJoint, to: canvasPoint)
            rigDragStartJoint = nil
        } else if rigSubTool == .select || rigSubTool == .ikDrag {
            if selectedJoint != nil { pushUndo() }
            selectedJoint = nil
        }
    }

    // MARK: - Apply Template
    func applyTemplate(_ template: AnimationTemplate) {
        pushUndo()
        figures = (0..<template.figureCount).map { i in
            StickFigure.newFigure(name: "Figure \(i + 1)", color: figureColor(i))
        }
        selectedFigureId = figures.first?.id

        let fps = Double(project.fps ?? 12)
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
                placedObjects: [],
                drawnElements: [],
                importedImages: []
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

// Color → Hex
extension Color {
    func toHex() -> String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
