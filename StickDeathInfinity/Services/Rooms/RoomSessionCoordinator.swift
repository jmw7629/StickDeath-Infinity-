// ═══════════════════════════════════════════════════════════════════
// RoomSessionCoordinator — the one active shared-project session. Owns the
// RoomCommandSync for the room whose project is open, drains queued local
// edits through RoomsClient and hands remote commands to whichever editor
// hook is registered. StudioRoomBridge (ViewModels/StudioViewModel+Rooms.swift)
// registers the Studio hook while the room's project is open in Studio; a
// remote command the editor cannot apply stays queued, with its reason, until
// it applies or the creator explicitly skips it.
//
// It also records the active-project handoff: which room's project was opened
// in Studio, so returning to Rooms lands on that room and leaving the room
// ends synchronisation without touching the device project.
// ═══════════════════════════════════════════════════════════════════

import Foundation

@MainActor
final class RoomSessionCoordinator {
    static let shared = RoomSessionCoordinator(client: nil)

    struct Session: Equatable {
        let room: UUID
        let projectID: UUID?
        let canEdit: Bool
        let account: UUID
    }
    /// The room whose shared project is open in Studio.
    struct Handoff: Equatable {
        let room: UUID
        let roomTitle: String
        let projectID: UUID
    }
    enum DrainOutcome: Equatable { case idle, sent(Int), conflict(Int), held(Int), stopped(String) }

    private var client: RoomsClient?
    private(set) var session: Session?
    private(set) var sync: RoomCommandSync?
    private(set) var handoff: Handoff?
    /// Why the last session ended, for a truthful notice. Device projects are
    /// never modified or deleted when a session ends.
    private(set) var endReason: String?
    /// Editor hook: returns true when the remote command was applied (or
    /// deliberately skipped); false keeps it queued for a later attempt.
    var applyRemote: ((RoomCommandRecord) -> Bool)?

    /// The oldest remote command the editor could not apply, and why. Later
    /// remote commands wait behind it so their order is never changed.
    struct BlockedRemote: Equatable { let opID: UUID; let revision: Int; let reason: String }
    private(set) var blockedRemote: BlockedRemote?
    /// Remote commands the creator chose to skip; their device copy differs from the room's.
    private(set) var skippedRemote: [UUID] = []
    private(set) var appliedRemoteCount = 0
    private(set) var publishedLocalCount = 0
    /// Local changes that could not be sent (unsupported edit, view-only role,
    /// size bound). They stay on this device; the reason is shown, never hidden.
    private(set) var unsharedLocalCount = 0
    private(set) var lastUnsharedReason: String?
    /// Why the last send stopped (offline, refused); cleared by the next clean pass.
    private(set) var lastStopReason: String?
    /// Editor hook for "Discard mine": revert this local edit through the
    /// editor's own undo history. Returns nil when it was reverted, otherwise
    /// the reason it could not be reverted automatically.
    var revertLocalEdit: ((UUID) -> String?)?

    init(client: RoomsClient?) { self.client = client }
    func attachClient(_ client: RoomsClient) { self.client = client }

    func begin(room: UUID, head: Int, projectID: UUID?, canEdit: Bool, account: UUID) {
        if let session, session.room == room, session.account == account {
            // Same session: only a permission change is applied.
            if session.canEdit != canEdit { self.session = Session(room: room, projectID: projectID, canEdit: canEdit, account: account) }
            return
        }
        session = Session(room: room, projectID: projectID, canEdit: canEdit, account: account)
        sync = RoomCommandSync(room: room, head: head)
        endReason = nil
        resetCounters()
        if let handoff, handoff.room != room { self.handoff = nil }
    }
    func end(reason: String? = nil) {
        session = nil; sync = nil; handoff = nil
        resetCounters()
        if let reason { endReason = reason }
    }
    private func resetCounters() {
        blockedRemote = nil; skippedRemote = []; appliedRemoteCount = 0; publishedLocalCount = 0
        unsharedLocalCount = 0; lastUnsharedReason = nil; lastStopReason = nil
    }

    // MARK: Handoff (#234)

