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
        let frameExposureTicks: Int?
        let isLayerGlowEdit: Bool
        let isLayerDuplicate: Bool
        let isLayerUpdate: Bool
        let isAudioEdit: Bool
        let renamedProjectName: String?
        let addedAudioClipCount: Int
        let removedAudioClipCount: Int
        let changedExistingAudioClipCount: Int
        let addedFrameCount: Int
        let fps: Int
        let addedDurationSeconds: Double
        var summary: String {
            if selectedErasureMaskCount > 0 {
                return "Added \(selectedErasureMaskCount) erasure \(selectedErasureMaskCount == 1 ? "mask" : "masks") to selected drawings in one undoable local edit. Original artwork remains editable."
            }
            if let renamedProjectName {
                return receipt.outcome == .unchanged ? "The project already has this name. Nothing changed."
                    : "Renamed project to “\(renamedProjectName)” in one undoable local edit."
            }
            if let frameExposureTicks {
                return receipt.outcome == .unchanged ? "The selected frame already has this exposure. Nothing changed."
                    : "Set selected frame exposure to \(frameExposureTicks) ticks at \(fps) FPS in one undoable local edit."
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
        let selectedTool: DrawingTool?
        let activePanel: StudioPanelType
        let isPlaying: Bool
        init(accountID: String?, screen: StudioViewModel.CommandScreenContext, document: StudioCommandContext) {
            self.accountID = accountID; projectID = document.projectID; revision = document.revision
            activeFrameID = document.activeFrameID; activeLayerID = document.activeLayerID
            displayedFrameID = screen.displayedFrameID; selectedElementIDs = screen.selectedElementIDs
            selectedAudioClipID = screen.selectedAudioClipID; selectedTool = screen.selectedTool
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
        let captured = Capture(accountID: accountID, screen: screen, document: document)
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
                let isErasure = SpatterSelectedErasureInstruction.isInstruction(draft)
                let isAudio = SpatterAudioInstruction.isAudioInstruction(draft)
                let isLayerUpdate = SpatterLayerUpdateInstruction.isInstruction(draft)
                let isRename = !isLayerUpdate && SpatterProjectRenameInstruction.isInstruction(draft)
                let isExposure = !isLayerUpdate && !isRename && SpatterFrameExposureInstruction.isInstruction(draft)
                let isLayerDuplicate = !isLayerUpdate && !isRename && SpatterLayerDuplicateInstruction.isInstruction(draft)
                let isGlow = !isLayerUpdate && !isRename && SpatterLayerGlowInstruction.isInstruction(draft)
                let preparedRequest: StudioCommandRequest
                if isErasure {
                    preparedRequest = try SpatterSelectedErasureInstruction.parse(draft).prepare(in: document,
                        selectedElementIDs: captured.selectedElementIDs, requestID: submissionID, checkCancellation: check)
                } else if isRename {
                    preparedRequest = try SpatterProjectRenameInstruction.parse(draft).prepare(in: document, requestID: submissionID, checkCancellation: check)
                } else if isExposure {
                    preparedRequest = try SpatterFrameExposureInstruction.parse(draft).prepare(in: document,
                        requestID: submissionID, checkCancellation: check)
                } else if isLayerUpdate {
                    preparedRequest = try SpatterLayerUpdateInstruction.parse(draft).prepare(in:document,requestID:submissionID,checkCancellation:check)
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
                let receipt = try studio.applyStudioCommands(preparedRequest, checkCancellation: check)
                let newIDs = Set(receipt.createdFrameIDs)
                let addedTicks = studio.frames.filter { newIDs.contains($0.id) }.reduce(0) { $0 + $1.durationTicks }
                let oldAudioIDs = Set(document.editableAudioClips.map(\.id))
                let addedAudioCount = studio.audioClips.filter { !oldAudioIDs.contains($0.id) }.count
                let currentMaskCount = studio.document.frames.reduce(0) { count, frame in
                    count + frame.elements.reduce(0) { $0 + ($1.selectionErasures?.count ?? 0) }
                }
                let result = AppliedEdit(receipt: receipt, selectedErasureMaskCount: isErasure ? max(0, currentMaskCount - previousMaskCount) : 0, frameExposureTicks: isExposure ? studio.currentFrame.durationTicks : nil, isLayerGlowEdit: isGlow, isLayerDuplicate:isLayerDuplicate, isLayerUpdate:isLayerUpdate, isAudioEdit: isAudio, renamedProjectName: isRename ? studio.document.name : nil, addedAudioClipCount: addedAudioCount,
                    removedAudioClipCount: document.editableAudioClips.filter { old in !studio.audioClips.contains { $0.id == old.id } }.count,
                    changedExistingAudioClipCount: studio.audioClips.filter { new in document.editableAudioClips.contains { $0.id == new.id && $0 != new } }.count,
                    addedFrameCount: receipt.createdFrameIDs.count,
                    fps: studio.fps, addedDurationSeconds: Double(addedTicks) / Double(studio.fps))
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
              Capture(accountID: scope.accountID, screen: screen, document: document) == captured else { throw SessionError.contextChanged }
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
