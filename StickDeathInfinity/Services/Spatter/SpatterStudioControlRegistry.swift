import Foundation

// MARK: - Studio control registry (#204)

/// Every visible Studio control and how Spatter may reach it. A control is
/// either reachable through named local instruction grammars (which prepare the
/// same typed StudioCommand the manual control uses), manual only (Spatter can
/// explain it but never performs it), or deliberately blocked (Spatter refuses
/// even when asked, because the action needs the user's own explicit step).
///
/// This is data, not authority: Apply still runs only the grammar parsers and the
/// typed command executor. `validate()` keeps the registry and the instruction
/// catalogue from drifting apart, so Spatter never offers an edit it cannot run
/// and never claims a control is unreachable when a grammar exists.
enum SpatterStudioControlRegistry {
    enum Surface: String, CaseIterable {
        /// The single white floating primary toolbar.
        case toolbar
        /// Drawing tools that exist in documents but have no toolbar button.
        case hiddenTool
        /// The single dismissible options popup and the Studio panels.
        case panel
        /// Header, timeline and canvas controls.
        case header, timeline, canvas
    }
    enum Route: Equatable {
        case instructions([String])
        case manual(String)
        case blocked(String)
    }
    struct Control: Equatable {
        let id: String
        let surface: Surface
        let title: String
        let route: Route
        var grammars: [String] {
            if case .instructions(let names) = route { return names }
            return []
        }
        /// One factual sentence Spatter can show about this control.
        var explanation: String {
            switch route {
            case .instructions(let names):
                let list = names.count == 1 ? "the " + names[0] + " instruction" : "these instructions: " + names.joined(separator: ", ")
                return "\(title): Spatter can prepare \(list) for this control. You still choose Apply, and one Undo reverses it."
            case .manual(let reason): return "\(title): manual only. \(reason)"
            case .blocked(let reason): return "\(title): Spatter will not do this. \(reason)"
            }
        }
    }

    static let selectionNote = "Selections are made by touch on the canvas; Spatter uses the selection you made and never draws one."
    static let pixelToolNote = "This touch tool edits pixels under your finger; Spatter has no instruction for it, so use the tool directly."
    static let viewNote = "View navigation only. It never changes the project, so Spatter does not operate it."
    static let freehandNote = "Spatter has no instruction for this tool yet. Draw with the tool directly; Spatter's brush-stroke instruction covers brush families only."

