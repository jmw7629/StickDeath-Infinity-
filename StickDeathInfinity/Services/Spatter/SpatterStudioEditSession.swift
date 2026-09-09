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
    enum Status: Equatable { case idle, preparing, applied, cancelled, stale, rejected, closed }
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
        let addedFrameCount: Int
        let fps: Int
        let addedDurationSeconds: Double
        var summary: String {
            "Added \(addedFrameCount) editable frames at \(fps) FPS (\(String(format: "%.3f", addedDurationSeconds)) seconds) in one undoable local edit."
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
    private let checkpoint: Checkpoint
    private var request: Task<Void, Never>?
    private var taskID: UUID?
    private var generation = UUID()
    private var acceptedIDs: Set<UUID> = []
    private var appliedAccountID: String?

    /// Injection is only a scheduling/cancellation boundary for deterministic
    /// tests. The parser, commands, editor and persistence are always production.
    init(checkpoint: @escaping Checkpoint = { await Task.yield(); try Task.checkCancellation() }) {
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
        case contextChanged, accountChanged, outsideStudio, unavailable(String)
        var errorDescription: String? {
            switch self {
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
        acceptedIDs.insert(submissionID)
        generation = submissionID; taskID = submissionID
        appliedEdit = nil; appliedAccountID = nil; notice = nil; status = .preparing
        request = Task { [weak self, weak studio] in
            guard let self else { return }
            defer {
                if self.taskID == submissionID { self.request = nil; self.taskID = nil }
            }
            do {
                try await self.checkpoint()
                guard let studio else { throw SessionError.outsideStudio }
                try self.requireCurrent(submissionID, captured: captured, studio: studio, currentScope: currentScope)
                let recipe = try SpatterMotionRecipe.parse(draft)
                let prepared = try recipe.prepare(in: document, requestID: submissionID)
                try await self.checkpoint()
                try self.requireCurrent(submissionID, captured: captured, studio: studio, currentScope: currentScope)
                // No suspension between the last fresh context check and this
                // synchronous atomic VM transaction. Its own original revision,
                // brush-input, work-budget and cancellation guards still apply.
                let receipt = try studio.applyStudioCommands(prepared.request)
                let result = AppliedEdit(receipt: receipt, addedFrameCount: receipt.createdFrameIDs.count,
                    fps: studio.fps, addedDurationSeconds: Double(receipt.createdFrameIDs.count) / Double(studio.fps))
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
    func waitForCompletion() async { let current = request; await current?.value }
}
