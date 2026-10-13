// ═══════════════════════════════════════════════════════════════════
// RoomsClient — invitation-based collaboration on explicitly shared Studio
// projects (collaboration-watch.sql, room-invitations.sql, rooms-v2.sql).
// Codes are admission-request credentials, never account tokens; both the
// recipient's consent and the owner's approval are recorded server-side.
// No chat, calls, camera, microphone or media streams exist here, and no
// project content leaves the device through any of these calls.
// ═══════════════════════════════════════════════════════════════════

import Foundation

@MainActor
final class RoomsClient {
    let gateway: CommunityGateway
    init(gateway: CommunityGateway) { self.gateway = gateway }

    // MARK: Browser

    /// Rooms visible under RLS: owned or accepted. Closed rooms are excluded
    /// server-side; the flag is still checked for older schemas.
    func myRooms() async throws -> [RoomSummary] {
        try await gateway.rows("sdi_rooms", filters: [], limit: 100, as: RoomSummary.self).filter { $0.closed != true }
    }
    func members(of room: UUID) async throws -> [RoomMember] {
        try await gateway.rows("sdi_room_members", filters: [.eq("room_id", room.uuidString.lowercased())], limit: 100, as: RoomMember.self)
            .sorted { $0.user_id.uuidString < $1.user_id.uuidString }
    }
    func pendingRequests() async throws -> [RoomPendingRequest] {
        let response = try await gateway.call("sdi_room_manage", params: RoomManageRequest(action: "my_requests"), as: RoomManageResponse.self)
        guard let requests = response.requests else { throw CommunityError.invalidResponse("Pending requests unavailable.") }
        return requests
    }
    func summary(of room: UUID) async throws -> RoomManageResponse {
        let response = try await gateway.call("sdi_room_manage", params: RoomManageRequest(action: "summary", room: room), as: RoomManageResponse.self)
        guard response.room_id == room else { throw CommunityError.invalidResponse("Room summary unavailable.") }
        return response
    }

    // MARK: Creation with explicit project share (#228)

    enum CreationOutcome: Equatable {
        /// Room row exists and the project reference, title and permissions were recorded.
        case created(room: UUID, projectRevision: Int)
        /// The room exists but the share was not recorded; the owner can retry
        /// `set_project` or close the room. Never reported as a shared project.
        case createdWithoutProject(room: UUID, problem: String)
    }
    func createRoom(title: String, share: RoomProjectShare, consent: Bool) async throws -> CreationOutcome {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard consent else { throw CommunityError.server(message: "Confirm that you choose to share this project before creating the room.", code: nil) }
        guard (1...100).contains(name.count) else { throw CommunityError.server(message: "Use a room name of 1–100 characters.", code: nil) }
        if let problem = RoomProjectShare.validate(title: share.title, permissions: share.permissions) { throw CommunityError.server(message: problem, code: nil) }
        let created = try await gateway.call("sdi_room_action", params: RoomActionRequest(action: "create", title: name, consent: true), as: RoomActionResponse.self)
        guard created.status == "created", let room = created.room_id else { throw CommunityError.invalidResponse("Room creation was not confirmed.") }
        do {
            let shared = try await gateway.call("sdi_room_manage", params: share.manageRequest(room: room, revision: 1), as: RoomManageResponse.self)
            guard shared.status == "updated", let revision = shared.project_revision else {
                return .createdWithoutProject(room: room, problem: "The room exists but the project share was not confirmed.")
            }
            return .created(room: room, projectRevision: revision)
        } catch {
            return .createdWithoutProject(room: room, problem: CommunityGateway.normalize(error).errorDescription ?? "Project share failed.")
        }
    }
    func setProject(room: UUID, share: RoomProjectShare, currentRevision: Int) async throws -> Int {
        let response = try await gateway.call("sdi_room_manage", params: share.manageRequest(room: room, revision: currentRevision), as: RoomManageResponse.self)
        guard response.status == "updated", let revision = response.project_revision else { throw CommunityError.invalidResponse("Project share was not confirmed.") }
        return revision
    }

    // MARK: Invitations (#229, #230)

    func mintInvitation(room: UUID) async throws -> String {
        let response = try await gateway.call("sdi_room_action", params: RoomActionRequest(action: "invite", room: room), as: RoomActionResponse.self)
        guard response.status == "invitation_created", let code = response.code, RoomInvitationPolicy.isWellFormed(code) else {
            throw CommunityError.invalidResponse("The server did not return a usable invitation code.")
        }
        return code
    }
    func revokeInvitations(room: UUID) async throws { _ = try await action(RoomActionRequest(action: "revoke_invites", room: room), expecting: "updated") }

