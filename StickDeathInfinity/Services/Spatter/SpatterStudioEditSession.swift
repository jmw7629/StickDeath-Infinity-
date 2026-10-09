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
        var summary: String {
            if let edit = audioTrackInstruction {
                if receipt.outcome == .unchanged { return "Audio track \(edit.track) already has this setting. Nothing changed." }
                if let volume = edit.volume { return "Set audio track \(edit.track) volume to \(String(format: "%.6g", volume * 100))% in one Undo step. Clip volumes and original audio are unchanged." }
                return "\(edit.muted == true ? "Muted" : "Unmuted") audio track \(edit.track) in one Undo step. Clips and original audio are preserved."
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
                let preparedRequest: StudioCommandRequest
                if SpatterFrameDuplicateRangeInstruction.isInstruction(draft) {
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
                } else if SpatterTwoActorBrief.isBrief(draft) {
                    preparedRequest = try SpatterTwoActorBrief.parse(draft).prepare(in: document, requestID: submissionID, checkCancellation: check).request
                } else if SpatterSceneBrief.isBrief(draft) {
                    let brief = try SpatterSceneBrief.parse(draft)
                    preparedRequest = try brief.prepare(in: document, requestID: submissionID, checkCancellation: check).request
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
                let receipt = try studio.applyStudioCommands(preparedRequest, checkCancellation: {
                    try check()
                    // The cancellation clock may reenter the editor. Preserve the
                    // exact selected image instance/token even at the final commit.
                    try self.requireCurrent(submissionID, captured: captured, studio: studio, currentScope: currentScope)
                })
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
                    audioTrackInstruction: audioTrackInstruction, cutFrameCount: isFrameCut ? document.frames.filter { old in !studio.frames.contains { $0.id == old.id } }.count : 0, duplicatedDrawingCount: isDrawingDuplicate ? receipt.createdElementIDs.count : 0)
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
