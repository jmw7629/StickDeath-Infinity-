import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class StudioViewModel: ObservableObject {
    static let shared = StudioViewModel(toolDefaults: .standard)
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
    struct TextDraft: Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let layerID: String
        let elementID: String?
        let origin: CGPoint
    }
    @Published private(set) var textDraft: TextDraft?
    @Published var textInput = ""
    @Published var textStyle = StudioTextStyle() { didSet { rememberDrawingToolPreferences() } }
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
            if editor.selectFrame(frames[newValue].id) { imageMoveTarget = nil; scheduleSave() }
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
    var copiedDrawingCount: Int { editor.clipboardElementCount }
    var copiedDrawingClipboardID: String? { copiedDrawingCount > 0 ? editor.clipboardVersion.uuidString : nil }
    var canDeleteSelected: Bool { !editor.selectedElementIDs.isEmpty }
    var selectedElementIDs: Set<String> { editor.selectedElementIDs }
    var isDirty: Bool { savedRevision != document.revision || pendingBrushStroke != nil || activeStrokeID != nil || textDraft != nil }
    var saveTimeAgo: String { activeStrokeID != nil ? "Drawing…" : isSaving ? "Saving…" : isDirty ? "Unsaved" : "Saved" }

    private let toolDefaults: UserDefaults?
    static let toolPreferencesKey = "studio.drawing-tool-preferences.v1"
    private var toolPreferences = StudioDrawingToolPreferences()
    private var restoringToolPreferences = false
    @Published private(set) var toolPreferencesWarning: String?
    @Published var selectedTool: DrawingTool = .brush {
        didSet { if selectedTool != oldValue { imageMoveTarget = nil; restoreDrawingToolPreferences() } }
    }
    @Published var strokeColor: Color = .red
    @Published var strokeWidth: Double = 3 { didSet { rememberDrawingToolPreferences() } }
    @Published var strokeOpacity: Double = 1 { didSet { rememberDrawingToolPreferences() } }
    @Published var eraserMode: StudioEraserMode = .hard { didSet { rememberDrawingToolPreferences() } }
    @Published var shapeFilled = false { didSet { rememberDrawingToolPreferences() } }
    @Published var shapeCornerRadius: Double = 0 { didSet { rememberDrawingToolPreferences() } }
    var toolOpacity: Double { get { strokeOpacity } set { strokeOpacity = min(1, max(0, newValue)) } }
    @Published var smoothing: Double = 3 { didSet { rememberDrawingToolPreferences() } }
    @Published var pressureSensitivity = false
    @Published var brushFamily: StudioBrushFamily = .round { didSet { rememberDrawingToolPreferences() } }
    @Published var brushTipAngle: Double = 45 { didSet { rememberDrawingToolPreferences() } }
    @Published var brushTexture: Double = 0.5 { didSet { rememberDrawingToolPreferences() } }
    @Published var brushGrain: Double = 0.3 { didSet { rememberDrawingToolPreferences() } }
    @Published var brushGradientEndColor: Color = .blue { didSet { rememberDrawingToolPreferences() } }
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
    @discardableResult
    func beginTextEditing(selected: Bool = false) -> Bool {
        guard isEditing, !isPlaying, !isSaving, activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil else {
            message = "Apply or cancel the current draft before starting text."; return false
        }
        let element = selectedElementIDs.count == 1 ? currentFrame.elements.first(where: { selectedElementIDs.contains($0.id) }) : nil
        if selected && element?.text == nil { message = "Select one editable text box with Move before editing text."; return false }
        let layerID = selected ? element!.layerID! : activeLayerID
        guard let layer = layers.first(where: { $0.id == layerID }), layer.visible,
              layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { message = StudioDocumentError.locked.localizedDescription; return false }
        selectedTool = .text
        if selected, let element, let text = element.text {
            let hex = element.color.hasPrefix("#") ? String(element.color.dropFirst()) : element.color
            guard let rgb = UInt32(hex, radix: 16) else { message = StudioTextDescriptor.Failure.invalid.localizedDescription; return false }
            textInput = text.content; textStyle = text.style
            strokeColor = Color(red: Double((rgb >> 16) & 255) / 255,
                                green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
            strokeOpacity = element.opacity
        } else { textInput = "" }
        let origin = selected ? CGPoint(x: element!.points[0].x, y: element!.points[0].y)
            : CGPoint(x: max(0, (Double(canvasWidth)-textStyle.boxWidth)/2), y: max(0, (Double(canvasHeight)-textStyle.boxHeight)/2))
        textDraft = TextDraft(projectID: document.id, revision: document.revision,
            frameID: currentFrame.id, layerID: layerID, elementID: selected ? element!.id : nil, origin: origin)
        activePanel = .toolSettings; message = nil
        return true
    }
    func cancelTextEditing() { textDraft = nil; textInput = ""; message = nil }
    @discardableResult
    func applyTextEditing() -> Bool {
        guard let draft = textDraft, selectedTool == .text, isEditing, !isPlaying, !isSaving,
              activeStrokeID == nil, pendingBrushStroke == nil,
              draft.projectID == document.id, draft.revision == document.revision,
              draft.frameID == currentFrame.id else {
            message = "The text draft's Studio context changed. Cancel it and reopen text; the project has not changed."; return false
        }
        do {
            let descriptor = StudioTextDescriptor(content: textInput, style: textStyle)
            let id = draft.elementID ?? UUID().uuidString
            let action: StudioCommand
            if draft.elementID != nil {
                action = .updateText(.init(frame: .id(draft.frameID), elementID: id,
                    text: descriptor, color: strokeColorHex, opacity: capturedStrokeOpacity))
            } else {
                action = .draw(.init(frame: .id(draft.frameID), layer: .id(draft.layerID), strokes: [
                    .init(id: id, tool: .text, points: [.init(x: draft.origin.x, y: draft.origin.y)],
                        color: strokeColorHex, width: 1, opacity: capturedStrokeOpacity, text: descriptor)]))
            }
            var candidate = editor
            _ = try StudioCommandExecutor.execute(.init(requestID: UUID(), projectID: draft.projectID, expectedRevision: draft.revision,
                action: .apply([action])), editor: &candidate)
            try preflightRasterDocument(candidate.document)
            editor = candidate; editor.selectedElementIDs = [id]
            textDraft = nil; textInput = ""; scheduleSave(); message = nil
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func shapeDescriptor() throws -> StudioShapeDescriptor? {
        guard [.rectangle, .circle].contains(selectedTool) else { return nil }
        let value = StudioShapeDescriptor(fillColor: shapeFilled ? strokeColorHex : nil,
            cornerRadius: selectedTool == .rectangle ? shapeCornerRadius : 0)
        try value.validate(tool: selectedTool)
        return value
    }
    func eraserDescriptor() throws -> StudioEraserDescriptor? {
        guard selectedTool == .eraser else { return nil }
        guard let layer = layers.first(where: { $0.id == activeLayerID }),
              layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else {
            throw StudioDocumentError.locked
        }
        guard editor.selectedElementIDs.isEmpty else {
            throw StudioDocumentError.unavailable("Erasing within a selection is unfinished. Deselect before erasing the active layer; nothing changed.")
        }
        return StudioEraserDescriptor(mode: eraserMode)
    }
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
    func selectDrawingTool(_ tool: DrawingTool) { selectedTool = tool }

    // Tool preferences are device settings, separate from the editable project,
    // its revision/history, and an in-flight stroke's immutable capture.
    private func rememberDrawingToolPreferences() {
        guard !restoringToolPreferences else { return }
        let value = StudioDrawingToolPreferences.Entry(width: strokeWidth, opacity: strokeOpacity,
            smoothing: smoothing, family: brushFamily, tipAngle: brushTipAngle,
            texture: brushTexture, grain: brushGrain, gradientEnd: Self.preferenceRGB(brushGradientEndColor),
            shapeFilled: shapeFilled, cornerRadius: shapeCornerRadius, eraserMode: eraserMode, textStyle: textStyle)
        // Invalid programmatic values remain visible to the existing operation
        // validators, but can never poison the next launch or another tool.
        guard value.isValid else { return }
        var candidate = toolPreferences
        candidate.values[selectedTool.rawValue] = value
        guard let data = try? candidate.encoded() else { return }
        toolPreferences = candidate
        toolDefaults?.set(data, forKey: Self.toolPreferencesKey)
    }
    private func restoreDrawingToolPreferences() {
        restoringToolPreferences = true
        defer { restoringToolPreferences = false }
        let value = toolPreferences.settings(for: selectedTool)
        strokeWidth = value.width; strokeOpacity = value.opacity; smoothing = value.smoothing
        brushFamily = value.family; brushTipAngle = value.tipAngle
        brushTexture = value.texture; brushGrain = value.grain
        brushGradientEndColor = Color(red: value.gradientEnd.red, green: value.gradientEnd.green,
                                     blue: value.gradientEnd.blue)
        shapeFilled = value.shapeFilled; shapeCornerRadius = value.cornerRadius
        eraserMode = value.eraserMode ?? .hard
        textStyle = value.textStyle ?? StudioTextStyle()
    }
    func resetCurrentDrawingToolPreferences() {
        toolPreferences.values.removeValue(forKey: selectedTool.rawValue)
        restoreDrawingToolPreferences()
        rememberDrawingToolPreferences()
    }
    private static func preferenceRGB(_ color: Color) -> StudioBrushColor {
        #if canImport(UIKit)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .init(red: 0, green: 0, blue: 1)
        }
        return .init(red: Double(red), green: Double(green), blue: Double(blue))
        #elseif canImport(AppKit)
        guard let value = NSColor(color).usingColorSpace(.sRGB) else { return .init(red: 0, green: 0, blue: 1) }
        return .init(red: Double(value.redComponent), green: Double(value.greenComponent), blue: Double(value.blueComponent))
        #else
        return .init(red: 0, green: 0, blue: 1)
        #endif
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
        let copiedDrawingCount: Int
        let copiedDrawingClipboardID: String?
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
                selectedElementIDs: [], copiedDrawingCount: 0, copiedDrawingClipboardID: nil, selectedAudioClipID: nil, displayedFrameID: nil,
                isPlaying: false, audioPlayheadTime: nil, retainedAudio: [], canApplyCommands: false,
                isDirty: false, isSaving: false, canUndo: false, canRedo: false)
        }
        return .init(route: .editor, activePanel: activePanel, selectedTool: selectedTool,
            document: StudioCommandContext(document: document), selectedElementIDs: selectedElementIDs,
            copiedDrawingCount: copiedDrawingCount, copiedDrawingClipboardID: copiedDrawingClipboardID,
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
        let clipboardVersion = editor.clipboardVersion
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
        guard editor.clipboardVersion == clipboardVersion else { throw StudioCommandError.staleClipboard }
        clearMissingImageMoveTarget(in: candidate.document)
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
        guard textDraft == nil else { throw StudioDocumentError.unavailable("Apply or cancel the text draft before applying Studio commands.") }
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
            for element in frame.elements { try addUnits(element.points.count); try addUnits(element.fillMask?.spans.count ?? 0); try addUnits(element.text?.content.utf8.count ?? 0) }
        }
        for command in commands {
            switch command {
            case .draw(let drawing):
                guard drawing.strokes.count <= StudioCommandExecutor.maximumStrokes - strokes else { throw StudioCommandError.limitExceeded }
                strokes += drawing.strokes.count; edits += drawing.strokes.count
                try addUnits(drawing.strokes.count, weight: 32)
                for stroke in drawing.strokes { try addUnits(stroke.points.count); try addUnits(stroke.text?.content.utf8.count ?? 0) }
            case .updateText(let text): edits += 1; try addUnits(text.text.content.utf8.count)
            case .transformElements(let selection): edits += selection.elementIDs.count; try addUnits(selection.elementIDs.count, weight: 32)
            case .duplicateFrame, .duplicateLayer, .pasteElements:
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
    init(storage: DeviceStorageManager = .shared, toolDefaults: UserDefaults? = nil) {
        self.storage = storage
        self.toolDefaults = toolDefaults
        editor = try! StudioDocumentEditor(document: .new(name: "Untitled Animation", width: 1080, height: 1080, fps: 12))
        if let data = toolDefaults?.data(forKey: Self.toolPreferencesKey) {
            do { toolPreferences = try StudioDrawingToolPreferences.decode(data) }
            catch { toolPreferencesWarning = "Saved tool preferences could not be read. Default settings are available; your projects are unchanged." }
        }
        restoreDrawingToolPreferences()
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
        guard !isEditing, pendingBrushStroke == nil, activeStrokeID == nil, textDraft == nil else { message = "Finish or discard any drawing draft, then save and return to projects before creating another animation."; return false }
        do {
            editor = try StudioDocumentEditor(document: .new(name: name, width: width, height: height, fps: fps))
            retainedRasterFrames.removeAll(); retainedAudioTracks.removeAll(); managedAudioTracks.removeAll()
            savedRevision = nil; lastSaveTime = nil; resetSession(); isEditing = true
            return await save()
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult
    func openProject(_ metadata: AnimationMetadata) async -> Bool {
        guard !isEditing, pendingBrushStroke == nil, activeStrokeID == nil, textDraft == nil else { message = "Finish or discard any drawing draft, then save and return to projects before opening another animation."; return false }
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
            if textDraft != nil { message = "Committed artwork is saved. Apply or cancel the unsaved text draft before leaving."; return false }
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
        selectedAudioClip = nil; audioPlayheadTime = 0; message = nil; imageMoveTarget = nil
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
            clearMissingImageMoveTarget(in: candidate.document)
            editor = candidate; pruneManagedAudio(); scheduleSave()
        } catch { message = error.localizedDescription }
    }
    private func allowDocumentEditDuringInput() -> Bool {
        guard textDraft == nil else { message = "Apply or cancel the text draft before changing the document."; return false }
        guard activeStrokeID == nil else { message = "Finish the current touch stroke before changing the document."; return false }
        return true
    }
    private func change(_ operation: (inout StudioDocument) throws -> Void) { command { try $0.change(operation) } }
    func addFrame() { stopPlayback(); command { try $0.addFrame() } }
    func duplicateFrame() { stopPlayback(); command { try $0.duplicateFrame() } }
    func copyFrame() { if allowDocumentEditDuringInput() { editor.copyFrame(); pruneManagedImages() } }
    func pasteFrame() { stopPlayback(); command { try $0.pasteFrame() } }
    func pasteClipboard() {
        guard copiedDrawingCount > 0 else { pasteFrame(); return }
        guard isEditing, !isPlaying, !isSaving, activeStrokeID == nil, pendingBrushStroke == nil else {
            message = "Finish the current Studio operation before pasting drawings."; return
        }
        do {
            let receipt = try applyStudioCommands(.init(requestID: UUID(), projectID: document.id,
                expectedRevision: document.revision, action: .apply([.pasteElements(.init(
                    frame: .id(currentFrame.id), layer: .id(activeLayerID), clipboardID: editor.clipboardVersion.uuidString))])))
            imageMoveTarget = nil
            editor.selectedElementIDs = Set(receipt.createdElementIDs)
        } catch { message = error.localizedDescription }
    }
    func deleteFrame(_ id: String) { stopPlayback(); command { try $0.deleteFrame(id) } }
    func moveFrame(_ id: String, offset: Int) { stopPlayback(); command { try $0.moveFrame(id, offset: offset) } }
    func nextFrame() { if currentFrameIndex + 1 < frames.count { currentFrameIndex += 1 } }
    func prevFrame() { if currentFrameIndex > 0 { currentFrameIndex -= 1 } }
    @discardableResult
    func commitElement(_ element: DrawnElement, frameID: String? = nil) -> Bool {
        guard textDraft == nil else { message = "Apply or cancel the text draft before drawing."; return false }
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
        guard isEditing, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil else { return false }
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
    @discardableResult
    func orderSelected(forward: Bool) -> Bool {
        guard isEditing, !isPlaying, !isSaving, activeStrokeID == nil, pendingBrushStroke == nil else {
            message = "Finish the current Studio operation before changing artwork order."; return false
        }
        let ids = selectedElementIDs
        guard !ids.isEmpty else { message = "Select drawn artwork before changing its order."; return false }
        let revision = document.revision
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: document.id,
                expectedRevision: revision, action: .apply([.orderElements(.init(frame: .id(currentFrame.id),
                    elementIDs: ids.sorted(), direction: forward ? .later : .earlier))])))
            editor.selectedElementIDs = ids
            // Successful direct manipulation keeps the canvas geometry and existing errors unchanged.
            return true
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult
    func reflectSelected(axis: StudioReflectionAxis) -> Bool {
        guard isEditing, !isPlaying, !isSaving, activeStrokeID == nil, pendingBrushStroke == nil else {
            message = "Finish the current Studio operation before flipping artwork."; return false
        }
        let ids = selectedElementIDs
        guard !ids.isEmpty else { message = "Select drawn artwork before flipping it."; return false }
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: document.id,
                expectedRevision: document.revision, action: .apply([.reflectElements(.init(frame: .id(currentFrame.id),
                    elementIDs: ids.sorted(), axis: axis))])))
            editor.selectedElementIDs = ids
            // The artwork is the success feedback; do not insert a canvas-resizing banner.
            return true
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult
    func copySelected() -> Bool {
        guard isEditing, !isPlaying, !isSaving, activeStrokeID == nil, pendingBrushStroke == nil else {
            message = "Finish the current Studio operation before copying drawings."; return false
        }
        guard !selectedElementIDs.isEmpty else { message = "Select drawn artwork before copying."; return false }
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: document.id,
                expectedRevision: document.revision, action: .apply([.copyElements(.init(
                    frame: .id(currentFrame.id), elementIDs: selectedElementIDs.sorted()))])))
            pruneManagedImages()
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func deleteSelected() { command { try $0.deleteSelected() } }
    enum SelectionMode: String, CaseIterable { case new, add, subtract
        var label: String { switch self { case .new: return "⬜ New"; case .add: return "➕ Add"; case .subtract: return "➖ Sub" } }
    }
    @Published var selectionMode: SelectionMode = .new
    @Published var selectionScalePercent: Double = 100
    @Published var selectionRotationDegrees: Double = 0
    @discardableResult
    func transformSelected() -> Bool {
        let ids=selectedElementIDs
        guard isEditing,!isPlaying,!ids.isEmpty else { message="Select drawings or text before transforming.";return false }
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: document.id,
                expectedRevision: document.revision, action: .apply([.transformElements(.init(frame:.id(currentFrame.id),
                    elementIDs:ids.sorted(),scaleX:selectionScalePercent/100,scaleY:selectionScalePercent/100,
                    rotation:selectionRotationDegrees))])))
            editor.selectedElementIDs=ids;resetSelectionTransform();return true
        } catch { message=error.localizedDescription;return false }
    }
    func resetSelectionTransform() { selectionScalePercent=100;selectionRotationDegrees=0 }
    struct SelectionHandleCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let ids: Set<String>
        let mode: SelectionMode
        let bounds: CGRect
    }
    func beginSelectionHandle() -> SelectionHandleCapture? {
        guard isEditing, !isPlaying, !isSaving, selectedTool == .move, !isMovingImageOnCanvas, selectionMode != .subtract,
              activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              !selectedElementIDs.isEmpty, selectedElementIDs.count <= 1024 else { return nil }
        var bounds = CGRect.null
        let elements = currentFrame.elements.filter { selectedElementIDs.contains($0.id) }
        guard elements.count == selectedElementIDs.count else { return nil }
        for element in elements {
            guard element.tool != .eraser,
                  layers.contains(where: { $0.id == element.layerID && $0.visible && $0.opacity > 0 && !$0.isFullyLocked && $0.lockMode == "free" }),
                  let rect = try? StudioSelectionRegion.drawingBounds(element), !rect.isNull,
                  rect.width > 0, rect.height > 0,
                  [rect.minX,rect.minY,rect.maxX,rect.maxY].allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else { return nil }
            bounds = bounds.union(rect)
        }
        return SelectionHandleCapture(projectID: document.id, revision: document.revision,
            frameID: currentFrame.id, ids: selectedElementIDs, mode: selectionMode, bounds: bounds)
    }
    private func selectionHandleRequest(_ capture: SelectionHandleCapture,
                                        values: StudioSelectionHandleGeometry.Values) throws -> StudioCommandRequest {
        guard beginSelectionHandle() == capture else { throw StudioCommandError.staleRevision }
        return .init(requestID: UUID(), projectID: capture.projectID, expectedRevision: capture.revision,
            action: .apply([.transformElements(.init(frame: .id(capture.frameID), elementIDs: capture.ids.sorted(),
                scaleX: values.scale, scaleY: values.scale, rotation: values.rotation))]))
    }
    /// Uses the same validated command as the final edit, on a disposable editor.
    /// Preview never mutates document history, selection, autosave or source assets.
    func selectionHandlePreview(_ capture: SelectionHandleCapture,
                                values: StudioSelectionHandleGeometry.Values) throws -> AnimationFrame {
        let request = try selectionHandleRequest(capture, values: values)
        try validateCommandWorkBudget(request)
        var candidate = editor
        _ = try StudioCommandExecutor.execute(request, editor: &candidate)
        guard let frame = candidate.document.frames.first(where: { $0.id == capture.frameID }) else {
            throw StudioCommandError.staleRevision
        }
        return frame
    }
    @discardableResult
    func finishSelectionHandle(_ capture: SelectionHandleCapture,
                               values: StudioSelectionHandleGeometry.Values) -> Bool {
        do {
            let request = try selectionHandleRequest(capture, values: values)
            _ = try applyStudioCommands(request)
            editor.selectedElementIDs = capture.ids
            resetSelectionTransform()
            return true
        } catch { message = error.localizedDescription; return false }
    }
    @Published var areaSelectionKind: StudioAreaSelectionKind = .freehand
    @Published var areaSelectionSmoothing: Double = 3
    struct AreaSelectionCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let selectedIDs: Set<String>
        let mode: SelectionMode
        let kind: StudioAreaSelectionKind
        let smoothing: Double
    }
    func beginAreaSelection() -> AreaSelectionCapture? {
        guard isEditing, !isPlaying, !isSaving, selectedTool == .lasso,
              activeStrokeID == nil, pendingBrushStroke == nil,
              areaSelectionSmoothing.isFinite, (0...10).contains(areaSelectionSmoothing) else { return nil }
        return .init(projectID: document.id, revision: document.revision, frameID: currentFrame.id,
            selectedIDs: selectedElementIDs, mode: selectionMode, kind: areaSelectionKind,
            smoothing: areaSelectionSmoothing)
    }
    @discardableResult
    func finishAreaSelection(_ capture: AreaSelectionCapture, points: [CGPoint],
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            guard beginAreaSelection() == capture else { throw StudioCommandError.staleRevision }
            try checkCancellation()
            let region = try StudioSelectionRegion(points: points, kind: capture.kind, smoothing: capture.smoothing)
            guard currentFrame.elements.count <= 2_000_000 / region.points.count else {
                throw StudioDocumentError.unavailable("This lasso is too complex for the current frame. Use Rectangle or a simpler outline.")
            }
            let eligibleLayers = Set(layers.filter { $0.visible && $0.opacity > 0 && !$0.isFullyLocked }.map(\.id))
            var found = Set<String>()
            for element in currentFrame.elements {
                try checkCancellation()
                guard let layerID = element.layerID, eligibleLayers.contains(layerID), element.opacity > 0,
                      element.tool != .eraser, let bounds = try StudioSelectionRegion.drawingBounds(element) else { continue }
                let visibleBounds = bounds.intersection(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
                guard !visibleBounds.isNull, region.contains(visibleBounds) else { continue }
                found.insert(element.id)
            }
            var selected = capture.selectedIDs
            switch capture.mode {
            case .new: selected = found
            case .add: selected.formUnion(found)
            case .subtract: selected.subtract(found)
            }
            try checkCancellation()
            guard beginAreaSelection() == capture else { throw StudioCommandError.staleRevision }
            // Selection is transient UI state: no document edit, revision,
            // autosave or Undo entry, and no success banner resizing the canvas.
            editor.selectedElementIDs = selected
            return true
        } catch { message = error.localizedDescription; return false }
    }
    private struct ImageMoveTarget: Equatable {
        let selectionID = UUID()
        let projectID: UUID
        let frameID: String
        let assetID: String
    }
    @Published private var imageMoveTarget: ImageMoveTarget?
    var isMovingImageOnCanvas: Bool {
        guard let target = imageMoveTarget else { return false }
        return selectedTool == .move && target.projectID == document.id &&
            target.frameID == currentFrame.id && target.assetID == currentFrame.rasterAssetID
    }
    @discardableResult
    func setImageCanvasMove(_ enabled: Bool) -> Bool {
        if !enabled { imageMoveTarget = nil; return true }
        guard let capture = prepareImagePlacement() else { return false }
        imageMoveTarget = .init(projectID: capture.projectID, frameID: capture.frameID, assetID: capture.assetID)
        editor.selectedElementIDs.removeAll()
        return true
    }
    private func clearMissingImageMoveTarget(in next: StudioDocument) {
        guard let target = imageMoveTarget else { return }
        if target.projectID != next.id || target.frameID != next.activeFrameID ||
            next.frames.first(where: { $0.id == target.frameID })?.rasterAssetID != target.assetID {
            imageMoveTarget = nil
        }
    }
    struct ImageMoveCapture: Equatable {
        let placement: ImagePlacementCapture
        let selectionID: UUID
    }
    func currentImageMoveCapture() -> ImageMoveCapture? {
        guard isMovingImageOnCanvas, let target = imageMoveTarget,
              let placement = prepareImagePlacement() else { return nil }
        return .init(placement: placement, selectionID: target.selectionID)
    }
    func beginImageMove(at point: CGPoint) -> ImageMoveCapture? {
        guard point.x.isFinite, point.y.isFinite, let capture = currentImageMoveCapture() else { return nil }
        let p = capture.placement.original
        return CGRect(x: p.x, y: p.y, width: p.width, height: p.height).contains(point) ? capture : nil
    }
    /// A transient frame preview; only finishImageMove commits through the shared command.
    func imageMovePreview(_ capture: ImageMoveCapture, delta: CGSize) throws -> AnimationFrame {
        guard currentImageMoveCapture() == capture else { throw StudioCommandError.staleRevision }
        guard delta.width.isFinite, delta.height.isFinite,
              abs(delta.width) <= 131_072, abs(delta.height) <= 131_072 else {
            throw StudioDocumentError.invalid("The image move has invalid coordinates.")
        }
        var frame = currentFrame
        let original = capture.placement.original
        // Keep the whole managed image inside the canvas, matching numeric placement.
        frame.rasterPlacement = .init(
            x: min(max(0, original.x + delta.width), max(0, Double(capture.placement.canvasWidth) - original.width)),
            y: min(max(0, original.y + delta.height), max(0, Double(capture.placement.canvasHeight) - original.height)),
            width: original.width, height: original.height)
        return frame
    }
    @discardableResult
    func finishImageMove(_ capture: ImageMoveCapture, delta: CGSize,
                         checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            let preview = try imageMovePreview(capture, delta: delta)
            guard let placement = preview.rasterPlacement else { throw StudioCommandError.invalidReference }
            return placeImage(capture.placement, at: placement, checkCancellation: {
                try checkCancellation()
                guard self.currentImageMoveCapture() == capture else { throw StudioCommandError.staleRevision }
            })
        } catch { message = error.localizedDescription; return false }
    }

    struct ImagePlacementCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let assetID: String
        let layerID: String
        let original: StudioRasterPlacement
        let fitted: StudioRasterPlacement
        let canvasWidth: Int
        let canvasHeight: Int
    }
    func prepareImagePlacement() -> ImagePlacementCapture? {
        guard isEditing, !isPlaying, !isSaving, selectedTool == .move,
              activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              let assetID = currentFrame.rasterAssetID, let original = currentFrame.rasterPlacement,
              let source = originalImageSource(assetID),
              let layer = layers.first(where: { $0.id == currentFrame.rasterLayerID }),
              layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { return nil }
        return .init(projectID: document.id, revision: document.revision, frameID: currentFrame.id,
            assetID: assetID, layerID: layer.id, original: original,
            fitted: .aspectFit(imageWidth: source.normalizedWidth, imageHeight: source.normalizedHeight,
                canvasWidth: document.width, canvasHeight: document.height),
            canvasWidth: document.width, canvasHeight: document.height)
    }
    @discardableResult
    func placeImage(_ capture: ImagePlacementCapture, at placement: StudioRasterPlacement,
                    checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            try checkCancellation()
            guard prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply([.updateImagePlacement(.init(
                    frame: .id(capture.frameID), assetID: capture.assetID, placement: placement))])),
                checkCancellation: {
                    try checkCancellation()
                    guard self.prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
                })
            return true
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func deleteImage(_ capture: ImagePlacementCapture,
                     checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            try checkCancellation()
            guard prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply([.deleteImage(.init(
                    frame: .id(capture.frameID), assetID: capture.assetID))])),
                checkCancellation: {
                    try checkCancellation()
                    guard self.prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
                })
            return true
        } catch { message = error.localizedDescription; return false }
    }

    struct MoveCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let ids: Set<String>
        let mode: SelectionMode
    }
    @discardableResult
    func selectElement(at point: CGPoint) -> String? {
        guard point.x.isFinite, point.y.isFinite, activeStrokeID == nil, !isPlaying else { return nil }
        var hit: String?
        for layer in layers where layer.visible && layer.opacity > 0 && !layer.isFullyLocked {
            if let element = currentFrame.elements.reversed().first(where: { element in
                guard element.layerID == layer.id, element.opacity > 0,
                      let rect = try? StudioSelectionRegion.drawingBounds(element) else { return false }
                if let mask = element.fillMask {
                    guard let placed = try? element.transform?.inversePoint(point) ?? point else { return false }
                    let x = (placed.x - (element.translation?.x ?? 0)) * (element.reflection?.horizontal == true ? -1 : 1)
                    let y = (placed.y - (element.translation?.y ?? 0)) * (element.reflection?.vertical == true ? -1 : 1)
                    return mask.spans.contains { y >= Double($0.row) && y < Double($0.row + 1) && x >= Double($0.start) && x < Double($0.end) }
                }
                return rect.insetBy(dx: -6, dy: -6).contains(point)
            }) { hit = element.id; break }
        }
        switch selectionMode {
        case .new:
            if let hit { if !selectedElementIDs.contains(hit) { editor.selectedElementIDs = [hit] } }
            else { editor.selectedElementIDs.removeAll() }
        case .add: if let hit { editor.selectedElementIDs.insert(hit) }
        case .subtract: if let hit { editor.selectedElementIDs.remove(hit) }
        }
        return hit
    }
    func beginMove(at point: CGPoint) -> MoveCapture? {
        guard isEditing, !isPlaying, !isSaving, selectedTool == .move, !isMovingImageOnCanvas,
              activeStrokeID == nil, pendingBrushStroke == nil else { return nil }
        let hit = selectElement(at: point)
        guard selectionMode != .subtract else { return nil }
        // Empty canvas is ordinary selection input. Guidance belongs in the
        // tool popup; a status banner here would resize the canvas mid-gesture.
        // Leave an existing save/validation error visible.
        guard hit != nil, !selectedElementIDs.isEmpty else { return nil }
        guard currentFrame.elements.filter({ selectedElementIDs.contains($0.id) }).allSatisfy({ element in
            layers.contains { $0.id == element.layerID && $0.visible && !$0.isFullyLocked && $0.lockMode == "free" }
        }) else { message = "This layer's position is locked. Choose Free before moving artwork."; return nil }
        message = nil
        return MoveCapture(projectID: document.id, revision: document.revision, frameID: currentFrame.id, ids: selectedElementIDs, mode: selectionMode)
    }
    func moveIsCurrent(_ capture: MoveCapture) -> Bool {
        isEditing && !isPlaying && selectedTool == .move && !isMovingImageOnCanvas && activeStrokeID == nil && pendingBrushStroke == nil &&
        capture.projectID == document.id && capture.revision == document.revision && capture.frameID == currentFrame.id &&
        capture.ids == selectedElementIDs && capture.mode == selectionMode
    }
    /// Preview derives from the captured document and never mutates undo or autosave.
    func movePreview(_ capture: MoveCapture, delta: CGSize) throws -> AnimationFrame {
        guard moveIsCurrent(capture) else { throw StudioCommandError.staleRevision }
        try StudioElementTranslation(x: delta.width, y: delta.height).validate()
        var frame = currentFrame
        for index in frame.elements.indices where capture.ids.contains(frame.elements[index].id) {
            if let prior = frame.elements[index].transform {
                let next = StudioElementTransform(tx: delta.width, ty: delta.height).after(prior)
                try next.validate(); frame.elements[index].transform = next
                continue
            }
            let old = frame.elements[index].translation
            let next = StudioElementTranslation(x: (old?.x ?? 0) + delta.width, y: (old?.y ?? 0) + delta.height)
            try next.validate(); frame.elements[index].translation = next.x == 0 && next.y == 0 ? nil : next
        }
        return frame
    }
    @discardableResult
    func finishMove(_ capture: MoveCapture, delta: CGSize) -> Bool {
        guard moveIsCurrent(capture) else { message = "Studio changed during the move. The artwork has not moved."; return false }
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply([.translateElements(.init(frame: .id(capture.frameID),
                    elementIDs: capture.ids.sorted(), dx: delta.width, dy: delta.height))])))
            editor.selectedElementIDs = capture.ids
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func clearElementSelection() { editor.selectedElementIDs.removeAll() }
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
    struct LayerRenameCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let layerID: String
        let originalName: String
    }
    func canRenameLayer(_ id: String) -> Bool {
        isEditing && !isPlaying && !isSaving && activeStrokeID == nil &&
        pendingBrushStroke == nil && textDraft == nil && document.activeLayerID == id &&
        layers.contains(where: { $0.id == id })
    }
    func prepareLayerRename(_ id: String) -> LayerRenameCapture? {
        guard canRenameLayer(id), let layer = layers.first(where: { $0.id == id }) else { return nil }
        return .init(projectID: document.id, revision: document.revision, layerID: id, originalName: layer.name)
    }
    static func normalizedLayerName(_ proposed: String) -> String? {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        return StudioCommandExecutor.isValidLayerName(name) ? name : nil
    }
    @discardableResult
    func renameLayer(_ capture: LayerRenameCapture, to proposed: String) -> Bool {
        guard prepareLayerRename(capture.layerID) == capture else {
            message = "Studio changed while the layer name was being edited. Select the layer again. Nothing was renamed."
            return false
        }
        guard let name = Self.normalizedLayerName(proposed) else {
            message = "Use 1–120 characters for the layer name, without control characters. Nothing was renamed."
            return false
        }
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply([.updateLayer(.init(
                    layer: .id(capture.layerID), settings: .init(name: name)))])))
            return true
        } catch { message = error.localizedDescription; return false }
    }
    struct LayerDeleteCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let layerID: String
        let name: String
        let frameCount: Int
    }
    func canDeleteLayer(_ id: String) -> Bool {
        isEditing && !isPlaying && !isSaving && activeStrokeID == nil &&
        pendingBrushStroke == nil && textDraft == nil && document.activeLayerID == id &&
        layers.count > 1 && layers.contains(where: { $0.id == id && !$0.isFullyLocked && $0.lockMode == "free" })
    }
    func prepareLayerDeletion(_ id: String) -> LayerDeleteCapture? {
        guard canDeleteLayer(id), let layer = layers.first(where: { $0.id == id }) else { return nil }
        let affected = document.frames.filter { frame in
            frame.rasterLayerID == id || frame.elements.contains(where: { $0.layerID == id })
        }.count
        return .init(projectID: document.id, revision: document.revision, layerID: id,
                     name: layer.name, frameCount: affected)
    }
    @discardableResult
    func deleteLayer(_ capture: LayerDeleteCapture) -> Bool {
        guard prepareLayerDeletion(capture.layerID) == capture else {
            message = "Studio changed after the layer was selected. Select it again before deleting. Nothing was deleted."
            return false
        }
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply([.deleteLayer(.id(capture.layerID))])))
            return true
        } catch { message = error.localizedDescription; return false }
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
    struct AudioDuplicationCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let clip: AudioClip
    }
    /// Capture the selected canonical clip, never an arbitrary or stale list row.
    func prepareAudioDuplication() -> AudioDuplicationCapture? {
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil,
              let clip = selectedCurrentAudioClip, let assetID = clip.assetID,
              let asset = audioTrack(forAssetID: assetID), asset.audioData?.isEmpty == false else { return nil }
        return .init(projectID: document.id, revision: document.revision, clip: clip)
    }
    /// The UI and validated assistants use this same atomic, reversible edit.
    /// Reuse managed source bytes; the new clip begins at the selected clip's end.
    @discardableResult
    func duplicateAudioClip(_ capture: AudioDuplicationCapture,
                            checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> String {
        try checkCancellation()
        guard prepareAudioDuplication() == capture else {
            throw StudioDocumentError.unavailable("Select the current audio clip again before duplicating it.")
        }
        let original = capture.clip
        let duplicate = AudioClip(id: UUID().uuidString, soundName: original.soundName,
            track: original.track, startTime: original.startTime + original.duration,
            duration: original.duration, volume: original.volume, assetID: original.assetID,
            sourceOffset: original.sourceOffset, isMuted: original.isMuted)
        var candidate = editor
        try candidate.change { value in value.audioClips.append(duplicate) }
        try preflightRasterDocument(candidate.document)
        _ = try audioTracksForSave(candidate.document)
        try checkCancellation()
        guard prepareAudioDuplication() == capture else {
            throw StudioDocumentError.unavailable("The project changed while duplicating audio. Nothing was added.")
        }
        editor = candidate; selectedAudioClip = duplicate; message = nil; scheduleSave()
        return duplicate.id
    }
    struct AudioClipVolumeCapture: Equatable {
        let selection: AudioDuplicationCapture
    }
    func prepareAudioClipVolume() -> AudioClipVolumeCapture? {
        prepareAudioDuplication().map { .init(selection: $0) }
    }
    /// A slider gesture belongs to one project, revision and selected source clip.
    /// Validate both before preflight and before committing its single history entry.
    func setAudioClipVolume(_ capture: AudioClipVolumeCapture, volume: Double,
                            checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        guard volume.isFinite, (0...1).contains(volume) else {
            throw StudioDocumentError.invalid("Clip volume must be between 0% and 100%.")
        }
        guard prepareAudioClipVolume() == capture,
              let index = document.audioClips.firstIndex(where: { $0.id == capture.selection.clip.id }) else {
            throw StudioDocumentError.unavailable("The selected clip or project changed. Finish saving and stop playback before changing clip volume.")
        }
        guard capture.selection.clip.volume != volume else { return }
        var candidate = editor
        try candidate.change { value in
            value.schemaVersion = max(value.schemaVersion, 4)
            value.audioClips[index].volume = volume
        }
        try preflightRasterDocument(candidate.document); _ = try audioTracksForSave(candidate.document)
        try checkCancellation()
        guard prepareAudioClipVolume() == capture else {
            throw StudioDocumentError.unavailable("The project changed while setting clip volume. Nothing was changed.")
        }
        editor = candidate; selectedAudioClip = document.audioClips[index]
        message = nil; scheduleSave()
    }
    struct AudioTrimCapture: Equatable {
        let selection: AudioDuplicationCapture
    }
    func prepareAudioTrim() -> AudioTrimCapture? {
        prepareAudioDuplication().map { .init(selection: $0) }
    }
    /// Decimal keyboard input is local draft state until the captured clip is applied.
    static func audioTrimSeconds(_ text: String, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> Double? {
        guard text.count <= 64 else { return nil }
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if decimalSeparator == "," { value = value.replacingOccurrences(of: ",", with: ".") }
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ "0123456789.eE+-".unicodeScalars.contains($0) }),
              let seconds = Double(value), seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
    func trimAudioClip(_ capture: AudioTrimCapture, sourceOffset: Double, duration: Double,
                       checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        guard prepareAudioTrim() == capture else {
            throw StudioDocumentError.unavailable("The selected clip changed. Reopen its trim values. Nothing was changed.")
        }
        try checkCancellation()
        guard prepareAudioTrim() == capture else {
            throw StudioDocumentError.unavailable("The project changed while trimming audio. Nothing was changed.")
        }
        try editSelectedAudioClip(capture.selection.clip.id, expectedRevision: capture.selection.revision,
                                  edit: .trim(sourceOffset: sourceOffset, duration: duration))
    }
    struct AudioSplitCapture: Equatable {
        let selection: AudioDuplicationCapture
        let playhead: Double
        let boundary: Double
        let rightSourceOffset: Double
    }
    /// Snap the cut to the mixer's sample grid and preserve its source phase.
    func prepareAudioSplit() -> AudioSplitCapture? {
        guard let selection = prepareAudioDuplication(), audioPlayheadTime.isFinite else { return nil }
        let original = selection.clip
        let rate = StudioAudioTimelineGeometry.sampleRate
        let startFrame = (original.startTime * rate).rounded()
        let endFrame = ((original.startTime + original.duration) * rate).rounded()
        let cutFrame = (audioPlayheadTime * rate).rounded()
        let boundary = cutFrame / rate
        let left = boundary - original.startTime
        let right = original.duration - left
        let sourceOffset = ((original.sourceOffset * rate).rounded() + cutFrame - startFrame) / rate
        guard boundary.isFinite, sourceOffset.isFinite,
              cutFrame > startFrame, cutFrame < endFrame,
              left >= 1 / rate, right >= 1 / rate else { return nil }
        return .init(selection: selection, playhead: audioPlayheadTime,
                     boundary: boundary, rightSourceOffset: sourceOffset)
    }
    /// Split metadata, never the managed original. Both halves remain editable.
    @discardableResult
    func splitAudioClip(_ capture: AudioSplitCapture,
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> String {
        try checkCancellation()
        guard prepareAudioSplit() == capture else {
            throw StudioDocumentError.unavailable("Select a current clip and place the playhead inside it before splitting.")
        }
        let original = capture.selection.clip
        let leftDuration = capture.boundary - original.startTime
        var left = original
        left.duration = leftDuration
        let right = AudioClip(id: UUID().uuidString, soundName: original.soundName,
            track: original.track, startTime: capture.boundary,
            duration: original.duration - leftDuration, volume: original.volume,
            assetID: original.assetID, sourceOffset: capture.rightSourceOffset,
            isMuted: original.isMuted)
        var candidate = editor
        try candidate.change { value in
            guard let index = value.audioClips.firstIndex(where: { $0.id == original.id }) else {
                throw StudioDocumentError.unavailable("The selected audio clip is no longer available.")
            }
            value.schemaVersion = max(value.schemaVersion, 4)
            value.audioClips[index] = left
            value.audioClips.insert(right, at: index + 1)
        }
        try preflightRasterDocument(candidate.document)
        _ = try audioTracksForSave(candidate.document)
        try checkCancellation()
        guard prepareAudioSplit() == capture else {
            throw StudioDocumentError.unavailable("The clip or playhead changed while splitting. Nothing was changed.")
        }
        editor = candidate; selectedAudioClip = right; message = nil; scheduleSave()
        return right.id
    }
    func setAudioTrackMuted(_ track: Int, muted: Bool, expectedRevision: Int,
                            checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil,
              expectedRevision == document.revision, (1...4).contains(track) else {
            throw StudioDocumentError.unavailable("Stop playback before muting this track.")
        }
        guard document.audioClips.filter({ $0.track == track }).allSatisfy({ $0.assetID != nil }) else {
            throw StudioDocumentError.unavailable("This track includes historical audio with unavailable source bytes.")
        }
        guard document.isAudioTrackMuted(track) != muted else { return }
        let projectID = document.id
        var candidate = editor
        try candidate.change { value in
            value.schemaVersion = max(value.schemaVersion, 12)
            var tracks = Set(value.mutedAudioTracks ?? [])
            if muted { tracks.insert(track) } else { tracks.remove(track) }
            value.mutedAudioTracks = tracks.sorted()
        }
        try preflightRasterDocument(candidate.document); _ = try audioTracksForSave(candidate.document)
        try checkCancellation()
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil,
              document.id == projectID, document.revision == expectedRevision else {
            throw StudioDocumentError.unavailable("The project changed while setting track mute. Nothing was changed.")
        }
        editor = candidate
        selectedAudioClip = selectedAudioClip.flatMap { selected in document.audioClips.first { $0.id == selected.id } }
        message = nil; scheduleSave()
    }
    struct AudioTrackVolumeCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let track: Int
        let volume: Double
    }
    func prepareAudioTrackVolume(_ track: Int) -> AudioTrackVolumeCapture? {
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil,
              (1...4).contains(track),
              document.audioClips.filter({ $0.track == track }).allSatisfy({ $0.assetID != nil }) else { return nil }
        return .init(projectID: document.id, revision: document.revision, track: track,
                     volume: document.audioTrackVolume(track))
    }
    func setAudioTrackVolume(_ capture: AudioTrackVolumeCapture, volume: Double,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        guard volume.isFinite, (0...1).contains(volume) else {
            throw StudioDocumentError.invalid("Track volume must be between 0% and 100%.")
        }
        guard prepareAudioTrackVolume(capture.track) == capture else {
            throw StudioDocumentError.unavailable("The project or track changed. Finish saving and stop playback before changing track volume.")
        }
        guard capture.volume != volume else { return }
        var candidate = editor
        try candidate.change { value in
            value.schemaVersion = max(value.schemaVersion, 13)
            var volumes = value.audioTrackVolumes ?? Array(repeating: 1, count: 4)
            volumes[capture.track - 1] = volume
            value.audioTrackVolumes = volumes
        }
        try preflightRasterDocument(candidate.document); _ = try audioTracksForSave(candidate.document)
        try checkCancellation()
        guard prepareAudioTrackVolume(capture.track) == capture else {
            throw StudioDocumentError.unavailable("The project changed while setting track volume. Nothing was changed.")
        }
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
        guard let capture = prepareAudioClipVolume(), capture.selection.clip.id == id else { return }
        do { try setAudioClipVolume(capture, volume: volume) }
        catch { message = error.localizedDescription }
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
            originalOrientation: imported.originalOrientation, normalizedWidth: imported.width, normalizedHeight: imported.height,
            catalogueAttribution: imported.catalogueAttribution)
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
        guard !candidate.referencedRasterAssetIDs.isEmpty || candidate.frames.contains(where: {
            $0.elements.contains(where: { $0.fillMask != nil })
        }) else { return }
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

/// Area selection encloses whole editable drawings, rather than altering pixels.
/// The exact same region is used for the visible outline and selected IDs.
enum StudioAreaSelectionKind: String, CaseIterable {
    case freehand, rectangle
    var label: String { self == .freehand ? "Freehand" : "Rectangle" }
}

struct StudioSelectionTrace {
    static let maximumPoints = 512
    private(set) var points: [CGPoint] = []
    mutating func append(_ point: CGPoint, kind: StudioAreaSelectionKind) throws {
        guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 1_000_000, abs(point.y) <= 1_000_000 else {
            throw StudioDocumentError.invalid("The selection outline has invalid coordinates.")
        }
        if kind == .rectangle {
            if points.isEmpty { points = [point] }
            else if points.count == 1 { points.append(point) }
            else { points[1] = point }
            return
        }
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 0.5 { return }
        if points.count > 1 {
            let a = points[points.count - 2], b = points[points.count - 1]
            let length = hypot(point.x - a.x, point.y - a.y)
            let cross = abs((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x))
            let dot = (b.x - a.x) * (point.x - a.x) + (b.y - a.y) * (point.y - a.y)
            if length > 0, cross / length <= 0.25, dot >= 0, dot <= length * length { points.removeLast() }
        }
        guard points.count < Self.maximumPoints else {
            throw StudioDocumentError.unavailable("The selection outline is too complex. Draw a simpler outline or choose Rectangle.")
        }
        points.append(point)
    }
}

struct StudioSelectionRegion {
    let points: [CGPoint]
    private let rectangle: CGRect?
    private let path: Path
    init(points input: [CGPoint], kind: StudioAreaSelectionKind, smoothing: Double) throws {
        guard input.count <= StudioSelectionTrace.maximumPoints,
              smoothing.isFinite, (0...10).contains(smoothing),
              input.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else {
            throw StudioDocumentError.invalid("The selection outline is invalid or too large.")
        }
        let vertices: [CGPoint]
        if kind == .rectangle {
            guard let a = input.first, let b = input.last, input.count >= 2 else {
                throw StudioDocumentError.invalid("Drag to enclose the drawings you want to select.")
            }
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            guard rect.width >= 1, rect.height >= 1 else { throw StudioDocumentError.invalid("Drag a larger selection rectangle.") }
            rectangle = rect
            vertices = [.init(x: rect.minX, y: rect.minY), .init(x: rect.maxX, y: rect.minY),
                        .init(x: rect.maxX, y: rect.maxY), .init(x: rect.minX, y: rect.maxY)]
        } else {
            var unique = input
            if unique.count > 1, let first = unique.first, let last = unique.last,
               hypot(first.x - last.x, first.y - last.y) < 0.5 { unique.removeLast() }
            guard unique.count >= 3 else { throw StudioDocumentError.invalid("Draw a closed outline around the drawings you want to select.") }
            vertices = unique.indices.map { index in
                let prev = unique[(index + unique.count - 1) % unique.count], next = unique[(index + 1) % unique.count], p = unique[index]
                let dx = (prev.x + next.x) / 2 - p.x, dy = (prev.y + next.y) / 2 - p.y
                let distance = hypot(dx, dy)
                let weight = distance > 0 ? min(0.5, CGFloat(smoothing) / distance) : 0
                return CGPoint(x: p.x + dx * weight, y: p.y + dy * weight)
            }
            var area: CGFloat = 0
            for i in vertices.indices { let a = vertices[i], b = vertices[(i + 1) % vertices.count]; area += a.x * b.y - b.x * a.y }
            guard abs(area) >= 1 else { throw StudioDocumentError.invalid("Draw an outline with a visible enclosed area.") }
            rectangle = nil
        }
        self.points = vertices
        var p = Path(); p.move(to: vertices[0]); vertices.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath(); path = p
    }
    func contains(_ rect: CGRect) -> Bool {
        guard !rect.isNull, !rect.isInfinite, rect.width >= 0, rect.height >= 0 else { return false }
        if let rectangle { return rectangle.minX <= rect.minX && rectangle.maxX >= rect.maxX && rectangle.minY <= rect.minY && rectangle.maxY >= rect.maxY }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        guard corners.allSatisfy({ path.contains($0, eoFill: true) || onBoundary($0) }) else { return false }
        // Corner-only tests incorrectly select a drawing cut through by a
        // concave lasso. Reject any outline edge entering its open bounds.
        let inner = rect.insetBy(dx: min(0.0001, rect.width / 4), dy: min(0.0001, rect.height / 4))
        for i in points.indices where segmentIntersects(points[i], points[(i + 1) % points.count], inner) { return false }
        return true
    }
    private func onBoundary(_ p: CGPoint) -> Bool {
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count], dx = b.x - a.x, dy = b.y - a.y
            let length = hypot(dx, dy)
            if length > 0, abs((p.x-a.x)*dy-(p.y-a.y)*dx) / length < 0.0001,
               (p.x-a.x)*dx+(p.y-a.y)*dy >= 0, (p.x-a.x)*dx+(p.y-a.y)*dy <= length*length { return true }
        }
        return false
    }
    private func segmentIntersects(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        var low: CGFloat = 0, high: CGFloat = 1
        for (origin, delta, minimum, maximum) in [(a.x,b.x-a.x,rect.minX,rect.maxX),(a.y,b.y-a.y,rect.minY,rect.maxY)] {
            if abs(delta) < 0.0000001 { if origin < minimum || origin > maximum { return false }; continue }
            let t1 = (minimum-origin)/delta, t2 = (maximum-origin)/delta
            low = max(low,min(t1,t2)); high = min(high,max(t1,t2))
            if low > high { return false }
        }
        return low <= high
    }
    static func drawingBounds(_ element: DrawnElement) throws -> CGRect? {
        guard element.brush != nil else { return element.selectionBounds }
        var bounds = try StudioBrushGeometryCache.geometry(for: element).bounds
        guard !bounds.isNull else { return nil }
        if element.reflection?.horizontal == true { bounds.origin.x = -bounds.maxX }
        if element.reflection?.vertical == true { bounds.origin.y = -bounds.maxY }
        let placed=bounds.offsetBy(dx: element.translation?.x ?? 0, dy: element.translation?.y ?? 0)
        return element.transform?.bounds(placed) ?? placed
    }
}

