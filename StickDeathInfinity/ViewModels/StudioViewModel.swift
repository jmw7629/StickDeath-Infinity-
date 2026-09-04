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

    // MARK: - Layers (typed StudioLayer for panel, CanvasLayer for persistence)
    @Published var studioLayers: [StudioLayer] = [
        StudioLayer(name: "Layer 1")
    ]
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
    @Published var isExporting = false
    @Published var lastExportResult: StudioExportResult?

    // MARK: - Publish State
    @Published var isPublishing = false
    @Published var currentPublishJob: PublishJob?
    @Published var publishTitle = ""
    @Published var publishDescription = ""
    @Published var publishTagsInput = ""
    @Published var publishVisibility: PublishVisibility = .unlisted
    @Published var publishAudience: PublishAudience = .allAges

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
        activeLayerID = layers.first?.id ?? ""
        currentFrameIndex = 0
        currentLayerIndex = 0
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
                    layerID: el.layerID
                )
            }
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
    }

    func prevFrame() {
        if currentFrameIndex > 0 { currentFrameIndex -= 1 }
    }

    // MARK: - Element Operations
    func commitElement(_ element: DrawnElement) {
        pushUndo()
        frames[currentFrameIndex].elements.append(element)
        lastSaveTime = Date()
    }

    func deleteSelected() {
        guard !frames[currentFrameIndex].elements.isEmpty else { return }
        pushUndo()
        frames[currentFrameIndex].elements.removeLast()
        lastSaveTime = Date()
    }

    func clearCanvas() {
        pushUndo()
        frames[currentFrameIndex].elements.removeAll()
        lastSaveTime = Date()
    }

    // MARK: - Layer Operations (CanvasLayer by string ID for backward compat)
    func toggleLayerVisibility(_ id: String) {
        if let idx = layers.firstIndex(where: { $0.id == id }) {
            layers[idx].visible.toggle()
        }
    }

    func toggleLayerLock(_ id: String) {
        if let idx = layers.firstIndex(where: { $0.id == id }) {
            layers[idx].locked.toggle()
        }
    }
    
    // StudioLayer operations for LayerPanel
    func toggleLayerVisibility(_ id: UUID) {
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            studioLayers[idx].visible.toggle()
        }
    }
    
    func setLayerLockMode(_ id: UUID, mode: LayerLockMode) {
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            studioLayers[idx].lockMode = mode
        }
    }
    
    func setLayerColor(_ id: UUID, color: Color) {
        if let idx = studioLayers.firstIndex(where: { $0.id == id }) {
            studioLayers[idx].labelColor = color
        }
    }
    
    func duplicateLayer(_ id: UUID) {
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
    }
    
    func moveLayerUp(_ id: UUID) {
        guard let idx = studioLayers.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        studioLayers.swapAt(idx, idx - 1)
    }
    
    func moveLayerDown(_ id: UUID) {
        guard let idx = studioLayers.firstIndex(where: { $0.id == id }), idx < studioLayers.count - 1 else { return }
        studioLayers.swapAt(idx, idx + 1)
    }
    
    func addLayer() {
        let num = studioLayers.count + 1
        let newLayer = StudioLayer(name: "Layer \(num)")
        studioLayers.insert(newLayer, at: 0)
        // Also sync to CanvasLayer
        let canvasLayer = CanvasLayer(
            id: newLayer.id.uuidString, name: newLayer.name,
            visible: true, locked: false, opacity: 1.0
        )
        layers.insert(canvasLayer, at: 0)
        activeLayerID = canvasLayer.id
        currentLayerIndex = 0
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

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(frames)
        frames = prev
        currentFrameIndex = min(currentFrameIndex, frames.count - 1)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(frames)
        frames = next
        currentFrameIndex = min(currentFrameIndex, frames.count - 1)
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

    // MARK: - Export Execution
    func performExport() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }

        // Render frames to a temporary file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdi_export_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileExtension: String
        let contentType: String
        switch exportFormat {
        case .mp4: fileExtension = "mp4"; contentType = "video/mp4"
        case .gif: fileExtension = "gif"; contentType = "image/gif"
        case .png: fileExtension = "png"; contentType = "image/png"
        case .spritesheet: fileExtension = "png"; contentType = "image/png"
        }

        let outputFile = tempDir.appendingPathComponent("export.\(fileExtension)")

        // Encode frames as JSON payload for server-side or local rendering
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let frameData = (try? encoder.encode(frames)) ?? Data()

        // Write frame data to a JSON file (server-side rendering consumes this)
        let jsonFile = tempDir.appendingPathComponent("frames.json")
        try? frameData.write(to: jsonFile)

        // For MP4: write a placeholder file indicating export readiness
        // In production this would invoke AVAssetExport or server-side render
        let placeholder = "SDI_EXPORT \(exportFormat.rawValue) \(exportQuality.rawValue)\nFrames: \(frames.count)\nFPS: \(fps)\nSize: \(canvasWidth)x\(canvasHeight)\n"
        try? placeholder.data(using: .utf8)?.write(to: outputFile)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputFile.path)[.size] as? Int64) ?? nil

        let result = StudioExportResult(
            fileURL: outputFile,
            format: exportFormat,
            quality: exportQuality,
            fileSize: fileSize
        )

        lastExportResult = result
        publishTitle = projectName
        publishDescription = "Created with StickDeath Infinity"
    }

    // MARK: - Publish Submission
    func submitPublish() async {
        guard let exportResult = lastExportResult else {
            print("[Publish] No export result available")
            return
        }

        // Prevent duplicate publish for same export
        if let existing = PublishJobStore.shared.job(forExportResultID: exportResult.id),
           !existing.status.isTerminal {
            currentPublishJob = existing
            return
        }

        isPublishing = true
        defer { isPublishing = false }

        let tags = publishTagsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let metadata = PublishMetadata(
            title: publishTitle,
            description: publishDescription,
            tags: tags,
            visibility: publishVisibility,
            audience: publishAudience
        )

        var job = PublishJob(
            exportResultID: exportResult.id,
            status: .preparing,
            metadata: metadata
        )

        PublishJobStore.shared.addJob(job)
        currentPublishJob = job

        do {
            // The YouTubePublishingClient handles session token injection internally
            let request = PublishRequest(
                idempotencyKey: job.idempotencyKey,
                exportAssetURL: exportResult.fileURL.absoluteString,
                exportFormat: exportFormat.rawValue,
                title: publishTitle,
                description: publishDescription,
                tags: tags,
                thumbnailDataURL: exportResult.thumbnailURL.flatMap { try? Data(contentsOf: $0) },
                visibility: publishVisibility.rawValue,
                audience: publishAudience.rawValue,
                userSessionToken: "" // Injected by YouTubePublishingClient
            )

            job.status = .uploading
            PublishJobStore.shared.updateJob(job)
            currentPublishJob = job

            let response = try await YouTubePublishingClient.shared.publish(request: request)

            job.serverJobID = response.serverJobID
            job.status = PublishJobStatus(rawValue: response.status) ?? .queued
            job.publishedVideoID = response.videoID
            job.publishedVideoURL = response.videoURL
            job.updatedAt = Date()

            PublishJobStore.shared.updateJob(job)
            currentPublishJob = job

            // Start polling if not terminal
            if !job.status.isTerminal {
                startStatusPolling(job: &job)
            }

        } catch {
            job.status = .failed
            job.errorMessage = error.localizedDescription
            job.updatedAt = Date()
            PublishJobStore.shared.updateJob(job)
            currentPublishJob = job
        }
    }

    private func startStatusPolling(job: inout PublishJob) {
        guard let serverJobID = job.serverJobID else { return }
        let jobID = job.id

        Task { [weak self] in
            var attempts = 0
            let maxAttempts = 60
            while attempts < maxAttempts {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                attempts += 1

                guard let self else { return }
                guard var currentJob = PublishJobStore.shared.activeJobs.first(where: { $0.id == jobID }),
                      !currentJob.status.isTerminal else { return }

                do {
                    let status = try await YouTubePublishingClient.shared.status(serverJobID: serverJobID)
                    currentJob.status = PublishJobStatus(rawValue: status.status) ?? currentJob.status
                    currentJob.publishedVideoID = status.videoID ?? currentJob.publishedVideoID
                    currentJob.publishedVideoURL = status.videoURL ?? currentJob.publishedVideoURL
                    currentJob.errorMessage = status.errorMessage ?? currentJob.errorMessage
                    currentJob.updatedAt = Date()

                    PublishJobStore.shared.updateJob(currentJob)
                    self.currentPublishJob = currentJob

                    if currentJob.status.isTerminal { return }
                } catch {
                    // Transient polling error — keep trying
                    print("[Publish] Status poll error: \(error)")
                }
            }
        }
    }

    func cancelPublish() async {
        guard var job = currentPublishJob, job.status.canCancel else { return }

        if let serverJobID = job.serverJobID {
            try? await YouTubePublishingClient.shared.cancel(serverJobID: serverJobID)
        }

        job.status = .cancelled
        job.updatedAt = Date()
        PublishJobStore.shared.updateJob(job)
        currentPublishJob = job
    }

    func retryPublish() async {
        guard var job = currentPublishJob, job.status == .failed else { return }

        job.status = .preparing
        job.retryCount += 1
        job.errorMessage = nil
        job.updatedAt = Date()
        PublishJobStore.shared.updateJob(job)
        currentPublishJob = job

        // Re-submit
        await submitPublish()
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