    struct InvitationPreview: Equatable { let room: UUID; let title: String }
    func previewInvitation(code raw: String) async throws -> InvitationPreview {
        let code = RoomInvitationPolicy.normalize(raw)
        guard RoomInvitationPolicy.isWellFormed(code) else { throw CommunityError.server(message: "Invitation codes are 64 hexadecimal characters.", code: nil) }
        let response = try await gateway.call("sdi_room_action", params: RoomActionRequest(action: "preview", code: code), as: RoomActionResponse.self)
        guard response.status == "preview", let room = response.room_id, let title = response.title else { throw CommunityError.invalidResponse("Invitation preview unavailable.") }
        return InvitationPreview(room: room, title: title)
    }
    enum AdmissionOutcome: Equatable { case pendingOwnerApproval(room: UUID), alreadyRequested(room: UUID) }
    /// The recipient's consent is sent explicitly; without it the server refuses.
    func requestAdmission(code raw: String, consent: Bool) async throws -> AdmissionOutcome {
        let code = RoomInvitationPolicy.normalize(raw)
        guard consent else { throw CommunityError.server(message: "Accept the room invitation before requesting admission.", code: nil) }
        guard RoomInvitationPolicy.isWellFormed(code) else { throw CommunityError.server(message: "Invitation codes are 64 hexadecimal characters.", code: nil) }
        let response = try await gateway.call("sdi_room_action", params: RoomActionRequest(action: "request", code: code, consent: true), as: RoomActionResponse.self)
        switch (response.status, response.room_id) {
        case ("pending_owner_approval", let room?): return .pendingOwnerApproval(room: room)
        case ("already_requested", let room?): return .alreadyRequested(room: room)
        default: throw CommunityError.invalidResponse("Admission request was not confirmed.")
        }
    }

    // MARK: Membership lifecycle (#231), report/block (#235)

    func approve(room: UUID, member: UUID) async throws { _ = try await action(RoomActionRequest(action: "approve", room: room, subject: member), expecting: "updated") }
    func remove(room: UUID, member: UUID) async throws { _ = try await action(RoomActionRequest(action: "remove", room: room, subject: member), expecting: "updated") }
    func block(room: UUID, member: UUID) async throws { _ = try await action(RoomActionRequest(action: "block", room: room, subject: member), expecting: "updated") }
    func leave(room: UUID) async throws { _ = try await action(RoomActionRequest(action: "leave", room: room), expecting: "left") }
    func close(room: UUID) async throws { _ = try await action(RoomActionRequest(action: "close", room: room), expecting: "updated") }
    func setRole(room: UUID, member: UUID, role: RoomRole) async throws {
        let response = try await gateway.call("sdi_room_manage", params: RoomManageRequest(action: "set_role", room: room, subject: member, role: role.rawValue), as: RoomManageResponse.self)
        guard response.status == "updated" else { throw CommunityError.invalidResponse("Role change was not confirmed.") }
    }
    func report(room: UUID, draft: RoomReportDraft) async throws {
        if let problem = draft.validation { throw CommunityError.server(message: problem, code: nil) }
        let response = try await gateway.call("sdi_room_manage", params: draft.request(room: room), as: RoomManageResponse.self)
        guard response.status == "recorded" else { throw CommunityError.invalidResponse("Report was not confirmed.") }
    }
    private func action(_ request: RoomActionRequest, expecting status: String) async throws -> RoomActionResponse {
        let response = try await gateway.call("sdi_room_action", params: request, as: RoomActionResponse.self)
        guard response.status == status else { throw CommunityError.invalidResponse("The room operation was not confirmed.") }
        return response
    }

    // MARK: Versioned command stream (#232)

    /// Replies keep their `error` field so RoomCommandSync can read a
    /// conflict's `head`/`missing` or detect that access ended.
    func commands(_ request: RoomCommandRequest) async throws -> RoomCommandResponse {
        guard request.action == "since" else { throw CommunityError.invalidResponse("Not a catch-up request.") }
        return try await gateway.callKeepingServerError("sdi_room_command", params: request, as: RoomCommandResponse.self)
    }
    func append(_ request: RoomCommandRequest) async throws -> RoomCommandResponse {
        guard request.action == "append" else { throw CommunityError.invalidResponse("Not an append request.") }
        return try await gateway.callKeepingServerError("sdi_room_command", params: request, as: RoomCommandResponse.self)
    }
}

/// Client state machine for shared edits. Operation ids make retries
/// idempotent; the base revision fences every append so a concurrent edit is
/// surfaced as an explicit conflict carrying the missing commands instead of
/// being overwritten. Remote commands are handed to the editor in order and
/// the head advances only after the editor acknowledges them.
@MainActor
final class RoomCommandSync {
    enum AppendOutcome: Equatable {
        case applied(revision: Int)
        case duplicate(revision: Int)
        case conflict(head: Int, missing: [RoomCommandRecord])
        case refused(String)
    }
    struct PendingCommand: Equatable {
        let opID: UUID
        let kind: String
        let payload: CommunityJSONValue
        let payloadBytes: Int
    }