    /// Panel keys are StudioPanelType raw values. The SwiftUI panel maps the
    /// enum with an exhaustive switch, so a new panel cannot compile unmapped.
    static let controls: [Control] = [
        // Primary toolbar, in the toolbar's order.
        .init(id: "tool.move", surface: .toolbar, title: "Move", route: .instructions([
            "selectionTranslate", "selectionTransform", "selectionReflect", "drawingDuplicate", "artworkOrder",
            "imageReflection", "imageRotation", "imageCrop", "imagePlacement", "textUpdate", "selectByID"])),
        .init(id: "tool.lasso", surface: .toolbar, title: "Lasso", route: .manual(selectionNote)),
        .init(id: "tool.wand", surface: .toolbar, title: "Wand", route: .manual(selectionNote)),
        .init(id: "tool.brush", surface: .toolbar, title: "Brush", route: .instructions(["brushStroke"])),
        .init(id: "tool.pencil", surface: .toolbar, title: "Pencil", route: .manual(freehandNote)),
        .init(id: "tool.pen", surface: .toolbar, title: "Pen", route: .manual(freehandNote)),
        .init(id: "tool.marker", surface: .toolbar, title: "Marker", route: .manual(freehandNote)),
        .init(id: "tool.crayon", surface: .toolbar, title: "Crayon", route: .manual(freehandNote)),
        .init(id: "tool.line", surface: .toolbar, title: "Line", route: .manual("Draw single lines directly. Spatter's stick-figure and brief instructions generate whole frames of lines on new layers instead.")),
        .init(id: "tool.rectangle", surface: .toolbar, title: "Rect", route: .manual("Draw rectangles directly; Spatter has no rectangle instruction.")),
        .init(id: "tool.circle", surface: .toolbar, title: "Circle", route: .manual("Draw single circles directly. Spatter's circle-motion instruction appends whole frames of a moving circle on a new layer instead.")),
        .init(id: "tool.fill", surface: .toolbar, title: "Fill", route: .instructions(["fill"])),
        .init(id: "tool.eyedropper", surface: .toolbar, title: "Dropper", route: .manual("Sampling a color reads the canvas under your finger; give colors to Spatter as #RRGGBB instead.")),
        .init(id: "tool.eraser", surface: .toolbar, title: "Eraser", route: .instructions(["selectedErasure"])),
        .init(id: "tool.smudge", surface: .toolbar, title: "Smudge", route: .manual(pixelToolNote)),
        .init(id: "tool.sharpen", surface: .toolbar, title: "Sharpen", route: .manual(pixelToolNote)),
        .init(id: "tool.dodge", surface: .toolbar, title: "Dodge", route: .manual(pixelToolNote)),
        .init(id: "tool.burn", surface: .toolbar, title: "Burn", route: .manual(pixelToolNote)),
        .init(id: "tool.blur", surface: .toolbar, title: "Blur", route: .manual(pixelToolNote)),
        .init(id: "tool.text", surface: .toolbar, title: "Text", route: .instructions(["textUpdate"])),
        .init(id: "tool.hand", surface: .toolbar, title: "Hand", route: .manual(viewNote)),
        .init(id: "tool.zoom", surface: .toolbar, title: "Zoom", route: .manual(viewNote)),
        // Tools present in the document model without a toolbar button.
        .init(id: "tool.arrow", surface: .hiddenTool, title: "Arrow", route: .manual("Not on the Studio toolbar; existing arrow drawings stay editable with Move.")),
        .init(id: "tool.image", surface: .hiddenTool, title: "Image", route: .manual("Pictures are added from Add Picture; Spatter can only open that picker for you to choose.")),
        .init(id: "tool.ruler", surface: .hiddenTool, title: "Ruler", route: .manual("Not on the Studio toolbar.")),
        .init(id: "tool.gradient", surface: .hiddenTool, title: "Gradient", route: .instructions(["brushStroke"])),
        .init(id: "tool.airbrush", surface: .hiddenTool, title: "Airbrush", route: .instructions(["brushStroke"])),
        .init(id: "tool.watercolor", surface: .hiddenTool, title: "Watercolor", route: .instructions(["brushStroke"])),
        .init(id: "tool.neon", surface: .hiddenTool, title: "Neon", route: .instructions(["brushStroke"])),
        .init(id: "tool.calligraphy", surface: .hiddenTool, title: "Calligraphy", route: .instructions(["brushStroke"])),
        // Panels and the single options popup.
        .init(id: "panel.none", surface: .canvas, title: "Canvas", route: .instructions(["navigation"])),
        .init(id: "panel.colorPicker", surface: .panel, title: "Color picker", route: .manual("Choosing a color is manual; instructions take colors inline as #RRGGBB.")),
        .init(id: "panel.gradientEndColor", surface: .panel, title: "Gradient end color", route: .manual("Gradient brush instructions take both colors inline as #RRGGBB to #RRGGBB.")),
        .init(id: "panel.shapeFillColor", surface: .panel, title: "Shape fill color", route: .manual("Choosing a shape fill color is manual.")),
        .init(id: "panel.toolSettings", surface: .panel, title: "Tool options popup", route: .manual("Tool sizes, opacity, Hand, Zoom and Fit are set in the options popup by touch; instructions carry their own size and opacity.")),
        .init(id: "panel.projectSettings", surface: .panel, title: "Project settings", route: .instructions(["projectSettings", "projectRename", "grid", "onionSkin"])),
        .init(id: "panel.layers", surface: .panel, title: "Layers", route: .instructions([
            "layerStructure", "layerDuplicate", "layerUpdate", "layerGlow", "layerOrder", "navigation"])),
        .init(id: "panel.export", surface: .panel, title: "Export", route: .blocked("Exports start only from Export or from the direct-export button after a saved Spatter edit. Spatter never exports, uploads or publishes on its own.")),
        .init(id: "panel.framesViewer", surface: .panel, title: "Frames", route: .instructions([
            "frameAction", "frameCut", "frameExposure", "frameReverse", "frameDuplicateRange", "frameClipboard", "tween", "navigation"])),
        .init(id: "panel.audioTimeline", surface: .panel, title: "Audio timeline", route: .instructions(["audioClip", "audioTrack"])),
        .init(id: "panel.soundLibrary", surface: .panel, title: "Sound library", route: .manual("You choose, preview and add licensed sounds yourself; Spatter edits clips already on the timeline.")),
        .init(id: "panel.stickerEmoji", surface: .panel, title: "Stickers", route: .manual("Stickers are placed by touch.")),
        .init(id: "panel.addImage", surface: .panel, title: "Add picture", route: .blocked("Spatter can open the picture picker, but you choose, preview and Add the picture yourself. No file path or URL is accepted from an instruction.")),
        .init(id: "panel.backgroundLibrary", surface: .panel, title: "Backgrounds", route: .manual("Backgrounds are chosen and added by you; generated background images are not available.")),
        .init(id: "panel.menu", surface: .panel, title: "Studio menu", route: .manual("Menu commands such as saving copies are performed by you.")),
        .init(id: "panel.aiVoice", surface: .panel, title: "Voice", route: .manual("Voice recording and import are started by you; Spatter edits the resulting clip only after it is on the timeline.")),
        .init(id: "panel.spatterAI", surface: .panel, title: "Spatter", route: .instructions([
            "batch", "multiClauseBrief", "sceneBrief", "twoActorBrief", "stickFigure", "circleMotion", "sourceReference"])),
        .init(id: "panel.magicCut", surface: .panel, title: "Magic Cut", route: .manual("Background removal runs from its own panel after you review the preview.")),
        .init(id: "panel.rotoscope", surface: .panel, title: "Rotoscope", route: .manual("Video frame import is chosen and confirmed by you.")),
        // Header and timeline controls.
        .init(id: "header.undo", surface: .header, title: "Undo", route: .manual("Studio Undo is yours. A Spatter receipt offers Undo Spatter edit only while that edit is still the latest change.")),
        .init(id: "header.redo", surface: .header, title: "Redo", route: .manual("Studio Redo is yours to use.")),
        .init(id: "header.save", surface: .header, title: "Save", route: .manual("Projects autosave on this device; Spatter never saves, uploads or shares a project.")),
        .init(id: "header.back", surface: .header, title: "Projects", route: .manual("Leaving the editor closes the Spatter session and cancels pending work.")),
        .init(id: "header.copy", surface: .header, title: "Copy", route: .manual("Copying drawings to the clipboard is manual; Spatter's duplicate instruction keeps your clipboard unchanged.")),
        .init(id: "header.paste", surface: .header, title: "Paste", route: .manual("Pasting drawings is manual. Spatter pastes frames only, through the frame clipboard instruction.")),
        .init(id: "header.delete-selection", surface: .header, title: "Delete selection", route: .manual("Spatter does not delete selected artwork; use Delete and Undo.")),
        .init(id: "timeline.play", surface: .timeline, title: "Play", route: .manual("Playback is yours. Most Spatter edits are refused while playback runs; stop it first.")),
        .init(id: "timeline.add-frame", surface: .timeline, title: "Add frame", route: .instructions(["frameAction"])),
        .init(id: "timeline.add-layer", surface: .timeline, title: "Add layer", route: .instructions(["layerStructure"])),
        .init(id: "timeline.frame-menu", surface: .timeline, title: "Frame menu", route: .instructions([
            "frameAction", "frameCut", "frameExposure", "frameClipboard", "tween"])),
        .init(id: "timeline.frame-timing", surface: .timeline, title: "Frame timing", route: .instructions([
            "frameExposure", "frameReverse", "frameDuplicateRange"]))
    ]