    /// Record that the room's shared project is now open in Studio.
    func handOffToStudio(room: UUID, roomTitle: String, projectID: UUID) {
        guard session?.room == room else { return }
        handoff = Handoff(room: room, roomTitle: roomTitle, projectID: projectID)
    }
    /// Whether leaving the Rooms screen should keep the session alive because
    /// its project is being edited in Studio.
    func isHandedOff(room: UUID) -> Bool { handoff?.room == room && session?.room == room }
    /// The room to show when the creator comes back from Studio.
    var returnRoom: UUID? { handoff?.room }
    /// The creator explicitly stopped working on the shared project.
    func finishHandoff() { handoff = nil }

    /// A local edit from the editor. Refused when the member can only view.
    @discardableResult
    func publishLocalEdit(kind: String, payload: CommunityJSONValue, opID: UUID = UUID()) -> Bool {
        guard let session, session.canEdit, let sync, sync.enqueue(kind: kind, payload: payload, opID: opID) else { return false }
        publishedLocalCount += 1
        return true
    }
    /// A local change the editor could not share; it stays on this device.
    func noteUnsharedLocalEdit(_ reason: String) {
        guard session != nil else { return }
        unsharedLocalCount += 1; lastUnsharedReason = reason
    }
    /// The editor could not apply this remote command yet (it stays queued).
    func noteRemoteBlocked(_ record: RoomCommandRecord, reason: String) {
        guard sync?.inbox.first?.op_id == record.op_id else { return }
        blockedRemote = BlockedRemote(opID: record.op_id, revision: record.revision, reason: reason)
    }
    /// The creator explicitly skips the blocked remote command after reading
    /// why it could not be applied. Their copy then differs from the room's;
    /// the skip is recorded and shown, and later commands continue in order.
    @discardableResult
    func skipBlockedRemote() -> Bool {
        guard let blocked = blockedRemote, let sync, let first = sync.nextRemoteToApply(), first.op_id == blocked.opID else { return false }
        sync.acknowledgeRemote(first)
        skippedRemote.append(first.op_id); blockedRemote = nil
        applyQueued()
        return true
    }
    /// Whether this room's shared project is the one open in the editor.
    func isSharing(projectID: UUID) -> Bool {
        guard let session, let handoff else { return false }
        return handoff.room == session.room && handoff.projectID == projectID
    }
    /// Undo one of this creator's own acknowledged edits.
    @discardableResult
    func undoOwnEdit(_ op: UUID) -> Bool {
        guard let session, session.canEdit, let sync else { return false }
        return sync.enqueueUndo(of: op)
    }
    /// The creator decided an overlapping conflict after seeing the other edit.
    @discardableResult
    func resolveHeldConflict(keepMine: Bool) -> Bool { sync?.resolveHeld(keepMine: keepMine) ?? false }
    var heldConflict: RoomCommandSync.HeldConflict? { sync?.held }

    enum DiscardOutcome: Equatable {
        /// The edit is no longer sent and the editor undid it locally.
        case reverted
        /// The edit is no longer sent but stays in the device copy, for this reason.
        case notReverted(String)
        case noConflict
    }
    /// "Discard mine": stop sending the held local edit and ask the editor to
    /// undo it. Studio reverts it only when it is still the most recent change
    /// in its history; otherwise the reason is returned and nothing else changes.
    @discardableResult
    func discardHeldConflict() -> DiscardOutcome {
        guard let held = sync?.held else { return .noConflict }
        let failure: String? = revertLocalEdit.map { $0(held.opID) }
            ?? "Studio is not open on the shared project, so your edit stays in your device copy. Open it in Studio and use Undo if you no longer want it."
        // The hook may end the session; the decision applies to the sync it was made for.
        guard sync?.resolveHeld(keepMine: false) == true else { return .noConflict }
        return failure.map(DiscardOutcome.notReverted) ?? .reverted
    }

