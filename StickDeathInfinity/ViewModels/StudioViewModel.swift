import SwiftUI
import Darwin
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
        let mirror: StudioMirrorCapture?
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
    var storageScanRequest: StudioStorageScanRequest { storage.storageScanRequest }
    func clearRegenerableStorageCache() throws -> DeviceStorageManager.CacheClearReceipt {
        try storage.clearCache()
    }
    func obsoleteRevisionCleanupRequest(id: UUID) throws -> StudioRevisionCleanupRequest {
        guard !isEditing, !isSaving, !isManagingProjects else {
            throw StudioDocumentError.unavailable("Save and return to projects before cleaning older saved versions.")
        }
        return StudioRevisionCleanupRequest(store: storage, projectID: id)
    }
    private let storage: DeviceStorageManager
    @Published private var imageClipboard: AnimationFrame?
    // An image copy wins only until another successful editor copy changes its
    // clipboard generation. Failed copies and Undo never select older payloads.
    private var imageClipboardEditorVersion: UUID?
    private var copiedImageLayer: CanvasLayer?
    private var copiedArtworkLayers: [CanvasLayer] = []
    private var copiedArtworkSchema: Int = 1
    var projectThumbnailRenderer: ((StudioDocument, Data?) throws -> Data)?
    var projectThumbnailSourcesRenderer: ((StudioDocument, [String: Data]) throws -> Data)?
    private var projectThumbnailData: Data?
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
            guard frames.indices.contains(newValue) else { return }
            selectFrame(frames[newValue].id)
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
    var canPaste: Bool { usesImageClipboard ? canPasteImage : activeStrokeID == nil && editor.canPaste }
    var copiedDrawingCount: Int { editor.clipboardElementCount }
    var copiedDrawingClipboardID: String? { copiedDrawingCount > 0 ? editor.clipboardVersion.uuidString : nil }
    var canDeleteSelected: Bool { isSelectingMixedArtwork ? captureArtworkSelection() != nil : !editor.selectedElementIDs.isEmpty }
    var selectedElementIDs: Set<String> { editor.selectedElementIDs }
    var isDirty: Bool { savedRevision != document.revision || pendingBrushStroke != nil || activeStrokeID != nil || textDraft != nil }
    var saveTimeAgo: String { activeStrokeID != nil ? "Drawing…" : isSaving ? "Saving…" : isDirty ? "Unsaved" : "Saved" }

    private let toolDefaults: UserDefaults?
    static let toolPreferencesKey = "studio.drawing-tool-preferences.v1"
    private var toolPreferences = StudioDrawingToolPreferences()
    private var restoringToolPreferences = false
    @Published private(set) var toolPreferencesWarning: String?
    @Published var selectedTool: DrawingTool = .brush {
        didSet {
            if selectedTool != oldValue {
                clearImageRegion()
                if selectedTool == .wand { clearElementSelection() }
                areaSelectionGeneration = UUID()
                // Only an explicitly selected, unchanged Lasso image may continue into Move.
                if selectedTool == .fill, [.move, .lasso].contains(oldValue),
                   imageMoveTarget != nil {
                    // Keep an invalid target as a fail-closed sentinel. Never
                    // refresh a stale Lasso revision into fresh Fill authority.
                    if fillImageLayerID != nil { imageMoveTarget?.areaRevision = document.revision }
                } else if oldValue == .lasso, selectedTool == .move, areaSelectionTarget != .drawings,
                   validAreaImageSelection != nil {
                    imageMoveTarget?.areaRevision = nil
                } else { imageMoveTarget = nil }
                if selectedTool == .lasso, areaSelectionTarget == .image {
                    editor.selectedElementIDs.removeAll()
                }
                restoreDrawingToolPreferences()
            }
        }
    }
    @Published var strokeColor: Color = .red { didSet { rememberRecentColor(Self.hex(strokeColor)) } }
    @Published var strokeWidth: Double = 3 { didSet { rememberDrawingToolPreferences() } }
    @Published var strokeOpacity: Double = 1 { didSet { rememberDrawingToolPreferences() } }
    @Published var eraserMode: StudioEraserMode = .hard { didSet { rememberDrawingToolPreferences() } }
    @Published var blurHardness: Double = 0.5 { didSet { rememberDrawingToolPreferences() } }
    @Published var blurRadius: Double = 4 { didSet { rememberDrawingToolPreferences() } }
    @Published var sharpenHardness: Double = 0.5 { didSet { rememberDrawingToolPreferences() } }
    @Published var sharpenRadius: Double = 2 { didSet { rememberDrawingToolPreferences() } }
    @Published var sharpenAmount: Double = 0.5 { didSet { rememberDrawingToolPreferences() } }
    @Published var sharpenThreshold: Double = 0.02 { didSet { rememberDrawingToolPreferences() } }
    @Published var dodgeBurnHardness: Double = 0.5 { didSet { rememberDrawingToolPreferences() } }
    @Published var dodgeBurnExposure: Double = 0.25 { didSet { rememberDrawingToolPreferences() } }
    @Published var dodgeBurnRange: StudioDodgeBurn.TonalRange = .midtones { didSet { rememberDrawingToolPreferences() } }
    @Published var dodgeBurnProtectTones = true { didSet { rememberDrawingToolPreferences() } }
    @Published var mirrorMode: StudioMirrorMode = .off { didSet { rememberDrawingToolPreferences() } }
    @Published var lineRulerEnabled = false { didSet { rememberDrawingToolPreferences() } }
    @Published var lineRulerAngle: Double = 0 { didSet { rememberDrawingToolPreferences() } }
    @Published var lineRulerFixedLength = false { didSet { rememberDrawingToolPreferences() } }
    @Published var lineRulerLength: Double = 100 { didSet { rememberDrawingToolPreferences() } }
    @Published var lineAngleSnap: Double = 0 { didSet { rememberDrawingToolPreferences() } }
    @Published var equalShapeSides = false { didSet { rememberDrawingToolPreferences() } }
    @Published var shapeFilled = false { didSet { rememberDrawingToolPreferences() } }
    @Published var shapeCornerRadius: Double = 0 { didSet { rememberDrawingToolPreferences() } }
    @Published var lineArrowEnds: StudioArrowEnds = .none { didSet { rememberDrawingToolPreferences() } }
    @Published var lineArrowLength: Double = 16 { didSet { rememberDrawingToolPreferences() } }
    var toolOpacity: Double { get { strokeOpacity } set { strokeOpacity = min(1, max(0, newValue)) } }
    @Published var smoothing: Double = 3 { didSet { rememberDrawingToolPreferences() } }
    @Published var pressureSensitivity = false { didSet { rememberDrawingToolPreferences() } }
    @Published var pencilTiltEnabled = false { didSet { rememberDrawingToolPreferences() } }
    @Published var brushFamily: StudioBrushFamily = .round { didSet { rememberDrawingToolPreferences() } }
    @Published var brushTipAngle: Double = 45 { didSet { rememberDrawingToolPreferences() } }
    @Published var brushTexture: Double = 0.5 { didSet { rememberDrawingToolPreferences() } }
    @Published var brushGrain: Double = 0.3 { didSet { rememberDrawingToolPreferences() } }
    @Published var brushGradientEndColor: Color = .blue { didSet { rememberDrawingToolPreferences() } }
    @Published var fillTolerance: Double = 32 { didSet { rememberDrawingToolPreferences() } }
    @Published var fillExpand: Double = 0 { didSet { rememberDrawingToolPreferences() } }
    @Published var fillGapClose: Double = 0 { didSet { rememberDrawingToolPreferences() } }
    @Published var fillContiguous = true { didSet { rememberDrawingToolPreferences() } }
    @Published var fillAntiAlias = true { didSet { rememberDrawingToolPreferences() } }
    @Published var fillSampleAll = false { didSet { rememberDrawingToolPreferences() } }
    @Published var activePanel: StudioPanelType = .none {
        didSet { if activePanel != .none { cancelMenuHandoff() } }
    }
    struct MenuHandoff: Equatable {
        let id: UUID
        let destination: StudioPanelType
        let projectID: UUID
        let revision: Int
        let frameID: String
        let layerID: String
        let accountID: String?
    }
    private var pendingMenuHandoff: MenuHandoff?
    func prepareMenuHandoff(to destination: StudioPanelType, accountID: String?, isForeground: Bool) -> MenuHandoff? {
        let allowed: [StudioPanelType] = [.projectSettings, .framesViewer, .magicCut, .backgroundLibrary, .rotoscope, .addImage, .aiVoice, .spatterAI]
        guard activePanel == .menu, pendingMenuHandoff == nil, allowed.contains(destination),
              isForeground, isEditing, !isSaving, !isPlaying, activeStrokeID == nil,
              pendingBrushStroke == nil, textDraft == nil else { return nil }
        let request = MenuHandoff(id: UUID(), destination: destination, projectID: document.id,
            revision: document.revision, frameID: document.activeFrameID,
            layerID: document.activeLayerID, accountID: accountID)
        pendingMenuHandoff = request
        return request
    }
    @discardableResult
    func consumeMenuHandoff(_ request: MenuHandoff, accountID: String?, isForeground: Bool) -> Bool {
        guard pendingMenuHandoff == request else { return false }
        pendingMenuHandoff = nil
        guard activePanel == .none, isForeground, isEditing, !isSaving, !isPlaying,
              activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              accountID == request.accountID, document.id == request.projectID,
              document.revision == request.revision, document.activeFrameID == request.frameID,
              document.activeLayerID == request.layerID else { return false }
        activePanel = request.destination
        return true
    }
    func cancelMenuHandoff() { pendingMenuHandoff = nil }
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
    var gridSpacing: Double {
        get { (document.gridSettings ?? .init()).spacing }
        set { var value = document.gridSettings ?? .init(); value.spacing = newValue; change { $0.gridSettings = value } }
    }
    var gridOpacity: Double {
        get { (document.gridSettings ?? .init()).opacity }
        set { var value = document.gridSettings ?? .init(); value.opacity = newValue; change { $0.gridSettings = value } }
    }
    var gridTint: StudioGridSettings.Tint {
        get { (document.gridSettings ?? .init()).tint }
        set { var value = document.gridSettings ?? .init(); value.tint = newValue; change { $0.gridSettings = value } }
    }
    var visibleOnionGhosts: [StudioOnionGhost] { isPlaying ? [] : document.onionGhosts }
    var onionPreviousCount: Int {
        get { (document.onionSettings ?? .init()).previousCount }
        set { var value = document.onionSettings ?? .init(); value.previousCount = newValue; change { $0.onionSettings = value } }
    }
    var onionNextCount: Int {
        get { (document.onionSettings ?? .init()).nextCount }
        set { var value = document.onionSettings ?? .init(); value.nextCount = newValue; change { $0.onionSettings = value } }
    }
    var onionOpacity: Double {
        get { (document.onionSettings ?? .init()).opacity }
        set { var value = document.onionSettings ?? .init(); value.opacity = newValue; change { $0.onionSettings = value } }
    }
    var onionTinted: Bool {
        get { (document.onionSettings ?? .init()).tinted }
        set { var value = document.onionSettings ?? .init(); value.tinted = newValue; change { $0.onionSettings = value } }
    }

    var gridEnabled: Bool { get { document.gridEnabled } set { change { $0.gridEnabled = newValue } } }
    var audioClips: [AudioClip] { get { document.audioClips } set { change { $0.audioClips = newValue } } }
    var audioDuration: Double { max(document.durationSeconds, document.audioClips.map { $0.startTime + $0.duration }.filter(\.isFinite).max() ?? 0) }
    var strokeColorHex: String { Self.hex(strokeColor) }
    var brushGradientEndColorHex: String { Self.hex(brushGradientEndColor) }
    // Text stores RGB and opacity separately. Keep the native color picker's
    // alpha control synchronized with the same opacity used by Apply/Undo/export.
    var textPickerColor: Color {
        get {
            let rgb = UInt32(strokeColorHex.dropFirst(), radix: 16) ?? 0
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255,
                         opacity: strokeOpacity.isFinite ? min(1, max(0, strokeOpacity)) : 1)
        }
        set {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            #if canImport(UIKit)
            guard UIColor(newValue).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            #elseif canImport(AppKit)
            guard let value = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            r = value.redComponent; g = value.greenComponent; b = value.blueComponent; a = value.alphaComponent
            #endif
            guard [r, g, b, a].allSatisfy({ $0.isFinite }) else { return }
            // Do not retain color alpha as a second multiplier of text opacity.
            strokeColor = Color(.sRGB, red: Double(min(1, max(0, r))),
                                green: Double(min(1, max(0, g))), blue: Double(min(1, max(0, b))))
            toolOpacity = Double(a)
        }
    }
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
        if selectedTool == .line, lineArrowEnds != .none {
            let value = StudioShapeDescriptor(version: 2, arrowEnds: lineArrowEnds, arrowLength: lineArrowLength)
            try value.validate(tool: .line); return value
        }
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
        return StudioEraserDescriptor(mode: eraserMode)
    }
    /// Freeze the complete target context even for an initially empty selection:
    /// clearing/changing selection during a drag must never broaden its scope.
    struct EraserInputCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let layerID: String
        let selectedIDs: Set<String>
    }
    func captureEraserInput(ownedStroke: String? = nil) -> EraserInputCapture? {
        guard selectedTool == .eraser, isEditing, !isPlaying, !isSaving,
              pendingBrushStroke == nil, textDraft == nil,
              activeStrokeID == nil || activeStrokeID == ownedStroke,
              let layer = layers.first(where: { $0.id == activeLayerID }),
              layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { return nil }
        return .init(projectID: document.id, revision: document.revision,
            frameID: currentFrame.id, layerID: activeLayerID, selectedIDs: selectedElementIDs)
    }
    func eraserInputPreview(_ capture: EraserInputCapture, element: DrawnElement) throws -> AnimationFrame {
        guard captureEraserInput(ownedStroke: element.id) == capture,
              element.tool == .eraser, element.layerID == capture.layerID else { throw StudioCommandError.staleRevision }
        if capture.selectedIDs.isEmpty {
            var frame = currentFrame; frame.elements.append(element); return frame
        }
        return try editor.previewSelectedErasure(element, frameID: capture.frameID, elementIDs: capture.selectedIDs)
    }
    @discardableResult
    func commitEraserInput(_ capture: EraserInputCapture, element: DrawnElement) -> Bool {
        do {
            guard captureEraserInput(ownedStroke: element.id) == capture,
                  element.tool == .eraser, element.layerID == capture.layerID else { throw StudioCommandError.staleRevision }
            if capture.selectedIDs.isEmpty { return commitElement(element, frameID: capture.frameID) }
            var candidate = editor
            try candidate.eraseSelectedElements(element, frameID: capture.frameID, elementIDs: capture.selectedIDs)
            try preflightRasterDocument(candidate.document)
            editor = candidate
            pruneManagedAudio(); scheduleSave()
            return true
        } catch { message = error.localizedDescription; return false }
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
        let value = StudioBrushDescriptor(version: pencilTiltEnabled && brushFamily == .calligraphy ? 2 : 1, family: brushFamily, seed: seed ?? StudioBrushRenderer.seed(for: elementID),
            smoothing: smoothing, pressureEnabled: pressureSensitivity, tipAngleDegrees: brushTipAngle,
            texture: brushTexture, grain: brushGrain,
            gradientEndColor: brushFamily == .gradient ? try StudioBrushGeometryCache.color(Self.hex(brushGradientEndColor)) : nil,
            tiltEnabled: pencilTiltEnabled && brushFamily == .calligraphy ? true : nil)
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
            shapeFilled: shapeFilled, cornerRadius: shapeCornerRadius, selectionMode: selectionMode,
            areaSelectionKind: areaSelectionKind, areaSelectionSmoothing: areaSelectionSmoothing, fillTolerance: fillTolerance, fillExpand: fillExpand, fillGapClose: fillGapClose,
            fillContiguous: fillContiguous, fillAntiAlias: fillAntiAlias, fillSampleAll: fillSampleAll,
            eraserMode: eraserMode, textStyle: textStyle,
            blurHardness: blurHardness, blurRadius: blurRadius,
            sharpenHardness: sharpenHardness, sharpenRadius: sharpenRadius,
            sharpenAmount: sharpenAmount, sharpenThreshold: sharpenThreshold,
            dodgeBurnHardness: dodgeBurnHardness, dodgeBurnExposure: dodgeBurnExposure,
            dodgeBurnRange: dodgeBurnRange, dodgeBurnProtectTones: dodgeBurnProtectTones,
            lineAngleSnap: lineAngleSnap, equalShapeSides: equalShapeSides,
            lineRulerEnabled: lineRulerEnabled, lineRulerAngle: lineRulerAngle,
            lineRulerFixedLength: lineRulerFixedLength, lineRulerLength: lineRulerLength, mirrorMode: mirrorMode, pressureSensitivity: pressureSensitivity, pencilTiltEnabled: pencilTiltEnabled, lineArrowEnds: lineArrowEnds, lineArrowLength: lineArrowLength)
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
        pressureSensitivity = value.pressureSensitivity ?? false
        pencilTiltEnabled = value.pencilTiltEnabled ?? false
        brushFamily = value.family; brushTipAngle = value.tipAngle
        brushTexture = value.texture; brushGrain = value.grain
        brushGradientEndColor = Color(red: value.gradientEnd.red, green: value.gradientEnd.green,
                                     blue: value.gradientEnd.blue)
        mirrorMode = value.mirrorMode ?? .off
        lineRulerEnabled = value.lineRulerEnabled ?? false; lineRulerAngle = value.lineRulerAngle ?? 0
        lineRulerFixedLength = value.lineRulerFixedLength ?? false; lineRulerLength = value.lineRulerLength ?? 100
        lineAngleSnap = value.lineAngleSnap ?? 0; equalShapeSides = value.equalShapeSides ?? false
        shapeFilled = value.shapeFilled; shapeCornerRadius = value.cornerRadius
        lineArrowEnds = value.lineArrowEnds ?? .none; lineArrowLength = value.lineArrowLength ?? 16
        selectionMode = value.selectionMode ?? .new
        areaSelectionKind = value.areaSelectionKind ?? .freehand
        areaSelectionSmoothing = value.areaSelectionSmoothing ?? 3
        fillTolerance = value.fillTolerance ?? 32; fillExpand = value.fillExpand ?? 0
        fillGapClose = value.fillGapClose ?? 0; fillContiguous = value.fillContiguous ?? true
        fillAntiAlias = value.fillAntiAlias ?? true; fillSampleAll = value.fillSampleAll ?? false
        eraserMode = value.eraserMode ?? .hard
        textStyle = value.textStyle ?? StudioTextStyle()
        blurHardness = value.blurHardness ?? 0.5; blurRadius = value.blurRadius ?? 4
        sharpenHardness = value.sharpenHardness ?? 0.5; sharpenRadius = value.sharpenRadius ?? 2
        sharpenAmount = value.sharpenAmount ?? 0.5; sharpenThreshold = value.sharpenThreshold ?? 0.02
        dodgeBurnHardness = value.dodgeBurnHardness ?? 0.5; dodgeBurnExposure = value.dodgeBurnExposure ?? 0.25
        dodgeBurnRange = value.dodgeBurnRange ?? .midtones; dodgeBurnProtectTones = value.dodgeBurnProtectTones ?? true
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
        let selection = editor.selectedElementIDs
        let containsTween: Bool
        let containsRename: Bool
        let containsCut: Bool
        let containsSelectedErasure: Bool
        let inputFrame = currentFrame.id, inputLayer = activeLayerID, inputTool = selectedTool
        if case .apply(let commands) = request.action {
            containsCut = commands.contains { if case .cutElements = $0 { return true }; return false }
            containsTween = commands.contains { if case .tweenFrames = $0 { return true }; return false }
            containsRename = commands.contains { if case .renameProject = $0 { return true }; return false }
            containsSelectedErasure = commands.contains { if case .eraseSelectedElements = $0 { return true }; return false }
        } else { containsCut = false; containsTween = false; containsRename = false; containsSelectedErasure = false }
        if containsCut && isPlaying { throw StudioDocumentError.unavailable("Stop playback before cutting selected drawings.") }
        if containsSelectedErasure && isPlaying { throw StudioDocumentError.unavailable("Stop playback before erasing selected drawings.") }
        if containsRename && isPlaying { throw StudioDocumentError.unavailable("Stop playback before renaming the project.") }
        if containsTween && isPlaying { throw StudioDocumentError.unavailable("Stop playback before tweening frames.") }
        var candidate = editor
        let receipt = try StudioCommandExecutor.execute(request, editor: &candidate, checkCancellation: checkCancellation)
        for clip in candidate.document.audioClips where clip.assetID != nil && document.audioClips.first(where: { $0.id == clip.id }) != clip {
            guard let assetID = clip.assetID, let asset = audioTrack(forAssetID: assetID), asset.audioData != nil else {
                throw StudioDocumentError.invalid("The audio edit needs its original managed source. Nothing changed.")
            }
            try validateAudioTrim(clip, asset: asset)
        }
        if candidate.document.audioClips != document.audioClips {
            guard !isPlaying else { throw StudioDocumentError.unavailable("Stop playback before applying audio edits.") }
            _ = try audioTracksForSave(candidate.document)
        }
        if containsTween {
            try storage.preflightAnimation(storageProject(candidate.document, rasters: retainedRasterFrames))
        } else { try preflightRasterDocument(candidate.document) }
        try checkCancellation()
        // A caller's synchronous cancellation probe may also change the live
        // editor. Recheck its ownership and revision before publishing the
        // staged copy, so that intervening edit or input can never be replaced.
        try requireOpenCommandEditor()
        guard request.projectID == document.id else { throw StudioCommandError.wrongProject }
        guard request.expectedRevision == document.revision else { throw StudioCommandError.staleRevision }
        if containsRename && (isPlaying || editor.selectedElementIDs != selection) {
            throw StudioDocumentError.unavailable("Playback or selection changed while renaming the project. Nothing changed.")
        }
        guard editor.clipboardVersion == clipboardVersion else { throw StudioCommandError.staleClipboard }
        if containsTween && (isPlaying || editor.selectedElementIDs != selection) {
            throw StudioDocumentError.unavailable("Playback or selection changed while preparing the tween. Nothing changed.")
        }
        if candidate.document.audioClips != document.audioClips, isPlaying {
            throw StudioDocumentError.unavailable("Playback started while preparing audio edits. Nothing changed.")
        }
        if containsCut && (isPlaying || editor.selectedElementIDs != selection ||
            currentFrame.id != inputFrame || activeLayerID != inputLayer || selectedTool != inputTool) {
            throw StudioDocumentError.unavailable("The selection or input context changed while cutting. Nothing was cut.")
        }
        if containsSelectedErasure && (isPlaying || editor.selectedElementIDs != selection ||
            currentFrame.id != inputFrame || activeLayerID != inputLayer || selectedTool != inputTool) {
            throw StudioDocumentError.unavailable("The selected eraser context changed. Nothing changed.")
        }
        clearMissingImageMoveTarget(in: candidate.document)
        editor = candidate
        if case .apply(let commands) = request.action {
            for command in commands.reversed() {
                switch command {
                case .duplicateAudioClip(let edit): selectedAudioClip = document.audioClips.first { $0.id == edit.newClipID }
                case .splitAudioClip(let edit): selectedAudioClip = document.audioClips.first { $0.id == edit.newClipID }
                case .deleteAudioClip(let edit) where selectedAudioClip?.id == edit.clipID: selectedAudioClip = nil
                default: continue
                }
                break
            }
        }
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
            for element in frame.elements {
                try addUnits(element.points.count); try addUnits(element.fillMask?.spans.count ?? 0)
                try addUnits(element.text?.content.utf8.count ?? 0)
                try addUnits(element.selectionErasures?.count ?? 0, weight: 32)
                for mask in element.selectionErasures ?? [] { try addUnits(mask.points.count) }
            }
        }
        for command in commands {
            switch command {
            case .draw(let drawing):
                guard drawing.strokes.count <= StudioCommandExecutor.maximumStrokes - strokes else { throw StudioCommandError.limitExceeded }
                strokes += drawing.strokes.count
                edits += StudioCommandExecutor.batchesPrimitiveDrawing(drawing.strokes) ? 1 : drawing.strokes.count
                try addUnits(drawing.strokes.count, weight: 32)
                for stroke in drawing.strokes { try addUnits(stroke.points.count); try addUnits(stroke.text?.content.utf8.count ?? 0) }
            case .eraseSelectedElements(let erasure):
                let targets = erasure.elementIDs.count
                guard targets > 0, targets <= 256, !erasure.points.isEmpty,
                      erasure.points.count <= StudioCommandExecutor.maximumPointsPerStroke,
                      erasure.points.count <= StudioCommandExecutor.maximumGeneratedPoints / targets,
                      strokes < StudioCommandExecutor.maximumStrokes else { throw StudioCommandError.limitExceeded }
                strokes += 1; edits += 1
                try addUnits(targets, weight: 32)
                try addUnits(erasure.points.count, weight: targets)
            case .updateText(let text): edits += 1; try addUnits(text.text.content.utf8.count)
            case .transformElements(let selection): edits += selection.elementIDs.count; try addUnits(selection.elementIDs.count, weight: 32)
            case .transformSelectedArtwork(let selection): edits += 1; try addUnits(selection.elementIDs.count + 1, weight: 32)
            case .deleteSelectedArtwork(let selection): edits += 1; try addUnits(selection.elementIDs.count + 1, weight: 32)
            case .duplicateFrame, .duplicateLayer, .pasteElements, .tweenFrames:
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

    static let recentColorsKey = "studio.recent-colors.v1"
    @Published private(set) var recentColorHexes: [String] = []
    static func normalizedColorHex(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        return "#" + value
    }
    func rememberRecentColor(_ input: String) {
        guard let hex = Self.normalizedColorHex(input) else { return }
        let next = [hex] + recentColorHexes.filter { $0 != hex }.prefix(15)
        guard next != recentColorHexes else { return }
        recentColorHexes = next
        toolDefaults?.set(next, forKey: Self.recentColorsKey)
    }
    @discardableResult
    func applyCustomColorHex(_ input: String, gradientEnd: Bool = false) -> Bool {
        guard let hex = Self.normalizedColorHex(input), let rgb = UInt32(hex.dropFirst(), radix: 16) else { return false }
        let color = Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                          green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        if gradientEnd { brushGradientEndColor = color; rememberRecentColor(hex) }
        else { strokeColor = color }
        return true
    }

    private static func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#FF0000" }
        #elseif canImport(AppKit)
        guard let value = NSColor(color).usingColorSpace(.sRGB) else { return "#FF0000" }
        r = value.redComponent; g = value.greenComponent; b = value.blueComponent
        #endif
        func byte(_ component: CGFloat) -> Int {
            guard component.isFinite else { return 0 }
            return Int((min(1, max(0, component)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
    init(storage: DeviceStorageManager = .shared, toolDefaults: UserDefaults? = nil) {
        self.storage = storage
        self.toolDefaults = toolDefaults
        editor = try! StudioDocumentEditor(document: .new(name: "Untitled Animation", width: 1080, height: 1080, fps: 12))
        if let data = toolDefaults?.data(forKey: Self.toolPreferencesKey) {
            do { toolPreferences = try StudioDrawingToolPreferences.decode(data) }
            catch { toolPreferencesWarning = "Saved tool preferences could not be read. Default settings are available; your projects are unchanged." }
        }
        var restoredColors: [String] = []
        for input in (toolDefaults?.stringArray(forKey: Self.recentColorsKey) ?? []).prefix(64) {
            if let hex = Self.normalizedColorHex(input), !restoredColors.contains(hex) { restoredColors.append(hex) }
            if restoredColors.count == 16 { break }
        }
        recentColorHexes = restoredColors
        restoreDrawingToolPreferences()
    }
    func loadProjects() async {
        do {
            let listing = try storage.listAnimationsReportingFailures()
            savedProjects = listing.animations.sorted { $0.modifiedAt > $1.modifiedAt }
            if !listing.failures.isEmpty { message = "Some projects could not be read. Their original files have been preserved." }
        } catch { message = "Projects could not be listed: \(error.localizedDescription)" }
    }
    @Published private(set) var isManagingProjects = false
    func duplicateProject(_ metadata: AnimationMetadata) async {
        guard !isEditing, !isSaving, !isManagingProjects else { return }
        isManagingProjects = true; defer { isManagingProjects = false }
        // Use the same full archive/asset validation as opening a project. The
        // temporary editor never replaces or changes the user's current session.
        let source = StudioViewModel(storage: storage)
        guard await source.openProject(metadata) else { message = source.message; return }
        do {
            let title = String(source.document.name.prefix(115)) + " Copy"
            let copy = try source.document.duplicated(name: title)
            let project = try source.storageProject(copy, rasters: source.retainedRasterFrames)
            try storage.saveNewAnimation(project)
            message = nil; await loadProjects()
        } catch { message = "Copy could not be saved. Original preserved: \(error.localizedDescription)" }
    }
    private func requirePortableLibrary() throws {
        guard !isEditing, !isSaving, activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil else {
            throw StudioDocumentError.unavailable("Save and return to projects before transferring a project backup.")
        }
    }
    func preparePortableBackup(_ metadata: AnimationMetadata,
                               checkCancellation: () throws -> Void = { try Task.checkCancellation() }) async throws -> Data {
        try requirePortableLibrary()
        guard !isManagingProjects else { throw StudioDocumentError.unavailable("Another project operation is running.") }
        isManagingProjects = true; defer { isManagingProjects = false }
        try Task.checkCancellation()
        guard let original = try storage.loadAnimation(id: metadata.id) else {
            throw StudioDocumentError.invalid("This project is no longer available.")
        }
        // Backup retains the original stored record, including historical bytes.
        let data = try storage.portableBundle(for: original, checkCancellation: checkCancellation)
        await Task.yield(); try checkCancellation(); try Task.checkCancellation(); try requirePortableLibrary()
        return data
    }
    func importPortableProject(from url: URL,
                               checkCancellation: () throws -> Void = { try Task.checkCancellation() }) async throws -> AnimationMetadata {
        try requirePortableLibrary()
        guard !isManagingProjects else { throw StudioDocumentError.unavailable("Another project operation is running.") }
        isManagingProjects = true; defer { isManagingProjects = false }
        try checkCancellation()
        // Read in a bounded background task while retaining the provider scope.
        let reader = Task.detached(priority: .userInitiated) { try Self.readPortableFile(url) }
        let data = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
        try checkCancellation(); try Task.checkCancellation()
        isManagingProjects = false
        return try await importPortableProject(data, checkCancellation: checkCancellation)
    }
    /// Same production entry point is exercised by transport/collision tests.
    /// The fresh identity is allocated locally; imported IDs never replace files.
    func importPortableProject(_ data: Data, newProjectID: UUID = UUID(),
                               checkCancellation: () throws -> Void = { try Task.checkCancellation() }) async throws -> AnimationMetadata {
        try requirePortableLibrary()
        guard !isManagingProjects else { throw StudioDocumentError.unavailable("Another project operation is running.") }
        isManagingProjects = true; defer { isManagingProjects = false }
        try checkCancellation()
        let original = try storage.projectFromPortableBundle(data, checkCancellation: checkCancellation)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-project-validation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = DeviceStorageManager(documentsDirectory: scratch, cachesDirectory: scratch)
        try staged.saveNewAnimation(original)
        let validator = StudioViewModel(storage: staged)
        guard await validator.openProject(original.metadata) else {
            throw StudioDocumentError.invalid(validator.message ?? "Project asset validation failed.")
        }
        // Opening validates raster pixels; managed audio also needs the same
        // actual bounded decoder used by Files import before it becomes playable.
        // Unreferenced historical audio remains opaque and byte-preserved.
        let referencedAudio = validator.document.referencedAudioAssetIDs
        let managed = original.audioTracks.filter { referencedAudio.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard Set(managed.map(\.id)) == referencedAudio else {
            throw StudioDocumentError.invalid("The backup is missing referenced managed audio.")
        }
        var managedBytes = 0
        for asset in managed {
            guard asset.legacySourceFilename == nil, asset.startTime == 0,
                  asset.duration.isFinite, asset.duration > 0, asset.duration <= 300,
                  StudioAudioImportService.Container(rawValue: asset.format) != nil,
                  let bytes = asset.audioData, !bytes.isEmpty, bytes.count <= 16 * 1024 * 1024,
                  bytes.count <= Self.maximumManagedAudioBytes - managedBytes else {
                throw StudioDocumentError.invalid("The backup's managed audio exceeds supported metadata or byte limits.")
            }
            managedBytes += bytes.count
        }
        for asset in managed {
            try checkCancellation(); try Task.checkCancellation()
            let bytes = asset.audioData!
            let file = scratch.appendingPathComponent("validate-" + asset.id.uuidString + "." + asset.format)
            try bytes.write(to: file, options: .withoutOverwriting)
            let decoded = try await StudioAudioImportService.shared.importAudio(from: file, name: asset.name, scratchParent: scratch)
            try checkCancellation(); try Task.checkCancellation()
            guard decoded.originalData == bytes, decoded.container.rawValue == asset.format,
                  abs(decoded.duration - asset.duration) <= 1 / decoded.sampleRate else {
                throw StudioDocumentError.invalid("The backup's audio metadata does not match its decoded source.")
            }
            try FileManager.default.removeItem(at: file)
        }
        let document = try validator.document.duplicated(name: validator.document.name, id: newProjectID)
        let imported = try validator.storageProject(document, rasters: validator.retainedRasterFrames)
        try FileManager.default.removeItem(at: scratch)
        await Task.yield()
        try checkCancellation(); try Task.checkCancellation(); try requirePortableLibrary()
        // No suspension between final eligibility/cancellation and collision-safe
        // creation. All decoding and asset validation happened in private staging.
        try storage.saveNewAnimation(imported)
        await loadProjects()
        return imported.metadata
    }
    nonisolated private static func readPortableFile(_ url: URL) throws -> Data {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw StudioDocumentError.invalid("Choose a local project backup file.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)
        guard descriptor >= 0 else { throw StudioDocumentError.invalid("The project file is unavailable or is a link.") }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= DeviceStorageManager.maximumPortableBundleBytes else {
            throw StudioDocumentError.invalid("The backup must be a regular file within the project size limit.")
        }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 65_536)
        data.reserveCapacity(Int(before.st_size))
        while data.count < before.st_size {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &bytes, min(bytes.count, Int(before.st_size) - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StudioDocumentError.invalid("The project file changed or could not be read completely.") }
            data.append(bytes, count: count)
        }
        var after = stat(), extra: UInt8 = 0
        guard Darwin.read(descriptor, &extra, 1) == 0, fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw StudioDocumentError.invalid("The project file changed during transfer. Select it again.")
        }
        try Task.checkCancellation()
        return data
    }
    @Published var recoverableProjects: [AnimationMetadata] = []
    func loadRecoverableProjects() {
        do {
            let listing = try storage.listRecoverableAnimations()
            recoverableProjects = listing.animations.sorted { $0.modifiedAt > $1.modifiedAt }
            if !listing.failures.isEmpty { message = "Some recovered projects need repair. Their original files remain preserved." }
        } catch { message = "Recently Deleted could not be read: \(error.localizedDescription)" }
    }
    func moveProjectToRecovery(_ id: UUID) async {
        guard !isEditing, !isSaving, !isManagingProjects else { message = "Save and return to projects before removing an animation."; return }
        do {
            try storage.recoverableDeleteAnimation(id: id)
            message = nil; await loadProjects(); loadRecoverableProjects()
        } catch { message = "Project was not removed: \(error.localizedDescription)" }
    }
    func restoreProject(_ id: UUID) async {
        guard !isEditing, !isSaving, !isManagingProjects else { return }
        do {
            try storage.restoreAnimation(id: id)
            message = nil; await loadProjects(); loadRecoverableProjects()
        } catch { message = "Project could not be restored. Both copies remain preserved: \(error.localizedDescription)" }
    }
    @discardableResult
    func createProject(name: String, width: Int, height: Int, fps: Int) async -> Bool {
        guard !isEditing, pendingBrushStroke == nil, activeStrokeID == nil, textDraft == nil else { message = "Finish or discard any drawing draft, then save and return to projects before creating another animation."; return false }
        do {
            editor = try StudioDocumentEditor(document: .new(name: name, width: width, height: height, fps: fps))
            projectThumbnailData = nil
            imageClipboard = nil; imageClipboardEditorVersion = nil; copiedImageLayer = nil; retainedRasterFrames.removeAll(); retainedAudioTracks.removeAll(); managedAudioTracks.removeAll()
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
                for (assetID, record) in stored.additionalImageAssets ?? [:] {
                    guard rasters[assetID] == nil || rasters[assetID] == record else {
                        throw StudioDocumentError.invalid("Conflicting image source records cannot be opened.")
                    }
                    rasters[assetID] = record
                }
                try validateManagedImageCapacity(rasters)
                guard Set(rasters.keys) == decoded.referencedRasterAssetIDs else {
                    throw StudioDocumentError.invalid("The image archive has unaccounted references. Its original bytes were preserved.")
                }
                var validatedSources = Set<String>()
                for (index, frame) in decoded.frames.enumerated() {
                    if let id = frame.rasterAssetID {
                        guard let record = rasters[id], stored.frames[index] == record else {
                            throw StudioDocumentError.invalid("An imported image reference is missing or its frame records disagree.")
                        }
                        try validateManagedRaster(frame: frame, record: record)
                        validatedSources.insert(id)
                        for instance in frame.rasterLayerInstances where instance.layerID != frame.rasterLayerID {
                            guard let projected = frame.projectedRasterFrame(on: instance.layerID),
                                  let assetID = projected.rasterAssetID, let sourceRecord = rasters[assetID] else {
                                throw StudioRasterImage.Failure.missing
                            }
                            if let mask = instance.regionMask {
                                guard let source = sourceRecord.sourceImage, mask.width == source.normalizedWidth,
                                      mask.height == source.normalizedHeight else { throw StudioRasterImage.Failure.invalid }
                            }
                            if validatedSources.insert(assetID).inserted {
                                try validateManagedRaster(frame: projected, record: sourceRecord)
                            }
                        }
                    } else {
                        guard stored.frames[index].imageData == nil, stored.frames[index].layerData == nil,
                              stored.frames[index].sourceImage == nil else {
                            throw StudioDocumentError.invalid("An unreferenced original image record cannot be discarded.")
                        }
                    }
                }
            } else {
                guard stored.frames.allSatisfy({ $0.sourceImage == nil }),
                      stored.additionalImageAssets?.isEmpty ?? true else {
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
            projectThumbnailData = stored.metadata.thumbnailData
            imageClipboard = nil; imageClipboardEditorVersion = nil; copiedImageLayer = nil; editor = nextEditor; retainedRasterFrames = rasters
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
    func renameProject(_ name: String, expectedProjectID: UUID, expectedRevision: Int) -> Bool {
        do {
            try requireOpenCommandEditor()
            guard !isPlaying else { throw StudioDocumentError.unavailable("Stop playback before renaming the project.") }
            guard document.id == expectedProjectID, document.revision == expectedRevision else {
                throw StudioDocumentError.unavailable("The project changed. Reload its current name before renaming.")
            }
            var candidate = editor
            try candidate.renameProject(name)
            guard candidate.document != document else { message = nil; return true }
            try preflightRasterDocument(candidate.document)
            editor = candidate; scheduleSave(); message = nil
            return true
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func save(updateThumbnail: Bool = false) async -> Bool {
        guard isEditing, !isSaving else { return !isDirty }
        autosaveTask?.cancel(); autosaveTask = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let snapshot = document
            if updateThumbnail, let renderThumbnail = projectThumbnailSourcesRenderer {
                projectThumbnailData = try? renderThumbnail(snapshot,
                    snapshot.frames.first.map { rasterSources(for: $0) } ?? [:])
            } else if updateThumbnail, let renderThumbnail = projectThumbnailRenderer,
                      (snapshot.frames.first?.referencedRasterAssetIDs.count ?? 0) <= 1 {
                // Optional preview generation never blocks preservation of the editable project.
                projectThumbnailData = try? renderThumbnail(snapshot,
                    snapshot.frames.first?.rasterAssetID.flatMap { retainedRasterFrames[$0]?.imageData })
            }
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
        guard await save(updateThumbnail: true), !isDirty else { return }
        isEditing = false; activePanel = .none; await loadProjects()
    }
    func flush() async { if isEditing && isDirty { _ = await save() } }
    private func resetSession() {
        cancelMenuHandoff()
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
            // This timer now owns the save. Release its handle before save()
            // cancels pending timers, so validation does not cancel itself.
            self.autosaveTask = nil
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
    /// Timeline actions retain identity even when their visible position changes.
    func selectFrame(_ id: String) {
        guard allowDocumentEditDuringInput(), frames.contains(where: { $0.id == id }) else { return }
        stopPlayback()
        if editor.selectFrame(id) { imageMoveTarget = nil; scheduleSave() }
    }
    /// The typed executor stages source selection and duplication together.
    /// One Undo therefore restores the selection from before the context menu.
    func duplicateFrame(_ id: String) {
        stopPlayback()
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: document.id,
                expectedRevision: document.revision,
                action: .apply([.duplicateFrame(.init(source: .id(id), result: "duplicate"))])))
        } catch { message = error.localizedDescription }
    }
    func setFrameHold(_ id: String, ticks: Int) {
        guard (1...600).contains(ticks), frames.contains(where: { $0.id == id }) else {
            message = "Choose an existing frame and an exposure of 1–600 ticks."; return
        }
        guard frames.first(where: { $0.id == id })?.durationTicks != ticks else { return }
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: document.id,
                expectedRevision: document.revision, action: .apply([.setFrameHold(.init(frame: .id(id), ticks: ticks))])))
        } catch { message = error.localizedDescription }
    }

    /// Extend a pose with independently editable copies. The existing typed
    /// transaction preserves raster originals/effects and commits one Undo step.
    @discardableResult
    func repeatFrame(_ id: String, additionalCopies: Int) -> Bool {
        guard (1...24).contains(additionalCopies), frames.count <= 1000 - additionalCopies,
              frames.contains(where: { $0.id == id }) else {
            message = "Choose an existing frame and 1–24 copies within the 1,000-frame project limit."
            return false
        }
        stopPlayback()
        let commands: [StudioCommand] = (0..<additionalCopies).map { index in
            .duplicateFrame(.init(source: .id(id), result: "repeat\(index)"))
        }
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: document.id,
                expectedRevision: document.revision, action: .apply(commands)))
            return true
        } catch { message = error.localizedDescription; return false }
    }

    struct TweenCapture: Identifiable, Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let activeFrameID: String
        let nextFrameID: String
        let layerID: String
        let clipboardVersion: UUID
        let selection: Set<String>
        var id: String { frameID }
    }
    func prepareTween(_ frameID: String) -> TweenCapture? {
        guard isEditing, !isSaving, !isPlaying, textDraft == nil, activeStrokeID == nil, pendingBrushStroke == nil,
              let index = frames.firstIndex(where: { $0.id == frameID }), index + 1 < frames.count else { return nil }
        return .init(projectID: document.id, revision: document.revision, frameID: frameID, activeFrameID: document.activeFrameID,
            nextFrameID: frames[index + 1].id, layerID: document.activeLayerID,
            clipboardVersion: editor.clipboardVersion, selection: editor.selectedElementIDs)
    }
    func applyTween(_ capture: TweenCapture, count: Int, easing: StudioTweenEasing,
                    checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        guard prepareTween(capture.frameID) == capture else {
            throw StudioDocumentError.unavailable("The endpoint frames or editor state changed. Reopen Tween; nothing changed.")
        }
        _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
            expectedRevision: capture.revision, action: .apply([.tweenFrames(.init(after: .id(capture.frameID),
                to: .id(capture.nextFrameID), inbetweenCount: count, easing: easing))])), checkCancellation: {
                    try checkCancellation()
                    guard self.prepareTween(capture.frameID) == capture else {
                        throw StudioDocumentError.unavailable("The captured tween endpoints or editor state changed. Nothing changed.")
                    }
                })
    }

    /// Capture the displayed frame, including a playback frame, without changing
    /// the editing selection. The explicit-ID path owns validation and retention.
    func copyFrame() { copyFrame(currentFrame.id) }
    func copyFrame(_ id: String) {
        guard allowDocumentEditDuringInput() else { return }
        do {
            try editor.copyFrame(id)
            pruneManagedImages()
        } catch { message = error.localizedDescription }
    }
    func pasteFrame() { stopPlayback(); command { try $0.pasteFrame() } }
    func pasteClipboard() {
        if usesArtworkClipboard { _ = pasteSelectedArtwork(); return }
        if usesImageClipboard { _ = pasteImage(); return }
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
    /// Existing local sticker/emoji shelf insertion. Rejection retains the chooser.
    @discardableResult
    func insertShelfGlyph(_ glyph: String, isForeground: Bool = true,
                          checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        guard isForeground, isEditing, activePanel == .stickerEmoji, !isPlaying, !isSaving,
              activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil else {
            message = "Finish the current edit or save and pause playback before adding a sticker. Nothing was added."
            return false
        }
        let captured = document, selection = selectedElementIDs, clipboard = editor.clipboardVersion
        let tool = selectedTool, imageSelection = imageMoveTarget
        do {
            guard !glyph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  glyph.count <= 16, glyph.utf8.count <= 128,
                  !glyph.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
                throw StudioDocumentError.invalid("This sticker glyph is invalid. Nothing was added.")
            }
            try checkCancellation()
            let element = DrawnElement(id: UUID().uuidString, tool: .text,
                points: [.init(x: CGFloat(captured.width) / 2, y: CGFloat(captured.height) / 2)],
                color: "#000000", width: 8, opacity: 1, fillColor: glyph, layerID: captured.activeLayerID)
            var candidate = editor
            guard candidate.document == captured else { throw StudioCommandError.staleRevision }
            try candidate.commit(element, frameID: captured.activeFrameID)
            try preflightRasterDocument(candidate.document)
            try checkCancellation()
            guard isEditing, activePanel == .stickerEmoji, !isPlaying, !isSaving,
                  activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
                  document == captured, selectedElementIDs == selection, editor.clipboardVersion == clipboard,
                  selectedTool == tool, imageMoveTarget == imageSelection else { throw StudioCommandError.staleRevision }
            editor = candidate
            pruneManagedAudio(); scheduleSave()
            message = nil; activePanel = .none
            return true
        } catch is CancellationError {
            message = "Sticker insertion cancelled. Nothing was added."; return false
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult
    func commitElement(_ element: DrawnElement, frameID: String? = nil, mirror: StudioMirrorCapture? = nil) -> Bool {
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
            if let mirror {
                guard mirror.width == Double(canvasWidth), mirror.height == Double(canvasHeight) else { throw StudioCommandError.staleRevision }
                try candidate.commitMirroredStroke(mirror.elements(from: element), frameID: target)
            } else { try candidate.commit(element, frameID: target) }
            try preflightRasterDocument(candidate.document)
            editor = candidate
            if pendingBrushStroke?.element.id == element.id { pendingBrushStroke = nil }
            pruneManagedAudio(); scheduleSave()
            return true
        } catch {
            if element.brush != nil || mirror != nil { retainRejectedBrush(element, frameID: target, reason: error.localizedDescription, mirror: mirror) }
            else { message = error.localizedDescription }
            return false
        }
    }
    func retainRejectedBrush(_ element: DrawnElement, frameID: String, reason: String, inputComplete: Bool = true, mirror: StudioMirrorCapture? = nil) {
        guard pendingBrushStroke == nil || pendingBrushStroke?.element.id == element.id else {
            message = "Resolve the existing rejected drawing draft before adding another."
            return
        }
        pendingBrushStroke = PendingBrushStroke(projectID: document.id, frameID: frameID,
            element: element, reason: reason, inputComplete: inputComplete, mirror: mirror)
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
        if input.tool == .eraser {
            message = "Erasing cancelled. The artwork is unchanged."
            return
        }
        guard !input.points.isEmpty else { return }
        retainRejectedBrush(input.element, frameID: input.frameID, reason: reason, inputComplete: false, mirror: input.mirror)
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
            _ = commitElement(element, frameID: pending.frameID, mirror: pending.mirror)
        } catch { message = error.localizedDescription }
    }
    @discardableResult
    func orderSelected(forward: Bool) -> Bool {
        guard !hasMixedArtworkSelection else { message = "Select drawings alone to change their order. Mixed group order is unavailable."; return false }
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
    func reflectSelected(axis: StudioReflectionAxis,
                         checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        if isSelectingMixedArtwork {
            return applyArtworkTransform(flipHorizontal: axis == .horizontal, flipVertical: axis == .vertical,
                                         checkCancellation: checkCancellation)
        }
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
        if hasMixedArtworkSelection { return copySelectedArtwork() }
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
    var canCutSelected: Bool {
        if hasMixedArtworkSelection { return captureArtworkSelection() != nil }
        guard isEditing, !isPlaying, !isSaving, activeStrokeID == nil,
              pendingBrushStroke == nil, textDraft == nil, !selectedElementIDs.isEmpty else { return false }
        let selected = currentFrame.elements.filter { selectedElementIDs.contains($0.id) }
        return selected.count == selectedElementIDs.count && selected.allSatisfy { element in
            !element.hasPixelEffect && layers.contains { $0.id == element.layerID && $0.visible && $0.opacity > 0 && !$0.isFullyLocked && $0.lockMode == "free" }
        }
    }
    @discardableResult
    func cutSelected(checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        if hasMixedArtworkSelection { return copySelectedArtwork(cut: true, checkCancellation: checkCancellation) }
        guard canCutSelected else { message = "Select drawings on visible unlocked layers before cutting."; return false }
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: document.id,
                expectedRevision: document.revision, action: .apply([.cutElements(.init(
                    frame: .id(currentFrame.id), elementIDs: selectedElementIDs.sorted()))])), checkCancellation: checkCancellation)
            pruneManagedImages()
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func deleteSelected(checkCancellation: () throws -> Void = { try Task.checkCancellation() }) {
        if isSelectingMixedArtwork {
            do {
                guard let capture = captureArtworkSelection(), let image = capture.image else { throw StudioCommandError.staleRevision }
                _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                    expectedRevision: capture.revision, action: .apply([.deleteSelectedArtwork(.init(
                        frame: .id(capture.frameID), elementIDs: capture.ids.sorted(),
                        image: .init(assetID: image.assetID, layerID: image.layerID)))])), checkCancellation: {
                            try checkCancellation()
                            guard self.captureArtworkSelection() == capture else { throw StudioCommandError.staleRevision }
                        })
                imageMoveTarget = nil; editor.selectedElementIDs.removeAll()
            } catch { message = error.localizedDescription }
        } else {
            do { try checkCancellation(); command { try $0.deleteSelected() } }
            catch { message = error.localizedDescription }
        }
    }
    enum SelectionMode: String, Codable, CaseIterable { case new, add, subtract
        var label: String { switch self { case .new: return "⬜ New"; case .add: return "➕ Add"; case .subtract: return "➖ Sub" } }
    }
    @Published var selectionMode: SelectionMode = .new { didSet { rememberDrawingToolPreferences() } }
    @Published var selectionScalePercent: Double = 100
    @Published var selectionRotationDegrees: Double = 0
    @discardableResult
    func transformSelected(checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        if isSelectingMixedArtwork {
            return applyArtworkTransform(scale: selectionScalePercent / 100, rotation: selectionRotationDegrees,
                                         checkCancellation: checkCancellation)
        }
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
        var image: AreaImageIdentity? = nil
        var imageSelectionID: UUID? = nil
        var generation: UUID? = nil
    }
    /// Mixed intent stays explicit even when a target becomes invalid, so an
    /// operation can never silently fall back to editing only its drawings.
    var hasMixedArtworkSelection: Bool {
        areaSelectionTarget == .artwork && imageMoveTarget != nil && !selectedElementIDs.isEmpty
    }
    var isSelectingMixedArtwork: Bool { areaSelectionTarget == .artwork && imageMoveTarget != nil }
    var selectedArtworkCount: Int { selectedElementIDs.count + (validSelectedArtworkImage == nil ? 0 : 1) }
    private var validSelectedArtworkImage: AreaImageIdentity? {
        guard let target = imageMoveTarget,
              target.areaRevision == nil || target.areaRevision == document.revision,
              let image = availableAreaImage, target.projectID == image.projectID,
              target.frameID == image.frameID, target.layerID == image.layerID,
              target.assetID == image.assetID else { return nil }
        return image
    }
    func selectedArtworkBounds(in frame: AnimationFrame) -> CGRect? {
        var bounds = CGRect.null
        for element in frame.elements where selectedElementIDs.contains(element.id) {
            guard let rect = try? StudioSelectionRegion.drawingBounds(element) else { return nil }
            bounds = bounds.union(rect)
        }
        if isSelectingMixedArtwork {
            guard let image = validSelectedArtworkImage,
                  let instance = frame.rasterInstance(on: image.layerID), let placement = instance.placement else { return nil }
            bounds = bounds.union(StudioImageRotationGeometry(placement: placement, degrees: instance.rotationDegrees ?? 0).bounds)
        }
        return bounds.isNull ? nil : bounds
    }
    private func captureArtworkSelection() -> SelectionHandleCapture? {
        guard isEditing, !isPlaying, !isSaving, !isMovingImageOnCanvas, selectionMode != .subtract,
              activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              (!selectedElementIDs.isEmpty || isSelectingMixedArtwork), selectedElementIDs.count <= 1024 else { return nil }
        let elements = currentFrame.elements.filter { selectedElementIDs.contains($0.id) }
        guard elements.count == selectedElementIDs.count else { return nil }
        for element in elements {
            guard element.tool != .eraser,
                  layers.contains(where: { $0.id == element.layerID && $0.visible && $0.opacity > 0 && !$0.isFullyLocked && $0.lockMode == "free" }),
                  let rect = try? StudioSelectionRegion.drawingBounds(element), !rect.isNull,
                  rect.width > 0, rect.height > 0,
                  [rect.minX,rect.minY,rect.maxX,rect.maxY].allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else { return nil }
        }
        let image = isSelectingMixedArtwork ? validSelectedArtworkImage : nil
        guard !isSelectingMixedArtwork || image != nil, let bounds = selectedArtworkBounds(in: currentFrame) else { return nil }
        return .init(projectID: document.id, revision: document.revision,
            frameID: currentFrame.id, ids: selectedElementIDs, mode: selectionMode, bounds: bounds,
            image: image, imageSelectionID: image == nil ? nil : imageMoveTarget?.selectionID,
            generation: areaSelectionGeneration)
    }
    func beginSelectionHandle() -> SelectionHandleCapture? {
        selectedTool == .move ? captureArtworkSelection() : nil
    }
    private func artworkRequest(_ capture: SelectionHandleCapture, dx: Double = 0, dy: Double = 0,
                                scale: Double = 1, rotation: Double = 0,
                                flipHorizontal: Bool = false, flipVertical: Bool = false) throws -> StudioCommandRequest {
        guard captureArtworkSelection() == capture else { throw StudioCommandError.staleRevision }
        return .init(requestID: UUID(), projectID: capture.projectID, expectedRevision: capture.revision,
            action: .apply([.transformSelectedArtwork(.init(frame: .id(capture.frameID), elementIDs: capture.ids.sorted(),
                image: capture.image.map { .init(assetID: $0.assetID, layerID: $0.layerID) },
                dx: dx, dy: dy, scale: scale, rotation: rotation, flipHorizontal: flipHorizontal, flipVertical: flipVertical))]))
    }
    private func retainArtworkSelection(_ capture: SelectionHandleCapture) {
        editor.selectedElementIDs = capture.ids
        if imageMoveTarget?.areaRevision != nil { imageMoveTarget?.areaRevision = document.revision }
        resetSelectionTransform()
    }
    @discardableResult
    private func applyArtworkTransform(scale: Double = 1, rotation: Double = 0,
                                       flipHorizontal: Bool = false, flipVertical: Bool = false,
                                       checkCancellation: () throws -> Void) -> Bool {
        do {
            guard let capture = captureArtworkSelection() else { throw StudioCommandError.staleRevision }
            let request = try artworkRequest(capture, scale: scale, rotation: rotation,
                                             flipHorizontal: flipHorizontal, flipVertical: flipVertical)
            _ = try applyStudioCommands(request, checkCancellation: {
                try checkCancellation()
                guard self.captureArtworkSelection() == capture else { throw StudioCommandError.staleRevision }
            })
            retainArtworkSelection(capture)
            return true
        } catch { message = error.localizedDescription; return false }
    }
    private func selectionHandleRequest(_ capture: SelectionHandleCapture,
                                        values: StudioSelectionHandleGeometry.Values) throws -> StudioCommandRequest {
        guard beginSelectionHandle() == capture else { throw StudioCommandError.staleRevision }
        if capture.image != nil { return try artworkRequest(capture, scale: values.scale, rotation: values.rotation) }
        return .init(requestID: UUID(), projectID: capture.projectID, expectedRevision: capture.revision,
            action: .apply([.transformElements(.init(frame: .id(capture.frameID), elementIDs: capture.ids.sorted(),
                scaleX: values.scale, scaleY: values.scale, rotation: values.rotation))]))
    }
    /// Preview executes the same validated operation on a disposable editor.
    func selectionHandlePreview(_ capture: SelectionHandleCapture,
                                values: StudioSelectionHandleGeometry.Values) throws -> AnimationFrame {
        let request = try selectionHandleRequest(capture, values: values)
        try validateCommandWorkBudget(request)
        var candidate = editor
        _ = try StudioCommandExecutor.execute(request, editor: &candidate)
        guard let frame = candidate.document.frames.first(where: { $0.id == capture.frameID }) else { throw StudioCommandError.staleRevision }
        return frame
    }
    @discardableResult
    func finishSelectionHandle(_ capture: SelectionHandleCapture, values: StudioSelectionHandleGeometry.Values,
                               checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            let request = try selectionHandleRequest(capture, values: values)
            _ = try applyStudioCommands(request, checkCancellation: {
                try checkCancellation()
                guard self.beginSelectionHandle() == capture else { throw StudioCommandError.staleRevision }
            })
            retainArtworkSelection(capture)
            return true
        } catch { message = error.localizedDescription; return false }
    }
    @Published var areaSelectionKind: StudioAreaSelectionKind = .freehand { didSet { rememberDrawingToolPreferences() } }
    @Published var areaSelectionSmoothing: Double = 3 { didSet { rememberDrawingToolPreferences() } }
    enum AreaSelectionTarget: String, CaseIterable { case drawings, image, artwork
        var label: String {
            switch self { case .drawings: return "Drawings"; case .image: return "Image on active layer"; case .artwork: return "Drawings + image" }
        }
    }
    private var areaSelectionGeneration = UUID()
    @Published var areaSelectionTarget: AreaSelectionTarget = .drawings {
        didSet {
            if areaSelectionTarget != oldValue {
                areaSelectionGeneration = UUID()
                cancelPolygonSelection(); imageMoveTarget = nil; editor.selectedElementIDs.removeAll()
            }
        }
    }
    struct AreaImageIdentity: Equatable {
        let projectID: UUID
        let frameID: String
        let layerID: String
        let assetID: String
        let placement: StudioRasterPlacement
        let angle: Double
    }
    private var availableAreaImage: AreaImageIdentity? {
        guard let assetID = currentFrame.rasterAssetID(on: activeLayerID),
              let instance = currentFrame.rasterInstance(on: activeLayerID), let placement = instance.placement,
              originalImageSource(assetID) != nil,
              let layer = layers.first(where: { $0.id == activeLayerID }), layer.visible,
              layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { return nil }
        return .init(projectID: document.id, frameID: currentFrame.id, layerID: activeLayerID,
                     assetID: assetID, placement: placement, angle: instance.rotationDegrees ?? 0)
    }
    private var validAreaImageSelection: AreaImageIdentity? {
        guard let target = imageMoveTarget, target.areaRevision == document.revision,
              let image = availableAreaImage, target.projectID == image.projectID,
              target.frameID == image.frameID, target.layerID == image.layerID,
              target.assetID == image.assetID else { return nil }
        return image
    }
    var selectedAreaImageCorners: [CGPoint]? {
        guard selectedTool == .lasso, areaSelectionTarget != .drawings,
              let image = validAreaImageSelection else { return nil }
        return StudioImageRotationGeometry(placement: image.placement, degrees: image.angle).corners
    }
    func deselectAreaImage() { areaSelectionGeneration = UUID(); imageMoveTarget = nil; cancelPolygonSelection() }
    struct AreaSelectionCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let selectedIDs: Set<String>
        let mode: SelectionMode
        let kind: StudioAreaSelectionKind
        let smoothing: Double
        let target: AreaSelectionTarget
        let image: AreaImageIdentity?
        let imageSelectionID: UUID?
        let generation: UUID
    }
    @Published private(set) var polygonSelectionVertices: [CGPoint] = []
    private var polygonSelectionCapture: AreaSelectionCapture?
    var currentPolygonSelectionVertices: [CGPoint] {
        guard let capture = polygonSelectionCapture, beginAreaSelection() == capture else { return [] }
        return polygonSelectionVertices
    }
    func cancelPolygonSelection() {
        polygonSelectionCapture = nil
        polygonSelectionVertices = []
    }
    @discardableResult
    func appendPolygonSelectionVertex(_ point: CGPoint) -> Bool {
        guard let capture = beginAreaSelection(), capture.kind == .polygon else {
            cancelPolygonSelection(); return false
        }
        if let previous = polygonSelectionCapture, previous != capture {
            cancelPolygonSelection()
            message = "Studio changed. Start a new polygon selection."
            return false
        }
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x <= CGFloat(canvasWidth), point.y <= CGFloat(canvasHeight) else { return false }
        guard polygonSelectionVertices.count < StudioSelectionTrace.maximumPoints else {
            message = "The polygon has reached its vertex limit. Finish it or remove a point."
            return false
        }
        if let last = polygonSelectionVertices.last, hypot(point.x-last.x, point.y-last.y) < 0.5 { return false }
        polygonSelectionCapture = capture
        polygonSelectionVertices.append(point)
        return true
    }
    func removeLastPolygonSelectionVertex() {
        guard !currentPolygonSelectionVertices.isEmpty else { cancelPolygonSelection(); return }
        polygonSelectionVertices.removeLast()
        if polygonSelectionVertices.isEmpty { polygonSelectionCapture = nil }
    }
    @discardableResult
    func finishPolygonSelection() -> Bool {
        guard let capture = polygonSelectionCapture, beginAreaSelection() == capture else {
            cancelPolygonSelection(); return false
        }
        // Invalid/degenerate polygons retain their vertices so the user can correct them.
        guard finishAreaSelection(capture, points: polygonSelectionVertices) else { return false }
        cancelPolygonSelection()
        return true
    }
    func beginAreaSelection() -> AreaSelectionCapture? {
        guard isEditing, !isPlaying, !isSaving, selectedTool == .lasso,
              activeStrokeID == nil, pendingBrushStroke == nil,
              areaSelectionSmoothing.isFinite, (0...10).contains(areaSelectionSmoothing),
              areaSelectionTarget != .image || availableAreaImage != nil else { return nil }
        return .init(projectID: document.id, revision: document.revision, frameID: currentFrame.id,
            selectedIDs: selectedElementIDs, mode: selectionMode, kind: areaSelectionKind,
            smoothing: areaSelectionSmoothing, target: areaSelectionTarget,
            image: areaSelectionTarget != .drawings ? availableAreaImage : nil,
            imageSelectionID: validAreaImageSelection == nil ? nil : imageMoveTarget?.selectionID,
            generation: areaSelectionGeneration)
    }
    @discardableResult
    func finishAreaSelection(_ capture: AreaSelectionCapture, points: [CGPoint],
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            guard beginAreaSelection() == capture else { throw StudioCommandError.staleRevision }
            try checkCancellation()
            let region = try StudioSelectionRegion(points: points, kind: capture.kind, smoothing: capture.smoothing)
            if capture.target == .image {
                guard let image = capture.image else { throw StudioCommandError.staleRevision }
                let found = region.containsImage(placement: image.placement, angle: image.angle)
                let selected: Bool
                switch capture.mode {
                case .new: selected = found
                case .add: selected = found || capture.imageSelectionID != nil
                case .subtract: selected = capture.imageSelectionID != nil && !found
                }
                try checkCancellation()
                guard beginAreaSelection() == capture, textDraft == nil else { throw StudioCommandError.staleRevision }
                if selected {
                    if capture.imageSelectionID == nil {
                        imageMoveTarget = .init(projectID: image.projectID, frameID: image.frameID,
                            assetID: image.assetID, layerID: image.layerID, areaRevision: document.revision)
                    }
                } else { imageMoveTarget = nil }
                editor.selectedElementIDs.removeAll()
                return true
            }
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
            if capture.target == .artwork {
                let foundImage = capture.image.map { region.containsImage(placement: $0.placement, angle: $0.angle) } ?? false
                let keepImage: Bool
                switch capture.mode {
                case .new: keepImage = foundImage
                case .add: keepImage = foundImage || capture.imageSelectionID != nil
                case .subtract: keepImage = capture.imageSelectionID != nil && !foundImage
                }
                if keepImage, let image = capture.image {
                    if capture.imageSelectionID == nil {
                        imageMoveTarget = .init(projectID: image.projectID, frameID: image.frameID,
                            assetID: image.assetID, layerID: image.layerID, areaRevision: document.revision)
                    }
                } else { imageMoveTarget = nil }
            }
            editor.selectedElementIDs = selected
            return true
        } catch { message = error.localizedDescription; return false }
    }
    /// All/Invert operate on visible editable artwork only. They never create
    /// document history and never select an invisible or fully locked layer.
    @discardableResult
    func selectVisibleArtwork(inverting: Bool = false,
                              checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            guard areaSelectionTarget != .image, let capture = beginAreaSelection(), textDraft == nil else { return false }
            let eligible = Set(layers.filter { $0.visible && $0.opacity > 0 && !$0.isFullyLocked }.map(\.id))
            let canvas = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
            var ids = Set<String>()
            for element in currentFrame.elements {
                try checkCancellation()
                guard let layer = element.layerID, eligible.contains(layer), element.opacity > 0,
                      element.tool != .eraser,
                      let bounds = try StudioSelectionRegion.drawingBounds(element),
                      !bounds.intersection(canvas).isNull else { continue }
                ids.insert(element.id)
            }
            try checkCancellation()
            guard beginAreaSelection() == capture, textDraft == nil else { throw StudioCommandError.staleRevision }
            editor.selectedElementIDs = inverting ? ids.subtracting(capture.selectedIDs) : ids
            if capture.target == .artwork {
                if let image = capture.image, !inverting || capture.imageSelectionID == nil {
                    imageMoveTarget = .init(projectID: image.projectID, frameID: image.frameID,
                        assetID: image.assetID, layerID: image.layerID, areaRevision: document.revision)
                } else { imageMoveTarget = nil }
            }
            cancelPolygonSelection()
            return true
        } catch { message = error.localizedDescription; return false }
    }
    private struct ImageMoveTarget: Equatable {
        let selectionID = UUID()
        let projectID: UUID
        let frameID: String
        let assetID: String
        let layerID: String
        var areaRevision: Int? = nil
    }
    @Published private var imageMoveTarget: ImageMoveTarget?
    var hasFillImageTarget: Bool { imageMoveTarget != nil }
    var fillImageSelectionID: UUID? { imageMoveTarget?.selectionID }
    var fillImageLayerID: String? {
        guard let target = imageMoveTarget, target.projectID == document.id,
              target.frameID == currentFrame.id, target.layerID == activeLayerID,
              target.areaRevision == nil || target.areaRevision == document.revision,
              target.assetID == currentFrame.rasterAssetID(on: target.layerID),
              currentFrame.rasterInstance(on: target.layerID)?.placement != nil,
              originalImageSource(target.assetID) != nil,
              let layer = layers.first(where: { $0.id == target.layerID }), layer.visible,
              layer.opacity > 0, !layer.isFullyLocked, ["free", "position"].contains(layer.lockMode) else { return nil }
        return target.layerID
    }
    var isMovingImageOnCanvas: Bool {
        guard !isSelectingMixedArtwork, let target = imageMoveTarget else { return false }
        return selectedTool == .move && target.projectID == document.id &&
            target.frameID == currentFrame.id && target.assetID == currentFrame.rasterAssetID(on: target.layerID) &&
            currentFrame.preferredRasterInstance(activeLayerID: activeLayerID)?.layerID == target.layerID
    }
    @discardableResult
    func setImageCanvasMove(_ enabled: Bool) -> Bool {
        if !enabled { imageMoveTarget = nil; return true }
        guard let capture = prepareImagePlacement() else { return false }
        if areaSelectionTarget == .artwork { areaSelectionTarget = .image }
        imageMoveTarget = .init(projectID: capture.projectID, frameID: capture.frameID, assetID: capture.assetID, layerID: capture.layerID)
        editor.selectedElementIDs.removeAll()
        return true
    }
    private func clearMissingImageMoveTarget(in next: StudioDocument) {
        guard let target = imageMoveTarget else { return }
        if target.projectID != next.id || target.frameID != next.activeFrameID ||
            next.frames.first(where: { $0.id == target.frameID })?.rasterAssetID(on: target.layerID) != target.assetID ||
            next.frames.first(where: { $0.id == target.frameID })?.preferredRasterInstance(activeLayerID: next.activeLayerID)?.layerID != target.layerID {
            imageMoveTarget = nil
        }
    }
    struct ImageMoveCapture: Equatable {
        let placement: ImagePlacementCapture
        let selectionID: UUID
    }
    func currentImageMoveCapture() -> ImageMoveCapture? {
        guard isMovingImageOnCanvas || (selectedTool == .move && isSelectingMixedArtwork && selectedElementIDs.isEmpty), let target = imageMoveTarget,
              let placement = prepareImagePlacement(), placement.layerID == target.layerID else { return nil }
        return .init(placement: placement, selectionID: target.selectionID)
    }
    func beginImageMove(at point: CGPoint) -> ImageMoveCapture? {
        guard point.x.isFinite, point.y.isFinite, let capture = currentImageMoveCapture() else { return nil }
        let p = capture.placement.original
        return StudioImageRotationGeometry(placement: p, degrees: capture.placement.rotationDegrees).contains(point) && imageRegionContains(point, layerID: capture.placement.layerID) ? capture : nil
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
        guard var instance = frame.rasterInstance(on: capture.placement.layerID) else { throw StudioCommandError.invalidReference }
        let proposed = StudioRasterPlacement(x: original.x + delta.width, y: original.y + delta.height,
            width: original.width, height: original.height)
        instance.placement = try StudioImageRotationGeometry(placement: proposed, degrees: capture.placement.rotationDegrees)
            .fitted(canvasWidth: capture.placement.canvasWidth, canvasHeight: capture.placement.canvasHeight, allowingShrink: false)
        try frame.updateRasterInstance(instance)
        return frame
    }
    @discardableResult
    func finishImageMove(_ capture: ImageMoveCapture, delta: CGSize,
                         checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            let preview = try imageMovePreview(capture, delta: delta)
            guard let placement = preview.rasterInstance(on: capture.placement.layerID)?.placement else { throw StudioCommandError.invalidReference }
            return placeImage(capture.placement, at: placement, checkCancellation: {
                try checkCancellation()
                guard self.currentImageMoveCapture() == capture else { throw StudioCommandError.staleRevision }
            })
        } catch { message = error.localizedDescription; return false }
    }

    /// Rotation is measured in canvas coordinates from the captured touch start.
    /// Preview changes only a value frame; finger-up uses the same typed angle edit.
    func imageRotationPreview(_ capture: ImageMoveCapture, start: CGPoint, current: CGPoint) throws -> AnimationFrame {
        guard currentImageMoveCapture() == capture else { throw StudioCommandError.staleRevision }
        guard [start.x, start.y, current.x, current.y].allSatisfy({ $0.isFinite && abs($0) <= 131_072 }) else {
            throw StudioCommandError.invalidGeometry
        }
        let original = capture.placement.original
        let center = CGPoint(x: original.x + original.width / 2, y: original.y + original.height / 2)
        let a = CGPoint(x: start.x - center.x, y: start.y - center.y)
        let b = CGPoint(x: current.x - center.x, y: current.y - center.y)
        guard a.x*a.x + a.y*a.y > 0.000001, b.x*b.x + b.y*b.y > 0.000001 else {
            throw StudioCommandError.invalidGeometry
        }
        if start == current { return currentFrame }
        let delta = atan2(a.x*b.y - a.y*b.x, a.x*b.x + a.y*b.y) * 180 / .pi
        var degrees = capture.placement.rotationDegrees + delta
        if degrees > 180 { degrees -= 360 }; if degrees < -180 { degrees += 360 }
        var frame = currentFrame
        guard var instance = frame.rasterInstance(on: capture.placement.layerID) else { throw StudioCommandError.invalidReference }
        instance.rotationDegrees = degrees == 0 ? nil : degrees
        instance.placement = try StudioImageRotationGeometry(placement: original, degrees: degrees)
            .fitted(canvasWidth: capture.placement.canvasWidth, canvasHeight: capture.placement.canvasHeight, allowingShrink: false)
        try frame.updateRasterInstance(instance)
        return frame
    }
    @discardableResult
    func finishImageRotation(_ capture: ImageMoveCapture, start: CGPoint, current: CGPoint,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            try checkCancellation()
            let preview = try imageRotationPreview(capture, start: start, current: current)
            guard let instance = preview.rasterInstance(on: capture.placement.layerID), let placement = instance.placement else {
                throw StudioCommandError.invalidReference
            }
            return placeImage(capture.placement, at: placement, rotationDegrees: instance.rotationDegrees ?? 0,
                checkCancellation: {
                    try checkCancellation()
                    guard self.currentImageMoveCapture() == capture else { throw StudioCommandError.staleRevision }
                })
        } catch { message = error.localizedDescription; return false }
    }

    /// Corner drags keep the opposite corner fixed and preserve the displayed
    /// aspect ratio. Preview retains the original asset and creates no history.
    func imageResizePreview(_ capture: ImageMoveCapture, corner: StudioSelectionHandleGeometry.Kind,
                            delta: CGSize) throws -> AnimationFrame {
        guard currentImageMoveCapture() == capture else { throw StudioCommandError.staleRevision }
        guard corner != .rotate, delta.width.isFinite, delta.height.isFinite,
              abs(delta.width) <= 131_072, abs(delta.height) <= 131_072 else {
            throw StudioDocumentError.invalid("The image resize has invalid coordinates.")
        }
        if delta == .zero { return currentFrame }
        let p = capture.placement.original
        if capture.placement.rotationDegrees != 0 {
            let bounds = StudioImageRotationGeometry(placement: p, degrees: capture.placement.rotationDegrees).bounds
            let left = corner == .topLeft || corner == .bottomLeft
            let top = corner == .topLeft || corner == .topRight
            let anchor = CGPoint(x: left ? bounds.maxX : bounds.minX, y: top ? bounds.maxY : bounds.minY)
            let dx = (left ? -1.0 : 1.0) * Double(delta.width)
            let dy = (top ? -1.0 : 1.0) * Double(delta.height)
            let requested = 1 + (dx * bounds.width + dy * bounds.height) / (bounds.width * bounds.width + bounds.height * bounds.height)
            let maximum = min((left ? anchor.x : Double(capture.placement.canvasWidth) - anchor.x) / bounds.width,
                              (top ? anchor.y : Double(capture.placement.canvasHeight) - anchor.y) / bounds.height)
            let scale = min(maximum, max(min(1, max(1 / p.width, 1 / p.height)), requested))
            guard scale.isFinite, scale > 0 else { throw StudioCommandError.invalidGeometry }
            let centerX = anchor.x + (p.x + p.width / 2 - anchor.x) * scale
            let centerY = anchor.y + (p.y + p.height / 2 - anchor.y) * scale
            let placement = StudioRasterPlacement(x: centerX - p.width * scale / 2,
                y: centerY - p.height * scale / 2, width: p.width * scale, height: p.height * scale)
            try StudioImageRotationGeometry(placement: placement, degrees: capture.placement.rotationDegrees)
                .validate(canvasWidth: capture.placement.canvasWidth, canvasHeight: capture.placement.canvasHeight)
            var frame = currentFrame
            guard var instance = frame.rasterInstance(on: capture.placement.layerID) else { throw StudioCommandError.invalidReference }
            instance.placement = placement; try frame.updateRasterInstance(instance)
            return frame
        }
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let anchorX = left ? p.x + p.width : p.x
        let anchorY = top ? p.y + p.height : p.y
        let dx = (left ? -1.0 : 1.0) * Double(delta.width)
        let dy = (top ? -1.0 : 1.0) * Double(delta.height)
        let scale = 1 + (dx * p.width + dy * p.height) / (p.width * p.width + p.height * p.height)
        let maximum = min((left ? anchorX : Double(capture.placement.canvasWidth) - anchorX) / p.width,
                          (top ? anchorY : Double(capture.placement.canvasHeight) - anchorY) / p.height)
        let minimum = min(1, max(1 / p.width, 1 / p.height))
        let bounded = min(maximum, max(minimum, scale))
        guard bounded.isFinite, bounded > 0 else { throw StudioCommandError.invalidGeometry }
        let width = p.width * bounded, height = p.height * bounded
        var frame = currentFrame
        guard var instance = frame.rasterInstance(on: capture.placement.layerID) else { throw StudioCommandError.invalidReference }
        instance.placement = .init(x: left ? anchorX - width : anchorX,
            y: top ? anchorY - height : anchorY, width: width, height: height)
        try frame.updateRasterInstance(instance)
        return frame
    }
    @discardableResult
    func finishImageResize(_ capture: ImageMoveCapture, corner: StudioSelectionHandleGeometry.Kind,
                           delta: CGSize, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            let preview = try imageResizePreview(capture, corner: corner, delta: delta)
            guard let placement = preview.rasterInstance(on: capture.placement.layerID)?.placement else { throw StudioCommandError.invalidReference }
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
        var rotationDegrees: Double = 0
    }
    func prepareImagePlacement() -> ImagePlacementCapture? {
        guard !hasMixedArtworkSelection, isEditing, !isPlaying, !isSaving, selectedTool == .move,
              activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              let instance = currentFrame.preferredRasterInstance(activeLayerID: activeLayerID), let original = instance.placement,
              let assetID = currentFrame.rasterAssetID(on: instance.layerID),
              let source = originalImageSource(assetID),
              let layer = layers.first(where: { $0.id == instance.layerID }),
              layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { return nil }
        let crop = instance.crop ?? .full
        let odd = (instance.quarterTurns ?? 0) % 2 != 0
        let sourceWidth = Double(source.normalizedWidth) * crop.width
        let sourceHeight = Double(source.normalizedHeight) * crop.height
        let width = odd ? sourceHeight : sourceWidth, height = odd ? sourceWidth : sourceHeight
        let angle = instance.rotationDegrees ?? 0
        let initialFit = StudioRasterPlacement(x: (Double(document.width) - width) / 2,
            y: (Double(document.height) - height) / 2, width: width, height: height)
        guard let rotatedFit = try? StudioImageRotationGeometry(placement: initialFit, degrees: angle)
            .fitted(canvasWidth: document.width, canvasHeight: document.height, allowingShrink: true, fillCanvas: true) else { return nil }
        return .init(projectID: document.id, revision: document.revision, frameID: currentFrame.id,
            assetID: assetID, layerID: layer.id, original: original,
            fitted: rotatedFit, canvasWidth: document.width, canvasHeight: document.height, rotationDegrees: angle)
    }
    @discardableResult
    func placeImage(_ capture: ImagePlacementCapture, at placement: StudioRasterPlacement, rotationDegrees: Double? = nil,
                    checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            try checkCancellation()
            guard prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply([.updateImagePlacement(.init(
                    frame: .id(capture.frameID), assetID: capture.assetID, placement: placement, rotationDegrees: rotationDegrees, layer: .id(capture.layerID)))])),
                checkCancellation: {
                    try checkCancellation()
                    guard self.prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
                })
            return true
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func cropImage(_ capture: ImagePlacementCapture, crop: StudioImageCrop,
                   checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            try checkCancellation()
            guard prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID, expectedRevision: capture.revision,
                action: .apply([.cropImage(.init(frame: .id(capture.frameID), assetID: capture.assetID, crop: crop, layer: .id(capture.layerID)))])),
                checkCancellation: {
                    try checkCancellation()
                    guard self.prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
                })
            return true
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func rotateImage(_ capture: ImagePlacementCapture, direction: StudioImageQuarterTurn,
                     checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            try checkCancellation()
            guard prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply([.rotateImage(.init(
                    frame: .id(capture.frameID), assetID: capture.assetID, direction: direction, layer: .id(capture.layerID)))])),
                checkCancellation: {
                    try checkCancellation()
                    guard self.prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
                })
            return true
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func reflectImage(_ capture: ImagePlacementCapture, axis: StudioReflectionAxis,
                      checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            try checkCancellation()
            guard prepareImagePlacement() == capture else { throw StudioCommandError.staleRevision }
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply([.reflectImage(.init(
                    frame: .id(capture.frameID), assetID: capture.assetID, axis: axis, layer: .id(capture.layerID)))])),
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
                    frame: .id(capture.frameID), assetID: capture.assetID, layer: .id(capture.layerID)))])),
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
        var artwork: SelectionHandleCapture? = nil
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
        if areaSelectionTarget == .artwork && selectionMode != .new {
            // Add/Subtract are selection input before transform admission. This
            // also lets either missing kind be re-added to a one-kind group.
            let drawingHit = selectElement(at: point)
            if drawingHit == nil, let image = availableAreaImage,
               StudioImageRotationGeometry(placement: image.placement, degrees: image.angle).contains(point) && imageRegionContains(point, layerID: activeLayerID) {
                if selectionMode == .subtract { imageMoveTarget = nil }
                else if imageMoveTarget == nil {
                    imageMoveTarget = .init(projectID: image.projectID, frameID: image.frameID,
                        assetID: image.assetID, layerID: image.layerID)
                }
            }
            if selectionMode == .subtract { return nil }
        }
        if isSelectingMixedArtwork {
            guard let artwork = beginSelectionHandle() else { return nil }
            if artwork.bounds.insetBy(dx: -6, dy: -6).contains(point) {
                return .init(projectID: document.id, revision: document.revision, frameID: currentFrame.id,
                             ids: selectedElementIDs, mode: selectionMode, artwork: artwork)
            }
            if selectionMode == .new { clearElementSelection() }
        }
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
        if let artwork = capture.artwork { return beginSelectionHandle() == artwork }
        return !isSelectingMixedArtwork && isEditing && !isPlaying && selectedTool == .move && !isMovingImageOnCanvas && activeStrokeID == nil && pendingBrushStroke == nil &&
        capture.projectID == document.id && capture.revision == document.revision && capture.frameID == currentFrame.id &&
        capture.ids == selectedElementIDs && capture.mode == selectionMode
    }
    /// Preview derives from the captured document and never mutates undo or autosave.
    func movePreview(_ capture: MoveCapture, delta: CGSize) throws -> AnimationFrame {
        guard moveIsCurrent(capture) else { throw StudioCommandError.staleRevision }
        try StudioElementTranslation(x: delta.width, y: delta.height).validate()
        if let artwork = capture.artwork {
            let request = try artworkRequest(artwork, dx: delta.width, dy: delta.height)
            try validateCommandWorkBudget(request)
            var candidate = editor
            _ = try StudioCommandExecutor.execute(request, editor: &candidate)
            guard let frame = candidate.document.frames.first(where: { $0.id == capture.frameID }) else { throw StudioCommandError.staleRevision }
            return frame
        }
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
    func finishMove(_ capture: MoveCapture, delta: CGSize,
                    checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        if let artwork = capture.artwork {
            do {
                guard moveIsCurrent(capture) else { throw StudioCommandError.staleRevision }
                let request = try artworkRequest(artwork, dx: delta.width, dy: delta.height)
                _ = try applyStudioCommands(request, checkCancellation: {
                    try checkCancellation()
                    guard self.moveIsCurrent(capture) else { throw StudioCommandError.staleRevision }
                })
                retainArtworkSelection(artwork)
                return true
            } catch { message = error.localizedDescription; return false }
        }
        guard moveIsCurrent(capture) else { message = "Studio changed during the move. The artwork has not moved."; return false }
        do {
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply([.translateElements(.init(frame: .id(capture.frameID),
                    elementIDs: capture.ids.sorted(), dx: delta.width, dy: delta.height))])))
            editor.selectedElementIDs = capture.ids
            return true
        } catch { message = error.localizedDescription; return false }
    }
    struct SelectionLayerLockCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let elementIDs: Set<String>
        let layerIDs: [String]
        let image: AreaImageIdentity?
        let imageSelectionID: UUID?
    }
    func prepareSelectionLayerLock() -> SelectionLayerLockCapture? {
        guard isEditing, selectedTool == .move, !isPlaying, !isSaving,
              activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              !selectedElementIDs.isEmpty, selectedElementIDs.count <= 1024 else { return nil }
        let selected = currentFrame.elements.filter { selectedElementIDs.contains($0.id) }
        guard selected.count == selectedElementIDs.count else { return nil }
        let image = isSelectingMixedArtwork ? validSelectedArtworkImage : nil
        guard !isSelectingMixedArtwork || image != nil else { return nil }
        var ids = Set(selected.compactMap(\.layerID))
        if let image { ids.insert(image.layerID) }
        guard !ids.isEmpty, ids.count <= StudioCommandExecutor.maximumCommands,
              selected.allSatisfy({ $0.layerID != nil }),
              ids.allSatisfy({ id in layers.contains { $0.id == id && $0.visible && $0.opacity > 0 && !$0.isFullyLocked } }) else { return nil }
        return .init(projectID: document.id, revision: document.revision, frameID: currentFrame.id,
                     elementIDs: selectedElementIDs, layerIDs: ids.sorted(), image: image,
                     imageSelectionID: image == nil ? nil : imageMoveTarget?.selectionID)
    }
    /// Explicitly locks whole layers, across frames, after the UI discloses that
    /// scope. One typed transaction makes every affected layer one Undo step.
    @discardableResult
    func lockSelectedLayers(_ capture: SelectionLayerLockCapture,
                            checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            try checkCancellation()
            guard prepareSelectionLayerLock() == capture else { throw StudioCommandError.staleRevision }
            let commands: [StudioCommand] = capture.layerIDs.map {
                .updateLayer(.init(layer: .id($0), settings: .init(lock: .full)))
            }
            _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
                expectedRevision: capture.revision, action: .apply(commands)), checkCancellation: {
                    try checkCancellation()
                    guard self.prepareSelectionLayerLock() == capture else { throw StudioCommandError.staleRevision }
                })
            clearElementSelection()
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func clearElementSelection() {
        areaSelectionGeneration = UUID()
        editor.selectedElementIDs.removeAll(); imageMoveTarget = nil; cancelPolygonSelection()
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
        command { try $0.updateLayer(id) { $0.lockMode = mode.rawValue; $0.locked = mode == .full } }
    }
    func setLayerOpacity(_ id: String, opacity: Double) { command { try $0.updateLayer(id) { $0.opacity = opacity } } }
    func setLayerBlend(_ id: String, mode: String) { command { try $0.updateLayer(id) { $0.blendMode = mode } } }
    func setLayerGlow(_ id: String, enabled: Bool) { command { try $0.updateLayer(id) { $0.glowEnabled = enabled } } }
    func setLayerGlowStyle(_ id: String, color: String? = nil, radius: Double? = nil, strength: Double? = nil) {
        command { try $0.updateLayer(id) { layer in
            if let color {
                guard CanvasLayer.isValidNewGlowColor(color) else { throw StudioDocumentError.invalid("Choose a valid six-digit RGB glow color.") }
                layer.glowColor = color
            }
            if let radius { layer.glowRadius = radius }
            if let strength { layer.glowStrength = strength }
        } }
    }
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
            frame.rasterInstance(on: id) != nil || frame.elements.contains(where: { $0.layerID == id })
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
    struct LayerReorderCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let layerID: String
        let order: [String]
    }
    func prepareLayerReorder(_ id: String) -> LayerReorderCapture? {
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil,
              textDraft == nil, layers.count > 1, layers.count <= 64,
              layers.contains(where: { $0.id == id }) else { return nil }
        return .init(projectID: document.id, revision: document.revision, frameID: document.activeFrameID,
                     layerID: id, order: layers.map(\.id))
    }
    /// Dragging across several rows is one atomic typed command transaction.
    @discardableResult
    func reorderLayer(_ capture: LayerReorderCapture, relativeTo targetID: String, after: Bool,
                      checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Bool {
        try checkCancellation()
        guard prepareLayerReorder(capture.layerID) == capture else { throw StudioCommandError.staleRevision }
        guard targetID != capture.layerID else { return false }
        guard let source = capture.order.firstIndex(of: capture.layerID), capture.order.contains(targetID) else {
            throw StudioCommandError.invalidReference
        }
        var remaining = capture.order.filter { $0 != capture.layerID }
        guard let target = remaining.firstIndex(of: targetID) else { throw StudioCommandError.invalidReference }
        let destination = target + (after ? 1 : 0)
        remaining.insert(capture.layerID, at: destination)
        guard remaining != capture.order else { return false }
        let direction: StudioCommandDirection = destination < source ? .earlier : .later
        let commands = (0..<abs(destination - source)).map { _ in
            StudioCommand.moveLayer(.init(target: .id(capture.layerID), direction: direction))
        }
        _ = try applyStudioCommands(.init(requestID: UUID(), projectID: capture.projectID,
            expectedRevision: capture.revision, action: .apply(commands)), checkCancellation: {
                try checkCancellation()
                guard self.prepareLayerReorder(capture.layerID) == capture else { throw StudioCommandError.staleRevision }
            })
        return true
    }

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
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
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
        let clipboardVersion = editor.clipboardVersion, selectedIDs = editor.selectedElementIDs
        let selectedClipID = selectedAudioClip?.id
        let clip = AudioClip(id: UUID().uuidString, soundName: track.name, track: trackNumber,
            startTime: Double(document.startTick(ofFrame: frame)) / Double(fps), duration: track.duration, assetID: track.id)
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
        // The cancellation checkpoint is caller-supplied and can reenter Studio.
        // Never overwrite a newer edit, clipboard or selection with this snapshot.
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              document.id == expectedProjectID, document.revision == expectedRevision,
              document.activeFrameID == frameID, editor.clipboardVersion == clipboardVersion,
              editor.selectedElementIDs == selectedIDs, selectedAudioClip?.id == selectedClipID else {
            throw StudioDocumentError.unavailable("The editor changed before the audio could be attached. No audio was added.")
        }
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
            if let envelope = clip.fadeEnvelope {
                try envelope.validate()
                guard envelope.sourceStartFrame + envelope.frameCount <= Int((asset.duration * StudioAudioTimelineGeometry.sampleRate).rounded()) else {
                    throw StudioDocumentError.invalid("The audio fade exceeds its original source. No save was made.")
                }
            }
        }
        return tracks
    }
    private func pruneManagedAudio() {
        let needed = editor.referencedAudioAssetIDsIncludingHistory
        managedAudioTracks = managedAudioTracks.filter { needed.contains($0.key) }
        pruneManagedImages()
    }
    /// A pending text draft owns its captured frame and document revision until
    /// Apply or Cancel. Audio commands must not invalidate that editable draft.
    private var canMutateAudioDocument: Bool {
        isEditing && !isSaving && !isPlaying && activeStrokeID == nil &&
            pendingBrushStroke == nil && textDraft == nil
    }
    /// Manual and assistant trims share the source bound used by the actual mixer.
    private func validateAudioTrim(_ clip: AudioClip, asset: AudioTrack) throws {
        guard clip.sourceOffset.isFinite, clip.duration.isFinite, clip.sourceOffset >= 0,
              clip.duration >= 1 / 48_000.0, asset.duration.isFinite,
              clip.sourceOffset + clip.duration <= asset.duration + 1 / 48_000.0 else {
            throw StudioDocumentError.invalid("The trim must contain real audio within the source file.")
        }
        let rate = StudioAudioTimelineGeometry.sampleRate
        guard clip.startTime.isFinite, (0...1000).contains(clip.startTime),
              clip.duration <= 300, clip.sourceOffset <= 300,
              asset.duration > 0, asset.duration <= 300 else {
            throw StudioDocumentError.invalid("The trim has unsupported source timing. Nothing changed.")
        }
        let exact = asset.duration * rate
        let fractional = abs(exact - exact.rounded()) >= 0.0000001
        let available = Int(fractional ? exact.rounded(.down) : exact.rounded())
        let sourceStart = Int((clip.sourceOffset * rate).rounded())
        let count = Int(((clip.startTime + clip.duration) * rate).rounded() - (clip.startTime * rate).rounded())
        let requestedEnd = sourceStart + count
        guard count > 0, sourceStart < available else {
            throw StudioDocumentError.invalid("The trim must contain real audio within the source file.")
        }
        if requestedEnd > available {
            // Match the mixer's single fractional conversion EOF exception;
            // integer EOF and a fragment with no real source sample never qualify.
            guard fractional, requestedEnd == Int(exact.rounded(.up)), requestedEnd == available + 1,
                  (clip.sourceOffset + clip.duration) * rate > Double(available),
                  clip.sourceOffset + clip.duration <= exact / rate + 0.000000001,
                  count > 1 else {
                throw StudioDocumentError.invalid("The trim extends beyond the source's playable samples. Nothing changed.")
            }
        }
    }
    /// The same command entry point is usable by Studio UI and validated assistants.
    /// Source bytes stay immutable; only a selected clip in the captured revision changes.
    func editSelectedAudioClip(_ id: String, expectedRevision: Int, edit: StudioAudioClipEdit) throws {
        guard canMutateAudioDocument,
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
        try validateAudioTrim(clip, asset: asset)
        guard clip != document.audioClips[index] else { return }
        var candidate = editor
        switch edit {
        case .place(let start, let track): try candidate.updateAudioClip(id, settings: .init(placement: .init(startTime: start, track: track)))
        case .volume(let value): try candidate.updateAudioClip(id, settings: .init(volume: value))
        case .mute(let value): try candidate.updateAudioClip(id, settings: .init(isMuted: value))
        case .trim(let offset, let duration):
            try candidate.updateAudioClip(id, settings: .init(trim: .init(sourceOffset: offset, duration: duration)))
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
        guard canMutateAudioDocument,
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
        var candidate = editor
        let duplicate = try candidate.duplicateAudioClip(capture.clip.id, newClipID: UUID().uuidString)
        guard let assetID = duplicate.assetID, let asset = audioTrack(forAssetID: assetID) else {
            throw StudioDocumentError.invalid("The original audio source is missing. Nothing was added.")
        }
        try validateAudioTrim(duplicate, asset: asset)
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
    struct AudioFadeCapture: Equatable {
        let selection: AudioDuplicationCapture
    }
    func prepareAudioFades() -> AudioFadeCapture? {
        prepareAudioDuplication().map { .init(selection: $0) }
    }
    /// Apply/reset one immutable envelope in one reversible document command.
    func setAudioFades(_ capture: AudioFadeCapture, fadeIn: Double, fadeOut: Double,
                       checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        guard prepareAudioFades() == capture else {
            throw StudioDocumentError.unavailable("The selected clip or project changed. Reopen its fade options.")
        }
        let clip = capture.selection.clip
        guard let index = document.audioClips.firstIndex(where: { $0.id == clip.id }) else {
            throw StudioDocumentError.unavailable("The selected audio clip is no longer available.")
        }
        var candidate = editor
        try candidate.updateAudioClip(clip.id, settings: .init(fades: .init(fadeIn: fadeIn, fadeOut: fadeOut)))
        guard candidate.document != document else { return }
        try preflightRasterDocument(candidate.document); _ = try audioTracksForSave(candidate.document)
        try checkCancellation()
        guard prepareAudioFades() == capture else {
            throw StudioDocumentError.unavailable("The project changed while setting fades. Nothing was changed.")
        }
        editor = candidate; selectedAudioClip = document.audioClips[index]; message = nil; scheduleSave()
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
        try candidate.updateAudioClip(capture.selection.clip.id, settings: .init(volume: volume))
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
        guard let timing = try? selection.clip.splitTiming(at: audioPlayheadTime) else { return nil }
        return .init(selection: selection, playhead: audioPlayheadTime,
                     boundary: timing.boundary, rightSourceOffset: timing.rightSourceOffset)
    }
    /// Split metadata, never the managed original. Both halves remain editable.
    @discardableResult
    func splitAudioClip(_ capture: AudioSplitCapture,
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> String {
        try checkCancellation()
        guard prepareAudioSplit() == capture else {
            throw StudioDocumentError.unavailable("Select a current clip and place the playhead inside it before splitting.")
        }
        var candidate = editor
        let right = try candidate.splitAudioClip(capture.selection.clip.id, at: capture.playhead, newClipID: UUID().uuidString)
        guard let assetID = right.assetID, let asset = audioTrack(forAssetID: assetID),
              let left = candidate.document.audioClips.first(where: { $0.id == capture.selection.clip.id }) else {
            throw StudioDocumentError.invalid("The original audio source is missing. Nothing changed.")
        }
        try validateAudioTrim(left, asset: asset); try validateAudioTrim(right, asset: asset)
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
        guard canMutateAudioDocument,
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
        guard canMutateAudioDocument,
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
        guard canMutateAudioDocument,
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
        let target = document.frameIndex(atTick: Int(min(Double(document.totalTimelineTicks), max(0, seconds * Double(fps))).rounded(.down)))
        if playing {
            playbackFrameIndex = target; isPlaying = true
        } else {
            playbackFrameIndex = nil; isPlaying = false
            guard canMutateAudioDocument else { return }
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
        command { try $0.deleteAudioClip(id) }
        if !document.audioClips.contains(where: { $0.id == id }) { selectedAudioClip = nil }
    }
    /// The picker/decoder owner must retain its result until this atomic handoff
    /// succeeds. No image is attached on rejection, and no save success is implied.
    @discardableResult
    func attachImportedImage(_ imported: StudioImageImportService.ImportedImage,
                             expectedProjectID: UUID, expectedRevision: Int, frameID: String, layerID: String,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> String {
        try checkCancellation()
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              document.id == expectedProjectID, document.revision == expectedRevision,
              document.activeFrameID == frameID, document.activeLayerID == layerID,
              let index = document.frames.firstIndex(where: { $0.id == frameID }) else {
            throw StudioDocumentError.unavailable("The project, frame, layer, save or drawing state changed. Import again in the current editor.")
        }
        guard document.frames[index].rasterAssetID == nil || document.frames[index].rasterPlacement != nil else {
            throw StudioDocumentError.unavailable("This frame contains a historical original record. Add a new blank frame; its original bytes were not replaced.")
        }
        guard let layer = document.layers.first(where: { $0.id == layerID }), layer.visible, !layer.isFullyLocked else { throw StudioDocumentError.locked }
        let clipboardVersion = editor.clipboardVersion, selectedIDs = editor.selectedElementIDs
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
            value.schemaVersion = max(value.schemaVersion, value.frames[index].rasterAssetID == nil ? 3 : 31)
            value.layers.append(imageLayer) // Behind drawings; active drawing layer stays selected.
            try value.frames[index].appendRasterInstance(.init(layerID: imageLayer.id, placement: placement), assetID: assetID)
        }
        let needed = candidate.referencedRasterAssetIDsIncludingHistoryAndClipboard.union(imageClipboard?.referencedRasterAssetIDs ?? [])
        var next = retainedRasterFrames.filter { $0.value.sourceImage == nil || needed.contains($0.key) }
        next[assetID] = record
        try validateManagedImageCapacity(next)
        try storage.preflightAnimation(storageProject(candidate.document, rasters: next))
        try checkCancellation()
        // No suspension occurs between the state guard, exact storage preflight
        // and publication of one history transaction plus its immutable bytes.
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              document.id == expectedProjectID, document.revision == expectedRevision,
              document.activeFrameID == frameID, document.activeLayerID == layerID,
              editor.clipboardVersion == clipboardVersion, editor.selectedElementIDs == selectedIDs else {
            throw StudioDocumentError.unavailable("The editor changed before the image could be attached. No image was added.")
        }
        retainedRasterFrames = next; editor = candidate
        scheduleSave()
        return assetID
    }
    /// Atomically append a bounded reference sequence after the captured frame.
    /// Existing frames and originals are never replaced; the new images share
    /// one reference layer behind all drawing layers and one Undo transaction.
    @discardableResult
    func attachImportedImageSequence(_ imports: [StudioImageImportService.ImportedImage],
                                     expectedProjectID: UUID, expectedRevision: Int, frameID: String, layerID: String,
                                     checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> [String] {
        try checkCancellation()
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              document.id == expectedProjectID, document.revision == expectedRevision,
              document.activeFrameID == frameID, document.activeLayerID == layerID,
              let index = document.frames.firstIndex(where: { $0.id == frameID }) else {
            throw StudioDocumentError.unavailable("The project, frame, layer, save or drawing state changed. Import again in the current editor.")
        }
        guard (1...24).contains(imports.count), document.frames.count <= 1000 - imports.count,
              document.layers.count < 128 else {
            throw StudioDocumentError.invalid("Import 1–24 reference frames within the 1,000-frame and 128-layer project limits.")
        }
        guard let layer = document.layers.first(where: { $0.id == layerID }), layer.visible, !layer.isFullyLocked else {
            throw StudioDocumentError.locked
        }
        let clipboardVersion = editor.clipboardVersion, selectedIDs = editor.selectedElementIDs
        let imageLayer = CanvasLayer(id: UUID().uuidString, name: "Video reference")
        var records: [String: StoredAnimationFrame] = [:], frames: [AnimationFrame] = []
        var pngBytes = 0, pixels = 0
        for imported in imports {
            try checkCancellation()
            guard imported.normalizedPNG.count <= 32 * 1024 * 1024 - pngBytes,
                  imported.width > 0, imported.height > 0,
                  imported.width <= (32_000_000 - pixels) / imported.height else {
                throw StudioDocumentError.invalid("Reference sequences are limited to 32 MB of PNG data and 32 million pixels.")
            }
            pngBytes += imported.normalizedPNG.count
            pixels += imported.width * imported.height
            let assetID = "image-" + imported.id.uuidString
            guard retainedRasterFrames[assetID] == nil, records[assetID] == nil else {
                throw StudioDocumentError.invalid("Every imported frame must have a new, unique image identity.")
            }
            let source = StoredImageSource(id: imported.id, name: imported.name, container: imported.container.rawValue,
                originalData: imported.originalData, originalWidth: imported.originalWidth, originalHeight: imported.originalHeight,
                originalOrientation: imported.originalOrientation, normalizedWidth: imported.width, normalizedHeight: imported.height,
                catalogueAttribution: imported.catalogueAttribution)
            try StudioRasterImage.validate(source: source, normalized: imported.normalizedPNG)
            records[assetID] = StoredAnimationFrame(imageData: imported.normalizedPNG, layerData: nil, sourceImage: source)
            var frame = AnimationFrame(id: UUID().uuidString, elements: [])
            frame.rasterAssetID = assetID; frame.rasterLayerID = imageLayer.id
            frame.rasterPlacement = StudioRasterPlacement.aspectFit(imageWidth: imported.width, imageHeight: imported.height,
                canvasWidth: document.width, canvasHeight: document.height)
            frames.append(frame)
        }
        var candidate = editor
        try candidate.change { value in
            value.schemaVersion = max(value.schemaVersion, 3)
            value.layers.append(imageLayer)
            value.frames.insert(contentsOf: frames, at: index + 1)
            value.activeFrameID = frames[0].id
        }
        let needed = candidate.referencedRasterAssetIDsIncludingHistoryAndClipboard.union(imageClipboard?.referencedRasterAssetIDs ?? [])
        var next = retainedRasterFrames.filter { $0.value.sourceImage == nil || needed.contains($0.key) }
        next.merge(records) { _, new in new }
        try validateManagedImageCapacity(next)
        try storage.preflightAnimation(storageProject(candidate.document, rasters: next))
        try checkCancellation()
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil, pendingBrushStroke == nil, textDraft == nil,
              document.id == expectedProjectID, document.revision == expectedRevision,
              document.activeFrameID == frameID, document.activeLayerID == layerID,
              editor.clipboardVersion == clipboardVersion, editor.selectedElementIDs == selectedIDs else {
            throw StudioDocumentError.unavailable("The editor changed before the reference sequence could be attached. No frames were added.")
        }
        candidate.selectedElementIDs.removeAll()
        retainedRasterFrames = next; editor = candidate
        scheduleSave()
        return frames.map(\.id)
    }
    struct ImageCutCapture: Equatable {
        let projectID: UUID
        let revision: Int
        let activeFrameID: String
        let allFrames: Bool
        let assetsByFrame: [String: String]
        let activeLayerID: String
    }
    func prepareImageCut(allFrames: Bool) throws -> ImageCutCapture {
        guard isEditing, !isSaving, !isPlaying, activeStrokeID == nil,
              pendingBrushStroke == nil, textDraft == nil else {
            throw StudioDocumentError.unavailable("Finish the current edit before cutting an image background.")
        }
        let targets = allFrames ? document.frames.filter { $0.rasterAssetID != nil } : [currentFrame]
        guard !targets.isEmpty, targets.count <= 64 else {
            throw StudioDocumentError.unavailable("Choose 1–64 frames with imported images. Drawing-only frames are unchanged.")
        }
        var mapping: [String: String] = [:], assets = Set<String>(), pixels = 0
        for frame in targets {
            let selectedSource: String?
            if frame.referencedRasterAssetIDs.count == 1 { selectedSource = frame.rasterAssetID }
            else { selectedSource = frame.rasterAssetID(on: activeLayerID) }
            guard let id = selectedSource else {
                throw StudioDocumentError.unavailable("Select an image layer in every multi-source frame in the chosen scope before Background Cut. Nothing changed.")
            }
            guard let record = retainedRasterFrames[id],
                  let source = record.sourceImage, let png = record.imageData, frame.rasterPlacement != nil else {
                throw StudioDocumentError.unavailable("Background Cut currently works on imported images. Historical raster originals and drawing-only frames are not converted.")
            }
            let affectedInstances = frame.rasterLayerInstances.filter { frame.rasterAssetID(on: $0.layerID) == id }
            guard !affectedInstances.isEmpty,
                  affectedInstances.allSatisfy({ instance in
                      layers.contains { $0.id == instance.layerID && $0.visible && $0.opacity > 0 && $0.lockMode == "free" && !$0.isFullyLocked }
                  }) else {
                throw StudioDocumentError.unavailable("Show and unlock every linked image layer in the chosen frames before cutting its background.")
            }
            guard source.normalizedWidth * source.normalizedHeight <= 4_194_304, png.count <= 16 * 1024 * 1024 else {
                throw StudioDocumentError.unavailable("Background Cut supports imported images up to 4 megapixels and 16 MB each.")
            }
            if assets.insert(id).inserted { pixels += source.normalizedWidth * source.normalizedHeight }
            guard assets.count <= 16, pixels <= 16_777_216 else {
                throw StudioDocumentError.unavailable("Cut at most 16 distinct images / 16 megapixels per batch. Use Current frame for larger projects.")
            }
            mapping[frame.id] = id
        }
        return .init(projectID: document.id, revision: document.revision, activeFrameID: currentFrame.id,
                     allFrames: allFrames, assetsByFrame: mapping, activeLayerID: activeLayerID)
    }
    /// New immutable normalized renditions retain original bytes and provenance.
    /// Every affected frame is changed in one history transaction after preflight.
    func applyImageCut(_ capture: ImageCutCapture, replacements: [String: Data],
                       checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Int {
        try checkCancellation()
        guard try prepareImageCut(allFrames: capture.allFrames) == capture else { throw StudioCommandError.staleRevision }
        guard !replacements.isEmpty, Set(replacements.keys).isSubset(of: Set(capture.assetsByFrame.values)) else {
            throw StudioDocumentError.invalid("The background preview does not belong to these frames.")
        }
        var next = retainedRasterFrames
        var updatedIDs: [String: String] = [:]
        for oldID in replacements.keys.sorted() {
            try checkCancellation()
            guard let png = replacements[oldID], let old = retainedRasterFrames[oldID], let source = old.sourceImage else {
                throw StudioRasterImage.Failure.missing
            }
            guard png != old.imageData else { continue }
            let newID = UUID()
            let copiedSource = StoredImageSource(id: newID, name: source.name, container: source.container,
                originalData: source.originalData, originalWidth: source.originalWidth, originalHeight: source.originalHeight,
                originalOrientation: source.originalOrientation, normalizedWidth: source.normalizedWidth,
                normalizedHeight: source.normalizedHeight, catalogueAttribution: source.catalogueAttribution)
            try StudioRasterImage.validate(source: copiedSource, normalized: png)
            let assetID = "image-" + newID.uuidString
            next[assetID] = StoredAnimationFrame(imageData: png, layerData: old.layerData, sourceImage: copiedSource)
            updatedIDs[oldID] = assetID
        }
        guard !updatedIDs.isEmpty else { throw StudioDocumentError.unavailable("No edge-connected pixels matched the background color. Nothing changed.") }
        var candidate = editor
        var affected = 0
        try candidate.change { document in
            for index in document.frames.indices {
                let frame = document.frames[index]
                if let oldID = capture.assetsByFrame[frame.id], let newID = updatedIDs[oldID] {
                    let newPrimary = frame.rasterAssetID == oldID ? newID : frame.rasterAssetID
                    document.frames[index].rasterAssetID = newPrimary
                    document.frames[index].rasterAliases = frame.rasterAliases?.map { instance in
                        var updated = instance
                        let resolved = instance.assetID ?? frame.rasterAssetID
                        if resolved == oldID { updated.assetID = newID == newPrimary ? nil : newID }
                        else if instance.assetID == nil && newPrimary != frame.rasterAssetID { updated.assetID = resolved }
                        return updated
                    }
                    affected += 1
                }
            }
        }
        let needed = candidate.referencedRasterAssetIDsIncludingHistoryAndClipboard.union(imageClipboard?.referencedRasterAssetIDs ?? [])
        next = next.filter { $0.value.sourceImage == nil || needed.contains($0.key) }
        try validateManagedImageCapacity(next)
        try storage.preflightAnimation(storageProject(candidate.document, rasters: next))
        try checkCancellation()
        guard try prepareImageCut(allFrames: capture.allFrames) == capture else { throw StudioCommandError.staleRevision }
        retainedRasterFrames = next; editor = candidate
        scheduleSave()
        return affected
    }

    var usesArtworkClipboard: Bool {
        usesImageClipboard && !(imageClipboard?.elements.isEmpty ?? true)
    }

    /// The mixed payload shares the existing image-source lifetime and editor
    /// clipboard generation. Nothing publishes until both selected kinds pass.
    @discardableResult
    func copySelectedArtwork(cut: Bool = false,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            guard hasMixedArtworkSelection, let capture = captureArtworkSelection(), let image = capture.image,
                  var copied = currentFrame.projectedRasterFrame(on: image.layerID),
                  let appearance = layers.first(where: { $0.id == image.layerID }),
                  let record = retainedRasterFrames[image.assetID] else { throw StudioCommandError.staleRevision }
            let before = document, version = editor.clipboardVersion
            let oldImage = imageClipboard, oldLayer = copiedImageLayer, oldScope = imageClipboardEditorVersion
            let oldLayers = copiedArtworkLayers
            var candidate = editor
            try candidate.copyElements(frameID: capture.frameID, ids: capture.ids, checkCancellation: checkCancellation)
            guard let elements = candidate.clipboardElements else { throw StudioCommandError.staleClipboard }
            copied.elements = elements; copied.holdTicks = nil
            let layerIDs = Set(elements.compactMap(\.layerID)).union([image.layerID])
            let appearances = layers.filter { layerIDs.contains($0.id) }
            try validateManagedRaster(frame: copied, record: record)
            if cut {
                try candidate.deleteSelectedArtwork(frameID: capture.frameID, ids: capture.ids,
                    imageAssetID: image.assetID, imageLayerID: image.layerID, checkCancellation: checkCancellation)
                try preflightRasterDocument(candidate.document)
            }
            try checkCancellation()
            guard document == before, captureArtworkSelection() == capture, editor.clipboardVersion == version,
                  imageClipboard == oldImage, copiedImageLayer == oldLayer, imageClipboardEditorVersion == oldScope,
                  copiedArtworkLayers == oldLayers else { throw StudioCommandError.staleRevision }
            imageClipboard = copied; copiedImageLayer = appearance
            copiedArtworkLayers = appearances; copiedArtworkSchema = before.schemaVersion
            imageClipboardEditorVersion = candidate.clipboardVersion
            editor = candidate
            if cut { imageMoveTarget = nil; editor.selectedElementIDs.removeAll(); scheduleSave() }
            pruneManagedImages(); message = nil
            return true
        } catch is CancellationError {
            message = "Artwork clipboard operation cancelled. Nothing changed."; return false
        } catch { message = error.localizedDescription; return false }
    }

    /// Preserve layer appearance/order and document-space relative geometry.
    /// Fresh identities are allocated in one history transaction, never flattened.
    @discardableResult
    func pasteSelectedArtwork(checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            guard usesArtworkClipboard, canPasteImage, let copied = imageClipboard,
                  let sourceLayerID = copied.rasterLayerID, let assetID = copied.rasterAssetID,
                  let record = retainedRasterFrames[assetID], record.sourceImage != nil,
                  let index = document.frames.firstIndex(where: { $0.id == document.activeFrameID }) else {
                throw StudioDocumentError.unavailable("Copy selected artwork, then choose Move and an unlocked destination layer. Nothing changed.")
            }
            let before = document, version = editor.clipboardVersion, selected = selectedElementIDs
            let appearances = copiedArtworkLayers, schema = copiedArtworkSchema, scope = imageClipboardEditorVersion
            let selectionTarget = imageMoveTarget
            try validateManagedRaster(frame: copied, record: record)
            var candidate = editor
            var created = Set<String>()
            try candidate.change { value in
                try checkCancellation()
                guard copied.elements.count <= 20_000 - value.frames[index].elements.count else {
                    throw StudioDocumentError.invalid("This paste exceeds the frame's drawing limit.")
                }
                var layerMap: [String: String] = [:]
                var newLayers: [CanvasLayer] = []
                for appearance in appearances {
                    try checkCancellation()
                    let layer = CanvasLayer(id: UUID().uuidString, name: "Pasted artwork",
                        opacity: appearance.opacity, blendMode: appearance.blendMode,
                        glowEnabled: appearance.glowEnabled, glowColor: appearance.glowColor,
                        colorLabel: appearance.colorLabel, glowRadius: appearance.glowRadius, glowStrength: appearance.glowStrength)
                    layerMap[appearance.id] = layer.id; newLayers.append(layer)
                }
                guard let imageLayer = layerMap[sourceLayerID] else { throw StudioCommandError.staleClipboard }
                value.schemaVersion = max(value.schemaVersion, schema)
                if let primary = value.frames[index].rasterAssetID {
                    value.schemaVersion = max(value.schemaVersion, primary == assetID ? 27 : 31)
                }
                value.layers.insert(contentsOf: newLayers, at: 0)
                try value.frames[index].appendRasterInstance(.init(layerID: imageLayer,
                    placement: copied.rasterPlacement, reflection: copied.rasterReflection,
                    quarterTurns: copied.rasterQuarterTurns, crop: copied.rasterCrop,
                    rotationDegrees: copied.rasterRotationDegrees, regionMask: copied.rasterRegionMask), assetID: assetID)
                if copied.rasterRegionMask != nil { value.schemaVersion = max(value.schemaVersion, 32) }
                for element in copied.elements {
                    try checkCancellation()
                    guard let sourceLayer = element.layerID, let destination = layerMap[sourceLayer] else {
                        throw StudioCommandError.staleClipboard
                    }
                    let id = UUID().uuidString
                    value.frames[index].elements.append(DrawnElement(id: id, tool: element.tool, points: element.points,
                        color: element.color, width: element.width, opacity: element.opacity, fillColor: element.fillColor,
                        layerID: destination, brush: element.brush, shape: element.shape, fillMask: element.fillMask,
                        translation: element.translation, reflection: element.reflection, eraser: element.eraser,
                        text: element.text, transform: element.transform, smudge: element.smudge, blur: element.blur,
                        sharpen: element.sharpen, dodgeBurn: element.dodgeBurn, preservesLayerAlpha: element.preservesLayerAlpha,
                        selectionErasures: element.selectionErasures))
                    created.insert(id)
                }
                value.activeLayerID = imageLayer
            }
            try preflightRasterDocument(candidate.document)
            try checkCancellation()
            guard document == before, editor.clipboardVersion == version, imageClipboard == copied,
                  copiedArtworkLayers == appearances, copiedArtworkSchema == schema, imageClipboardEditorVersion == scope,
                  selectedElementIDs == selected, imageMoveTarget == selectionTarget, canPasteImage else {
                throw StudioCommandError.staleRevision
            }
            editor = candidate; editor.selectedElementIDs = created; imageMoveTarget = nil
            scheduleSave(); message = nil
            return true
        } catch { message = error.localizedDescription; return false }
    }

    var usesImageClipboard: Bool {
        imageClipboard != nil && imageClipboardEditorVersion == editor.clipboardVersion
    }
    var bottomImageSelection: ImageMoveCapture? {
        selectedElementIDs.isEmpty ? currentImageMoveCapture() : nil
    }
    var bottomCopyLabel: String {
        if selectedTool == .wand { return canEditImageRegion ? "Copy selected image region" : "Select an image region to copy" }
        if hasMixedArtworkSelection { return "Copy selected artwork" }
        if selectedTool == .lasso && (areaSelectionTarget == .image || validAreaImageSelection != nil) { return "Choose Move to copy the selected image" }
        if bottomImageSelection != nil { return "Copy selected image" }
        if isSelectingMixedArtwork { return "Select the image again before copying" }
        return selectedElementIDs.isEmpty ? "Copy frame" : selectedElementIDs.count == 1 ? "Copy selected drawing" : "Copy \(selectedElementIDs.count) selected drawings"
    }
    var bottomPasteLabel: String {
        if usesArtworkClipboard { return "Paste artwork" }
        if usesImageClipboard { return "Paste image" }
        return copiedDrawingCount == 1 ? "Paste drawing" : copiedDrawingCount > 0 ? "Paste \(copiedDrawingCount) drawings" : "Paste frame"
    }
    var canCopyBottomSelection: Bool {
        if selectedTool == .wand { return canEditImageRegion }
        if hasMixedArtworkSelection { return captureArtworkSelection() != nil }
        if selectedTool == .lasso && (areaSelectionTarget == .image || validAreaImageSelection != nil) { return false }
        if isSelectingMixedArtwork { return selectedElementIDs.isEmpty && bottomImageSelection != nil }
        return !isMovingImageOnCanvas || bottomImageSelection != nil
    }
    @discardableResult
    func deleteBottomImage(_ capture: ImageMoveCapture) -> Bool {
        guard bottomImageSelection == capture else {
            message = "The selected image changed. Select it again before deleting. Nothing was removed."
            return false
        }
        return deleteImage(capture.placement)
    }
    func copyBottomSelection() {
        if selectedTool == .wand {
            guard canEditImageRegion else { return }
            _ = applyImageRegion(.copy); return
        }
        guard canCopyBottomSelection else { return }
        if !selectedElementIDs.isEmpty { _ = copySelected() }
        else if bottomImageSelection != nil { _ = copyImage() }
        else { copyFrame() }
    }
    var hasCopiedImage: Bool { imageClipboard != nil }
    @discardableResult
    func copyImage() -> Bool {
        guard let capture = prepareImagePlacement(),
              let sourceLayer = layers.first(where: { $0.id == capture.layerID }),
              var copied = currentFrame.projectedRasterFrame(on: capture.layerID) else { return false }
        // Copy only the selected linked instance; immutable source bytes remain shared.
        copied.elements = []; copied.holdTicks = nil
        copiedImageLayer = sourceLayer
        imageClipboard = copied
        imageClipboardEditorVersion = editor.clipboardVersion
        pruneManagedImages()
        return true
    }
    var selectedImageCutCapture: ImageMoveCapture? {
        guard selectedElementIDs.isEmpty, let capture = currentImageMoveCapture(),
              capture.placement.layerID == activeLayerID else { return nil }
        return capture
    }
    /// Stage the selected instance's clipboard and deletion together. A failed
    /// or cancelled Cut never replaces an earlier successful copy.
    @discardableResult
    func cutSelectedImage(_ capture: ImageMoveCapture,
                          checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            guard selectedImageCutCapture == capture,
                  let layer = layers.first(where: { $0.id == capture.placement.layerID }),
                  var copied = currentFrame.projectedRasterFrame(on: capture.placement.layerID),
                  let record = retainedRasterFrames[capture.placement.assetID] else {
                throw StudioDocumentError.unavailable("Select the image on its active, visible, unlocked layer with Move before cutting. Nothing changed.")
            }
            copied.elements = []; copied.holdTicks = nil
            let before = document, previousClipboard = imageClipboard, previousLayer = copiedImageLayer
            let previousScope = imageClipboardEditorVersion, version = editor.clipboardVersion
            try checkCancellation()
            guard selectedImageCutCapture == capture, editor.clipboardVersion == version,
                  imageClipboard == previousClipboard, copiedImageLayer == previousLayer,
                  imageClipboardEditorVersion == previousScope else { throw StudioCommandError.staleRevision }
            try validateManagedRaster(frame: copied, record: record)
            var candidate = editor
            try candidate.deleteImage(frameID: capture.placement.frameID, assetID: capture.placement.assetID,
                layerID: capture.placement.layerID, checkCancellation: checkCancellation)
            try preflightRasterDocument(candidate.document)
            try checkCancellation()
            guard document == before, selectedImageCutCapture == capture, editor.clipboardVersion == version,
                  imageClipboard == previousClipboard, copiedImageLayer == previousLayer,
                  imageClipboardEditorVersion == previousScope else { throw StudioCommandError.staleRevision }
            // No throwing or suspension after publication begins. The clipboard
            // and editor history both retain the same immutable original bytes.
            imageClipboard = copied; copiedImageLayer = layer
            imageClipboardEditorVersion = candidate.clipboardVersion
            editor = candidate; imageMoveTarget = nil
            pruneManagedImages(); pruneManagedAudio(); scheduleSave()
            message = nil
            return true
        } catch is CancellationError {
            message = "Image Cut cancelled. No image was cut."; return false
        } catch { message = error.localizedDescription; return false }
    }
    var canPasteImage: Bool {
        isEditing && !isPlaying && !isSaving && selectedTool == .move &&
        activeStrokeID == nil && pendingBrushStroke == nil && textDraft == nil &&
        imageClipboard != nil && (currentFrame.rasterAssetID == nil || currentFrame.rasterPlacement != nil) &&
        currentFrame.rasterLayerInstances.count < 128 &&
        layers.contains { $0.id == activeLayerID && $0.visible && $0.opacity > 0 && !$0.isFullyLocked && $0.lockMode == "free" }
    }
    @discardableResult
    func pasteImage(checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        if usesArtworkClipboard { return pasteSelectedArtwork(checkCancellation: checkCancellation) }
        do {
            guard canPasteImage, let copied = imageClipboard, let appearance = copiedImageLayer, let assetID = copied.rasterAssetID,
                  let record = retainedRasterFrames[assetID], record.sourceImage != nil,
                  let index = document.frames.firstIndex(where: { $0.id == document.activeFrameID }) else {
                throw StudioDocumentError.unavailable("Copy an image, then choose an editable frame and an unlocked layer. Existing images are never replaced.")
            }
            let before = document, clipboardVersion = editor.clipboardVersion
            let selectedIDs = selectedElementIDs, clipboardScope = imageClipboardEditorVersion
            try checkCancellation()
            guard document == before, imageClipboard == copied, copiedImageLayer == appearance,
                  editor.clipboardVersion == clipboardVersion, imageClipboardEditorVersion == clipboardScope,
                  selectedElementIDs == selectedIDs, canPasteImage else { throw StudioCommandError.staleRevision }
            var candidate = editor
            let layer = CanvasLayer(id: UUID().uuidString, name: "Pasted image",
                opacity: appearance.opacity, blendMode: appearance.blendMode,
                glowEnabled: appearance.glowEnabled, glowColor: appearance.glowColor, colorLabel: appearance.colorLabel, glowRadius: appearance.glowRadius, glowStrength: appearance.glowStrength)
            try candidate.change { value in
                value.schemaVersion = max(value.schemaVersion, (layer.glowRadius != nil || layer.glowStrength != nil) ? 28 : 22)
                if copied.rasterRotationDegrees != nil { value.schemaVersion = max(value.schemaVersion, 30) }
                if let primary = value.frames[index].rasterAssetID { value.schemaVersion = max(value.schemaVersion, primary == assetID ? 27 : 31) }
                value.layers.append(layer)
                value.activeLayerID = layer.id
                try value.frames[index].appendRasterInstance(.init(layerID: layer.id,
                    placement: copied.rasterPlacement, reflection: copied.rasterReflection,
                    quarterTurns: copied.rasterQuarterTurns, crop: copied.rasterCrop,
                    rotationDegrees: copied.rasterRotationDegrees, regionMask: copied.rasterRegionMask), assetID: assetID)
                if copied.rasterRegionMask != nil { value.schemaVersion = max(value.schemaVersion, 32) }
            }
            guard let projected = candidate.document.frames[index].projectedRasterFrame(on: layer.id) else {
                throw StudioRasterImage.Failure.missing
            }
            try validateManagedRaster(frame: projected, record: record)
            try preflightRasterDocument(candidate.document)
            try checkCancellation()
            guard document == before, imageClipboard == copied, copiedImageLayer == appearance,
                  editor.clipboardVersion == clipboardVersion, imageClipboardEditorVersion == clipboardScope,
                  selectedElementIDs == selectedIDs, canPasteImage else { throw StudioCommandError.staleRevision }
            editor = candidate
            scheduleSave()
            return true
        } catch { message = error.localizedDescription; return false }
    }
    struct ImageRegionCapture: Equatable {
        let projectID: UUID, revision: Int, frameID: String, layerID: String, sourceID: String
        let instance: StudioRasterLayerInstance
    }
    private struct ImageRegionSelection {
        let capture: ImageRegionCapture
        let result: StudioImageRegionService.Result
    }
    @Published var wandTolerance: Double = 32 { didSet { cancelImageRegionWork() } }
    @Published var wandContiguous = true { didSet { cancelImageRegionWork() } }
    @Published var wandMode: StudioImageRegionService.Mode = .newSelection { didSet { cancelImageRegionWork() } }
    @Published var wandMoveX: Double = 0
    @Published var wandMoveY: Double = 0
    @Published private(set) var wandWorking = false
    @Published private(set) var wandSelectedPixels = 0
    @Published private(set) var wandPreviewPNG: Data?
    private var imageRegionSelection: ImageRegionSelection?
    private var imageRegionGeneration = UUID()
    private var imageRegionWorker: Task<StudioImageRegionService.Result?, Error>?
    private var imageRegionWorkerID: UUID?
    func cancelImageRegionWork() {
        imageRegionGeneration = UUID()
        imageRegionWorker?.cancel()
        // ImageIO decode/encode is bounded but cannot be interrupted midway.
        // Retain ownership and busy state until awaiting this worker completes.
        // Cancellation revokes publication immediately, not its memory lease.
        if imageRegionWorker == nil { wandWorking = false }
    }
    func clearImageRegion() {
        cancelImageRegionWork(); imageRegionSelection = nil; wandPreviewPNG = nil; wandSelectedPixels = 0
    }
    func captureImageRegion() throws -> ImageRegionCapture {
        guard isEditing, !isPlaying, !isSaving, selectedTool == .wand, activeStrokeID == nil,
              pendingBrushStroke == nil, textDraft == nil, selectedElementIDs.isEmpty,
              let instance = currentFrame.rasterInstance(on: activeLayerID), instance.placement != nil,
              let sourceID = currentFrame.rasterAssetID(on: activeLayerID), originalImageSource(sourceID) != nil,
              let layer = layers.first(where: { $0.id == activeLayerID }), layer.visible, layer.opacity == 1,
              !layer.isFullyLocked, layer.lockMode == "free", layer.blendMode == "normal", !layer.glowEnabled,
              !currentFrame.elements.contains(where: { $0.layerID == activeLayerID }) else { throw StudioImageRegionService.Failure.unavailable }
        return .init(projectID: document.id, revision: document.revision, frameID: currentFrame.id,
                     layerID: activeLayerID, sourceID: sourceID, instance: instance)
    }
    var canEditImageRegion: Bool {
        !wandWorking && imageRegionSelection != nil && (try? captureImageRegion()) == imageRegionSelection?.capture
    }
    @discardableResult
    func selectImageRegion(_ capture: ImageRegionCapture, at point: CGPoint) async -> Bool {
        guard imageRegionWorker == nil else {
            message = "The previous Wand selection is still finishing. Wait for it to finish before selecting again."
            return false
        }
        cancelImageRegionWork()
        let generation = imageRegionGeneration, owner = UUID()
        defer {
            // No later submission can acquire this lease before this await has
            // finished. Identity checking also prevents an older completion
            // from clearing any future owner's state.
            if imageRegionWorkerID == owner {
                imageRegionWorker = nil; imageRegionWorkerID = nil; wandWorking = false
            }
        }
        do {
            guard try captureImageRegion() == capture, let png = rasterData(capture.sourceID),
                  wandTolerance.isFinite, (0...128).contains(wandTolerance) else { throw StudioCommandError.staleRevision }
            let previous = imageRegionSelection?.capture == capture ? imageRegionSelection?.result.membership : nil
            let mode = wandMode, tolerance = Int(wandTolerance.rounded()), contiguous = wandContiguous
            wandWorking = true
            let worker = Task.detached(priority: .userInitiated) {
                try StudioImageRegionService.select(png: png, instance: capture.instance, point: point,
                    tolerance: tolerance, contiguous: contiguous, mode: mode, previous: previous)
            }
            imageRegionWorker = worker; imageRegionWorkerID = owner
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard imageRegionGeneration == generation, try captureImageRegion() == capture else { throw StudioCommandError.staleRevision }
            imageRegionSelection = result.map { .init(capture: capture, result: $0) }
            wandPreviewPNG = result?.fragmentPNG; wandSelectedPixels = result?.selectedPixels ?? 0
            message = nil
            return true
        } catch {
            if imageRegionGeneration == generation {
                message = error is CancellationError ? "Wand selection cancelled. Artwork is unchanged." : error.localizedDescription
            }
            return false
        }
    }
    enum ImageRegionAction { case copy, delete, move }
    @discardableResult
    func applyImageRegion(_ action: ImageRegionAction,
                          checkCancellation: () throws -> Void = { try Task.checkCancellation() }) -> Bool {
        do {
            guard canEditImageRegion, let selected = imageRegionSelection,
                  retainedRasterFrames[selected.capture.sourceID]?.sourceImage != nil,
                  let layer = layers.first(where: { $0.id == selected.capture.layerID }) else { throw StudioImageRegionService.Failure.empty }
            let before = document, generation = imageRegionGeneration, version = editor.clipboardVersion
            let oldClipboard = imageClipboard, oldAppearance = copiedImageLayer, oldArtwork = copiedArtworkLayers
            let scope = imageClipboardEditorVersion, oldSelection = selectedElementIDs
            let dx = wandMoveX, dy = wandMoveY
            if case .move = action {
                guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { throw StudioImageRegionService.Failure.invalid }
            }
            try checkCancellation()
            var next = retainedRasterFrames, candidate = editor
            var copied: AnimationFrame?
            switch action {
            case .copy:
                guard var frame = currentFrame.projectedRasterFrame(on: selected.capture.layerID) else { throw StudioImageRegionService.Failure.invalid }
                frame.elements = []; frame.holdTicks = nil
                let fragment = try StudioImageRegionService.fragmentInstance(selected.result, original: selected.capture.instance, checkCancellation: checkCancellation)
                try frame.updateRasterInstance(fragment); copied = frame
            case .delete, .move:
                let operation: StudioDocumentEditor.ImageRegionAction
                if case .move = action { operation = .move(dx: dx, dy: dy) } else { operation = .delete }
                try candidate.editImageRegion(frameID: selected.capture.frameID, layerID: selected.capture.layerID,
                    sourceID: selected.capture.sourceID, expected: selected.capture.instance,
                    fragment: try StudioImageRegionService.fragmentInstance(selected.result, original: selected.capture.instance, checkCancellation: checkCancellation),
                    remainderMask: selected.result.remainderMask, fragmentLayerID: UUID().uuidString,
                    action: operation, checkCancellation: checkCancellation)
            }
            let needed = candidate.referencedRasterAssetIDsIncludingHistoryAndClipboard.union((copied ?? imageClipboard)?.referencedRasterAssetIDs ?? [])
            next = next.filter { $0.value.sourceImage == nil || needed.contains($0.key) }
            try validateManagedImageCapacity(next)
            try storage.preflightAnimation(storageProject(candidate.document, rasters: next))
            try checkCancellation()
            guard document == before, imageRegionGeneration == generation, canEditImageRegion,
                  try captureImageRegion() == selected.capture, editor.clipboardVersion == version,
                  imageClipboard == oldClipboard, copiedImageLayer == oldAppearance, copiedArtworkLayers == oldArtwork,
                  imageClipboardEditorVersion == scope, selectedElementIDs == oldSelection,
                  wandMoveX == dx, wandMoveY == dy else { throw StudioCommandError.staleRevision }
            retainedRasterFrames = next
            if let copied {
                imageClipboard = copied; copiedImageLayer = layer; copiedArtworkLayers = []; copiedArtworkSchema = 32
                imageClipboardEditorVersion = version
                message = "Copied \(selected.result.selectedPixels) image pixels. Choose Move to paste a separate image."
            } else {
                editor = candidate; clearImageRegion(); scheduleSave(); message = nil
            }
            return true
        } catch { message = error is CancellationError ? "Wand action cancelled. Artwork and clipboard are unchanged." : error.localizedDescription; return false }
    }

    private func imageRegionContains(_ point: CGPoint, layerID: String) -> Bool {
        guard let instance = currentFrame.rasterInstance(on: layerID), let mask = instance.regionMask else { return true }
        guard let source = try? StudioImageRegionService.sourcePoint(point, instance: instance, width: mask.width, height: mask.height) else { return false }
        return mask.contains(x: Int(floor(source.x)), y: Int(floor(source.y)))
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
            if let mask = frame.rasterRegionMask {
                try mask.validate()
                guard mask.width == source.normalizedWidth, mask.height == source.normalizedHeight else { throw StudioRasterImage.Failure.invalid }
            }
        } else if frame.rasterPlacement != nil { throw StudioRasterImage.Failure.missing }
    }
    private func storageProject(_ snapshot: StudioDocument, rasters: [String: StoredAnimationFrame],
                                audioTracks: [AudioTrack]? = nil) throws -> AnimationProject {
        for frame in snapshot.frames {
            for instance in frame.rasterLayerInstances {
                if let mask = instance.regionMask {
                    guard let asset = frame.rasterAssetID(on: instance.layerID), let source = rasters[asset]?.sourceImage,
                          mask.width == source.normalizedWidth, mask.height == source.normalizedHeight else { throw StudioRasterImage.Failure.invalid }
                }
            }
        }
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
        var additional: [String: StoredAnimationFrame] = [:]
        for asset in snapshot.referencedRasterAssetIDs.subtracting(Set(indices.keys)) {
            guard let record = rasters[asset], let source = record.sourceImage,
                  asset == "image-" + source.id.uuidString, record.imageData?.isEmpty == false,
                  record.layerData == nil, record.legacyFrameIndex == nil else { throw StudioRasterImage.Failure.missing }
            additional[asset] = record
        }
        let metadata = AnimationMetadata(id: snapshot.id, title: snapshot.name, fps: snapshot.fps,
            canvasWidth: snapshot.width, canvasHeight: snapshot.height, frameCount: snapshot.frames.count,
            layerCount: snapshot.layers.count, createdAt: snapshot.createdAt, modifiedAt: snapshot.modifiedAt, thumbnailData: projectThumbnailData)
        return AnimationProject(id: snapshot.id, metadata: metadata, frames: frames,
            audioTracks: try audioTracks ?? audioTracksForSave(snapshot),
            editableDocumentData: try StudioDocumentArchive(document: snapshot, rasterFrameIndices: indices).encoded(),
            additionalImageAssets: additional.isEmpty ? nil : additional)
    }
    private func preflightRasterDocument(_ candidate: StudioDocument) throws {
        guard !candidate.referencedRasterAssetIDs.isEmpty || candidate.frames.contains(where: {
            $0.elements.contains(where: { $0.fillMask != nil })
        }) else { return }
        try storage.preflightAnimation(storageProject(candidate, rasters: retainedRasterFrames))
    }
    private func pruneManagedImages() {
        let needed = editor.referencedRasterAssetIDsIncludingHistoryAndClipboard.union(imageClipboard?.referencedRasterAssetIDs ?? [])
        retainedRasterFrames = retainedRasterFrames.filter { $0.value.sourceImage == nil || needed.contains($0.key) }
    }
    func rasterData(_ assetID: String?) -> Data? { assetID.flatMap { retainedRasterFrames[$0]?.imageData } }
    func rasterSources(for frame: AnimationFrame) -> [String: Data] {
        frame.referencedRasterAssetIDs.reduce(into: [:]) { result, assetID in
            if let data = rasterData(assetID) { result[assetID] = data }
        }
    }
    func undo() {
        stopPlayback(); let before = document
        command { $0.undo() }
        if document != before { clearElementSelection() }
    }
    func redo() {
        stopPlayback(); let before = document
        command { $0.redo() }
        if document != before { clearElementSelection() }
    }
    func togglePlayback() { if isPlaying { stopPlayback() } else { startPlayback() } }
    private var playbackTick: Int?
    private func startPlayback() {
        guard allowDocumentEditDuringInput() else { return }
        guard document.totalTimelineTicks > 1 else { return }
        playbackTick = document.startTick(ofFrame: currentFrameIndex)
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
        let tick = ((playbackTick ?? document.startTick(ofFrame: currentFrameIndex)) + 1) % document.totalTimelineTicks
        playbackTick = tick
        playbackFrameIndex = document.frameIndex(atTick: tick)
        audioPlayheadTime = Double(tick) / Double(fps)
    }
    func stopPlayback() { isPlaying = false; playbackTimer?.invalidate(); playbackTimer = nil; playbackFrameIndex = nil; playbackTick = nil }
}

enum StudioPanelType: String {
    case none, colorPicker, gradientEndColor, toolSettings, projectSettings, layers, export, framesViewer, audioTimeline
    case soundLibrary, stickerEmoji, addImage, backgroundLibrary, menu, aiVoice, spatterAI, magicCut, rotoscope
}
extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Area selection encloses whole editable drawings, rather than altering pixels.
/// The exact same region is used for the visible outline and selected IDs.
enum StudioAreaSelectionKind: String, Codable, CaseIterable {
    case freehand, rectangle, polygon
    var label: String {
        switch self { case .freehand: return "Freehand"; case .rectangle: return "Rectangle"; case .polygon: return "Polygon" }
    }
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
                let weight = distance > 0 ? min(0.5, CGFloat(kind == .polygon ? 0 : smoothing) / distance) : 0
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
        guard corners.allSatisfy({ path.cgPath.contains($0, using: .evenOdd) || onBoundary($0) }) else { return false }
        // Corner-only tests incorrectly select a drawing cut through by a
        // concave lasso. Reject any outline edge entering its open bounds.
        let inner = rect.insetBy(dx: min(0.0001, rect.width / 4), dy: min(0.0001, rect.height / 4))
        for i in points.indices where segmentIntersects(points[i], points[(i + 1) % points.count], inner) { return false }
        return true
    }
    /// Whole rotated-image enclosure, not enclosure of its axis-aligned bounds.
    /// The image polygon is convex. A concave lasso must not enter its open interior.
    func containsImage(placement: StudioRasterPlacement, angle: Double) -> Bool {
        let geometry = StudioImageRotationGeometry(placement: placement, degrees: angle)
        let corners = geometry.corners
        // SwiftUI Path's even-odd hit test can misclassify an interior point
        // aligned with a rotated polygon vertex. Use the canonical CGPath
        // even-odd operation; retain exact edge inclusion and concavity checks.
        guard corners.allSatisfy({ path.cgPath.contains($0, using: .evenOdd) || onBoundary($0) }) else { return false }
        let radians = -angle * .pi / 180, cosine = cos(radians), sine = sin(radians)
        let center = geometry.center
        func local(_ point: CGPoint) -> CGPoint {
            let x = point.x - center.x, y = point.y - center.y
            return .init(x: center.x + x * cosine - y * sine, y: center.y + x * sine + y * cosine)
        }
        let inner = CGRect(x: placement.x, y: placement.y, width: placement.width, height: placement.height)
            .insetBy(dx: min(0.0001, placement.width / 4), dy: min(0.0001, placement.height / 4))
        for i in points.indices {
            if segmentIntersects(local(points[i]), local(points[(i + 1) % points.count]), inner) { return false }
        }
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
        var selectionMode: StudioViewModel.SelectionMode? = nil
        var areaSelectionKind: StudioAreaSelectionKind? = nil
        var areaSelectionSmoothing: Double? = nil
        var fillTolerance: Double? = nil
        var fillExpand: Double? = nil
        var fillGapClose: Double? = nil
        var fillContiguous: Bool? = nil
        var fillAntiAlias: Bool? = nil
        var fillSampleAll: Bool? = nil
        var eraserMode: StudioEraserMode? = nil
        var textStyle: StudioTextStyle? = nil
        var blurHardness: Double? = nil
        var blurRadius: Double? = nil
        var sharpenHardness: Double? = nil
        var sharpenRadius: Double? = nil
        var sharpenAmount: Double? = nil
        var sharpenThreshold: Double? = nil
        var dodgeBurnHardness: Double? = nil
        var dodgeBurnExposure: Double? = nil
        var dodgeBurnRange: StudioDodgeBurn.TonalRange? = nil
        var dodgeBurnProtectTones: Bool? = nil
        var lineAngleSnap: Double? = nil
        var equalShapeSides: Bool? = nil
        var lineRulerEnabled: Bool? = nil
        var lineRulerAngle: Double? = nil
        var lineRulerFixedLength: Bool? = nil
        var lineRulerLength: Double? = nil
        var mirrorMode: StudioMirrorMode? = nil
        var pressureSensitivity: Bool? = nil
        var pencilTiltEnabled: Bool? = nil
        var lineArrowEnds: StudioArrowEnds? = nil
        var lineArrowLength: Double? = nil

        var isValid: Bool {
            (areaSelectionSmoothing.map { $0.isFinite && (0...10).contains($0) } ?? true) &&
            (fillTolerance.map { $0.isFinite && (0...128).contains($0) } ?? true) &&
            (fillExpand.map { $0.isFinite && (-5...5).contains($0) } ?? true) &&
            (fillGapClose.map { $0.isFinite && (0...5).contains($0) } ?? true) &&
            (lineArrowLength.map { $0.isFinite && (1...100).contains($0) } ?? true) &&
            (lineRulerAngle.map { $0.isFinite && (-180...180).contains($0) } ?? true) &&
            (lineRulerLength.map { $0.isFinite && (1...4096).contains($0) } ?? true) &&
            (lineAngleSnap.map { [0.0, 15, 45, 90].contains($0) } ?? true) &&
            width.isFinite && (0.25...512).contains(width) &&
            opacity.isFinite && (0...1).contains(opacity) &&
            smoothing.isFinite && (0...10).contains(smoothing) &&
            tipAngle.isFinite && (0..<180).contains(tipAngle) &&
            texture.isFinite && (0...1).contains(texture) &&
            grain.isFinite && (0...1).contains(grain) &&
            cornerRadius.isFinite && (0...50).contains(cornerRadius) &&
            (try? gradientEnd.validate()) != nil && gradientEnd.alpha == 1 &&
            (textStyle?.isValid ?? true) &&
            (blurHardness.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
            (blurRadius.map { $0.isFinite && (0.5...32).contains($0) } ?? true) &&
            (sharpenHardness.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
            (sharpenRadius.map { $0.isFinite && (0.5...32).contains($0) } ?? true) &&
            (sharpenAmount.map { $0.isFinite && (0...2).contains($0) } ?? true) &&
            (sharpenThreshold.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
            (dodgeBurnHardness.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
            (dodgeBurnExposure.map { $0.isFinite && (0...1).contains($0) } ?? true)
        }
        static func defaults(for tool: DrawingTool) -> Self {
            var value = Self()
            switch tool {
            case .pencil: value.width = 2; value.smoothing = 2
            case .pen: value.family = .roughPen
            case .marker: value.width = 12; value.opacity = 0.75; value.family = .calligraphy
            case .crayon: value.width = 8; value.opacity = 0.9; value.family = .grain; value.smoothing = 1
            case .eraser: value.width = 8
            case .smudge: value.width = 24; value.smoothing = 0
            case .blur: value.width = 32; value.opacity = 0.5; value.smoothing = 0
                value.blurHardness = 0.5; value.blurRadius = 4
            case .sharpen: value.width = 32; value.opacity = 1; value.smoothing = 0
                value.sharpenHardness = 0.5; value.sharpenRadius = 2
                value.sharpenAmount = 0.5; value.sharpenThreshold = 0.02
            case .dodge, .burn: value.width = 32; value.opacity = 1; value.smoothing = 0
                value.dodgeBurnHardness = 0.5; value.dodgeBurnExposure = 0.25
                value.dodgeBurnRange = .midtones; value.dodgeBurnProtectTones = true
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