    static func control(id: String) -> Control? { controls.first { $0.id == id } }
    static func control(for tool: DrawingTool) -> Control? { control(id: "tool." + tool.rawValue) }
    /// `key` is a StudioPanelType raw value.
    static func control(forPanel key: String) -> Control? { control(id: "panel." + key) }
    /// Every StudioPanelType raw value the registry expects. The SwiftUI panel's
    /// exhaustive switch and the edit-session suite keep this list complete.
    static let panelKeys = ["none", "colorPicker", "gradientEndColor", "shapeFillColor", "toolSettings", "projectSettings", "layers",
                            "export", "framesViewer", "audioTimeline", "soundLibrary", "stickerEmoji", "addImage", "backgroundLibrary",
                            "menu", "aiVoice", "spatterAI", "magicCut", "rotoscope"]

    /// Controls through which a grammar is reachable; empty means unreachable.
    static func controls(forGrammar name: String) -> [Control] { controls.filter { $0.grammars.contains(name) } }

    /// Every problem found; empty means the registry matches the catalogue,
    /// the drawing tools and the panel list exactly.
    static func validate(catalogNames: [String] = SpatterInstructionCatalog.names) -> [String] {
        var problems: [String] = []
        var seen = Set<String>()
        for control in controls {
            if !seen.insert(control.id).inserted { problems.append("duplicate control \(control.id)") }
            if control.title.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("untitled control \(control.id)") }
            switch control.route {
            case .instructions(let names):
                if names.isEmpty { problems.append("\(control.id) lists no grammar") }
                if Set(names).count != names.count { problems.append("\(control.id) repeats a grammar") }
                for name in names where !catalogNames.contains(name) { problems.append("\(control.id) names unknown grammar \(name)") }
            case .manual(let reason), .blocked(let reason):
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.count > 240 { problems.append("\(control.id) needs a 1–240 character reason") }
            }
        }
        for tool in DrawingTool.allCases where control(for: tool) == nil { problems.append("drawing tool \(tool.rawValue) has no control") }
        for control in controls where control.surface == .toolbar || control.surface == .hiddenTool {
            if !control.id.hasPrefix("tool.") || DrawingTool(rawValue: String(control.id.dropFirst(5))) == nil {
                problems.append("\(control.id) is not a real drawing tool")
            }
        }
        for key in panelKeys where control(forPanel: key) == nil { problems.append("panel \(key) has no control") }
        for control in controls where control.id.hasPrefix("panel.") && !panelKeys.contains(String(control.id.dropFirst(6))) {
            problems.append("\(control.id) is not a known panel")
        }
        for name in catalogNames where controls(forGrammar: name).isEmpty { problems.append("grammar \(name) is reachable from no control") }
        return problems
    }
}