    /// The compact room status Studio shows in its top bar while the shared
    /// project is open. Nil when no room session is handed off to Studio.
    struct StudioSyncStatus: Equatable {
        enum Level: Equatable { case synced, syncing, waiting, conflict, paused }
        let level: Level
        let label: String
        let detail: String
    }
    var studioSyncStatus: StudioSyncStatus? {
        guard let session, let handoff, handoff.room == session.room, let sync else { return nil }
        let unshared = unsharedLocalCount == 0 ? "" : " \(unsharedLocalCount) local change\(unsharedLocalCount == 1 ? "" : "s") not shared\(lastUnsharedReason.map { " (latest: \($0))" } ?? "")."
        let counts = "Head revision \(sync.head). \(appliedRemoteCount) applied, \(publishedLocalCount) sent or queued, \(sync.pending.count) unsent, \(sync.inbox.count) waiting, \(skippedRemote.count) skipped.\(unshared)"
        if let held = sync.held {
            return .init(level: .conflict, label: "Room: decide",
                detail: "Your edit\(held.target.map { " to \($0)" } ?? "") overlaps \(held.overlapping.count) edit\(held.overlapping.count == 1 ? "" : "s") by another creator. Nothing was overwritten. Keep yours on top, or discard yours (Studio undoes it when it is still your latest change). " + counts)
        }
        if !session.canEdit {
            return .init(level: .paused, label: "Room: view only", detail: "You can view this room's project but not edit it. Local changes stay on this device. " + counts)
        }
        if let blockedRemote {
            return .init(level: .waiting, label: "Room: waiting", detail: "Shared edit #\(blockedRemote.revision) is waiting: \(blockedRemote.reason) " + counts)
        }
        if let lastStopReason {
            return .init(level: .paused, label: "Room: paused", detail: "Synchronisation paused: \(lastStopReason) It retries automatically. " + counts)
        }
        let busy = sync.pending.count + sync.inbox.count
        if busy > 0 { return .init(level: .syncing, label: "Room: \(busy) to sync", detail: counts) }
        return .init(level: .synced, label: "Room: in sync", detail: counts)
    }

    /// Send queued edits in order; stop at the first conflict so the editor
    /// applies the missing remote commands before retrying.
    func drain() async -> DrainOutcome {
        guard let sync, let client, session != nil else { return .idle }
        if let held = sync.held { return .held(held.overlapping.count) }
        var sent = 0
        while let request = sync.nextAppend(), let opID = request.op_id {
            let response: RoomCommandResponse
            do { response = try await client.append(request) }
            catch {
                let reason = CommunityGateway.normalize(error).errorDescription ?? "Synchronisation failed."
                lastStopReason = reason
                return .stopped(reason)
            }
            switch sync.handleAppend(response, for: opID) {
            case .applied, .duplicate: sent += 1
            case .rebased: sent += 1
            case .conflict(_, let missing):
                if let held = sync.held { return .held(held.overlapping.count) }
                return .conflict(missing.count)
            case .refused(let message):
                if sync.accessEnded { end(reason: "Room access ended. Your device copy of the project is unchanged.") }
                else if sync.editingRevoked { endReason = "Editing permission was withdrawn. Your local edits stay on this device." }
                if session != nil { lastStopReason = message }
                return .stopped(message)
            }
        }
        lastStopReason = nil
        return sent == 0 ? .idle : .sent(sent)
    }

    /// Fetch newer commands and hand them to the editor hook in order.
    func catchUp() async -> RoomCommandSync.CatchUpOutcome {
        guard let sync, let client, session != nil else { return .accessEnded }
        let response: RoomCommandResponse
        do { response = try await client.commands(sync.catchUpRequest()) }
        catch { return .upToDate }
        let outcome = sync.handleCatchUp(response)
        if sync.accessEnded { end(reason: "Room access ended. Your device copy of the project is unchanged."); return .accessEnded }
        applyQueued()
        return outcome
    }
    /// Hand queued remote commands to the editor hook, oldest first, stopping
    /// at the first one the editor cannot apply yet.
    func applyQueued() {
        guard let sync else { return }
        while let record = sync.nextRemoteToApply() {
            guard let apply = applyRemote, apply(record) else { break }
            // The hook may end the session (for example on a revoked project).
            guard self.sync === sync else { return }
            sync.acknowledgeRemote(record)
            appliedRemoteCount += 1
            if blockedRemote?.opID == record.op_id { blockedRemote = nil }
        }
    }
    /// One synchronisation pass: fetch and apply newer commands, then send
    /// queued local edits fenced on the resulting head.
    func synchronise() async -> (catchUp: RoomCommandSync.CatchUpOutcome, drain: DrainOutcome) {
        let received = await catchUp()
        guard session != nil else { return (received, .idle) }
        // Remote edits that arrived with a conflict reply are applied first.
        applyQueued()
        return (received, await drain())
    }
    var pendingRemoteCount: Int { sync?.inbox.count ?? 0 }
    var pendingLocalCount: Int { sync?.pending.count ?? 0 }
    var head: Int { sync?.head ?? 0 }
}
