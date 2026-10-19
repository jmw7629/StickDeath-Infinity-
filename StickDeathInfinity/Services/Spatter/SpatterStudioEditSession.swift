import Foundation
import Combine

/// Explicit local Studio editing only. Advice/provider text never enters this
/// session automatically. Each presented editing surface owns one instance.
@MainActor
final class SpatterStudioEditSession: ObservableObject {
    struct Scope: Equatable {
        let isStudioVisible: Bool
        /// Nil is the current local guest identity, not cloud authentication.
        let accountID: String?
    }
    enum Status: Equatable { case idle, preparing, applied, cancelled, timedOut, stale, rejected, closed }
    enum SaveState: Equatable {
        case unavailable, projectChanged, unsaved, saving, saved
        var text: String {
            switch self {
            case .unavailable: return "Save state unavailable for this editor"
            case .projectChanged: return "The project changed after this local edit"
            case .unsaved: return "Unsaved"
            case .saving: return "Saving…"
            case .saved: return "Saved"
            }
        }
    }
    struct AppliedEdit {
        let receipt: StudioCommandReceipt
        let selectedErasureMaskCount: Int
        let gridInstruction: SpatterGridInstruction?
        let onionInstruction: SpatterOnionInstruction?
        let frameExposureTicks: Int?
        var exposureFrames: ClosedRange<Int>? = nil
        var reversedFrames: ClosedRange<Int>? = nil
        var duplicatedFrameRange: ClosedRange<Int>? = nil
        let frameAction: SpatterFrameActionInstruction.Action?
        var layerStructureAction: SpatterLayerStructureInstruction.Action? = nil
        var layerSettingsInstruction: SpatterLayerUpdateInstruction? = nil
        var navigationInstruction: SpatterNavigationInstruction? = nil
        let isLayerGlowEdit: Bool
        let isLayerDuplicate: Bool
        let isLayerUpdate: Bool
        let layerVisibility: Bool?
        let layerOrderUp: Bool?
        let artworkOrderForward: Bool?
        let imageReflectionAxis: StudioReflectionAxis?
        let isAudioEdit: Bool
        let renamedProjectName: String?
        let addedAudioClipCount: Int
        let removedAudioClipCount: Int
        let changedExistingAudioClipCount: Int
        let addedFrameCount: Int
        let fps: Int
        let addedDurationSeconds: Double
        var audioTrackInstruction: SpatterAudioTrackInstruction? = nil
        var cutFrameCount: Int = 0
        var duplicatedDrawingCount: Int = 0
        var selectionTranslate: SpatterSelectionTranslateInstruction? = nil
        var selectionTransform: SpatterSelectionTransformInstruction? = nil
        var selectionReflectAxis: StudioReflectionAxis? = nil
        var imageRotation: StudioImageQuarterTurn? = nil
        var imageCrop: StudioImageCrop? = nil
        var imagePlacement: SpatterImagePlacementInstruction? = nil
        var textUpdate: SpatterTextUpdateInstruction? = nil
        // October 13 registry extensions, briefs and batches (#204, #205, #206, #214).
        var storyboard: SpatterStoryboard? = nil
        var batchSummary: String? = nil
        var tween: SpatterTweenInstruction? = nil
        var frameClipboard: SpatterFrameClipboardInstruction? = nil
        var projectSettings: SpatterProjectSettingsInstruction? = nil
        var brushStroke: SpatterBrushStrokeInstruction? = nil
        /// Content of the frames and layers this edit created, captured right after
        /// apply, so a typed revert can prove they are still untouched later.
        var createdFrames: [AnimationFrame] = []
        var createdLayers: [CanvasLayer] = []
        // Fill, select-by-ID and source-reference grammars (#204, #279).
        var fill: SpatterFillInstruction? = nil
        var selectByID: SpatterSelectByIDInstruction? = nil
        var source: SpatterSourceInstruction? = nil
        var recordedSource: SpatterSourceReference? = nil
        /// The explicit 20–60 s length receipt for a source-referenced generation.
        var sourceReceipt: String? = nil
        var summary: String {
            if let source {
                guard case .record = source.action, let recordedSource else {
                    return receipt.outcome == .unchanged ? "No reference source was recorded. Nothing changed."
                        : "Cleared the reference source in one undoable local edit. Later briefs are treated as original text."
                }
                let decision = SpatterSourceRightsGate.evaluate(recordedSource)
                return "Recorded \(recordedSource.url.absoluteString) as a \(recordedSource.rightsBasis.label) reference in one undoable local edit; nothing was downloaded. \(decision.allowed ? "20–60 s briefs may now generate from it." : "Generation stays refused:") \(decision.reason)"
            }
            if let selectByID {
                return selectByID.elementIDs.isEmpty ? "Cleared the drawing selection. The project did not change."
                    : "Selected \(selectByID.elementIDs.count) drawing\(selectByID.elementIDs.count == 1 ? "" : "s") on the active frame by ID. The project did not change; use Move or a selection instruction next."
            }
            if fill != nil {
                return receipt.outcome == .unchanged ? "The fill matched the current artwork. Nothing changed."
                    : "Filled the region at the requested point on the active layer with Studio's Fill tool in one undoable local edit. Original artwork remains editable."
            }
            let base = baseSummary
            return sourceReceipt.map { base + " " + $0 } ?? base
        }
        private var baseSummary: String {
            if let batchSummary {
                return receipt.outcome == .unchanged ? "The batch matched the current project. Nothing changed."
                    : "Applied \(batchSummary) as one revision and one Undo step. Frame numbers were resolved against the project as captured when Spatter opened."
            }
            if let storyboard {
                return "Built \(storyboard.frameCount) editable frames (\(String(format: "%.2f", storyboard.durationSeconds)) s at \(storyboard.fps) FPS, each pose held \(storyboard.poseHoldTicks) tick\(storyboard.poseHoldTicks == 1 ? "" : "s")) for \(storyboard.actors.count) actor\(storyboard.actors.count == 1 ? "" : "s") on new layers in one Undo step, seed \(storyboard.seed). The storyboard is attached to this receipt; nothing was exported or published."
            }
            if let tween {
                return receipt.outcome == .unchanged ? "No in-betweens were added. Nothing changed."
                    : "Added \(addedFrameCount) in-betweens between frames \(tween.firstFrame) and \(tween.firstFrame + 1) with \(tween.easing.title) easing in one Undo step. Endpoint frames are unchanged."
            }
            if let frameClipboard {
                if frameClipboard.destination == nil { return "Copied the frame to the frame clipboard. The document did not change; Paste frame after … inserts an editable copy." }
                return "Pasted \(addedFrameCount) editable frame copy with fresh identities in one Undo step\(frameClipboard.source != nil ? " after copying the source frame" : ""). Audio times are unchanged."
            }
            if let projectSettings {
                if receipt.outcome == .unchanged { return "The project already has these settings. Nothing changed." }
                let size = projectSettings.width.map { "\($0)×\(projectSettings.height ?? $0) px" }
                let rate = projectSettings.fps.map { "\($0) FPS" }
                return "Updated project settings (\([size, rate].compactMap { $0 }.joined(separator: ", "))) in one Undo step. Artwork coordinates are unchanged; audio keeps its time in seconds."
            }
            if let brushStroke {
                return "Drew one \(SpatterBrushStrokeInstruction.name(brushStroke.family)) brush stroke on the active layer in one Undo step. It is an editable stroke with its own brush settings."
            }
            if let edit = audioTrackInstruction {
                if receipt.outcome == .unchanged { return "Audio track \(edit.track) already has this setting. Nothing changed." }
                if let volume = edit.volume { return "Set audio track \(edit.track) volume to \(String(format: "%.6g", volume * 100))% in one Undo step. Clip volumes and original audio are unchanged." }
                if let pan = edit.pan {
                    let position = pan == 0 ? "center" : (pan < 0 ? "L" : "R") + String(format: "%.6g", abs(pan) * 100)
                    return "Panned audio track \(edit.track) to \(position) in one Undo step. Clip gains and original audio are unchanged."
                }
                if let soloed = edit.soloed { return "\(soloed ? "Soloed" : "Unsoloed") audio track \(edit.track) in one Undo step. Other tracks keep their own settings." }
                return "\(edit.muted == true ? "Muted" : "Unmuted") audio track \(edit.track) in one Undo step. Clips and original audio are preserved."
            }
            if let selectionTranslate {
                return receipt.outcome == .unchanged ? "The selected drawings did not move. Nothing changed."
                    : "Moved the selected drawings by (\(String(format: "%.6g", selectionTranslate.dxPercent))%, \(String(format: "%.6g", selectionTranslate.dyPercent))%) of the canvas in one Undo step. Original geometry stays editable."
            }
            if let selectionTransform {
                return receipt.outcome == .unchanged ? "The selected drawings already have this scale and rotation. Nothing changed."
                    : "Scaled the selected drawings to \(String(format: "%.6g", selectionTransform.scalePercent))% and rotated \(String(format: "%.6g", selectionTransform.rotationDegrees))° around their center in one Undo step."
            }
            if let selectionReflectAxis {
                return "Flipped the selected drawings \(selectionReflectAxis == .horizontal ? "horizontally" : "vertically") around their combined bounds in one Undo step. Stroke geometry stays editable."
            }
            if let imageRotation {
                return "Rotated the selected image one quarter turn \(imageRotation == .clockwise ? "clockwise" : "counterclockwise") in one Undo step. Original image bytes are unchanged."
            }
            if let imageCrop {
                return receipt.outcome == .unchanged ? "The selected image already has this crop. Nothing changed."
                    : "Cropped the selected image to \(String(format: "%.6g", imageCrop.width * 100))% × \(String(format: "%.6g", imageCrop.height * 100))% of its source in one Undo step. Original image bytes are unchanged."
            }
            if let imagePlacement {
                return receipt.outcome == .unchanged ? "The selected image already has this placement. Nothing changed."
                    : "Placed the selected image at (\(String(format: "%.6g", imagePlacement.xPercent))%, \(String(format: "%.6g", imagePlacement.yPercent))%) with size \(String(format: "%.6g", imagePlacement.widthPercent))% × \(String(format: "%.6g", imagePlacement.heightPercent))%\(imagePlacement.angleDegrees.map { " and angle \(String(format: "%.6g", $0))°" } ?? "") in one Undo step. Original image bytes are unchanged."
            }
            if textUpdate != nil {
                return receipt.outcome == .unchanged ? "The selected text already has this content and color. Nothing changed."
                    : "Updated the selected text box content\(textUpdate?.colorHex != nil ? " and color" : "") in one Undo step. Typography and position are unchanged."
            }
            if cutFrameCount > 0 {
                return "Cut the captured frame into the frame clipboard. Paste frame after this inserts an editable copy; Undo restores the removed frame. Audio timing is unchanged."
            }
            if duplicatedDrawingCount > 0 {
                return "Created \(duplicatedDrawingCount) editable drawing copies in one Undo step. Copies are selected for Move; original drawings and clipboard are preserved."
            }
            if let navigationInstruction {
                return receipt.outcome == .unchanged ? "That frame or layer is already selected. Nothing changed."
                    : "Selected \(navigationInstruction.target.rawValue) \(navigationInstruction.number). Artwork is unchanged."
            }
            if let layerStructureAction {
                return layerStructureAction == .add
                    ? "Added and selected a named blank layer in one undoable local edit. Existing artwork is preserved."
                    : "Deleted the captured active layer and its contents across frames in one undoable local edit. Undo restores the layer."
            }
            if let gridInstruction {
                if receipt.outcome == .unchanged { return "Grid settings already match. Nothing changed." }
                if let visible = gridInstruction.visible {
                    return "\(visible ? "Enabled" : "Disabled") grid guides in one undoable local edit. Artwork and export pixels are unchanged."
                }
                return "Updated grid spacing, opacity and tint in one undoable local edit. Grid visibility, onion skin and artwork are unchanged."
            }
            if let onionInstruction {
                if receipt.outcome == .unchanged { return "Onion-skin settings already match. Nothing changed." }
                if let visible = onionInstruction.visible {
                    return "\(visible ? "Enabled" : "Disabled") onion-skin guides in one undoable local edit. Artwork and export pixels are unchanged."
                }
                return "Updated onion-skin counts, opacity and tint in one undoable local edit. Guide visibility and artwork are unchanged."
            }
            if let duplicatedFrameRange {
                return "Duplicated frames \(duplicatedFrameRange.lowerBound) through \(duplicatedFrameRange.upperBound) after the source range in one undoable edit. Copies have new identities with editable artwork and the same exposure. Audio times are unchanged."
            }
            if let reversedFrames {
                return "Reversed frames \(reversedFrames.lowerBound) through \(reversedFrames.upperBound) in one undoable local edit, keeping their artwork and exposure. Audio times are unchanged."
            }
            if let frameAction {
                switch frameAction {
                case .add: return "Added \(addedFrameCount) blank \(addedFrameCount == 1 ? "frame" : "frames") after the active frame in one undoable local edit. Existing frames remain editable."
                case .duplicate: return "Created \(addedFrameCount) editable \(addedFrameCount == 1 ? "copy" : "copies") of the active frame in one undoable local edit. Artwork and exposure were copied."
                case .delete: return "Deleted only the active frame in one undoable local edit. Undo restores its artwork and exposure."
                case .earlier: return "Moved the active frame one position earlier in one undoable local edit. Its identity and exposure are unchanged."
                case .later: return "Moved the active frame one position later in one undoable local edit. Its identity and exposure are unchanged."
                }
            }
            if let artworkOrderForward {
                return receipt.outcome == .unchanged ? "Selected artwork is already at this ordering boundary. Nothing changed."
                    : "Moved selected artwork \(artworkOrderForward ? "forward" : "backward") within its layers in one undoable local edit."
            }
            if let imageReflectionAxis {
                let direction = imageReflectionAxis == .horizontal ? "horizontally" : "vertically"
                return "Flipped the selected image \(direction) in one undoable local edit. Original image bytes are unchanged."
            }
            if selectedErasureMaskCount > 0 {
                return "Added \(selectedErasureMaskCount) erasure \(selectedErasureMaskCount == 1 ? "mask" : "masks") to selected drawings in one undoable local edit. Original artwork remains editable."
            }
            if let renamedProjectName {
                return receipt.outcome == .unchanged ? "The project already has this name. Nothing changed."
                    : "Renamed project to “\(renamedProjectName)” in one undoable local edit."
            }
            if let frameExposureTicks, let exposureFrames {
                return receipt.outcome == .unchanged ? "The frame range already has that exposure. Nothing changed."
                    : "Set frames \(exposureFrames.lowerBound) through \(exposureFrames.upperBound) to \(frameExposureTicks) ticks each at \(fps) FPS in one undoable local edit."
            }
            if let frameExposureTicks {
                return receipt.outcome == .unchanged ? "The selected frame already has this exposure. Nothing changed."
                    : "Set selected frame exposure to \(frameExposureTicks) ticks at \(fps) FPS in one undoable local edit."
            }
            if let layerOrderUp {
                return receipt.outcome == .unchanged ? "Layer order did not change."
                    : "Moved the active layer \(layerOrderUp ? "up" : "down") in one undoable local edit. Artwork, visibility and lock settings are unchanged."
            }
            if let layerVisibility {
                return receipt.outcome == .unchanged ? "The active layer is already \(layerVisibility ? "shown" : "hidden"). Nothing changed."
                    : "\(layerVisibility ? "Showed" : "Hid") the active layer in one undoable local edit. Artwork and lock settings are unchanged."
            }
            if isLayerUpdate, let instruction = layerSettingsInstruction {
                let setting: String
                if let blend = instruction.blend { setting = "blend mode to \(blend.rawValue)" }
                else if let lock = instruction.lock { setting = "lock mode to \(lock.rawValue)" }
                else if let name = instruction.name { setting = "name to \(name)" }
                else if let opacity = instruction.opacity { setting = "opacity to \(String(format: "%.12g", opacity * 100))%" }
                else { setting = "visibility" }
                return receipt.outcome == .unchanged ? "The active layer already matches the requested setting. Nothing changed."
                    : "Set the active layer \(setting) in one undoable local edit."
            }
            if isLayerUpdate {
                return receipt.outcome == .unchanged ? "The active layer settings already match. Nothing changed."
                    : "Updated the active layer settings in one undoable local edit."
            }
            if isLayerDuplicate {
                return receipt.outcome == .unchanged ? "The layer was not duplicated. Nothing changed."
                    : "Duplicated the active layer across its frames in one undoable local edit. Original artwork remains editable."
            }
            if isLayerGlowEdit {
                return receipt.outcome == .unchanged ? "The active layer glow already matches this instruction. Nothing changed."
                    : "Updated the active layer glow in one undoable local edit."
            }
            if isAudioEdit {
                if removedAudioClipCount > 0 { return "Deleted the selected audio clip in one undoable local edit. Its source remains available for Undo." }
                if addedAudioClipCount > 0 && changedExistingAudioClipCount > 0 { return "Split the selected audio clip into two editable clips in one undoable local edit." }
                if addedAudioClipCount > 1 { return "Added \(addedAudioClipCount) consecutive editable copies of the selected audio clip in one Undo step, reusing its original sound." }
                if addedAudioClipCount > 0 { return "Duplicated the selected audio clip in one undoable local edit." }
                return receipt.outcome == .unchanged
                    ? "The selected audio clip already matches this instruction. Nothing changed."
                    : "Updated the selected audio clip in one undoable local edit."
            }
            return "Added \(addedFrameCount) editable frames at \(fps) FPS (\(String(format: "%.3f", addedDurationSeconds)) seconds) in one undoable local edit."
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var notice: String?
    @Published private(set) var submittedDraft: String?
    @Published private(set) var appliedEdit: AppliedEdit?
    @Published private(set) var isClosed = false
    var isWorking: Bool { status == .preparing }

    /// Bound replay bookkeeping without silently evicting accepted request IDs.
    /// This is an in-memory session safety limit, not an account entitlement.
    static let maximumSubmissions = 64
    typealias Checkpoint = @MainActor () async throws -> Void
    typealias ScopeProvider = @MainActor () -> Scope
    private let now: @MainActor () -> ContinuousClock.Instant
    private let budget: Duration
    private let checkpoint: Checkpoint
    private var request: Task<Void, Never>?
    private var taskID: UUID?
    private var generation = UUID()
    private var acceptedIDs: Set<UUID> = []
    private var exportedEditIDs: Set<UUID> = []
    private var appliedAccountID: String?

    /// Injection is only a scheduling/cancellation boundary for deterministic
    /// tests. The parser, commands, editor and persistence are always production.
    init(budget: Duration = .seconds(15), now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         checkpoint: @escaping Checkpoint = { await Task.yield(); try Task.checkCancellation() }) {
        // Injection can shorten but never disable or extend the production bound.
        self.budget = min(.seconds(15), max(.nanoseconds(1), budget)); self.now = now
        self.checkpoint = checkpoint
    }
    deinit { request?.cancel() }

    private struct Capture: Equatable {
        let accountID: String?
        let projectID: UUID
        let revision: Int
        let activeFrameID: String
        let activeLayerID: String
        let displayedFrameID: String?
        let selectedElementIDs: Set<String>
        let selectedAudioClipID: String?
        let selectedImage: StudioViewModel.ImageMoveCapture?
        let selectedArtwork: StudioViewModel.SelectionHandleCapture?
        let mixedArtwork: Bool
        let selectedTool: DrawingTool?
        let activePanel: StudioPanelType
        let isPlaying: Bool
        init(accountID: String?, screen: StudioViewModel.CommandScreenContext, document: StudioCommandContext,
             selectedImage: StudioViewModel.ImageMoveCapture?, selectedArtwork: StudioViewModel.SelectionHandleCapture?, mixedArtwork: Bool) {
            self.accountID = accountID; projectID = document.projectID; revision = document.revision
            activeFrameID = document.activeFrameID; activeLayerID = document.activeLayerID
            displayedFrameID = screen.displayedFrameID; selectedElementIDs = screen.selectedElementIDs
            selectedAudioClipID = screen.selectedAudioClipID; selectedTool = screen.selectedTool
            self.selectedImage = selectedImage; self.selectedArtwork = selectedArtwork; self.mixedArtwork = mixedArtwork
            activePanel = screen.activePanel; isPlaying = screen.isPlaying
        }
    }
    private enum SessionError: LocalizedError {
        case contextChanged, accountChanged, outsideStudio, timedOut, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .timedOut: return "This local edit exceeded its time limit before commit. Nothing was added. Your existing edits are preserved; try a smaller brief."
            case .contextChanged: return "The Studio project or selection changed. Submit again for the current editor."
            case .accountChanged: return "The active account changed. Submit again in the current account."
            case .outsideStudio: return "Open the current Studio editor before applying a local recipe."
            case .unavailable(let reason): return reason
            }
        }
    }