// MARK: - Context snapshot (#203)

/// A bounded, typed description of what Spatter can see in Studio right now:
/// screen, tool, selection, active layer and frame, and document statistics.
/// It holds counts, settings and identifiers only; no artwork, audio bytes,
/// file paths or credentials. Names are truncated. It is read-only context for
/// explanations and for the plan preview; Apply still recaptures the live editor.
struct SpatterContextSnapshot: Codable, Equatable {
    /// Screen facts that live outside the document (the view model supplies them).
    struct Screen: Equatable {
        var toolRawValue: String?
        var panelKey: String
        var selectedDrawingCount: Int
        var selectedImageCount: Int
        var selectedAudioClipID: String?
        var displayedFrameID: String?
        var isPlaying: Bool
        var isDirty: Bool
        var isSaving: Bool
        var canUndo: Bool
        var canRedo: Bool
    }
    enum Readiness: Equatable {
        case ready
        case needs(String)
    }
    static let maximumNameLength = 80
    static let maximumSelection = 4096
    static let maximumElementTotal = 1_000_000

    let projectID: UUID
    let revision: Int
    let width: Int, height: Int, fps: Int
    let frameCount: Int
    /// One-based positions; nil only when the identifier is not in the document.
    let activeFrameNumber: Int?
    let displayedFrameNumber: Int?
    let activeFrameID: String
    let totalTicks: Int
    let durationSeconds: Double
    let layerCount: Int
    let activeLayerNumber: Int?
    let activeLayerID: String
    let activeLayerName: String
    let activeLayerVisible: Bool
    let activeLayerLockMode: String
    let activeFrameElementCount: Int
    let documentElementCount: Int
    let framesWithImages: Int
    let audioClipCount: Int
    let selectedAudioClipKnown: Bool
    let gridEnabled: Bool
    let onionEnabled: Bool
    let tool: String?
    let panel: String
    let selectedDrawingCount: Int
    let selectedImageCount: Int
    let isPlaying: Bool, isDirty: Bool, isSaving: Bool, canUndo: Bool, canRedo: Bool

