// ═══════════════════════════════════════════════════════════════════
// RoomsClient — invitation-based collaboration on explicitly shared Studio
// projects (collaboration-watch.sql, room-invitations.sql, rooms-v2.sql).
// Codes are admission-request credentials, never account tokens; both the
// recipient's consent and the owner's approval are recorded server-side.
// No chat, calls, camera, microphone or media streams exist here, and no
// project content leaves the device through any of these calls.
// ═══════════════════════════════════════════════════════════════════

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

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

    /// Bounded transfer of explicitly chosen files (#233).
    var assets: RoomAssetTransfer { RoomAssetTransfer(gateway: gateway) }

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

/// The entity a command edits, read from its payload's `target` field
/// ("frame:<id>", "layer:<id>", "audio:<id>"). Nil means the whole document,
/// which overlaps every other edit. Mirrors rooms-v2.sql's rebase rule.
enum RoomCommandTarget {
    static func of(_ payload: CommunityJSONValue) -> String? {
        guard let value = payload.objectValue?["target"]?.stringValue, (1...200).contains(value.count) else { return nil }
        return value
    }
    static func overlaps(_ local: String?, _ remote: String?) -> Bool {
        guard let local, let remote else { return true }
        return local == remote
    }
}

/// Client state machine for shared edits. Operation ids make retries
/// idempotent; the base revision fences every append. The server rebases an
/// edit whose target no intervening command touched; anything else returns
/// an explicit conflict, and an overlapping conflict is held until the editor
/// decides (keep mine on top, or discard mine) — never silently overwritten.
/// Remote commands are handed to the editor in order and the head advances
/// only after the editor acknowledges them.
@MainActor
final class RoomCommandSync {
    enum AppendOutcome: Equatable {
        case applied(revision: Int)
        case rebased(revision: Int, missing: [RoomCommandRecord])
        case duplicate(revision: Int)
        case conflict(head: Int, missing: [RoomCommandRecord])
        case refused(String)
    }
    struct PendingCommand: Equatable {
        let opID: UUID
        let kind: String
        let payload: CommunityJSONValue
        let payloadBytes: Int
        /// Entity this edit touches; for an undo, the undone edit's entity.
        let target: String?
    }
    /// A local edit that overlaps edits another creator made concurrently.
    struct HeldConflict: Equatable {
        let opID: UUID
        let target: String?
        let overlapping: [UUID]
    }

    let room: UUID
    private(set) var head: Int
    private(set) var pending: [PendingCommand] = []
    private(set) var acknowledged: Set<UUID> = []
    private(set) var inbox: [RoomCommandRecord] = []
    private(set) var accessEnded = false
    /// Edit permission was withdrawn; local edits stay on this device only.
    private(set) var editingRevoked = false
    private(set) var held: HeldConflict?
    private(set) var lastProblem: String?
    /// This client's acknowledged edits (op id → target): the only edits it may undo.
    private(set) var ownCommands: [UUID: String?] = [:]
    private(set) var undone: Set<UUID> = []
    /// Revisions of own edits the server rebased above remote edits not yet applied here.
    private var ownRebasedRevisions: Set<Int> = []

    init(room: UUID, head: Int) { self.room = room; self.head = max(0, head) }

    /// Queue a local edit; refused when the payload exceeds the server bound.
    func enqueue(kind: String, payload: CommunityJSONValue, opID: UUID = UUID()) -> Bool {
        enqueue(kind: kind, payload: payload, opID: opID, target: RoomCommandTarget.of(payload))
    }
    private func enqueue(kind: String, payload: CommunityJSONValue, opID: UUID, target: String?) -> Bool {
        guard !accessEnded, !editingRevoked, (1...64).contains(kind.count), payload.objectValue != nil,
              let bytes = try? CommunityCoding.encoder().encode(payload), RoomQuotaPolicy.payloadFits(bytes),
              !pending.contains(where: { $0.opID == opID }), !acknowledged.contains(opID) else { return false }
        pending.append(PendingCommand(opID: opID, kind: kind, payload: payload, payloadBytes: bytes.count, target: target))
        return true
    }
    /// Undo ownership: only this client's own acknowledged edit, once. Undoing
    /// another creator's edit is refused here and by the server.
    func enqueueUndo(of op: UUID, opID: UUID = UUID()) -> Bool {
        guard let target = ownCommands[op], !undone.contains(op),
              !pending.contains(where: { $0.kind == "undo" && $0.payload.objectValue?["undo_op"]?.stringValue == op.uuidString.lowercased() }) else { return false }
        return enqueue(kind: "undo", payload: .object(["undo_op": .string(op.uuidString.lowercased())]), opID: opID, target: target)
    }
    /// The next append request, fenced on the current head. Nil when nothing is
    /// pending, remote commands still await the editor, or a conflict is held.
    func nextAppend() -> RoomCommandRequest? {
        skipOwnAtFront()
        guard !accessEnded, !editingRevoked, held == nil, inbox.isEmpty, let next = pending.first else { return nil }
        return RoomCommandRequest(action: "append", room: room, op_id: next.opID, base_revision: head, kind: next.kind, payload: next.payload)
    }
    func catchUpRequest(pageSize: Int = 200) -> RoomCommandRequest {
        RoomCommandRequest(action: "since", room: room, after: head, page_size: pageSize)
    }

