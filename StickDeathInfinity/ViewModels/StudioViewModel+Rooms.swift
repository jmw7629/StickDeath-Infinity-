// ═══════════════════════════════════════════════════════════════════
// StudioRoomBridge — connects the project open in Studio to its room's
// versioned command stream (#232). Every committed Studio command that another
// creator's copy can replay is published with its frame:/layer:/audio: target;
// remote commands are replayed through the same strict decoder and executor as
// any other typed command, keeping the author's stable identities. Conflicts
// follow RoomCommandSync: versioned appends, explicit held conflicts, and a
// blocked remote edit waits with its reason until it applies or the creator
// skips it. Nothing is silently overwritten, dropped or claimed as shared.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Combine

@MainActor
final class StudioRoomBridge: ObservableObject {
    static let shared = StudioRoomBridge()

    /// What the Studio top bar shows while the room's project is open. Nil
    /// when no room session is handed off to Studio.
    @Published private(set) var status: RoomSessionCoordinator.StudioSyncStatus?

    /// True only while a remote command is being replayed, so it is not re-published.
    private(set) var isApplyingRemote = false
    private(set) var lastSync: Date?
    private weak var studio: StudioViewModel?
    private var loop: Task<Void, Never>?
    private var loopToken: UUID?
    /// Document revision after the last change the bridge accounted for
    /// (shared, replayed or view-only). Any other revision change was made by
    /// a path with no shared command (for example Undo) and is reported.
    private var accountedRevision: Int?
    /// Document revision right after each published local edit (op id →
    /// revision). "Discard mine" undoes an edit only while the document is
    /// still at that revision, i.e. it is the latest change in history.
    private var localEditRevisions: [UUID: Int] = [:]
    private var localEditOrder: [UUID] = []
    private var coordinator: RoomSessionCoordinator { .shared }

    var isRunning: Bool { loop != nil }