    init(document: StudioCommandContext, screen: Screen) {
        projectID = document.projectID; revision = document.revision
        width = document.width; height = document.height; fps = max(1, document.fps)
        frameCount = document.frames.count
        activeFrameID = document.activeFrameID
        activeFrameNumber = document.frames.firstIndex { $0.id == document.activeFrameID }.map { $0 + 1 }
        displayedFrameNumber = screen.displayedFrameID.flatMap { id in document.frames.firstIndex { $0.id == id }.map { $0 + 1 } }
        let ticks = document.frames.reduce(0) { $0 + max(1, $1.durationTicks) }
        totalTicks = ticks
        durationSeconds = Double(ticks) / Double(max(1, document.fps))
        layerCount = document.layers.count
        activeLayerID = document.activeLayerID
        activeLayerNumber = document.layers.firstIndex { $0.id == document.activeLayerID }.map { $0 + 1 }
        let layer = document.layers.first { $0.id == document.activeLayerID }
        activeLayerName = String((layer?.name ?? "Unavailable layer").prefix(Self.maximumNameLength))
        activeLayerVisible = layer?.visible ?? false
        activeLayerLockMode = layer.map { $0.isFullyLocked ? "full" : String($0.lockMode.prefix(16)) } ?? "unknown"
        activeFrameElementCount = document.frames.first { $0.id == document.activeFrameID }?.elementCount ?? 0
        documentElementCount = min(Self.maximumElementTotal, document.frames.reduce(0) { $0 + $1.elementCount })
        framesWithImages = document.frames.filter { $0.imageAssetID != nil }.count
        audioClipCount = document.editableAudioClips.count
        selectedAudioClipKnown = screen.selectedAudioClipID.map { id in document.editableAudioClips.contains { $0.id == id } } ?? false
        gridEnabled = document.gridEnabled; onionEnabled = document.onionEnabled
        tool = screen.toolRawValue.flatMap { DrawingTool(rawValue: $0)?.rawValue }
        panel = SpatterStudioControlRegistry.panelKeys.contains(screen.panelKey) ? screen.panelKey : "unknown"
        selectedDrawingCount = min(Self.maximumSelection, max(0, screen.selectedDrawingCount))
        selectedImageCount = min(1, max(0, screen.selectedImageCount))
        isPlaying = screen.isPlaying; isDirty = screen.isDirty; isSaving = screen.isSaving
        canUndo = screen.canUndo; canRedo = screen.canRedo
    }

    /// True when an answer or plan built from `self` no longer describes `current`:
    /// another project, a later revision, or a different frame, layer, tool or selection.
    func isStale(comparedTo current: SpatterContextSnapshot) -> Bool {
        projectID != current.projectID || revision != current.revision || activeFrameID != current.activeFrameID
            || activeLayerID != current.activeLayerID || tool != current.tool
            || selectedDrawingCount != current.selectedDrawingCount || selectedImageCount != current.selectedImageCount
            || selectedAudioClipKnown != current.selectedAudioClipKnown || isPlaying != current.isPlaying
    }