    func handleAppend(_ response: RoomCommandResponse, for opID: UUID) -> AppendOutcome {
        guard let index = pending.firstIndex(where: { $0.opID == opID }) else { return .refused("Unknown operation.") }
        let command = pending[index]
        if let error = response.error, !error.isEmpty {
            if error == "conflict", let serverHead = response.head {
                let missing = queueMissing(response.missing)
                let overlapping = missing.filter { RoomCommandTarget.overlaps(command.target, entity(of: $0)) }.map(\.op_id)
                if !overlapping.isEmpty {
                    held = HeldConflict(opID: opID, target: command.target, overlapping: overlapping)
                    lastProblem = "Another creator changed the same part of the project. Review their edit, then keep yours on top or discard yours."
                } else {
                    lastProblem = "Another editor changed the project. Apply \(missing.count) remote edit\(missing.count == 1 ? "" : "s") before yours is sent."
                }
                return .conflict(head: serverHead, missing: missing)
            }
            if error.contains("unavailable") || error.contains("Sign in") { accessEnded = true }
            if error.hasPrefix("You can view") { editingRevoked = true }
            lastProblem = error
            return .refused(error)
        }
        switch (response.status, response.revision) {
        case ("applied", let revision?):
            guard revision == head + 1 else { lastProblem = "Revision sequence broke; resynchronising."; return .refused("Resynchronise before continuing.") }
            head = revision; acknowledge(command, at: index); lastProblem = nil
            return .applied(revision: revision)
        case ("rebased", let revision?):
            // The server placed this edit above remote edits it did not touch.
            // Those remote edits still go to the editor; the head then skips
            // over this client's own revision.
            guard revision > head else { lastProblem = "Revision sequence broke; resynchronising."; return .refused("Resynchronise before continuing.") }
            let missing = queueMissing(response.missing)
            ownRebasedRevisions.insert(revision); acknowledge(command, at: index); lastProblem = nil
            skipOwnAtFront()
            return .rebased(revision: revision, missing: missing)
        case ("duplicate", let revision?):
            acknowledge(command, at: index)
            if revision > head { head = revision }
            return .duplicate(revision: revision)
        default:
            lastProblem = "Append was not confirmed."
            return .refused("Append was not confirmed.")
        }
    }
    /// Explicit decision on a held conflict, made after the editor applied the
    /// other creator's edit. Keeping re-sends the local edit fenced on the new
    /// head; discarding drops it (the editor reverts it locally).
    @discardableResult
    func resolveHeld(keepMine: Bool) -> Bool {
        guard let held, let index = pending.firstIndex(where: { $0.opID == held.opID }) else { return false }
        if !keepMine { pending.remove(at: index) }
        self.held = nil; lastProblem = nil
        return true
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
            if record.revision != expected {
                // Own rebased revisions may be absent from an older page boundary.
                if ownRebasedRevisions.contains(expected) && record.revision == expected + 1 { expected += 1 } else { return .gap(expected: expected) }
            }
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
    /// The next remote command for the editor, after dropping this client's
    /// own acknowledged edits from the front of the inbox.
    func nextRemoteToApply() -> RoomCommandRecord? {
        skipOwnAtFront()
        return inbox.first
    }
    /// The editor applied (or deliberately skipped) a remote command.
    func acknowledgeRemote(_ record: RoomCommandRecord) {
        guard let first = inbox.first, first.op_id == record.op_id else { return }
        inbox.removeFirst(); head = max(head, record.revision); acknowledged.insert(record.op_id)
        if record.kind == "undo", let undoneOp = record.payload.objectValue?["undo_op"]?.stringValue.flatMap(UUID.init(uuidString:)) { undone.insert(undoneOp) }
        skipOwnAtFront()
    }
    func endAccess() { accessEnded = true; pending = []; inbox = []; held = nil }
    var remainingRevisions: Int { RoomQuotaPolicy.remainingRevisions(head: head) }

    private func acknowledge(_ command: PendingCommand, at index: Int) {
        acknowledged.insert(command.opID); pending.remove(at: index)
        if command.kind == "undo", let op = command.payload.objectValue?["undo_op"]?.stringValue.flatMap(UUID.init(uuidString:)) {
            undone.insert(op)
        } else {
            ownCommands.updateValue(command.target, forKey: command.opID)
        }
    }
    private func queueMissing(_ records: [RoomCommandRecord]?) -> [RoomCommandRecord] {
        let missing = (records ?? []).filter { $0.revision > head }.sorted { $0.revision < $1.revision }
        inbox.append(contentsOf: missing.filter { record in !inbox.contains(where: { $0.op_id == record.op_id }) })
        inbox.sort { $0.revision < $1.revision }
        return missing
    }
    /// Drop own acknowledged records at the inbox front and step the head over
    /// own rebased revisions once everything below them is applied.
    private func skipOwnAtFront() {
        var moved = true
        while moved {
            moved = false
            if let first = inbox.first, acknowledged.contains(first.op_id) {
                inbox.removeFirst(); head = max(head, first.revision); ownRebasedRevisions.remove(first.revision); moved = true
            }
            if ownRebasedRevisions.contains(head + 1), inbox.first.map({ $0.revision > head + 1 }) ?? true {
                ownRebasedRevisions.remove(head + 1); head += 1; moved = true
            }
        }
    }
    /// A remote record's entity; an undo of an unknown edit counts as the whole document.
    private func entity(of record: RoomCommandRecord) -> String? {
        if record.kind == "undo" {
            guard let op = record.payload.objectValue?["undo_op"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
            if let mine = ownCommands[op] { return mine }
            return inbox.first(where: { $0.op_id == op }).flatMap { RoomCommandTarget.of($0.payload) }
        }
        return RoomCommandTarget.of(record.payload)
    }
}

// MARK: - Bounded asset transfer (#233)

/// Bounds from rooms-v2.sql's asset block. Only files a creator explicitly
/// picks are sent; copies are temporary and the sender's original is never
/// modified or deleted.
enum RoomAssetPolicy {
    static let chunkBytes = 32_768
    static let maximumBytes = 8 * 1024 * 1024
    static let roomBytes = 64 * 1024 * 1024
    static let roomFiles = 100
    static let dailyFiles = 30
    static let callsPerMinute = 600
    static let pendingLifetime: TimeInterval = 3600
    static let retention: TimeInterval = 72 * 3600
    static let mimeTypes: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                              "m4a": "audio/mp4", "mp3": "audio/mpeg", "wav": "audio/wav", "caf": "audio/x-caf"]
    static func mime(forExtension ext: String) -> String? { mimeTypes[ext.lowercased()] }
    static func chunkCount(bytes: Int) -> Int { bytes <= 0 ? 0 : (bytes + chunkBytes - 1) / chunkBytes }
    static func chunk(_ data: Data, index: Int) -> Data? {
        let start = index * chunkBytes
        guard index >= 0, start < data.count else { return nil }
        let begin = data.startIndex + start
        return data.subdata(in: begin..<min(begin + chunkBytes, data.endIndex))
    }
    static func validate(name: String, bytes: Int, mime: String?, license: RoomAssetLicense, attribution: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 120 { return "The file needs a name of 1–120 characters." }
        guard let mime, mimeTypes.values.contains(mime) else { return "Only PNG, JPEG and audio files (M4A, MP3, WAV, CAF) can be sent." }
        if bytes <= 0 || bytes > maximumBytes { return "Files up to 8 MB can be sent." }
        if attribution.count > 500 { return "Keep the attribution under 500 characters." }
        if license == .ccBy && attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "CC BY files need an attribution." }
        return nil
    }
    static func sha256Hex(_ data: Data) -> String? {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

enum RoomAssetLicense: String, CaseIterable, Codable {
    case ownWork = "own-work", cc0 = "cc0", ccBy = "cc-by", licensedLibrary = "licensed-library"
    var title: String {
        switch self {
        case .ownWork: return "My own work"
        case .cc0: return "CC0 / public domain"
        case .ccBy: return "CC BY (attribution required)"
        case .licensedLibrary: return "Licensed library sound or image"
        }
    }
}

/// `sdi_room_asset` request: declare, put, status, finalize, list, get, withdraw.
struct RoomAssetRequest: Encodable, Equatable {
    let action: String
    let room: UUID
    var asset: UUID? = nil
    var name: String? = nil
    var mime: String? = nil
    var byte_size: Int? = nil
    var sha256: String? = nil
    var license: String? = nil
    var attribution = ""
    var chunk_index: Int? = nil
    var data: String? = nil
}
struct RoomAssetRecord: Decodable, Identifiable, Equatable {
    var id: UUID { asset_id }
    let asset_id: UUID
    let name: String
    let mime: String
    let byte_size: Int
    let chunk_count: Int
    let sha256: String
    let license: String
    let attribution: String
    let state: String
    let expires_at: Date
    var mine: Bool? = nil
    var received: Int? = nil
    var licenseTitle: String { RoomAssetLicense(rawValue: license)?.title ?? license }
}
struct RoomAssetResponse: CommunityResponse {
    let error: String?
    let status: String?
    let asset_id: UUID?
    let state: String?
    let chunk_size: Int?
    let chunk_count: Int?
    let chunk_index: Int?
    let sha256: String?
    let data: String?
    let expires_at: Date?
    let verified: Bool?
    let assets: [RoomAssetRecord]?
    /// A count after `put`, a list of chunk indexes after `status`/`finalize`.
    let received: CommunityJSONValue?
    var receivedIndexes: Set<Int> {
        guard case .array(let values)? = received else { return [] }
        return Set(values.compactMap { if case .number(let n) = $0 { return Int(n) } else { return nil } })
    }
}

/// Moves explicitly chosen files through the bounded transfer route. Sending
/// resumes from the chunks the server already holds; receiving verifies the
/// SHA-256 of the whole file before handing it back.
@MainActor
final class RoomAssetTransfer {
    enum SendOutcome: Equatable { case available(UUID), alreadyShared(UUID) }
    enum TransferError: Error, Equatable, LocalizedError {
        case invalid(String), refused(String), corrupt, unavailable(String), cancelled(UUID?)
        var errorDescription: String? {
            switch self {
            case .invalid(let text), .refused(let text), .unavailable(let text): return text
            case .corrupt: return "The received file did not match its SHA-256 and was discarded. Nothing was saved."
            case .cancelled: return "Transfer cancelled. Nothing was changed on this device."
            }
        }
    }
    /// Download progress kept by the caller so an interrupted download resumes.
    struct Download: Equatable {
        let asset: RoomAssetRecord
        var chunks: [Data] = []
        var complete: Bool { chunks.count == asset.chunk_count }
    }

    let gateway: CommunityGateway
    init(gateway: CommunityGateway) { self.gateway = gateway }

    func list(room: UUID) async throws -> [RoomAssetRecord] {
        let response = try await call(RoomAssetRequest(action: "list", room: room))
        guard let assets = response.assets else { throw TransferError.unavailable("Room assets are unavailable from this service version.") }
        return assets
    }

    /// Send one chosen file. `progress` receives (sent chunks, total chunks).
    func send(room: UUID, file: Data, name: String, mime: String?, license: RoomAssetLicense, attribution: String,
              progress: (Int, Int) -> Void = { _, _ in }) async throws -> SendOutcome {
        if let problem = RoomAssetPolicy.validate(name: name, bytes: file.count, mime: mime, license: license, attribution: attribution) {
            throw TransferError.invalid(problem)
        }
        guard let digest = RoomAssetPolicy.sha256Hex(file) else { throw TransferError.unavailable("File hashing is unavailable on this device.") }
        let declared = try await call(RoomAssetRequest(action: "declare", room: room, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                       mime: mime, byte_size: file.count, sha256: digest, license: license.rawValue,
                                                       attribution: attribution.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard let asset = declared.asset_id, let total = declared.chunk_count, declared.chunk_size == RoomAssetPolicy.chunkBytes,
              total == RoomAssetPolicy.chunkCount(bytes: file.count) else { throw TransferError.refused("The transfer was not confirmed.") }
        if declared.status == "existing" && declared.state == "available" { return .alreadyShared(asset) }
        guard declared.status == "declared" || declared.status == "existing" else { throw TransferError.refused("The transfer was not confirmed.") }
        // Resume: send only the chunks the server does not hold yet.
        var held: Set<Int> = []
        if declared.status == "existing" { held = try await call(RoomAssetRequest(action: "status", room: room, asset: asset)).receivedIndexes }
        for attempt in 0..<2 {
            for index in 0..<total where !held.contains(index) {
                if Task.isCancelled { throw TransferError.cancelled(asset) }
                guard let chunk = RoomAssetPolicy.chunk(file, index: index) else { throw TransferError.invalid("The file changed while sending.") }
                let stored = try await call(RoomAssetRequest(action: "put", room: room, asset: asset, chunk_index: index, data: chunk.base64EncodedString()))
                guard stored.status == "stored" else { throw TransferError.refused("A chunk was not confirmed.") }
                held.insert(index); progress(held.count, total)
            }
            let finished = try await gateway.callKeepingServerError("sdi_room_asset",
                params: RoomAssetRequest(action: "finalize", room: room, asset: asset), as: RoomAssetResponse.self)
            if finished.error == "incomplete", attempt == 0 { held = finished.receivedIndexes; continue }
            if let error = finished.error, !error.isEmpty { throw error.contains("corrupt") ? TransferError.corrupt : TransferError.refused(error) }
            guard finished.status == "available", finished.asset_id == asset else { throw TransferError.refused("The transfer was not confirmed.") }
            return .available(asset)
        }
        throw TransferError.refused("The server is still missing parts of the file. Try again.")
    }

    /// Fetch the remaining chunks of `download`, then verify size and SHA-256.
    /// On failure the partial download is returned through `download` so the
    /// caller can resume; corrupt data is discarded entirely.
    func receive(room: UUID, _ download: inout Download) async throws -> Data {
        let asset = download.asset
        guard asset.state == "available", (1...256).contains(asset.chunk_count),
              asset.chunk_count == RoomAssetPolicy.chunkCount(bytes: asset.byte_size), asset.byte_size <= RoomAssetPolicy.maximumBytes else {
            throw TransferError.unavailable("This asset is not available to download.")
        }
        while !download.complete {
            if Task.isCancelled { throw TransferError.cancelled(asset.asset_id) }
            let index = download.chunks.count
            let reply = try await call(RoomAssetRequest(action: "get", room: room, asset: asset.asset_id, chunk_index: index))
            guard reply.chunk_index == index, reply.sha256 == asset.sha256, reply.chunk_count == asset.chunk_count,
                  let text = reply.data, let chunk = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
                  chunk.count == (index == asset.chunk_count - 1 ? asset.byte_size - index * RoomAssetPolicy.chunkBytes : RoomAssetPolicy.chunkBytes) else {
                download.chunks = []
                throw TransferError.corrupt
            }
            download.chunks.append(chunk)
        }
        let whole = download.chunks.reduce(into: Data()) { $0.append($1) }
        guard whole.count == asset.byte_size, let digest = RoomAssetPolicy.sha256Hex(whole), digest == asset.sha256 else {
            download.chunks = []
            throw TransferError.corrupt
        }
        return whole
    }

    /// Cancel or remove a transfer copy (sender or room owner). Server bytes
    /// are deleted and the deletion verified; no device file is touched.
    func withdraw(room: UUID, asset: UUID) async throws -> Bool {
        let response = try await call(RoomAssetRequest(action: "withdraw", room: room, asset: asset))
        guard response.status == "withdrawn" else { throw TransferError.refused("Withdrawal was not confirmed.") }
        return response.verified ?? false
    }

    private func call(_ request: RoomAssetRequest) async throws -> RoomAssetResponse {
        do { return try await gateway.call("sdi_room_asset", params: request, as: RoomAssetResponse.self) }
        catch CommunityError.server(let message, _) {
            if message.contains("unavailable") { throw TransferError.unavailable(message) }
            throw TransferError.refused(message)
        }
    }
}

/// Saves a verified received asset into this device's Room Transfers folder.
/// Never overwrites a different existing file and never touches projects.
enum RoomAssetInbox {
    static func directory(base: URL, room: UUID) -> URL {
        base.appendingPathComponent("RoomTransfers", isDirectory: true).appendingPathComponent(room.uuidString.lowercased(), isDirectory: true)
    }
    static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ")).prefix(100)
        return cleaned.isEmpty ? "asset" : String(cleaned)
    }
    static func save(_ data: Data, asset: RoomAssetRecord, room: UUID, base: URL) throws -> URL {
        guard RoomAssetPolicy.sha256Hex(data) == asset.sha256 else { throw RoomAssetTransfer.TransferError.corrupt }
        let folder = directory(base: base, room: room)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(String(asset.sha256.prefix(12)) + "-" + safeName(asset.name))
        if FileManager.default.fileExists(atPath: url.path) {
            if let existing = try? Data(contentsOf: url), RoomAssetPolicy.sha256Hex(existing) == asset.sha256 { return url }
            throw RoomAssetTransfer.TransferError.refused("A different file already uses that name; nothing was overwritten.")
        }
        try data.write(to: url, options: [.withoutOverwriting])
        return url
    }
}