    /// Starts synchronising while this room's handoff lasts. Pull and push run
    /// every `interval`; local edits are also pushed as soon as they commit.
    func start(studio: StudioViewModel, interval: Duration = .seconds(3)) {
        self.studio = studio
        accountedRevision = studio.document.revision
        coordinator.applyRemote = { [weak self] record in self?.applyRemote(record) ?? false }
        coordinator.revertLocalEdit = { [weak self] op in
            // Nil from the bridge means "reverted"; only a missing bridge is a failure.
            guard let self else { return "Studio is not open on the shared project, so your edit stays in your device copy." }
            return self.revertLocalEdit(op)
        }
        localEditRevisions = [:]; localEditOrder = []
        StudioEditObservers.commandsCommitted = { [weak self] request, receipt in self?.committed(request, receipt) }
        StudioEditObservers.elementsCommitted = { [weak self] before, after, frameID in self?.committed(before: before, after: after, frameID: frameID) }
        loop?.cancel()
        // A replaced loop must not detach the hooks this start installed when it
        // finally observes its cancellation, so each loop carries its own token.
        let token = UUID()
        loopToken = token
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.coordinator.handoff != nil else { break }
                await self.synchronise()
                try? await Task.sleep(for: interval)
            }
            guard let self, self.loopToken == token else { return }
            self.detach()
        }
        refreshStatus()
    }

    func stop() {
        loop?.cancel()
        detach()
    }

    private func detach() {
        loop = nil
        loopToken = nil
        coordinator.applyRemote = nil
        coordinator.revertLocalEdit = nil
        localEditRevisions = [:]; localEditOrder = []
        status = nil
        StudioEditObservers.commandsCommitted = nil
        StudioEditObservers.elementsCommitted = nil
    }

    /// The open document is this room's shared project.
    private var sharingStudio: StudioViewModel? {
        guard let studio, studio.isEditing, coordinator.isSharing(projectID: studio.document.id) else { return nil }
        return studio
    }

    /// One pass: report unaccounted local changes, apply newer remote commands,
    /// then send queued local edits fenced on the resulting head.
    func synchronise() async {
        guard let studio = sharingStudio else { refreshStatus(); return }
        noteUnaccountedChanges(upTo: studio.document.revision)
        let previousHeld = coordinator.heldConflict
        let report = await coordinator.synchronise()
        lastSync = Date()
        refreshStatus()
        if coordinator.session == nil, let reason = coordinator.endReason {
            studio.message = reason
            return
        }
        if let held = coordinator.heldConflict, held != previousHeld {
            studio.message = "Another creator changed the same \(held.target ?? "project") at the same time. Nothing was overwritten. Use the room status at the top of Studio to keep your edit on top or discard it."
        }
        if case .stopped(let reason) = report.drain { studio.message = "Room synchronisation paused: \(reason)" }
    }

    // MARK: Publishing

    private func committed(_ request: StudioCommandRequest, _ receipt: StudioCommandReceipt) {
        guard !isApplyingRemote, let studio = sharingStudio else { return }
        noteUnaccountedChanges(upTo: receipt.previousRevision)
        defer { accountedRevision = studio.document.revision }
        guard receipt.outcome != .unchanged else { return }
        guard case .apply(let commands) = request.action else {
            unshared("Undo and Redo are not shared with the room yet; collaborators keep the earlier version.")
            return
        }
        switch StudioSharedEdit.share(commands) {
        case .viewOnly: return
        case .unsupported(let reason): unshared(reason)
        case .replay(let replay):
            do { publish(try StudioSharedEdit.payload(replay, receipt: receipt)) }
            catch { unshared("This edit is too large to share with the room in one message.") }
        }
    }

    private func committed(before: StudioDocument, after: StudioDocument, frameID: String) {
        guard !isApplyingRemote, let studio = sharingStudio else { return }
        noteUnaccountedChanges(upTo: before.revision)
        defer { accountedRevision = studio.document.revision }
        guard let touch = StudioSharedEdit.drawCommands(before: before, after: after, frameID: frameID) else {
            unshared("This drawing (for example a fill, pixel effect or erasure) cannot be replayed exactly on another device yet.")
            return
        }
        do { publish(try StudioSharedEdit.payload(touch.commands, created: touch.created)) }
        catch { unshared("This drawing is too large to share with the room in one message.") }
    }

    private func publish(_ payload: StudioSharedEdit.Payload) {
        guard coordinator.session?.canEdit == true else {
            unshared("You can view this room's project but not edit it.")
            return
        }
        let op = UUID()
        guard let value = try? JSONDecoder().decode(CommunityJSONValue.self, from: JSONEncoder().encode(payload)),
              coordinator.publishLocalEdit(kind: StudioSharedEdit.kind, payload: value, opID: op) else {
            unshared("The room did not accept this edit for sending (size bound, ended access or withdrawn editing).")
            return
        }
        if let studio { rememberLocalEdit(op, revision: studio.document.revision) }
        refreshStatus()
        Task { [weak self] in await self?.push() }
    }

    private func rememberLocalEdit(_ op: UUID, revision: Int) {
        localEditRevisions[op] = revision; localEditOrder.append(op)
        // Only the latest edit can be reverted through Undo; keep a short tail.
        while localEditOrder.count > 32 { localEditRevisions.removeValue(forKey: localEditOrder.removeFirst()) }
    }

    /// The held local edit is still the newest change in Studio's history.
    private func isLatestChange(_ op: UUID) -> Bool {
        guard let studio = sharingStudio, let revision = localEditRevisions[op] else { return false }
        return studio.document.revision == revision && studio.canUndo
    }

    /// "Discard mine" (#232): undo the held local edit through Studio's own
    /// history when it is still the most recent change. Returns nil when it
    /// was reverted, otherwise why it was left in the device copy.
    private func revertLocalEdit(_ op: UUID) -> String? {
        guard let studio = sharingStudio else {
            return "Studio is not open on the shared project, so your edit stays in your device copy. Open it in Studio and use Undo if you no longer want it."
        }
        guard isLatestChange(op) else {
            return "Your edit is no longer the most recent change in Studio, so it can't be reverted automatically. It stays in your device copy; undo or change it yourself if you no longer want it."
        }
        guard studio.activeStrokeID == nil, studio.pendingBrushStroke == nil, studio.textDraft == nil, !studio.isSaving else {
            return "Studio is drawing, editing text or saving, so your edit was not reverted automatically. It stays in your device copy; use Undo when Studio is idle."
        }
        let before = studio.document.revision
        studio.undo()
        guard studio.document.revision != before else {
            return "Studio could not undo your edit right now. It stays in your device copy; use Undo if you no longer want it."
        }
        accountedRevision = studio.document.revision
        localEditRevisions.removeValue(forKey: op); localEditOrder.removeAll { $0 == op }
        studio.message = "Discarded your overlapping edit: Studio undid it, and the other creator's edit is applied next."
        return nil
    }

    /// The top-bar decision on a held conflict. The outcome is shown in Studio.
    func resolveConflict(keepMine: Bool) {
        if keepMine {
            guard coordinator.resolveHeldConflict(keepMine: true) else { refreshStatus(); return }
            studio?.message = "Keeping your edit: it is sent again on top of the other creator's edit."
        } else {
            switch coordinator.discardHeldConflict() {
            case .reverted: break
            case .notReverted(let reason): studio?.message = "Your edit will not be sent to the room. " + reason
            case .noConflict: break
            }
        }
        refreshStatus()
        Task { [weak self] in await self?.synchronise() }
    }

    func refreshStatus() {
        let next = loop == nil ? nil : coordinator.studioSyncStatus
        if next != status { status = next }
    }

    /// Sends queued local edits without waiting for the next pull.
    private func push() async {
        guard coordinator.session != nil else { return }
        if case .stopped(let reason) = await coordinator.drain() { studio?.message = "Room synchronisation paused: \(reason)" }
        refreshStatus()
    }

    private func unshared(_ reason: String) {
        coordinator.noteUnsharedLocalEdit(reason)
        studio?.message = "Not shared with the room: \(reason) It stays on this device."
        refreshStatus()
    }

    private func noteUnaccountedChanges(upTo revision: Int) {
        guard let accounted = accountedRevision else { accountedRevision = revision; return }
        if revision != accounted {
            unshared("A change made without a shared Studio command (for example Undo, Redo or a panel action) was not sent; collaborators do not see it.")
        }
        accountedRevision = revision
    }

    // MARK: Replaying

    private func applyRemote(_ record: RoomCommandRecord) -> Bool {
        guard let studio = sharingStudio else {
            coordinator.noteRemoteBlocked(record, reason: "Open the shared project in Studio to apply edits from other creators.")
            return false
        }
        // Playback, touch input and saving defer replay; it retries on the next pass.
        guard !studio.isPlaying, studio.activeStrokeID == nil, studio.pendingBrushStroke == nil, !studio.isSaving else {
            coordinator.noteRemoteBlocked(record, reason: "Waiting for playback, drawing or saving to finish before applying the next shared edit.")
            return false
        }
        // While an overlapping conflict is held and the local edit is still the
        // latest change, their edit waits for the decision so "Discard mine"
        // can undo yours first. It is not marked blocked and cannot be skipped.
        if let held = coordinator.heldConflict, isLatestChange(held.opID) { return false }
        guard record.kind == StudioSharedEdit.kind else {
            coordinator.noteRemoteBlocked(record, reason: record.kind == "undo"
                ? "Another creator undid one of their edits. Studio cannot replay a room undo yet; skip it to continue (your copy will keep that edit)."
                : "This shared edit (\(record.kind.prefix(64))) is not one Studio can replay. Skip it to continue; your copy will differ.")
            return false
        }
        noteUnaccountedChanges(upTo: studio.document.revision)
        do {
            let payload = try JSONDecoder().decode(StudioSharedEdit.Payload.self, from: JSONEncoder().encode(record.payload))
            let request = try StudioSharedEdit.request(from: payload, projectID: studio.document.id, revision: studio.document.revision)
            isApplyingRemote = true
            defer { isApplyingRemote = false }
            _ = try studio.applyStudioCommands(request, checkCancellation: {})
            accountedRevision = studio.document.revision
            return true
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "The edit is malformed."
            coordinator.noteRemoteBlocked(record, reason: "Shared edit #\(record.revision) could not be applied: \(reason) It is retried automatically; skip it only if your copy has diverged.")
            return false
        }
    }
}

extension StudioViewModel {
    /// Begin synchronising the open project with the room it was opened from.
    func startRoomSynchronisation() { StudioRoomBridge.shared.start(studio: self) }
}