    /// True means accepted for preparation, not edited or saved. The caller must
    /// retain its draft until it observes the actual outcome. This method never
    /// clears a caller binding; submittedDraft keeps an exact bounded copy.
    /// Reusing an accepted submissionID is rejected even after failure/cancel.
    @discardableResult
    func submit(_ draft: String, in studio: StudioViewModel, accountID: String?,
                submissionID: UUID = UUID(), currentScope: @escaping ScopeProvider) -> Bool {
        guard !isWorking else { return false }
        guard !isClosed else { notice = "This local edit session is closed. Open a new session to create another recipe."; return false }
        appliedEdit = nil; appliedAccountID = nil
        guard draft.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else {
            status = .rejected; notice = SpatterMotionRecipe.RecipeError.instructionTooLong.localizedDescription; return false
        }
        submittedDraft = draft
        guard !acceptedIDs.contains(submissionID) else {
            status = .rejected; notice = "This local recipe submission was already handled. Nothing was replayed."; return false
        }
        guard acceptedIDs.count < Self.maximumSubmissions else {
            status = .rejected; notice = "This local edit session has reached its request limit. Open a new session; your project is unchanged."; return false
        }
        let scope = currentScope(), screen = studio.commandScreenContext
        do {
            guard scope.isStudioVisible else { throw SessionError.outsideStudio }
            guard scope.accountID == accountID else { throw SessionError.accountChanged }
            try Self.requireEligible(studio, screen: screen)
        } catch { reject(error); return false }
        guard let document = screen.document else { reject(SessionError.outsideStudio); return false }
        let captured = Capture(accountID: accountID, screen: screen, document: document,
                               selectedImage: studio.currentImageMoveCapture(), selectedArtwork: studio.beginSelectionHandle(), mixedArtwork: studio.isSelectingMixedArtwork)
        let started = now()
        let deadline = started.advanced(by: budget)
        acceptedIDs.insert(submissionID)
        generation = submissionID; taskID = submissionID
        appliedEdit = nil; appliedAccountID = nil; notice = nil; status = .preparing
        request = Task { [weak self, weak studio] in
            guard let self else { return }
            defer {
                if self.taskID == submissionID { self.request = nil; self.taskID = nil }
            }
            do {
                var lastInstant = started
                let check: () throws -> Void = {
                    try Task.checkCancellation()
                    guard self.generation == submissionID, !self.isClosed else { throw CancellationError() }
                    let instant = self.now()
                    guard instant >= lastInstant else { throw SessionError.unavailable("The local edit clock could not be verified. Nothing was added.") }
                    lastInstant = instant
                    guard instant < deadline else { throw SessionError.timedOut }
                    guard self.generation == submissionID, !self.isClosed else { throw CancellationError() }
                }
                try check()
                try await self.checkpoint()
                try check()
                guard let studio else { throw SessionError.outsideStudio }
                try self.requireCurrent(submissionID, captured: captured, studio: studio, currentScope: currentScope)
                let isAudioTrack = SpatterAudioTrackInstruction.isInstruction(draft)
                let isFrameCut = SpatterFrameCutInstruction.isInstruction(draft)
                let isDrawingDuplicate = SpatterDrawingDuplicateInstruction.isInstruction(draft)
                let isErasure = SpatterSelectedErasureInstruction.isInstruction(draft)
                let isAudio = SpatterAudioInstruction.isAudioInstruction(draft)
                let isLayerUpdate = SpatterLayerUpdateInstruction.isInstruction(draft)
                let isNavigation = SpatterNavigationInstruction.isInstruction(draft)
                let isLayerStructure = SpatterLayerStructureInstruction.isInstruction(draft)
                let isRename = !isLayerUpdate && SpatterProjectRenameInstruction.isInstruction(draft)
                let isExposure = !isLayerUpdate && !isRename && SpatterFrameExposureInstruction.isInstruction(draft)
                let isLayerDuplicate = !isLayerUpdate && !isRename && SpatterLayerDuplicateInstruction.isInstruction(draft)
                let isGlow = !isLayerUpdate && !isRename && SpatterLayerGlowInstruction.isInstruction(draft)
                let isImage = !isLayerUpdate && !isRename && SpatterImageReflectionInstruction.isInstruction(draft)
                let isOrder = !isLayerUpdate && !isRename && SpatterArtworkOrderInstruction.isInstruction(draft)
                let isLayerOrder = !isLayerUpdate && !isRename && SpatterLayerOrderInstruction.isInstruction(draft)
                let isFrameAction = !isLayerUpdate && !isRename && SpatterFrameActionInstruction.isInstruction(draft)
                let isOnion = !isLayerUpdate && !isRename && SpatterOnionInstruction.isInstruction(draft)
                let isGrid = !isLayerUpdate && !isRename && SpatterGridInstruction.isInstruction(draft)
                // Selection, image and text grammars are classified before the broad
                // audio first-word classifier ("move", "set", ...) can claim them.
                let isSelectionTranslate = SpatterSelectionTranslateInstruction.isInstruction(draft)
                let isSelectionTransform = SpatterSelectionTransformInstruction.isInstruction(draft)
                let isSelectionReflect = SpatterSelectionReflectInstruction.isInstruction(draft)
                let isImageRotation = SpatterImageRotationInstruction.isInstruction(draft)
                let isImageCrop = SpatterImageCropInstruction.isInstruction(draft)
                let isImagePlacement = SpatterImagePlacementInstruction.isInstruction(draft)
                let isTextUpdate = SpatterTextUpdateInstruction.isInstruction(draft)
                var selectionTranslate: SpatterSelectionTranslateInstruction?
                var selectionTransform: SpatterSelectionTransformInstruction?
                var selectionReflectAxis: StudioReflectionAxis?
                var imageRotation: StudioImageQuarterTurn?
                var imageCrop: StudioImageCrop?
                var imagePlacement: SpatterImagePlacementInstruction?
                var textUpdate: SpatterTextUpdateInstruction?
                // October 13 registry extensions (#204), batches (#205) and briefs (#206).
                let isBatch = SpatterInstructionBatch.isBatch(draft)
                let isTween = SpatterTweenInstruction.isInstruction(draft)
                let isFrameClipboard = SpatterFrameClipboardInstruction.isInstruction(draft)
                let isProjectSettings = SpatterProjectSettingsInstruction.isInstruction(draft)
                let isBrushStroke = SpatterBrushStrokeInstruction.isInstruction(draft)
                var batchSummary: String?
                var storyboard: SpatterStoryboard?
                var tweenInstruction: SpatterTweenInstruction?
                var frameClipboardInstruction: SpatterFrameClipboardInstruction?
                var projectSettingsInstruction: SpatterProjectSettingsInstruction?
                var brushStrokeInstruction: SpatterBrushStrokeInstruction?
                var exposureInstruction: SpatterFrameExposureInstruction?
                var reverseInstruction: SpatterFrameReverseInstruction?
                var duplicateRangeInstruction: SpatterFrameDuplicateRangeInstruction?
                var gridInstruction: SpatterGridInstruction?
                var onionInstruction: SpatterOnionInstruction?
                var frameAction: SpatterFrameActionInstruction.Action?
                var layerStructureAction: SpatterLayerStructureInstruction.Action?
                var layerSettingsInstruction: SpatterLayerUpdateInstruction?
                var navigationInstruction: SpatterNavigationInstruction?
                var layerOrderUp: Bool?
                var layerVisibility: Bool?
                var audioTrackInstruction: SpatterAudioTrackInstruction?
                var artworkOrderForward: Bool?
                var imageReflectionAxis: StudioReflectionAxis?
                let isSource = SpatterSourceInstruction.isInstruction(draft)
                let isSelectByID = SpatterSelectByIDInstruction.isInstruction(draft)
                let isFill = SpatterFillInstruction.isInstruction(draft)
                var fillInstruction: SpatterFillInstruction?
                var selectByIDInstruction: SpatterSelectByIDInstruction?
                var sourceInstruction: SpatterSourceInstruction?
                let preparedRequest: StudioCommandRequest
                if !isBatch && isSource {
                    // Metadata only: the URL text, stated rights basis and time. Nothing is fetched.
                    guard !captured.isPlaying else { throw SessionError.unavailable("Stop playback before recording a reference source.") }
                    let instruction = try SpatterSourceInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    sourceInstruction = instruction
                } else if !isBatch && isSelectByID {
                    guard !captured.isPlaying else { throw SessionError.unavailable("Stop playback before selecting drawings.") }
                    let instruction = try SpatterSelectByIDInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    selectByIDInstruction = instruction
                } else if !isBatch && isFill {
                    // The same capture and region computation as the Fill tool. A
                    // selection-clipped fill stays with the Fill tool itself.
                    guard !captured.isPlaying, captured.selectedElementIDs.isEmpty, captured.selectedImage == nil else {
                        throw SessionError.unavailable("Stop playback and clear the selection before a Spatter fill; selection-clipped fills use the Fill tool. Nothing changed.")
                    }
                    let instruction = try SpatterFillInstruction.parse(draft)
                    let elementID = UUID().uuidString
                    let command = try instruction.command(in: document, elementID: elementID)
                    guard let frame = studio.document.frames.first(where: { $0.id == captured.activeFrameID }) else { throw SessionError.contextChanged }
                    let capture = try StudioFillService.capture(document: studio.document, frameID: captured.activeFrameID,
                        layerID: captured.activeLayerID, point: CGPoint(x: command.x, y: command.y), color: command.color,
                        opacity: command.opacity, settings: .init(tolerance: command.tolerance, contiguous: command.contiguous,
                            expand: 0, gapClose: 0, antiAlias: true),
                        sampleAllLayers: command.sampleAllLayers, rasterData: studio.rasterData(frame.rasterAssetID),
                        rasterDataByID: studio.rasterSources(for: frame))
                    let worker = Task.detached(priority: .userInitiated) { try StudioFillService.element(from: capture, id: elementID) }
                    let element = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    try check()
                    preparedRequest = StudioCommandRequest(requestID: submissionID, projectID: document.projectID,
                        expectedRevision: document.revision, action: .apply([.fillAtPoint(command)]),
                        preparedFills: [elementID: .init(projectID: document.projectID, revision: document.revision, command: command, element: element)])
                    fillInstruction = instruction
                } else if isBatch {
                    // Several context-only lines become one typed request: one revision,
                    // one Undo step, nothing applied if any line fails to prepare.
                    guard !captured.isPlaying else { throw SessionError.unavailable("Stop playback before applying a batch of instructions.") }
                    let batch = try SpatterInstructionBatch.parse(draft)
                    preparedRequest = try batch.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    batchSummary = batch.summary
                } else if SpatterFrameDuplicateRangeInstruction.isInstruction(draft) {
                    guard !captured.isPlaying else { throw SpatterFrameDuplicateRangeInstruction.Failure.unsupported }
                    let instruction = try SpatterFrameDuplicateRangeInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    duplicateRangeInstruction = instruction
                } else if SpatterFrameReverseInstruction.isInstruction(draft) {
                    guard !captured.isPlaying else { throw SpatterFrameReverseInstruction.Failure.unsupported }
                    let instruction = try SpatterFrameReverseInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    reverseInstruction = instruction
                } else if isNavigation {
                    guard !captured.isPlaying else { throw SpatterNavigationInstruction.Failure.unsupported }
                    let instruction = try SpatterNavigationInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    navigationInstruction = instruction
                } else if isLayerStructure {
                    guard !captured.isPlaying else { throw SpatterLayerStructureInstruction.Failure.unavailable }
                    let instruction = try SpatterLayerStructureInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    layerStructureAction = instruction.action
                } else if isGrid {
                    guard !captured.isPlaying else { throw SpatterGridInstruction.Failure.unavailable }
                    let instruction = try SpatterGridInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    gridInstruction = instruction
                } else if isOnion {
                    guard !captured.isPlaying else { throw SpatterOnionInstruction.Failure.unavailable }
                    let instruction = try SpatterOnionInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    onionInstruction = instruction
                } else if isFrameAction {
                    guard !captured.isPlaying, captured.displayedFrameID == captured.activeFrameID else { throw SpatterFrameActionInstruction.Failure.unavailable }
                    let instruction = try SpatterFrameActionInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in:document,requestID:submissionID,checkCancellation:check)
                    frameAction = instruction.action
                } else if isLayerOrder {
                    let instruction = try SpatterLayerOrderInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in:document,requestID:submissionID,checkCancellation:check)
                    layerOrderUp = instruction.up
                } else if isAudioTrack {
                    guard !captured.isPlaying else { throw SessionError.unavailable("Stop playback before changing audio tracks.") }
                    let instruction = try SpatterAudioTrackInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    audioTrackInstruction = instruction
                } else if isFrameCut {
                    guard !captured.isPlaying else { throw SessionError.unavailable("Stop playback before cutting a frame.") }
                    preparedRequest = try SpatterFrameCutInstruction.prepare(draft, in: document,
                        requestID: submissionID, checkCancellation: check)
                } else if isDrawingDuplicate {
                    guard captured.selectedTool == .move, !captured.isPlaying,
                          !captured.mixedArtwork, captured.selectedImage == nil,
                          captured.selectedArtwork != nil, !captured.selectedElementIDs.isEmpty else {
                        throw SpatterDrawingDuplicateInstruction.Failure.selection
                    }
                    preparedRequest = try SpatterDrawingDuplicateInstruction.parse(draft).prepare(in: document,
                        selectedElementIDs: captured.selectedElementIDs, requestID: submissionID, checkCancellation: check)
                } else if isOrder {
                    let instruction = try SpatterArtworkOrderInstruction.parse(draft)
                    guard captured.selectedTool == .move, !captured.isPlaying else { throw SpatterArtworkOrderInstruction.Failure.selection }
                    let image: StudioCommand.SelectedArtworkImage?
                    if captured.mixedArtwork {
                        guard let selection = captured.selectedArtwork, let target = selection.image else { throw SpatterArtworkOrderInstruction.Failure.selection }
                        image = .init(assetID: target.assetID, layerID: target.layerID)
                    } else if let target = captured.selectedImage {
                        guard captured.selectedElementIDs.isEmpty else { throw SpatterArtworkOrderInstruction.Failure.selection }
                        image = .init(assetID: target.placement.assetID, layerID: target.placement.layerID)
                    } else {
                        guard captured.selectedArtwork != nil, !captured.selectedElementIDs.isEmpty else { throw SpatterArtworkOrderInstruction.Failure.selection }
                        image = nil
                    }
                    preparedRequest = try instruction.prepare(in: document, selectedElementIDs: captured.selectedElementIDs,
                        image: image, requestID: submissionID, checkCancellation: check)
                    artworkOrderForward = instruction.forward
                } else if isImage {
                    let instruction = try SpatterImageReflectionInstruction.parse(draft)
                    guard captured.selectedTool == .move, captured.selectedElementIDs.isEmpty,
                          !captured.isPlaying, let image = captured.selectedImage,
                          image.placement.projectID == captured.projectID,
                          image.placement.revision == captured.revision,
                          image.placement.frameID == captured.activeFrameID,
                          image.placement.layerID == captured.activeLayerID else {
                        throw SessionError.unavailable("Select one visible, unlocked image with Move before flipping it. Deselect drawings and stop playback.")
                    }
                    preparedRequest = try instruction.prepare(in: document, frameID: image.placement.frameID,
                        layerID: image.placement.layerID, assetID: image.placement.assetID,
                        requestID: submissionID, checkCancellation: check)
                    imageReflectionAxis = instruction.axis
                } else if isSelectionTranslate || isSelectionTransform || isSelectionReflect {
                    // Same captured-selection authority as drawing duplication: Move tool,
                    // drawings only, no image or mixed artwork, playback stopped.
                    guard captured.selectedTool == .move, !captured.isPlaying, !captured.mixedArtwork,
                          captured.selectedImage == nil, captured.selectedArtwork != nil, !captured.selectedElementIDs.isEmpty else {
                        throw SessionError.unavailable("Select 1–1,024 drawings with Move before opening Spatter; images and mixed artwork use their own instructions. Stop playback. Nothing changed.")
                    }
                    if isSelectionTranslate {
                        let instruction = try SpatterSelectionTranslateInstruction.parse(draft)
                        preparedRequest = try instruction.prepare(in: document, selectedElementIDs: captured.selectedElementIDs, requestID: submissionID, checkCancellation: check)
                        selectionTranslate = instruction
                    } else if isSelectionTransform {
                        let instruction = try SpatterSelectionTransformInstruction.parse(draft)
                        preparedRequest = try instruction.prepare(in: document, selectedElementIDs: captured.selectedElementIDs, requestID: submissionID, checkCancellation: check)
                        selectionTransform = instruction
                    } else {
                        let instruction = try SpatterSelectionReflectInstruction.parse(draft)
                        preparedRequest = try instruction.prepare(in: document, selectedElementIDs: captured.selectedElementIDs, requestID: submissionID, checkCancellation: check)
                        selectionReflectAxis = instruction.axis
                    }
                } else if isImageRotation || isImageCrop || isImagePlacement {
                    guard captured.selectedTool == .move, captured.selectedElementIDs.isEmpty,
                          !captured.isPlaying, let image = captured.selectedImage,
                          image.placement.projectID == captured.projectID,
                          image.placement.revision == captured.revision,
                          image.placement.frameID == captured.activeFrameID,
                          image.placement.layerID == captured.activeLayerID else {
                        throw SessionError.unavailable("Select one visible, unlocked image with Move before editing it. Deselect drawings and stop playback.")
                    }
                    let frameID = image.placement.frameID, layerID = image.placement.layerID, assetID = image.placement.assetID
                    if isImageRotation {
                        let instruction = try SpatterImageRotationInstruction.parse(draft)
                        preparedRequest = try instruction.prepare(in: document, frameID: frameID, layerID: layerID, assetID: assetID, requestID: submissionID, checkCancellation: check)
                        imageRotation = instruction.direction
                    } else if isImageCrop {
                        let instruction = try SpatterImageCropInstruction.parse(draft)
                        preparedRequest = try instruction.prepare(in: document, frameID: frameID, layerID: layerID, assetID: assetID, requestID: submissionID, checkCancellation: check)
                        imageCrop = instruction.crop
                    } else {
                        let instruction = try SpatterImagePlacementInstruction.parse(draft)
                        preparedRequest = try instruction.prepare(in: document, frameID: frameID, layerID: layerID, assetID: assetID, requestID: submissionID, checkCancellation: check)
                        imagePlacement = instruction
                    }
                } else if isTextUpdate {
                    let instruction = try SpatterTextUpdateInstruction.parse(draft)
                    // Exactly one captured selected element that is a real text box on the active frame.
                    guard !captured.isPlaying, captured.selectedElementIDs.count == 1, let elementID = captured.selectedElementIDs.first,
                          captured.selectedImage == nil, !captured.mixedArtwork,
                          let frame = studio.document.frames.first(where: { $0.id == captured.activeFrameID }),
                          let element = frame.elements.first(where: { $0.id == elementID }), element.tool == .text, element.text != nil else {
                        throw SpatterTextUpdateInstruction.Failure.selection
                    }
                    preparedRequest = try instruction.prepare(in: document, element: element, requestID: submissionID, checkCancellation: check)
                    textUpdate = instruction
                } else if isTween {
                    guard !captured.isPlaying else { throw SessionError.unavailable("Stop playback before tweening frames.") }
                    let instruction = try SpatterTweenInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    tweenInstruction = instruction
                } else if isFrameClipboard {
                    guard !captured.isPlaying else { throw SessionError.unavailable("Stop playback before copying or pasting frames.") }
                    let instruction = try SpatterFrameClipboardInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    frameClipboardInstruction = instruction
                } else if isProjectSettings {
                    guard !captured.isPlaying else { throw SessionError.unavailable("Stop playback before changing project settings.") }
                    let instruction = try SpatterProjectSettingsInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    projectSettingsInstruction = instruction
                } else if isBrushStroke {
                    guard !captured.isPlaying else { throw SessionError.unavailable("Stop playback before drawing with Spatter.") }
                    let instruction = try SpatterBrushStrokeInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    brushStrokeInstruction = instruction
                } else if isErasure {
                    preparedRequest = try SpatterSelectedErasureInstruction.parse(draft).prepare(in: document,
                        selectedElementIDs: captured.selectedElementIDs, requestID: submissionID, checkCancellation: check)
                } else if isRename {
                    preparedRequest = try SpatterProjectRenameInstruction.parse(draft).prepare(in: document, requestID: submissionID, checkCancellation: check)
                } else if isExposure {
                    let instruction = try SpatterFrameExposureInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document, requestID: submissionID, checkCancellation: check)
                    exposureInstruction = instruction
                } else if isLayerUpdate {
                    let instruction = try SpatterLayerUpdateInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in:document,requestID:submissionID,checkCancellation:check)
                    layerVisibility = instruction.visible
                    layerSettingsInstruction = instruction
                } else if isLayerDuplicate {
                    preparedRequest = try SpatterLayerDuplicateInstruction.parse(draft).prepare(in:document, requestID:submissionID, checkCancellation:check)
                } else if isGlow {
                    preparedRequest = try SpatterLayerGlowInstruction.parse(draft).prepare(in: document, requestID: submissionID, checkCancellation: check)
                } else if isAudio {
                    let instruction = try SpatterAudioInstruction.parse(draft)
                    preparedRequest = try instruction.prepare(in: document,
                        selectedClipID: captured.selectedAudioClipID, requestID: submissionID, checkCancellation: check)
                } else if let kind = SpatterInstructionRouter.classify(draft), kind == .twoActorBrief || kind == .sceneBrief || kind == .multiClauseBrief {
                    // The historical brief grammars keep their exact output for the
                    // briefs they accept; every other brief goes to the general planner.
                    switch kind {
                    case .twoActorBrief:
                        preparedRequest = try SpatterTwoActorBrief.parse(draft).prepare(in: document, requestID: submissionID, checkCancellation: check).request
                    case .sceneBrief:
                        preparedRequest = try SpatterSceneBrief.parse(draft).prepare(in: document, requestID: submissionID, checkCancellation: check).request
                    default:
                        let plan = try SpatterMultiClauseBrief.parse(draft).prepare(in: document, requestID: submissionID, checkCancellation: check)
                        preparedRequest = plan.prepared.request
                        storyboard = plan.storyboard
                    }
                } else if SpatterStickFigureRecipe.isStickFigureInstruction(draft) {
                    let recipe = try SpatterStickFigureRecipe.parse(draft)
                    preparedRequest = try recipe.prepare(in: document, requestID: submissionID, checkCancellation: check).request
                } else {
                    let recipe = try SpatterMotionRecipe.parse(draft)
                    preparedRequest = try recipe.prepare(in: document, requestID: submissionID, checkCancellation: check).request
                }
                try await self.checkpoint()
                try check()
                try self.requireCurrent(submissionID, captured: captured, studio: studio, currentScope: currentScope)
                // No suspension between the last fresh context check and this
                // synchronous atomic VM transaction. Its own original revision,
                // brush-input, work-budget and cancellation guards still apply.
                let previousMaskCount = studio.document.frames.reduce(0) { count, frame in
                    count + frame.elements.reduce(0) { $0 + ($1.selectionErasures?.count ?? 0) }
                }
                let receipt: StudioCommandReceipt
                do {
                    receipt = try studio.applyStudioCommands(preparedRequest, checkCancellation: {
                        try check()
                        // The cancellation clock may reenter the editor. Preserve the
                        // exact selected image instance/token even at the final commit.
                        try self.requireCurrent(submissionID, captured: captured, studio: studio, currentScope: currentScope)
                    })
                } catch where isBatch && !(error is CancellationError) && !(error is SessionError)
                    && (error as? StudioCommandError).map({ $0 != .staleRevision && $0 != .wrongProject }) != false {
                    // A batch whose lines all prepared can still fail while committing,
                    // e.g. two lines deleting the same captured layer. The staged
                    // transaction leaves the editor untouched; say so per batch (#205).
                    throw SessionError.unavailable(SpatterInstructionBatch.rollbackNotice(error))
                }
                let newIDs = Set(receipt.createdFrameIDs)
                let addedTicks = studio.frames.filter { newIDs.contains($0.id) }.reduce(0) { $0 + $1.durationTicks }
                let oldAudioIDs = Set(document.editableAudioClips.map(\.id))
                let addedAudioCount = studio.audioClips.filter { !oldAudioIDs.contains($0.id) }.count
                let currentMaskCount = studio.document.frames.reduce(0) { count, frame in
                    count + frame.elements.reduce(0) { $0 + ($1.selectionErasures?.count ?? 0) }
                }
                let result = AppliedEdit(receipt: receipt, selectedErasureMaskCount: isErasure ? max(0, currentMaskCount - previousMaskCount) : 0, gridInstruction: gridInstruction, onionInstruction: onionInstruction, frameExposureTicks: exposureInstruction?.ticks, exposureFrames: exposureInstruction?.frames, reversedFrames: reverseInstruction?.frames, duplicatedFrameRange: duplicateRangeInstruction?.frames, frameAction:frameAction, layerStructureAction:layerStructureAction, layerSettingsInstruction:layerSettingsInstruction, navigationInstruction:navigationInstruction, isLayerGlowEdit: isGlow, isLayerDuplicate:isLayerDuplicate, isLayerUpdate:isLayerUpdate, layerVisibility:layerVisibility, layerOrderUp:layerOrderUp, artworkOrderForward: artworkOrderForward, imageReflectionAxis: imageReflectionAxis, isAudioEdit: isAudio, renamedProjectName: isRename ? studio.document.name : nil, addedAudioClipCount: addedAudioCount,
                    removedAudioClipCount: document.editableAudioClips.filter { old in !studio.audioClips.contains { $0.id == old.id } }.count,
                    changedExistingAudioClipCount: studio.audioClips.filter { new in document.editableAudioClips.contains { $0.id == new.id && $0 != new } }.count,
                    addedFrameCount: receipt.createdFrameIDs.count,
                    fps: studio.fps, addedDurationSeconds: Double(addedTicks) / Double(studio.fps),
                    audioTrackInstruction: audioTrackInstruction, cutFrameCount: isFrameCut ? document.frames.filter { old in !studio.frames.contains { $0.id == old.id } }.count : 0, duplicatedDrawingCount: isDrawingDuplicate ? receipt.createdElementIDs.count : 0,
                    selectionTranslate: selectionTranslate, selectionTransform: selectionTransform, selectionReflectAxis: selectionReflectAxis,
                    imageRotation: imageRotation, imageCrop: imageCrop, imagePlacement: imagePlacement, textUpdate: textUpdate,
                    storyboard: storyboard, batchSummary: batchSummary, tween: tweenInstruction, frameClipboard: frameClipboardInstruction,
                    projectSettings: projectSettingsInstruction, brushStroke: brushStrokeInstruction,
                    createdFrames: studio.document.frames.filter { newIDs.contains($0.id) },
                    createdLayers: studio.document.layers.filter { Set(receipt.createdLayerIDs).contains($0.id) },
                    fill: fillInstruction, selectByID: selectByIDInstruction, source: sourceInstruction,
                    recordedSource: sourceInstruction == nil ? nil : studio.document.spatterSource,
                    sourceReceipt: storyboard != nil ? studio.document.spatterSource.map {
                        SpatterSourceVideoBounds.receipt(seconds: Double(addedTicks) / Double(studio.fps), fps: studio.fps, reference: $0)
                    } : nil)
                self.appliedAccountID = captured.accountID
                self.appliedEdit = result; self.status = .applied; self.notice = result.summary
            } catch is CancellationError {
                guard self.generation == submissionID, !self.isClosed else { return }
                self.status = .cancelled; self.notice = "Local recipe cancelled before applying any edits."
            } catch {
                guard self.generation == submissionID, !self.isClosed else { return }
                self.reject(error)
            }
        }
        return true
    }

    private static func requireEligible(_ studio: StudioViewModel, screen: StudioViewModel.CommandScreenContext) throws {
        guard screen.route == .editor, screen.document != nil, studio.isEditing else { throw SessionError.outsideStudio }
        guard studio.activeStrokeID == nil else { throw SessionError.unavailable("Finish the current touch stroke before creating a local recipe.") }
        guard studio.pendingBrushStroke == nil else { throw SessionError.unavailable("Retry or discard the rejected brush draft before creating a local recipe.") }
        guard !studio.isSaving, screen.canApplyCommands else { throw SessionError.unavailable("Wait for the current save before creating a local recipe.") }
    }
    private func requireCurrent(_ id: UUID, captured: Capture, studio: StudioViewModel,
                                currentScope: ScopeProvider) throws {
        try Task.checkCancellation()
        guard generation == id, !isClosed else { throw CancellationError() }
        let scope = currentScope()
        guard scope.isStudioVisible else { throw SessionError.outsideStudio }
        guard scope.accountID == captured.accountID else { throw SessionError.accountChanged }
        let screen = studio.commandScreenContext
        try Self.requireEligible(studio, screen: screen)
        guard let document = screen.document,
              Capture(accountID: scope.accountID, screen: screen, document: document,
                      selectedImage: studio.currentImageMoveCapture(), selectedArtwork: studio.beginSelectionHandle(), mixedArtwork: studio.isSelectingMixedArtwork) == captured else { throw SessionError.contextChanged }
    }
    private func reject(_ error: Error) {
        if let sessionError = error as? SessionError {
            switch sessionError {
            case .contextChanged, .accountChanged, .outsideStudio: status = .stale
            case .timedOut: status = .timedOut
            case .unavailable: status = .rejected
            }
        } else { status = .rejected }
        notice = error.localizedDescription
    }

    /// Reads the current real editor, not a cached inference from an edit receipt.
    /// A later undo/edit makes this receipt's save state explicitly noncurrent.
    func saveState(in studio: StudioViewModel, currentScope: Scope) -> SaveState {
        guard !isClosed, currentScope.isStudioVisible, studio.isEditing,
              currentScope.accountID == appliedAccountID, let result = appliedEdit else { return .unavailable }
        guard studio.document.id == result.receipt.projectID,
              studio.document.revision == result.receipt.revision else { return .projectChanged }
        if studio.isSaving { return .saving }
        return studio.isDirty ? .unsaved : .saved
    }
    /// A user explicitly requests this saved edit's MP4; never parse provider
    /// prose into export authority. The receiving panel rechecks this capture.
    func prepareMovieExport(in studio: StudioViewModel, currentScope: Scope) -> StudioMovieExportRequest? {
        guard saveState(in: studio, currentScope: currentScope) == .saved,
              !isWorking, let edit = appliedEdit, !exportedEditIDs.contains(edit.receipt.requestID),
              studio.textDraft == nil, studio.activeStrokeID == nil, studio.pendingBrushStroke == nil,
              !studio.isPlaying else {
            notice = "Save the current edit and finish any active draft before requesting its MP4. Each edit can hand off one direct export."
            return nil
        }
        exportedEditIDs.insert(edit.receipt.requestID)
        return .init(editRequestID: edit.receipt.requestID, projectID: edit.receipt.projectID,
            revision: edit.receipt.revision, accountID: currentScope.accountID)
    }
    /// Typed revert for generative edits (#205): offered as long as every frame
    /// and layer the edit created still exists unchanged and the created layers
    /// hold no other artwork, even after unrelated later edits. It removes exactly
    /// those entities in one new revision (deleteFrameRange + deleteLayer), so the
    /// user's intervening edits survive and Studio's Undo restores the content.
    func canRevertAppliedEdit(in studio: StudioViewModel, currentScope: Scope) -> Bool {
        guard !isClosed, !isWorking, currentScope.isStudioVisible, studio.isEditing,
              currentScope.accountID == appliedAccountID, let edit = appliedEdit,
              edit.receipt.outcome == .applied, studio.document.id == edit.receipt.projectID,
              !studio.isPlaying, !studio.isSaving, studio.textDraft == nil,
              studio.activeStrokeID == nil, studio.pendingBrushStroke == nil else { return false }
        return revertCommands(in: studio.document, edit: edit) != nil
    }
    private func revertCommands(in document: StudioDocument, edit: AppliedEdit) -> [StudioCommand]? {
        guard !edit.createdFrames.isEmpty || !edit.createdLayers.isEmpty,
              edit.receipt.deletedFrameIDs.isEmpty, edit.receipt.deletedLayerIDs.isEmpty, edit.receipt.deletedElementIDs.isEmpty else { return nil }
        let createdFrameIDs = Set(edit.createdFrames.map(\.id)), createdLayerIDs = Set(edit.createdLayers.map(\.id))
        // Every created frame must still exist with identical content.
        for frame in edit.createdFrames where !document.frames.contains(frame) { return nil }
        for layer in edit.createdLayers {
            guard document.layers.contains(where: { $0.id == layer.id }) else { return nil }
            // Artwork the user added to a created layer outside the created frames is kept, so no revert.
            for frame in document.frames where !createdFrameIDs.contains(frame.id) {
                if frame.elements.contains(where: { $0.layerID == layer.id }) || frame.rasterInstance(on: layer.id) != nil { return nil }
            }
        }
        // Edits that only created elements on existing frames (e.g. one brush stroke) keep the receipt-revision Undo offer instead.
        guard document.frames.count - createdFrameIDs.count >= 1, document.layers.count - createdLayerIDs.count >= 1,
              createdFrameIDs.count <= StudioCommandExecutor.maximumAppendedFrames else { return nil }
        var commands: [StudioCommand] = []
        if !createdFrameIDs.isEmpty { commands.append(.deleteFrameRange(.init(frameIDs: edit.createdFrames.map(\.id)))) }
        for layer in edit.createdLayers { commands.append(.deleteLayer(.id(layer.id))) }
        guard commands.count <= StudioCommandExecutor.maximumCommands else { return nil }
        return commands
    }
    @discardableResult
    func revertAppliedEdit(in studio: StudioViewModel, currentScope: Scope) -> Bool {
        guard let edit = appliedEdit, !isClosed, !isWorking else { return false }
        guard canRevertAppliedEdit(in: studio, currentScope: currentScope), let commands = revertCommands(in: studio.document, edit: edit) else {
            notice = "Revert Spatter edit is unavailable: the frames or layers this edit created were changed, removed or reused, or the editor is busy. Use Studio's Undo history instead."
            return false
        }
        do {
            let receipt = try studio.applyStudioCommands(.init(requestID: UUID(), projectID: edit.receipt.projectID,
                expectedRevision: studio.document.revision, action: .apply(commands)))
            guard receipt.outcome == .applied else { throw StudioCommandError.noHistory }
            appliedEdit = nil; appliedAccountID = nil; status = .idle
            notice = "Reverted this Spatter edit's \(edit.createdFrames.count) frame\(edit.createdFrames.count == 1 ? "" : "s") and \(edit.createdLayers.count) layer\(edit.createdLayers.count == 1 ? "" : "s") as one new Undo step. Your later edits are preserved; Studio's Undo restores the generated content."
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }
    /// Linear history: the applied edit is the top undo entry only while the
    /// document revision still equals the receipt revision. Any later edit, undo
    /// or save-with-change makes the offer unavailable with an explanation.
    func canUndoAppliedEdit(in studio: StudioViewModel, currentScope: Scope) -> Bool {
        guard !isClosed, !isWorking, currentScope.isStudioVisible, studio.isEditing,
              currentScope.accountID == appliedAccountID, let edit = appliedEdit,
              edit.receipt.outcome == .applied, studio.document.id == edit.receipt.projectID,
              studio.document.revision == edit.receipt.revision, studio.canUndo,
              !studio.isPlaying, !studio.isSaving, studio.textDraft == nil,
              studio.activeStrokeID == nil, studio.pendingBrushStroke == nil else { return false }
        return true
    }
    /// Reverts exactly the applied Spatter edit through the same typed undo
    /// transaction (revision-checked), never a blind history pop.
    @discardableResult
    func undoAppliedEdit(in studio: StudioViewModel, currentScope: Scope) -> Bool {
        guard let edit = appliedEdit, !isClosed, !isWorking else { return false }
        guard canUndoAppliedEdit(in: studio, currentScope: currentScope) else {
            if studio.document.id != edit.receipt.projectID || studio.document.revision != edit.receipt.revision {
                notice = "The document changed after this Spatter edit (revision \(studio.document.revision) vs \(edit.receipt.revision)), so Undo Spatter edit is unavailable. Use Studio's own Undo history to step back through later changes first."
            } else {
                notice = "Undo Spatter edit is unavailable right now. Stop playback, finish drafts and wait for saving, then try again."
            }
            return false
        }
        do {
            let receipt = try studio.applyStudioCommands(.init(requestID: UUID(), projectID: edit.receipt.projectID,
                expectedRevision: edit.receipt.revision, action: .undo))
            guard receipt.outcome == .undone else { throw StudioCommandError.noHistory }
            appliedEdit = nil; appliedAccountID = nil; status = .idle
            notice = "Reverted the Spatter edit in one step. Studio's Redo restores it; nothing was saved by this action."
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }
    @discardableResult
    func cancel() -> Bool {
        guard isWorking else { return false }
        generation = UUID(); request?.cancel()
        status = .cancelled; notice = "Local recipe cancelled before applying any edits."
        return true
    }
    func close() {
        let wasWorking = cancel()
        isClosed = true; generation = UUID(); status = .closed
        notice = wasWorking ? "Local edit session closed; its pending recipe was cancelled before editing." : "Local edit session closed."
    }
    /// Useful for deterministic completion observation; never drives persistence.
    func waitForCompletion(onCapture: () -> Void = {}) async { let current = request; onCapture(); await current?.value }
}

/// Explicit navigation authority only. No source path, URL, provider text or
/// picture bytes may enter this handoff; the existing picker owns selection.
@MainActor
final class SpatterPictureImportHandoff: ObservableObject {
    struct Request: Equatable {
        let id: UUID
        let projectID: UUID
        let revision: Int
        let frameID: String
        let layerID: String
        let accountID: String?
    }
    private var issued: Request?
    func prepare(in studio: StudioViewModel, accountID: String?, isForeground: Bool) -> Request? {
        guard issued == nil, isForeground, studio.activePanel == .spatterAI, eligible(studio) else { return nil }
        let request = Request(id: UUID(), projectID: studio.document.id, revision: studio.document.revision,
            frameID: studio.document.activeFrameID, layerID: studio.document.activeLayerID, accountID: accountID)
        issued = request
        return request
    }
    /// Consumes once, even if the captured context is no longer eligible.
    /// Returning true means only that the native import panel may open.
    func consume(_ request: Request, in studio: StudioViewModel, accountID: String?, isForeground: Bool) -> Bool {
        guard issued == request else { return false }
        issued = nil
        return isForeground && studio.activePanel == .none && eligible(studio)
            && accountID == request.accountID && studio.document.id == request.projectID
            && studio.document.revision == request.revision && studio.document.activeFrameID == request.frameID
            && studio.document.activeLayerID == request.layerID
    }
    func cancel() { issued = nil }
    private func eligible(_ studio: StudioViewModel) -> Bool {
        studio.isEditing && !studio.isSaving && !studio.isPlaying && studio.textDraft == nil
            && studio.activeStrokeID == nil && studio.pendingBrushStroke == nil
    }
}

// MARK: - Export receipt (#215)

/// Factual description of one completed direct export that a Spatter edit handed
/// off. Every field is measured from the real output; nothing is estimated. The
/// builder that reads the movie session lives in the SwiftUI panel because the
/// export service is not part of the Foundation-only edit-session test build.
struct SpatterExportReceipt: Codable, Equatable {
    let editRequestID: UUID
    let revision: Int
    let byteCount: Int
    let durationSeconds: Double
    let frameCount: Int
    let sha256: String
    enum Failure: LocalizedError {
        case missingFile, mismatch, unreadable
        var errorDescription: String? {
            switch self {
            case .missingFile: return "The exported file is no longer available, so no export receipt was produced."
            case .mismatch: return "The export output does not match its manifest; no receipt was produced."
            case .unreadable: return "The exported file could not be read for verification; no receipt was produced."
            }
        }
    }
    /// Reads the actual file bytes (bounded) and hashes them. `byteCount` must equal
    /// the manifest's encoded byte count or the receipt is refused.
    static func make(editRequestID: UUID, revision: Int, fileURL: URL, expectedByteCount: Int,
                     durationSeconds: Double, frameCount: Int, byteLimit: Int = 512 * 1024 * 1024) throws -> SpatterExportReceipt {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize else { throw Failure.missingFile }
        guard size == expectedByteCount, size > 0, size <= byteLimit, durationSeconds.isFinite, durationSeconds > 0, frameCount > 0 else { throw Failure.mismatch }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]), data.count == size else { throw Failure.unreadable }
        return .init(editRequestID: editRequestID, revision: revision, byteCount: size,
                     durationSeconds: durationSeconds, frameCount: frameCount, sha256: SpatterSHA256.hexDigest(of: data))
    }
    var summary: String {
        "Spatter edit \(editRequestID.uuidString) · revision \(revision) · \(byteCount) bytes · \(String(format: "%.3f", durationSeconds)) s · \(frameCount) frames · SHA-256 \(sha256.prefix(16))…"
    }
}

/// Foundation-only SHA-256 (FIPS 180-4) so receipts hash identically on every
/// platform the tests run on. Not a general crypto library; digest only.
enum SpatterSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
    static func digest(of data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { [UInt8($0 >> 24 & 0xff), UInt8($0 >> 16 & 0xff), UInt8($0 >> 8 & 0xff), UInt8($0 & 0xff)] }
    }
    static func hexDigest(of data: Data) -> String {
        digest(of: data).map { String(format: "%02x", $0) }.joined()
    }
}
