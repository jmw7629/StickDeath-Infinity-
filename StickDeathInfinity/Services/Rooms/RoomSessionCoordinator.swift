// ═══════════════════════════════════════════════════════════════════
// RoomSessionCoordinator — the one active shared-project session. Owns the
// RoomCommandSync for the room whose project is open, drains queued local
// edits through RoomsClient and hands remote commands to whichever editor
// hook is registered. The Studio editor registers its hook (deferred to the
// Studio owner); until then remote commands stay queued and the Rooms screen
// shows them truthfully as "not applied in Studio".
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
    enum DrainOutcome: Equatable { case idle, sent(Int), conflict(Int), stopped(String) }

    private var client: RoomsClient?
    private(set) var session: Session?
    private(set) var sync: RoomCommandSync?
    /// Editor hook: returns true when the remote command was applied (or
    /// deliberately skipped); false keeps it queued for a later attempt.
    var applyRemote: ((RoomCommandRecord) -> Bool)?

    init(client: RoomsClient?) { self.client = client }
    func attachClient(_ client: RoomsClient) { self.client = client }

    func begin(room: UUID, head: Int, projectID: UUID?, canEdit: Bool, account: UUID) {
        guard session?.room != room || session?.account != account else { return }
        session = Session(room: room, projectID: projectID, canEdit: canEdit, account: account)
        sync = RoomCommandSync(room: room, head: head)
    }
    func end() { session = nil; sync = nil }

    /// A local edit from the editor. Refused when the member can only view.
    @discardableResult
    func publishLocalEdit(kind: String, payload: CommunityJSONValue) -> Bool {
        guard let session, session.canEdit, let sync else { return false }
        return sync.enqueue(kind: kind, payload: payload)
    }

    /// Send queued edits in order; stop at the first conflict so the editor
    /// applies the missing remote commands before retrying.
    func drain() async -> DrainOutcome {
        guard let sync, let client, session != nil else { return .idle }
        var sent = 0
        while let request = sync.nextAppend(), let opID = request.op_id {
            let response: RoomCommandResponse
            do { response = try await client.append(request) }
            catch { return .stopped(CommunityGateway.normalize(error).errorDescription ?? "Synchronisation failed.") }
            switch sync.handleAppend(response, for: opID) {
            case .applied, .duplicate: sent += 1
            case .conflict(_, let missing): return .conflict(missing.count)
            case .refused(let message):
                if sync.accessEnded { end() }
                return .stopped(message)
            }
        }
        return sent == 0 ? .idle : .sent(sent)
    }

    /// Fetch newer commands and hand them to the editor hook in order.
    func catchUp() async -> RoomCommandSync.CatchUpOutcome {
        guard let sync, let client, let session else { return .accessEnded }
        let response: RoomCommandResponse
        do { response = try await client.commands(sync.catchUpRequest()) }
        catch { return .upToDate }
        let outcome = sync.handleCatchUp(response)
        if sync.accessEnded { end(); return .accessEnded }
        for record in sync.remoteCommandsToApply(author: session.account) {
            guard let apply = applyRemote, apply(record) else { break }
            sync.acknowledgeRemote(record)
        }
        return outcome
    }
    var pendingRemoteCount: Int { sync?.inbox.count ?? 0 }
    var pendingLocalCount: Int { sync?.pending.count ?? 0 }
    var head: Int { sync?.head ?? 0 }
}
