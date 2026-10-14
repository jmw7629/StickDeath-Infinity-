// ═══════════════════════════════════════════════════════════════════
// RoomSessionCoordinator — the one active shared-project session. Owns the
// RoomCommandSync for the room whose project is open, drains queued local
// edits through RoomsClient and hands remote commands to whichever editor
// hook is registered. The Studio editor registers its hook (deferred to the
// Studio owner); until then remote commands stay queued and the Rooms screen
// shows them truthfully as "not applied in Studio".
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
        if let handoff, handoff.room != room { self.handoff = nil }
    }
    func end(reason: String? = nil) {
        session = nil; sync = nil; handoff = nil
        if let reason { endReason = reason }
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
    func publishLocalEdit(kind: String, payload: CommunityJSONValue) -> Bool {
        guard let session, session.canEdit, let sync else { return false }
        return sync.enqueue(kind: kind, payload: payload)
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

    /// Send queued edits in order; stop at the first conflict so the editor
    /// applies the missing remote commands before retrying.
    func drain() async -> DrainOutcome {
        guard let sync, let client, session != nil else { return .idle }
        if let held = sync.held { return .held(held.overlapping.count) }
        var sent = 0
        while let request = sync.nextAppend(), let opID = request.op_id {
            let response: RoomCommandResponse
            do { response = try await client.append(request) }
            catch { return .stopped(CommunityGateway.normalize(error).errorDescription ?? "Synchronisation failed.") }
            switch sync.handleAppend(response, for: opID) {
            case .applied, .duplicate: sent += 1
            case .rebased: sent += 1
            case .conflict(_, let missing):
                if let held = sync.held { return .held(held.overlapping.count) }
                return .conflict(missing.count)
            case .refused(let message):
                if sync.accessEnded { end(reason: "Room access ended. Your device copy of the project is unchanged.") }
                else if sync.editingRevoked { endReason = "Editing permission was withdrawn. Your local edits stay on this device." }
                return .stopped(message)
            }
        }
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
            sync.acknowledgeRemote(record)
        }
    }
    var pendingRemoteCount: Int { sync?.inbox.count ?? 0 }
    var pendingLocalCount: Int { sync?.pending.count ?? 0 }
    var head: Int { sync?.head ?? 0 }
}