    let room: UUID
    private(set) var head: Int
    private(set) var pending: [PendingCommand] = []
    private(set) var acknowledged: Set<UUID> = []
    private(set) var inbox: [RoomCommandRecord] = []
    private(set) var accessEnded = false
    private(set) var lastProblem: String?

    init(room: UUID, head: Int) { self.room = room; self.head = max(0, head) }

    /// Queue a local edit; refused when the payload exceeds the server bound.
    func enqueue(kind: String, payload: CommunityJSONValue, opID: UUID = UUID()) -> Bool {
        guard !accessEnded, (1...64).contains(kind.count), payload.objectValue != nil,
              let bytes = try? CommunityCoding.encoder().encode(payload), RoomQuotaPolicy.payloadFits(bytes),
              !pending.contains(where: { $0.opID == opID }), !acknowledged.contains(opID) else { return false }
        pending.append(PendingCommand(opID: opID, kind: kind, payload: payload, payloadBytes: bytes.count))
        return true
    }
    /// The next append request, fenced on the current head. Nil when nothing is
    /// pending or remote commands still await the editor.
    func nextAppend() -> RoomCommandRequest? {
        guard !accessEnded, inbox.isEmpty, let next = pending.first else { return nil }
        return RoomCommandRequest(action: "append", room: room, op_id: next.opID, base_revision: head, kind: next.kind, payload: next.payload)
    }
    func catchUpRequest(pageSize: Int = 200) -> RoomCommandRequest {
        RoomCommandRequest(action: "since", room: room, after: head, page_size: pageSize)
    }

    func handleAppend(_ response: RoomCommandResponse, for opID: UUID) -> AppendOutcome {
        guard let index = pending.firstIndex(where: { $0.opID == opID }) else { return .refused("Unknown operation.") }
        if let error = response.error, !error.isEmpty {
            if error == "conflict", let serverHead = response.head {
                let missing = (response.missing ?? []).filter { $0.revision > head }.sorted { $0.revision < $1.revision }
                inbox.append(contentsOf: missing.filter { record in !inbox.contains(where: { $0.op_id == record.op_id }) })
                lastProblem = "Another editor changed the project. Apply \(missing.count) remote edit\(missing.count == 1 ? "" : "s") before yours is sent."
                return .conflict(head: serverHead, missing: missing)
            }
            if error.contains("unavailable") || error.contains("Sign in") { accessEnded = true }
            lastProblem = error
            return .refused(error)
        }
        switch (response.status, response.revision) {
        case ("applied", let revision?):
            guard revision == head + 1 else { lastProblem = "Revision sequence broke; resynchronising."; return .refused("Resynchronise before continuing.") }
            head = revision; acknowledged.insert(opID); pending.remove(at: index); lastProblem = nil
            return .applied(revision: revision)
        case ("duplicate", let revision?):
            acknowledged.insert(opID); pending.remove(at: index)
            if revision > head { head = revision }
            return .duplicate(revision: revision)
        default:
            lastProblem = "Append was not confirmed."
            return .refused("Append was not confirmed.")
        }
    }

    /// Merge a `since` reply: contiguous records newer than the head enter the
    /// inbox; a gap means an older page is still needed.
    enum CatchUpOutcome: Equatable { case upToDate, received(Int), gap(expected: Int), accessEnded }
    func handleCatchUp(_ response: RoomCommandResponse) -> CatchUpOutcome {
        if let error = response.error, !error.isEmpty {
            if error.contains("unavailable") || error.contains("Sign in") { accessEnded = true; return .accessEnded }
            lastProblem = error; return .upToDate
        }
        let records = (response.commands ?? []).sorted { $0.revision < $1.revision }
        var expected = (inbox.last?.revision ?? head) + 1
        var added = 0
        for record in records {
            if record.revision < expected { continue }
            if record.revision != expected { return .gap(expected: expected) }
            if !inbox.contains(where: { $0.op_id == record.op_id }) { inbox.append(record); added += 1 }
            expected += 1
        }
        if let serverHead = response.head, serverHead > expected - 1, records.isEmpty { return .gap(expected: expected) }
        return added == 0 ? .upToDate : .received(added)
    }
    /// Commands the editor must apply, oldest first. Own commands that were
    /// already acknowledged are skipped so undo ownership stays local.
    func remoteCommandsToApply(author: UUID?) -> [RoomCommandRecord] {
        inbox.filter { !acknowledged.contains($0.op_id) || $0.author != author }
    }
    /// The editor applied (or deliberately skipped) a remote command.
    func acknowledgeRemote(_ record: RoomCommandRecord) {
        guard let first = inbox.first, first.op_id == record.op_id else { return }
        inbox.removeFirst(); head = max(head, record.revision); acknowledged.insert(record.op_id)
    }
    func endAccess() { accessEnded = true; pending = []; inbox = [] }
    var remainingRevisions: Int { RoomQuotaPolicy.remainingRevisions(head: head) }
}