    /// Whether a grammar's preconditions hold in this snapshot. This is guidance
    /// only; Apply re-validates everything against the live editor.
    func readiness(of grammar: String) -> Readiness {
        if isSaving { return .needs("Wait for the current save to finish.") }
        if isPlaying { return .needs("Stop playback first.") }
        let move = tool == DrawingTool.move.rawValue
        switch grammar {
        case "selectionTranslate", "selectionTransform", "selectionReflect", "drawingDuplicate":
            guard move, selectedDrawingCount > 0, selectedImageCount == 0 else { return .needs("Select one or more drawings with Move, without an image.") }
        case "imageReflection", "imageRotation", "imageCrop", "imagePlacement":
            guard move, selectedImageCount == 1, selectedDrawingCount == 0 else { return .needs("Select one image with Move and deselect drawings.") }
        case "artworkOrder":
            guard move, selectedDrawingCount + selectedImageCount > 0 else { return .needs("Select artwork with Move.") }
        case "textUpdate":
            guard move, selectedDrawingCount == 1, selectedImageCount == 0 else { return .needs("Select exactly one text box with Move.") }
        case "selectedErasure":
            guard selectedDrawingCount > 0 else { return .needs("Select the drawings to erase first.") }
        case "audioClip":
            guard selectedAudioClipKnown else { return .needs("Select an audio clip on the timeline first.") }
        case "frameAction", "frameCut":
            guard activeFrameNumber != nil, displayedFrameNumber == activeFrameNumber else { return .needs("Select the frame you want to change.") }
        case "fill":
            guard activeLayerVisible, activeLayerLockMode == "free" || activeLayerLockMode == "position" else { return .needs("Show the active layer and unlock it (free or position lock).") }
        case "selectByID":
            guard activeFrameNumber != nil else { return .needs("Select the frame whose drawings you want first.") }
        case "brushStroke":
            guard activeLayerVisible, activeLayerLockMode == "free" || activeLayerLockMode == "alpha" else { return .needs("Show and unlock the active layer.") }
        default: break
        }
        return .ready
    }
    /// Catalogue grammars whose preconditions currently hold, in catalogue order.
    func readyGrammars(catalogNames: [String] = SpatterInstructionCatalog.names) -> [String] {
        catalogNames.filter { readiness(of: $0) == .ready }
    }

    /// One line for the Spatter panel: exactly what Spatter sees, nothing inferred.
    var summary: String {
        let frame = activeFrameNumber.map { "Frame \($0) of \(frameCount)" } ?? "Frame unavailable (\(frameCount) frames)"
        let layer = activeLayerNumber.map { "layer \($0) of \(layerCount) \u{201C}\(activeLayerName)\u{201D}" } ?? "layer unavailable"
        var state: [String] = []
        if !activeLayerVisible { state.append("hidden") }
        if activeLayerLockMode != "free" { state.append(activeLayerLockMode + "-locked") }
        let toolText = tool.flatMap { raw in DrawingTool(rawValue: raw).flatMap { SpatterStudioControlRegistry.control(for: $0)?.title } }.map { "\($0) tool" } ?? "no tool"
        var selection: [String] = []
        if selectedDrawingCount > 0 { selection.append("\(selectedDrawingCount) drawing\(selectedDrawingCount == 1 ? "" : "s") selected") }
        if selectedImageCount > 0 { selection.append("1 image selected") }
        if selectedAudioClipKnown { selection.append("1 audio clip selected") }
        let timing = "\(width)×\(height) px, \(fps) FPS, \(String(format: "%.2f", durationSeconds)) s"
        let layerText = state.isEmpty ? layer : layer + " (" + state.joined(separator: ", ") + ")"
        var parts: [String] = [frame, layerText, toolText]
        parts += selection.isEmpty ? ["nothing selected"] : selection
        parts.append(timing)
        parts.append("\(documentElementCount) drawings in \(frameCount) frames")
        parts.append("revision \(revision)")
        if isPlaying { parts.append("playing") }
        if isSaving { parts.append("saving") }
        return parts.joined(separator: " · ")
    }
}