/// Editor-only handle geometry. Coordinates enter in the unscaled canvas view;
/// zoom affects touch radius and decoration size, never document transforms.
struct StudioSelectionHandleGeometry {
    enum Kind: String, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight, rotate }
    struct Handle { let kind: Kind; let point: CGPoint }
    struct Values: Equatable { var scale: Double = 1; var rotation: Double = 0 }
    let bounds: CGRect
    let documentSize: CGSize
    let viewport: CGSize
    let zoom: Double
    var hitRadius: Double { 22 / zoom }
    var visualRadius: Double { 6 / zoom }
    init?(bounds: CGRect, documentSize: CGSize, viewport: CGSize, zoom: Double) {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0,
              [bounds.minX,bounds.minY,bounds.maxX,bounds.maxY,documentSize.width,documentSize.height,viewport.width,viewport.height,zoom].allSatisfy(\.isFinite),
              documentSize.width > 0, documentSize.height > 0, zoom >= 0.25, zoom <= 5,
              viewport.width * zoom >= 44, viewport.height * zoom >= 44 else { return nil }
        self.bounds = bounds; self.documentSize = documentSize; self.viewport = viewport; self.zoom = zoom
    }
    var handles: [Handle] {
        let sx = viewport.width / documentSize.width, sy = viewport.height / documentSize.height
        let margin = visualRadius + 2 / zoom
        func x(_ v: Double) -> Double { min(viewport.width-margin,max(margin,v)) }
        func y(_ v: Double) -> Double { min(viewport.height-margin,max(margin,v)) }
        let halfWidth = max(bounds.width*sx/2,hitRadius), halfHeight = max(bounds.height*sy/2,hitRadius)
        let center = CGPoint(x: bounds.midX*sx, y: bounds.midY*sy)
        let left=x(center.x-halfWidth), right=x(center.x+halfWidth)
        let top=y(center.y-halfHeight), bottom=y(center.y+halfHeight)
        let rotationY = top-30/zoom >= margin ? top-30/zoom : min(viewport.height-margin,bottom+30/zoom)
        return [.init(kind:.topLeft,point:.init(x:left,y:top)), .init(kind:.topRight,point:.init(x:right,y:top)),
                .init(kind:.bottomLeft,point:.init(x:left,y:bottom)), .init(kind:.bottomRight,point:.init(x:right,y:bottom)),
                .init(kind:.rotate,point:.init(x:x(center.x),y:rotationY))]
    }
    func hit(_ point: CGPoint) -> Kind? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return handles.filter { hypot($0.point.x-point.x,$0.point.y-point.y) <= hitRadius }
            .min { hypot($0.point.x-point.x,$0.point.y-point.y) < hypot($1.point.x-point.x,$1.point.y-point.y) }?.kind
    }
    func values(kind: Kind, start: CGPoint, current: CGPoint) throws -> Values {
        guard [start.x,start.y,current.x,current.y].allSatisfy(\.isFinite) else { throw StudioElementTransform.Failure.settings }
        let sx = documentSize.width / viewport.width, sy = documentSize.height / viewport.height
        let a = CGPoint(x:start.x*sx-bounds.midX,y:start.y*sy-bounds.midY)
        let b = CGPoint(x:current.x*sx-bounds.midX,y:current.y*sy-bounds.midY)
        let length = a.x*a.x+a.y*a.y
        guard length > 0.000001 else { throw StudioElementTransform.Failure.settings }
        if kind == .rotate {
            guard b.x*b.x+b.y*b.y > 0.000001 else { throw StudioElementTransform.Failure.settings }
            var degrees = (atan2(b.y,b.x)-atan2(a.y,a.x))*180 / .pi
            if degrees > 180 { degrees -= 360 }; if degrees < -180 { degrees += 360 }
            return Values(rotation: degrees)
        }
        return Values(scale: min(4,max(0.25,(a.x*b.x+a.y*b.y)/length)))
    }
}

/// Bounded, versioned device preferences. Documents continue to store their own
/// captured stroke/shape settings, so changing these never changes existing art.
struct StudioDrawingToolPreferences: Codable, Equatable {
    static let maximumBytes = 32_768
    var version = 1
    var values: [String: Entry] = [:]

    struct Entry: Codable, Equatable {
        var width: Double = 3
        var opacity: Double = 1
        var smoothing: Double = 3
        var family: StudioBrushFamily = .round
        var tipAngle: Double = 45
        var texture: Double = 0.5
        var grain: Double = 0.3
        var gradientEnd = StudioBrushColor(red: 0, green: 0, blue: 1)
        var shapeFilled = false
        var cornerRadius: Double = 0
        var eraserMode: StudioEraserMode? = nil
        var textStyle: StudioTextStyle? = nil

        var isValid: Bool {
            width.isFinite && (0.25...512).contains(width) &&
            opacity.isFinite && (0...1).contains(opacity) &&
            smoothing.isFinite && (0...10).contains(smoothing) &&
            tipAngle.isFinite && (0..<180).contains(tipAngle) &&
            texture.isFinite && (0...1).contains(texture) &&
            grain.isFinite && (0...1).contains(grain) &&
            cornerRadius.isFinite && (0...50).contains(cornerRadius) &&
            (try? gradientEnd.validate()) != nil && gradientEnd.alpha == 1 &&
            (textStyle?.isValid ?? true)
        }
        static func defaults(for tool: DrawingTool) -> Self {
            var value = Self()
            switch tool {
            case .pencil: value.width = 2; value.smoothing = 2
            case .pen: value.family = .roughPen
            case .marker: value.width = 12; value.opacity = 0.75; value.family = .calligraphy
            case .crayon: value.width = 8; value.opacity = 0.9; value.family = .grain; value.smoothing = 1
            case .eraser: value.width = 8
            default: break
            }
            return value
        }
    }
    func settings(for tool: DrawingTool) -> Entry { values[tool.rawValue] ?? .defaults(for: tool) }
    func validate() throws {
        guard version == 1, values.count <= DrawingTool.allCases.count,
              values.allSatisfy({ DrawingTool(rawValue: $0.key) != nil && $0.value.isValid }) else {
            throw StudioDocumentError.invalid("Saved tool preferences are unsupported or outside their valid ranges.")
        }
    }
    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw StudioDocumentError.invalid("Tool preferences are too large.") }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw StudioDocumentError.invalid("Tool preferences are too large.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
}
