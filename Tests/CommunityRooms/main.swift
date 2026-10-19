import Foundation

// Foundation-only verification of the Rooms client and the versioned command
// synchronisation state machine against scripted fake transports.

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}

final class FakeTransport: CommunityTransport {
    struct Call { let name: String; let params: [String: Any] }
    var replies: [Result<String, Error>] = []
    var calls: [Call] = []
    var hasSession = true
    func rpc<P: Encodable & Sendable>(_ name: String, params: P) async throws -> CommunityReply {
        let data = try CommunityCoding.encoder().encode(params)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        calls.append(Call(name: name, params: object))
        return try next()
    }
    func rows(_ table: String, select: String, filters: [CommunityRowFilter], limit: Int) async throws -> CommunityReply {
        calls.append(Call(name: "rows:" + table, params: ["select": select, "filters": filters.map { "\($0.column)=\($0.value)" }, "limit": limit]))
        return try next()
    }
    private func next() throws -> CommunityReply {
        guard !replies.isEmpty else { throw CommunityError.transport("No scripted reply.") }
        switch replies.removeFirst() {
        case .success(let json): return CommunityReply(data: Data(json.utf8), serverDate: nil, sentAt: Date(), receivedAt: Date())
        case .failure(let error): throw error
        }
    }
}

private let room = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
private let member = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
private let project = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
private let code = String(repeating: "ab12", count: 16)
private func record(_ revision: Int, op: UUID = UUID(), author: UUID = member) -> String {
    #"{"revision":\#(revision),"op_id":"\#(op.uuidString)","author":"\#(author.uuidString)","base_revision":\#(revision - 1),"kind":"frame.add","payload":{"frame":\#(revision)},"created_at":"2026-10-12T20:00:00+00:00"}"#
}

private let asset = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
private func targeted(_ revision: Int, _ target: String, op: UUID = UUID(), author: UUID = member) -> String {
    #"{"revision":\#(revision),"op_id":"\#(op.uuidString)","author":"\#(author.uuidString)","base_revision":\#(revision - 1),"kind":"frame.update","payload":{"target":"\#(target)"},"created_at":"2026-10-12T20:00:00+00:00"}"#
}

@main @MainActor struct CommunityRoomsTests {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        await test("invitation codes are 64 hex characters, normalised, and the forward text explains owner approval") {
            try require(RoomInvitationPolicy.isWellFormed(code) && RoomInvitationPolicy.isWellFormed(" " + code.uppercased() + "\n"), "well-formed codes")
            try require(!RoomInvitationPolicy.isWellFormed(String(code.dropLast())) && !RoomInvitationPolicy.isWellFormed(code.replacingOccurrences(of: "a", with: "g")), "malformed codes")
            let text = RoomInvitationPolicy.shareText(code: code, roomTitle: "Duel")
            try require(text.contains(code) && text.contains("owner still approves") && text.contains("24 hours"), "share text")
        }

        await test("project share sends only an opaque reference, title and permissions") {
            let share = RoomProjectShare(projectID: project, title: "  Fight scene  ", permissions: [.view, .edit])
            try require(RoomProjectShare.validate(title: share.title, permissions: share.permissions) == nil, "valid share")
            try require(RoomProjectShare.validate(title: "", permissions: [.view]) != nil && RoomProjectShare.validate(title: "x", permissions: [.edit]) != nil, "title and view rules")
            let request = share.manageRequest(room: room, revision: 1)
            try require(request.action == "set_project" && request.project_ref == "device-project:" + project.uuidString.lowercased() && request.project_title == "Fight scene" && request.permissions == ["view", "edit"] && request.revision == 1, "set_project payload")
            try require(RoomProjectShare.projectID(from: request.project_ref) == project && RoomProjectShare.projectID(from: "other:1") == nil, "reference round trip")
            let encoded = try CommunityCoding.encoder().encode(request)
            try require(!String(decoding: encoded, as: UTF8.self).contains("frames"), "no project content in the payload")
        }

        await test("room creation requires consent, records the share, and reports a room whose share failed") {
            let transport = FakeTransport()
            let client = RoomsClient(gateway: CommunityGateway(transport: transport))
            let share = RoomProjectShare(projectID: project, title: "Fight scene", permissions: [.view])
            do { _ = try await client.createRoom(title: "Duel", share: share, consent: false); throw Failure(description: "created without consent") } catch CommunityError.server {}
            try require(transport.calls.isEmpty, "no request without consent")
            transport.replies = [.success(#"{"status":"created","room_id":"\#(room.uuidString)"}"#), .success(#"{"status":"updated","project_revision":2}"#)]
            let outcome = try await client.createRoom(title: "Duel", share: share, consent: true)
            try require(outcome == .created(room: room, projectRevision: 2), "created with project")
            try require(transport.calls[0].params["action"] as? String == "create" && transport.calls[0].params["consent"] as? Bool == true, "create payload carries consent")
            try require(transport.calls[1].name == "sdi_room_manage" && transport.calls[1].params["action"] as? String == "set_project", "share recorded second")
            transport.replies = [.success(#"{"status":"created","room_id":"\#(room.uuidString)"}"#), .success(#"{"error":"Current project reference, title, permissions and revision are required."}"#)]
            let partial = try await client.createRoom(title: "Duel", share: share, consent: true)
            if case .createdWithoutProject(let id, let problem) = partial { try require(id == room && problem.contains("required"), "partial outcome names the room and the reason") }
            else { throw Failure(description: "share failure hidden") }
        }

        await test("invitation preview and admission request validate locally and need explicit consent") {
            let transport = FakeTransport()
            let client = RoomsClient(gateway: CommunityGateway(transport: transport))
            do { _ = try await client.previewInvitation(code: "short"); throw Failure(description: "malformed preview sent") } catch CommunityError.server {}
            transport.replies = [.success(#"{"status":"preview","room_id":"\#(room.uuidString)","title":"Duel"}"#)]
            let preview = try await client.previewInvitation(code: code.uppercased())
            try require(preview.title == "Duel" && transport.calls.last?.params["code"] as? String == code, "normalised code sent")
            do { _ = try await client.requestAdmission(code: code, consent: false); throw Failure(description: "requested without consent") } catch CommunityError.server {}
            transport.replies = [.success(#"{"status":"pending_owner_approval","room_id":"\#(room.uuidString)"}"#)]
            try require(try await client.requestAdmission(code: code, consent: true) == .pendingOwnerApproval(room: room), "pending owner approval")
            transport.replies = [.success(#"{"status":"already_requested","room_id":"\#(room.uuidString)"}"#)]
            try require(try await client.requestAdmission(code: code, consent: true) == .alreadyRequested(room: room), "already requested")
            transport.replies = [.success(#"{"error":"Invitation is unavailable."}"#)]
            do { _ = try await client.requestAdmission(code: code, consent: true); throw Failure(description: "revoked code accepted") }
            catch CommunityError.server(let message, _) { try require(message == "Invitation is unavailable.", "server refusal surfaced") }
            transport.replies = [.success(#"{"status":"invitation_created","code":"\#(code)"}"#)]
            try require(try await client.mintInvitation(room: room) == code, "minted code")
            transport.replies = [.success(#"{"status":"invitation_created","code":"short"}"#)]
            do { _ = try await client.mintInvitation(room: room); throw Failure(description: "unusable code accepted") } catch CommunityError.invalidResponse {}
        }

        await test("membership lifecycle, roles, reports and the browser decode truthfully") {
            let transport = FakeTransport()
            let client = RoomsClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"[{"id":"\#(room.uuidString)","owner_id":"\#(owner.uuidString)","title":"Open","closed":false,"project_ref":null,"project_title":null,"permissions":["view"],"project_revision":1,"command_revision":0},{"id":"\#(project.uuidString)","owner_id":"\#(owner.uuidString)","title":"Closed","closed":true}]"#)]
            let rooms = try await client.myRooms()
            try require(rooms.count == 1 && rooms[0].title == "Open" && !rooms[0].sharesEdit, "closed rooms filtered; v2 columns optional")
            transport.replies = [.success(#"[{"user_id":"\#(member.uuidString)","owner_approved":false,"member_accepted":true,"revoked":false,"role":"viewer","request_expires_at":"2026-10-13T20:00:00+00:00"}]"#)]
            let members = try await client.members(of: room)
            try require(members[0].statusText == "Awaiting owner approval" && !members[0].isActive, "pending member status")
            transport.replies = [.success(#"{"status":"updated"}"#)]
            try await client.setRole(room: room, member: member, role: .editor)
            try require(transport.calls.last?.params["role"] as? String == "editor" && transport.calls.last?.params["subject"] as? String == member.uuidString, "set_role payload")
            var draft = RoomReportDraft(reason: .rights, detail: String(repeating: "x", count: 2001))
            do { try await client.report(room: room, draft: draft); throw Failure(description: "oversized report sent") } catch CommunityError.server {}
            draft.detail = "Copied artwork"
            transport.replies = [.success(#"{"status":"recorded"}"#)]
            try await client.report(room: room, draft: draft)
            try require(transport.calls.last?.params["reason"] as? String == "rights" && transport.calls.last?.params["detail"] as? String == "Copied artwork", "report payload")
            transport.replies = [.success(#"{"requests":[{"room_id":"\#(room.uuidString)","title":"Duel","owner_id":"\#(owner.uuidString)","request_expires_at":"2026-10-13T20:00:00+00:00"}]}"#)]
            try require(try await client.pendingRequests().count == 1, "pending requests decoded")
            transport.replies = [.success(#"{"status":"left"}"#)]
            try await client.leave(room: room)
            transport.replies = [.success(#"{"status":"updated"}"#)]
            do { try await client.leave(room: room); throw Failure(description: "wrong status accepted as left") } catch CommunityError.invalidResponse {}
        }

        await test("command sync fences appends on the head, replays idempotently and surfaces conflicts explicitly") {
            let sync = RoomCommandSync(room: room, head: 3)
            let huge = CommunityJSONValue.object(["blob": .string(String(repeating: "x", count: RoomQuotaPolicy.commandPayloadBytes))])
            try require(!sync.enqueue(kind: "frame.add", payload: huge), "oversized payload refused")
            try require(!sync.enqueue(kind: "frame.add", payload: .string("not an object")), "non-object payload refused")
            let op = UUID()
            try require(sync.enqueue(kind: "frame.add", payload: .object(["frame": .number(4)]), opID: op), "enqueue")
            try require(!sync.enqueue(kind: "frame.add", payload: .object([:]), opID: op), "duplicate op id refused")
            guard let append = sync.nextAppend() else { throw Failure(description: "no append prepared") }
            try require(append.base_revision == 3 && append.op_id == op && append.kind == "frame.add", "append fenced on head")
            let decoder = CommunityCoding.decoder()
            let wrong = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"status":"applied","revision":6}"#.utf8))
            try require(sync.handleAppend(wrong, for: op) == .refused("Resynchronise before continuing.") && sync.head == 3, "non-sequential revision refused")
            let applied = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"status":"applied","revision":4}"#.utf8))
            try require(sync.handleAppend(applied, for: op) == .applied(revision: 4) && sync.head == 4 && sync.pending.isEmpty, "applied advances head")
            let duplicate = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"status":"duplicate","revision":4,"head":4}"#.utf8))
            try require(sync.handleAppend(duplicate, for: op) == .refused("Unknown operation."), "replayed op already acknowledged")
            let second = UUID()
            _ = sync.enqueue(kind: "layer.rename", payload: .object(["name": .string("Sky")]), opID: second)
            let conflict = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"error":"conflict","head":6,"missing":[\#(record(5)),\#(record(6))]}"#.utf8))
            guard case .conflict(let head, let missing) = sync.handleAppend(conflict, for: second) else { throw Failure(description: "conflict not surfaced") }
            try require(head == 6 && missing.count == 2 && sync.pending.count == 1 && sync.nextAppend() == nil, "conflict keeps the local edit and blocks sends until remote edits are applied")
            try require(sync.held?.opID == second && sync.held?.overlapping.count == 2 && sync.lastProblem?.contains("same part") == true, "untargeted edit overlapping remote edits is held for a decision")
            for remote in sync.remoteCommandsToApply(author: owner) { sync.acknowledgeRemote(remote) }
            try require(sync.head == 6 && sync.nextAppend() == nil, "held edit is not re-sent silently after applying remote edits")
            try require(sync.resolveHeld(keepMine: true) && sync.nextAppend()?.base_revision == 6, "keeping mine re-sends on the new head")
            let dup = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"status":"duplicate","revision":7,"head":7}"#.utf8))
            try require(sync.handleAppend(dup, for: second) == .duplicate(revision: 7) && sync.head == 7, "duplicate reply after a retried send is idempotent")
            let ended = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"error":"Room is unavailable."}"#.utf8))
            _ = sync.enqueue(kind: "frame.add", payload: .object([:]))
            try require(sync.handleAppend(ended, for: sync.pending[0].opID) == .refused("Room is unavailable.") && sync.accessEnded && sync.nextAppend() == nil, "access ended stops synchronisation")
        }

        await test("catch-up pages require contiguous revisions and report gaps") {
            let sync = RoomCommandSync(room: room, head: 2)
            let decoder = CommunityCoding.decoder()
            try require(sync.catchUpRequest().after == 2 && sync.catchUpRequest().action == "since", "catch-up from head")
            let contiguous = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"commands":[\#(record(3)),\#(record(4))],"head":4}"#.utf8))
            try require(sync.handleCatchUp(contiguous) == .received(2) && sync.inbox.count == 2, "contiguous records queued")
            let repeated = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"commands":[\#(record(3)),\#(record(4))],"head":4}"#.utf8))
            try require(sync.handleCatchUp(repeated) == .upToDate && sync.inbox.count == 2, "replayed page adds nothing")
            let gap = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"commands":[\#(record(7))],"head":7}"#.utf8))
            try require(sync.handleCatchUp(gap) == .gap(expected: 5), "gap detected")
            let ended = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"error":"Room is unavailable."}"#.utf8))
            try require(sync.handleCatchUp(ended) == .accessEnded && sync.accessEnded, "revoked access ends catch-up")
            try require(RoomQuotaPolicy.remainingRevisions(head: 99_990) == 10 && RoomQuotaPolicy.remainingRevisions(head: 200_000) == 0, "quota arithmetic")
        }

        await test("command replies keep the server error field so conflicts carry head and missing commands") {
            let transport = FakeTransport()
            let client = RoomsClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"error":"conflict","head":9,"missing":[\#(record(9))]}"#)]
            let response = try await client.append(RoomCommandRequest(action: "append", room: room, op_id: UUID(), base_revision: 8, kind: "k", payload: .object([:])))
            try require(response.error == "conflict" && response.head == 9 && response.missing?.count == 1, "conflict decoded with companions")
            do { _ = try await client.append(RoomCommandRequest(action: "since", room: room)); throw Failure(description: "wrong action accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.failure(CommunityError.transport("offline"))]
            do { _ = try await client.commands(RoomCommandRequest(action: "since", room: room, after: 0)); throw Failure(description: "transport failure hidden") } catch CommunityError.transport {}
            try require(transport.calls.first?.params["payload"] as? [String: Any] != nil && transport.calls.first?.params["base_revision"] as? Int == 8, "append payload shape")
        }

        await test("session coordinator drains local edits in order, stops at conflicts and refuses edits for viewers") {
            let transport = FakeTransport()
            let coordinator = RoomSessionCoordinator(client: RoomsClient(gateway: CommunityGateway(transport: transport)))
            coordinator.begin(room: room, head: 2, projectID: project, canEdit: false, account: member)
            try require(!coordinator.publishLocalEdit(kind: "frame.add", payload: .object([:])), "viewer cannot publish edits")
            coordinator.end()
            coordinator.begin(room: room, head: 2, projectID: project, canEdit: true, account: member)
            try require(coordinator.publishLocalEdit(kind: "frame.add", payload: .object(["frame": .number(3)])), "editor enqueues")
            try require(coordinator.publishLocalEdit(kind: "frame.add", payload: .object(["frame": .number(4)])), "second edit enqueues")
            transport.replies = [.success(#"{"status":"applied","revision":3}"#), .success(#"{"error":"conflict","head":5,"missing":[\#(record(4)),\#(record(5))]}"#)]
            try require(await coordinator.drain() == .held(2) && coordinator.head == 3 && coordinator.pendingLocalCount == 1 && coordinator.pendingRemoteCount == 2, "first edit applied, second held by an overlapping conflict")
            try require(transport.calls.count == 2 && transport.calls[1].params["base_revision"] as? Int == 3, "second append fenced on the advanced head")
            var applied: [Int] = []
            coordinator.applyRemote = { record in applied.append(record.revision); return true }
            transport.replies = [.success(#"{"commands":[],"head":5}"#)]
            _ = await coordinator.catchUp()
            try require(applied == [4, 5] && coordinator.head == 5 && coordinator.pendingRemoteCount == 0, "remote edits applied in order through the hook")
            try require(await coordinator.drain() == .held(2) && transport.calls.count == 3, "nothing sent until the creator decides")
            try require(coordinator.resolveHeldConflict(keepMine: true), "creator keeps their edit on top")
            transport.replies = [.success(#"{"status":"applied","revision":6}"#)]
            try require(await coordinator.drain() == .sent(1) && coordinator.head == 6, "blocked edit sent after rebasing")
            transport.replies = [.success(#"{"error":"Room is unavailable."}"#)]
            _ = coordinator.publishLocalEdit(kind: "frame.add", payload: .object([:]))
            try require(await coordinator.drain() == .stopped("Room is unavailable.") && coordinator.session == nil, "revoked access ends the session")
            try require(await coordinator.drain() == .idle, "no session means nothing is sent")
        }

        await test("server rebase: own revision is skipped once the remote edits below it are applied") {
            let sync = RoomCommandSync(room: room, head: 3)
            let mine = UUID(), theirs = UUID()
            try require(sync.enqueue(kind: "frame.update", payload: .object(["target": .string("frame:a")]), opID: mine), "enqueue targeted edit")
            let decoder = CommunityCoding.decoder()
            let rebased = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"status":"rebased","revision":5,"head":5,"missing":[\#(targeted(4, "frame:b", op: theirs))]}"#.utf8))
            guard case .rebased(let revision, let missing) = sync.handleAppend(rebased, for: mine) else { throw Failure(description: "rebase not recognised") }
            try require(revision == 5 && missing.count == 1 && sync.head == 3 && sync.pending.isEmpty && sync.held == nil, "own edit acknowledged, remote edit still to apply")
            let page = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"commands":[\#(targeted(4, "frame:b", op: theirs)),\#(targeted(5, "frame:a", op: mine, author: owner))],"head":5}"#.utf8))
            _ = sync.handleCatchUp(page)
            guard let next = sync.nextRemoteToApply() else { throw Failure(description: "remote edit missing") }
            try require(next.op_id == theirs, "the other creator's edit is applied first")
            sync.acknowledgeRemote(next)
            try require(sync.head == 5 && sync.inbox.isEmpty && sync.nextRemoteToApply() == nil, "head skips over the own rebased revision")
            try require((sync.ownCommands[mine] ?? nil) == "frame:a", "own edit recorded with its target for undo")
        }

        await test("conflicts: disjoint ones re-fence, overlapping ones wait for keep or discard") {
            let decoder = CommunityCoding.decoder()
            let sync = RoomCommandSync(room: room, head: 0)
            let first = UUID()
            _ = sync.enqueue(kind: "frame.update", payload: .object(["target": .string("frame:a")]), opID: first)
            let disjoint = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"error":"conflict","head":1,"missing":[\#(targeted(1, "frame:b"))],"overlap":[]}"#.utf8))
            _ = sync.handleAppend(disjoint, for: first)
            try require(sync.held == nil && sync.lastProblem?.contains("Apply 1 remote edit") == true, "disjoint conflict is not held")
            if let next = sync.nextRemoteToApply() { sync.acknowledgeRemote(next) }
            try require(sync.nextAppend()?.base_revision == 1, "disjoint edit re-sent on the new head")
            let overlap = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"error":"conflict","head":2,"missing":[\#(targeted(2, "frame:a"))]}"#.utf8))
            _ = sync.handleAppend(overlap, for: first)
            try require(sync.held?.opID == first && sync.held?.target == "frame:a", "same-target conflict held")
            if let next = sync.nextRemoteToApply() { sync.acknowledgeRemote(next) }
            try require(sync.nextAppend() == nil, "held edit never sent silently")
            try require(sync.resolveHeld(keepMine: false) && sync.pending.isEmpty && sync.nextAppend() == nil, "discarding mine drops the edit")
            try require(!sync.resolveHeld(keepMine: true), "nothing left to resolve")
        }

        await test("undo ownership: only own acknowledged edits, once; revoked editing keeps edits local") {
            let decoder = CommunityCoding.decoder()
            let sync = RoomCommandSync(room: room, head: 0)
            let edit = UUID()
            _ = sync.enqueue(kind: "layer.rename", payload: .object(["target": .string("layer:1"), "name": .string("Sky")]), opID: edit)
            _ = sync.handleAppend(try decoder.decode(RoomCommandResponse.self, from: Data(#"{"status":"applied","revision":1}"#.utf8)), for: edit)
            try require(!sync.enqueueUndo(of: UUID()), "another creator's edit cannot be undone")
            let undo = UUID()
            try require(sync.enqueueUndo(of: edit, opID: undo), "own edit can be undone")
            try require(!sync.enqueueUndo(of: edit), "undo not queued twice")
            try require(sync.pending.first?.payload.objectValue?["undo_op"]?.stringValue == edit.uuidString.lowercased() && sync.pending.first?.target == "layer:1", "undo payload names the edit and inherits its target")
            _ = sync.handleAppend(try decoder.decode(RoomCommandResponse.self, from: Data(#"{"status":"applied","revision":2}"#.utf8)), for: undo)
            try require(sync.undone.contains(edit) && !sync.enqueueUndo(of: edit), "undone edit cannot be undone again")
            let later = UUID()
            _ = sync.enqueue(kind: "frame.add", payload: .object(["target": .string("frame:9")]), opID: later)
            let revoked = try decoder.decode(RoomCommandResponse.self, from: Data(#"{"error":"You can view this project but not edit it."}"#.utf8))
            try require(sync.handleAppend(revoked, for: later) == .refused("You can view this project but not edit it."), "revocation surfaced")
            try require(sync.editingRevoked && !sync.accessEnded && sync.nextAppend() == nil && sync.pending.count == 1, "edits stay local after revocation")
            try require(!sync.enqueue(kind: "frame.add", payload: .object([:])), "no new shared edits after revocation")
        }

        await test("asset send validates locally, transfers bounded chunks and finalises against the server hash") {
            let transport = FakeTransport()
            let transfer = RoomAssetTransfer(gateway: CommunityGateway(transport: transport))
            let file = Data((0..<40_000).map { UInt8($0 % 251) })
            guard let digest = RoomAssetPolicy.sha256Hex(file) else { throw Failure(description: "hashing unavailable") }
            do { _ = try await transfer.send(room: room, file: file, name: "clip.mov", mime: RoomAssetPolicy.mime(forExtension: "mov"), license: .ownWork, attribution: ""); throw Failure(description: "video accepted") }
            catch RoomAssetTransfer.TransferError.invalid {}
            do { _ = try await transfer.send(room: room, file: file, name: "a.png", mime: "image/png", license: .ccBy, attribution: " "); throw Failure(description: "CC BY without attribution") }
            catch RoomAssetTransfer.TransferError.invalid {}
            do { _ = try await transfer.send(room: room, file: Data(count: RoomAssetPolicy.maximumBytes + 1), name: "a.png", mime: "image/png", license: .ownWork, attribution: ""); throw Failure(description: "oversized file") }
            catch RoomAssetTransfer.TransferError.invalid {}
            try require(transport.calls.isEmpty, "nothing sent for invalid files")
            transport.replies = [
                .success(#"{"status":"declared","asset_id":"\#(asset.uuidString)","state":"receiving","chunk_size":32768,"chunk_count":2,"expires_at":"2026-10-14T21:00:00+00:00"}"#),
                .success(#"{"status":"stored","received":1}"#), .success(#"{"status":"stored","received":2}"#),
                .success(#"{"status":"available","asset_id":"\#(asset.uuidString)","expires_at":"2026-10-17T20:00:00+00:00"}"#)]
            var progress: [Int] = []
            let outcome = try await transfer.send(room: room, file: file, name: " punch.png ", mime: "image/png", license: .ownWork, attribution: "") { sent, _ in progress.append(sent) }
            try require(outcome == .available(asset) && progress == [1, 2], "two chunks sent then finalised")
            let declare = transport.calls[0].params
            try require(declare["action"] as? String == "declare" && declare["sha256"] as? String == digest && declare["byte_size"] as? Int == 40_000 && declare["name"] as? String == "punch.png" && declare["license"] as? String == "own-work", "declare payload")
            let chunk0 = (transport.calls[1].params["data"] as? String).flatMap { Data(base64Encoded: $0) }
            try require(chunk0 == file.prefix(32_768) && transport.calls[2].params["chunk_index"] as? Int == 1 && transport.calls[3].params["action"] as? String == "finalize", "chunks carry exact bytes in order")
        }

        await test("asset send resumes from server-held chunks, retries an incomplete finalise and reports corruption") {
            let transport = FakeTransport()
            let transfer = RoomAssetTransfer(gateway: CommunityGateway(transport: transport))
            let file = Data((0..<40_000).map { UInt8($0 % 13) })
            transport.replies = [
                .success(#"{"status":"existing","asset_id":"\#(asset.uuidString)","state":"receiving","chunk_size":32768,"chunk_count":2,"expires_at":"2026-10-14T21:00:00+00:00"}"#),
                .success(#"{"asset_id":"\#(asset.uuidString)","state":"receiving","chunk_count":2,"expires_at":"2026-10-14T21:00:00+00:00","received":[0]}"#),
                .success(#"{"status":"stored","received":2}"#),
                .success(#"{"error":"incomplete","received":[1]}"#),
                .success(#"{"status":"stored","received":2}"#),
                .success(#"{"status":"available","asset_id":"\#(asset.uuidString)","expires_at":"2026-10-17T20:00:00+00:00"}"#)]
            try require(try await transfer.send(room: room, file: file, name: "a.wav", mime: "audio/wav", license: .cc0, attribution: "") == .available(asset), "resumed transfer completes")
            let indexes = transport.calls.filter { $0.params["action"] as? String == "put" }.compactMap { $0.params["chunk_index"] as? Int }
            try require(indexes == [1, 0], "only missing chunks were sent")
            transport.replies = [.success(#"{"status":"existing","asset_id":"\#(asset.uuidString)","state":"available","chunk_size":32768,"chunk_count":2,"expires_at":"2026-10-17T20:00:00+00:00"}"#)]
            try require(try await transfer.send(room: room, file: file, name: "a.wav", mime: "audio/wav", license: .cc0, attribution: "") == .alreadyShared(asset), "identical file already shared")
            transport.replies = [
                .success(#"{"status":"declared","asset_id":"\#(asset.uuidString)","state":"receiving","chunk_size":32768,"chunk_count":2,"expires_at":"2026-10-14T21:00:00+00:00"}"#),
                .success(#"{"status":"stored","received":1}"#), .success(#"{"status":"stored","received":2}"#),
                .success(#"{"error":"The transferred file was corrupt and has been discarded. Send it again."}"#)]
            do { _ = try await transfer.send(room: room, file: file, name: "a.wav", mime: "audio/wav", license: .cc0, attribution: ""); throw Failure(description: "corruption hidden") }
            catch RoomAssetTransfer.TransferError.corrupt {}
            transport.replies = [.success(#"{"error":"Only editors can share assets in this room."}"#)]
            do { _ = try await transfer.send(room: room, file: file, name: "a.wav", mime: "audio/wav", license: .cc0, attribution: ""); throw Failure(description: "refusal hidden") }
            catch RoomAssetTransfer.TransferError.refused(let message) { try require(message.contains("Only editors"), "server refusal surfaced") }
        }

        await test("asset receive verifies every chunk and the whole-file hash, resumes, and saves without overwriting") {
            let transport = FakeTransport()
            let transfer = RoomAssetTransfer(gateway: CommunityGateway(transport: transport))
            let file = Data((0..<40_000).map { UInt8(($0 * 7) % 256) })
            guard let digest = RoomAssetPolicy.sha256Hex(file) else { throw Failure(description: "hashing unavailable") }
            transport.replies = [.success(#"{"assets":[{"asset_id":"\#(asset.uuidString)","name":"../punch.png","mime":"image/png","byte_size":40000,"chunk_count":2,"sha256":"\#(digest)","license":"cc-by","attribution":"Ann","state":"available","expires_at":"2026-10-17T20:00:00+00:00","created_at":"2026-10-14T20:00:00+00:00","mine":false,"received":2}],"chunk_size":32768}"#)]
            let listed = try await transfer.list(room: room)
            try require(listed.count == 1 && listed[0].licenseTitle.contains("CC BY"), "assets listed with licence")
            func chunkReply(_ index: Int, _ bytes: Data, sha: String = digest) -> String {
                #"{"asset_id":"\#(asset.uuidString)","chunk_index":\#(index),"chunk_count":2,"sha256":"\#(sha)","data":"\#(bytes.base64EncodedString(options: .lineLength76Characters).replacingOccurrences(of: "\r\n", with: "\\n"))"}"#
            }
            var download = RoomAssetTransfer.Download(asset: listed[0])
            transport.replies = [.success(chunkReply(0, file.prefix(32_768))), .failure(CommunityError.transport("offline"))]
            do { _ = try await transfer.receive(room: room, &download); throw Failure(description: "offline hidden") } catch CommunityError.transport {}
            try require(download.chunks.count == 1, "partial download kept for resume")
            transport.replies = [.success(chunkReply(1, file.suffix(from: 32_768)))]
            let received = try await transfer.receive(room: room, &download)
            try require(received == file && transport.calls.last?.params["chunk_index"] as? Int == 1, "resumed from chunk 1 and verified")
            var tampered = RoomAssetTransfer.Download(asset: listed[0])
            var bad = Data(file.suffix(from: 32_768)); bad[bad.startIndex] ^= 0xFF
            transport.replies = [.success(chunkReply(0, file.prefix(32_768))), .success(chunkReply(1, bad))]
            do { _ = try await transfer.receive(room: room, &tampered); throw Failure(description: "tampered file accepted") }
            catch RoomAssetTransfer.TransferError.corrupt { try require(tampered.chunks.isEmpty, "corrupt download discarded") }
            var short = RoomAssetTransfer.Download(asset: listed[0])
            transport.replies = [.success(chunkReply(0, file.prefix(100)))]
            do { _ = try await transfer.receive(room: room, &short); throw Failure(description: "short chunk accepted") } catch RoomAssetTransfer.TransferError.corrupt {}
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-room-assets-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: base) }
            let saved = try RoomAssetInbox.save(received, asset: listed[0], room: room, base: base)
            let written = try Data(contentsOf: saved)
            try require(saved.deletingLastPathComponent().standardizedFileURL == RoomAssetInbox.directory(base: base, room: room).standardizedFileURL && saved.lastPathComponent.hasSuffix("_punch.png") && written == file, "saved inside the room transfer folder")
            try require(try RoomAssetInbox.save(received, asset: listed[0], room: room, base: base) == saved, "saving again is idempotent")
            try Data("other".utf8).write(to: saved)
            do { _ = try RoomAssetInbox.save(received, asset: listed[0], room: room, base: base); throw Failure(description: "overwrote a different file") }
            catch RoomAssetTransfer.TransferError.refused {}
            do { _ = try RoomAssetInbox.save(Data("x".utf8), asset: listed[0], room: room, base: base); throw Failure(description: "saved unverified data") }
            catch RoomAssetTransfer.TransferError.corrupt {}
        }

        await test("active-project handoff survives leaving Rooms for Studio and ends with the session") {
            let coordinator = RoomSessionCoordinator(client: nil)
            coordinator.handOffToStudio(room: room, roomTitle: "Duel", projectID: project)
            try require(coordinator.handoff == nil, "no handoff without a session")
            coordinator.begin(room: room, head: 0, projectID: project, canEdit: true, account: member)
            coordinator.handOffToStudio(room: room, roomTitle: "Duel", projectID: project)
            try require(coordinator.isHandedOff(room: room) && coordinator.returnRoom == room, "handoff recorded for the return trip")
            coordinator.begin(room: room, head: 0, projectID: project, canEdit: false, account: member)
            try require(coordinator.session?.canEdit == false && coordinator.isHandedOff(room: room), "permission change keeps the handoff")
            try require(!coordinator.publishLocalEdit(kind: "frame.add", payload: .object([:])), "viewer after downgrade cannot publish")
            coordinator.end(reason: "Room access ended. Your device copy of the project is unchanged.")
            try require(coordinator.handoff == nil && coordinator.session == nil && coordinator.endReason?.contains("unchanged") == true, "ending clears the handoff with a truthful reason")
        }

        await test("editor hook: blocked remote edits wait in order with a reason until applied or explicitly skipped") {
            let transport = FakeTransport()
            let coordinator = RoomSessionCoordinator(client: RoomsClient(gateway: CommunityGateway(transport: transport)))
            coordinator.begin(room: room, head: 0, projectID: project, canEdit: true, account: member)
            try require(!coordinator.isSharing(projectID: project), "no handoff means the open project is not shared")
            coordinator.handOffToStudio(room: room, roomTitle: "Duel", projectID: project)
            try require(coordinator.isSharing(projectID: project) && !coordinator.isSharing(projectID: UUID()), "handoff binds exactly the shared project")
            let first = UUID(), second = UUID()
            var attempts: [Int] = [], refuse = true
            coordinator.applyRemote = { record in
                attempts.append(record.revision)
                if record.op_id == first && refuse { coordinator.noteRemoteBlocked(record, reason: "Cannot replay yet."); return false }
                return true
            }
            transport.replies = [.success(#"{"commands":[\#(record(1, op: first, author: owner)),\#(record(2, op: second, author: owner))],"head":2}"#)]
            let report = await coordinator.synchronise()
            try require(report.catchUp == .received(2) && attempts.first == 1 && !attempts.contains(2), "later edit must wait behind the blocked one")
            try require(coordinator.blockedRemote?.revision == 1 && coordinator.blockedRemote?.reason == "Cannot replay yet." && coordinator.head == 0
                && coordinator.pendingRemoteCount == 2, "blocked edit recorded with its reason, nothing acknowledged")
            // Local edits are not sent past unapplied remote edits.
            try require(coordinator.publishLocalEdit(kind: "studio.apply", payload: .object(["target": .string("frame:a")])) && coordinator.publishedLocalCount == 1, "local edit queued")
            try require(await coordinator.drain() == .idle && transport.calls.count == 1, "nothing sent while remote edits wait")
            // Transient block clears by itself on the next pass.
            refuse = false
            coordinator.applyQueued()
            try require(coordinator.blockedRemote == nil && coordinator.appliedRemoteCount == 2 && coordinator.head == 2 && coordinator.skippedRemote.isEmpty, "retry applied both in order")
            // An explicit skip acknowledges exactly the blocked edit and records it.
            refuse = true
            let third = UUID()
            transport.replies = [.success(#"{"commands":[\#(record(3, op: third, author: owner))],"head":3}"#)]
            coordinator.applyRemote = { record in coordinator.noteRemoteBlocked(record, reason: "Diverged."); return false }
            _ = await coordinator.catchUp()
            try require(coordinator.blockedRemote?.revision == 3, "third edit blocked")
            coordinator.applyRemote = { _ in true }
            try require(coordinator.skipBlockedRemote() && coordinator.skippedRemote == [third] && coordinator.head == 3 && coordinator.blockedRemote == nil
                && coordinator.appliedRemoteCount == 2, "skip acknowledges without counting as applied")
            try require(!coordinator.skipBlockedRemote(), "nothing left to skip")
            transport.replies = [.success(#"{"status":"applied","revision":4}"#)]
            try require(await coordinator.drain() == .sent(1) && transport.calls.last?.params["base_revision"] as? Int == 3, "local edit sent fenced on the advanced head")
            coordinator.noteUnsharedLocalEdit("Undo is not shared yet.")
            try require(coordinator.unsharedLocalCount == 1 && coordinator.lastUnsharedReason == "Undo is not shared yet.", "unshared local change reported")
            coordinator.end()
            try require(coordinator.unsharedLocalCount == 0 && coordinator.blockedRemote == nil && coordinator.publishedLocalCount == 0, "ending resets the counters")
            coordinator.noteUnsharedLocalEdit("ignored")
            try require(coordinator.unsharedLocalCount == 0, "no session, nothing recorded")
        }

        await test("Discard mine reverts through the editor hook only when it can, and Studio status reflects every state") {
            let transport = FakeTransport()
            let coordinator = RoomSessionCoordinator(client: RoomsClient(gateway: CommunityGateway(transport: transport)))
            try require(coordinator.studioSyncStatus == nil, "no session, no Studio status")
            coordinator.begin(room: room, head: 0, projectID: project, canEdit: true, account: member)
            try require(coordinator.studioSyncStatus == nil, "status appears only while handed off to Studio")
            coordinator.handOffToStudio(room: room, roomTitle: "Duel", projectID: project)
            try require(coordinator.studioSyncStatus?.level == .synced && coordinator.studioSyncStatus?.label == "Room: in sync", "idle session is in sync")
            try require(coordinator.discardHeldConflict() == .noConflict, "nothing to discard")
            // A held conflict with a hook that reverts.
            let mine = UUID(), theirs = UUID()
            try require(coordinator.publishLocalEdit(kind: "studio.apply", payload: .object(["target": .string("frame:a")]), opID: mine), "local edit queued with the editor's op id")
            try require(coordinator.studioSyncStatus?.level == .syncing && coordinator.studioSyncStatus?.label == "Room: 1 to sync", "queued edit shown as syncing")
            transport.replies = [.success(#"{"error":"conflict","head":1,"missing":[\#(targeted(1, "frame:a", op: theirs, author: owner))]}"#)]
            try require(await coordinator.drain() == .held(1) && coordinator.heldConflict?.opID == mine, "overlap held for the creator")
            try require(coordinator.studioSyncStatus?.level == .conflict && coordinator.studioSyncStatus?.detail.contains("frame:a") == true, "conflict shown in Studio status")
            var reverted: [UUID] = []
            coordinator.revertLocalEdit = { op in reverted.append(op); return nil }
            try require(coordinator.discardHeldConflict() == .reverted && reverted == [mine], "editor asked to revert exactly the held edit")
            try require(coordinator.heldConflict == nil && coordinator.pendingLocalCount == 0, "discarded edit is never sent")
            // The other creator's edit then applies and nothing is re-sent.
            coordinator.applyRemote = { _ in true }
            coordinator.applyQueued()
            let afterDiscard = await coordinator.drain()
            try require(coordinator.head == 1 && afterDiscard == .idle && transport.calls.count == 1, "their edit applied; nothing re-sent")
            // Not the latest change: the hook says why and the edit stays local.
            let second = UUID()
            _ = coordinator.publishLocalEdit(kind: "studio.apply", payload: .object(["target": .string("frame:b")]), opID: second)
            transport.replies = [.success(#"{"error":"conflict","head":2,"missing":[\#(targeted(2, "frame:b", author: owner))]}"#)]
            try require(await coordinator.drain() == .held(1), "second overlap held")
            coordinator.revertLocalEdit = { _ in "Not the most recent change." }
            try require(coordinator.discardHeldConflict() == .notReverted("Not the most recent change.") && coordinator.pendingLocalCount == 0, "reason returned; edit no longer sent")
            // No editor hook: a clear reason, never a claimed revert.
            coordinator.applyQueued()
            _ = coordinator.publishLocalEdit(kind: "studio.apply", payload: .object(["target": .string("frame:c")]))
            transport.replies = [.success(#"{"error":"conflict","head":3,"missing":[\#(targeted(3, "frame:c", author: owner))]}"#)]
            try require(await coordinator.drain() == .held(1), "third overlap held")
            coordinator.revertLocalEdit = nil
            if case .notReverted(let reason) = coordinator.discardHeldConflict() { try require(reason.contains("not open"), "no-hook reason") }
            else { throw Failure(description: "discard without an editor claimed a revert") }
            // A transport failure pauses with a reason; the next clean pass clears it.
            coordinator.applyQueued()
            _ = coordinator.publishLocalEdit(kind: "studio.apply", payload: .object(["target": .string("frame:d")]))
            transport.replies = [.failure(CommunityError.transport("offline"))]
            if case .stopped = await coordinator.drain() {} else { throw Failure(description: "offline append not stopped") }
            try require(coordinator.studioSyncStatus?.level == .paused && coordinator.lastStopReason != nil, "paused status after a failed send")
            transport.replies = [.success(#"{"status":"applied","revision":4}"#)]
            try require(await coordinator.drain() == .sent(1) && coordinator.lastStopReason == nil && coordinator.studioSyncStatus?.level == .synced, "clean pass clears the pause")
            coordinator.begin(room: room, head: 4, projectID: project, canEdit: false, account: member)
            try require(coordinator.studioSyncStatus?.level == .paused && coordinator.studioSyncStatus?.label == "Room: view only", "view-only shown")
            coordinator.end()
            try require(coordinator.studioSyncStatus == nil && coordinator.lastStopReason == nil, "ending clears the status")
        }

        await test("file hashing matches FIPS 180-4 known answers on every platform") {
            try require(RoomAssetPolicy.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty input digest")
            try require(RoomAssetPolicy.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc digest")
            try require(RoomAssetPolicy.sha256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "two-block digest")
        }

        // MARK: Owner-approved project handoff (#234)

        let snapshotID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        func portableBundle(_ count: Int) -> Data {
            var data = RoomProjectHandoffPolicy.portableMagic
            data.append(Data((0..<(count - data.count)).map { UInt8(($0 * 31) % 251) }))
            return data
        }
        func snapshotJSON(_ digest: String, bytes: Int, chunks: Int, state: String = "available", mine: Bool = false, receivedByMe: Bool = false) -> String {
            #"{"snapshot_id":"\#(snapshotID.uuidString)","title":"Duel","project_ref":"device-project:\#(project.uuidString.lowercased())","project_revision":2,"byte_size":\#(bytes),"chunk_count":\#(chunks),"sha256":"\#(digest)","state":"\#(state)","offered_at":"2026-10-18T20:00:00+00:00","expires_at":"2026-10-21T20:00:00+00:00","mine":\#(mine),"received_by_me":\#(receivedByMe),"received":null,"delivered":null,"awaiting":null}"#
        }

        await test("handoff policy bounds the portable backup, chunks it exactly and decides what a member is offered") {
            try require(RoomProjectHandoffPolicy.chunkCount(bytes: 262_144) == 1 && RoomProjectHandoffPolicy.chunkCount(bytes: 262_145) == 2
                        && RoomProjectHandoffPolicy.chunkCount(bytes: RoomProjectHandoffPolicy.maximumBytes) == RoomProjectHandoffPolicy.maximumChunks, "chunk counts mirror the SQL bounds")
            try require(RoomProjectHandoffPolicy.validate(bundle: Data()) != nil && RoomProjectHandoffPolicy.validate(bundle: Data("PK\u{3}\u{4}zip".utf8)) != nil, "empty and foreign files refused")
            try require(RoomProjectHandoffPolicy.validate(bundle: portableBundle(100)) == nil, "portable backup accepted")
            var huge = RoomProjectHandoffPolicy.portableMagic; huge.append(Data(count: RoomProjectHandoffPolicy.maximumBytes))
            try require(RoomProjectHandoffPolicy.validate(bundle: huge)?.contains("32 MB") == true, "over 32 MB refused with the reason")
            let bundle = portableBundle(300_000)
            let parts = (0..<2).compactMap { RoomProjectHandoffPolicy.chunk(bundle, index: $0) }
            try require(parts.count == 2 && parts[0].count == 262_144 && parts[1].count == 300_000 - 262_144 && parts[0] + parts[1] == bundle
                        && RoomProjectHandoffPolicy.chunk(bundle, index: 2) == nil, "exact chunks")
            let digest = String(repeating: "a", count: 64)
            let offered = try CommunityCoding.decode(RoomSnapshotResponse.self, from: Data(#"{"chunk_size":262144,"snapshot":\#(snapshotJSON(digest, bytes: 10, chunks: 1))}"#.utf8)).snapshot
            let local = UUID()
            let link = RoomProjectLink(room: room, projectRef: "device-project:\(project.uuidString.lowercased())", sha256: digest, localProjectID: local, importedAt: Date())
            typealias P = RoomProjectHandoffPolicy
            try require(P.memberState(isOwner: true, snapshot: offered, ownerProjectOnDevice: true, link: nil, linkedProjectExists: false) == .nothingToDo, "owner is never offered a download")
            try require(P.memberState(isOwner: false, snapshot: offered, ownerProjectOnDevice: true, link: nil, linkedProjectExists: false) == .ownerProjectOnDevice, "same device project needs no download")
            try require(P.memberState(isOwner: false, snapshot: offered, ownerProjectOnDevice: false, link: nil, linkedProjectExists: false) == .download, "member without the project downloads")
            try require(P.memberState(isOwner: false, snapshot: nil, ownerProjectOnDevice: false, link: nil, linkedProjectExists: false) == .nothingToDo, "nothing offered yet")
            try require(P.memberState(isOwner: false, snapshot: offered, ownerProjectOnDevice: false, link: link, linkedProjectExists: true) == .imported(local), "same version already imported")
            try require(P.memberState(isOwner: false, snapshot: nil, ownerProjectOnDevice: false, link: link, linkedProjectExists: true) == .imported(local), "import remains after the server copy is deleted")
            try require(P.memberState(isOwner: false, snapshot: offered, ownerProjectOnDevice: false, link: link, linkedProjectExists: false) == .download, "a deleted import is offered again")
            let older = RoomProjectLink(room: room, projectRef: link.projectRef, sha256: String(repeating: "b", count: 64), localProjectID: local, importedAt: Date())
            try require(P.memberState(isOwner: false, snapshot: offered, ownerProjectOnDevice: false, link: older, linkedProjectExists: true) == .updateAvailable(previous: local), "newer version offered without replacing the earlier import")
        }

        await test("owner sends the portable backup in verified chunks, resumes, and surfaces refusals and corruption") {
            let transport = FakeTransport()
            let handoff = RoomProjectHandoff(gateway: CommunityGateway(transport: transport))
            let bundle = portableBundle(300_000)
            guard let digest = RoomAssetPolicy.sha256Hex(bundle) else { throw Failure(description: "hashing unavailable") }
            transport.replies = [
                .success(#"{"status":"declared","snapshot_id":"\#(snapshotID.uuidString)","state":"receiving","chunk_size":262144,"chunk_count":2,"expires_at":"2026-10-18T21:00:00+00:00"}"#),
                .success(#"{"status":"stored","received":1}"#), .success(#"{"status":"stored","received":2}"#),
                .success(#"{"status":"available","snapshot_id":"\#(snapshotID.uuidString)","awaiting":2,"expires_at":"2026-10-21T20:00:00+00:00"}"#)]
            var progress: [Int] = []
            let outcome = try await handoff.send(room: room, bundle: bundle) { sent, _ in progress.append(sent) }
            try require(outcome == .available(snapshotID, awaiting: 2) && progress == [1, 2], "sent then verified by the server")
            let offer = transport.calls[0]
            try require(offer.name == "sdi_room_snapshot" && offer.params["action"] as? String == "offer" && offer.params["sha256"] as? String == digest
                        && offer.params["byte_size"] as? Int == 300_000 && offer.params["room"] as? String != nil, "offer payload carries size and digest only")
            let part0 = (transport.calls[1].params["data"] as? String).flatMap { Data(base64Encoded: $0) }
            try require(part0 == bundle.prefix(262_144) && transport.calls[2].params["chunk_index"] as? Int == 1 && transport.calls[3].params["action"] as? String == "finalize", "exact bytes in order")

            transport.calls = []
            transport.replies = [
                .success(#"{"status":"existing","snapshot_id":"\#(snapshotID.uuidString)","state":"receiving","chunk_size":262144,"chunk_count":2,"expires_at":"2026-10-18T21:00:00+00:00","received":[0]}"#),
                .success(#"{"status":"stored","received":2}"#),
                .success(#"{"error":"incomplete","received":[1]}"#),
                .success(#"{"status":"stored","received":2}"#),
                .success(#"{"status":"available","snapshot_id":"\#(snapshotID.uuidString)","awaiting":0,"expires_at":"2026-10-21T20:00:00+00:00"}"#)]
            try require(try await handoff.send(room: room, bundle: bundle) == .available(snapshotID, awaiting: 0), "resumed send completes")
            try require(transport.calls.filter { $0.params["action"] as? String == "put" }.compactMap { $0.params["chunk_index"] as? Int } == [1, 0], "only missing parts sent")
            transport.replies = [.success(#"{"status":"existing","snapshot_id":"\#(snapshotID.uuidString)","state":"available","chunk_size":262144,"chunk_count":2,"expires_at":"2026-10-21T20:00:00+00:00","received":[0,1]}"#)]
            try require(try await handoff.send(room: room, bundle: bundle) == .alreadyAvailable(snapshotID), "same version already waiting")
            transport.replies = [
                .success(#"{"status":"declared","snapshot_id":"\#(snapshotID.uuidString)","state":"receiving","chunk_size":262144,"chunk_count":2,"expires_at":"2026-10-18T21:00:00+00:00"}"#),
                .success(#"{"status":"stored","received":1}"#), .success(#"{"status":"stored","received":2}"#),
                .success(#"{"error":"The sent project was corrupt and has been discarded. Send it again."}"#)]
            do { _ = try await handoff.send(room: room, bundle: bundle); throw Failure(description: "corruption hidden") } catch RoomProjectHandoff.HandoffError.corrupt {}
            transport.replies = [.success(#"{"error":"Only the room owner can send the shared project."}"#)]
            do { _ = try await handoff.send(room: room, bundle: bundle); throw Failure(description: "refusal hidden") }
            catch RoomProjectHandoff.HandoffError.refused(let message) { try require(message.contains("Only the room owner"), "server refusal surfaced") }
            transport.calls = []
            do { _ = try await handoff.send(room: room, bundle: Data("not a project".utf8)); throw Failure(description: "foreign file sent") }
            catch RoomProjectHandoff.HandoffError.invalid {}
            try require(transport.calls.isEmpty, "invalid backups never reach the server")
        }

        await test("member download verifies every part and the SHA-256, resumes, discards tampering, and records a receipt") {
            let transport = FakeTransport()
            let handoff = RoomProjectHandoff(gateway: CommunityGateway(transport: transport))
            let bundle = portableBundle(300_000)
            guard let digest = RoomAssetPolicy.sha256Hex(bundle) else { throw Failure(description: "hashing unavailable") }
            transport.replies = [.success(#"{"chunk_size":262144,"snapshot":\#(snapshotJSON(digest, bytes: 300_000, chunks: 2))}"#)]
            guard let snapshot = try await handoff.current(room: room) else { throw Failure(description: "no snapshot") }
            try require(snapshot.sha256 == digest && snapshot.mine == false && snapshot.delivered == nil, "member sees the offer without delivery counts")
            transport.replies = [.success(#"{"chunk_size":262144,"snapshot":null}"#)]
            try require(try await handoff.current(room: room) == nil, "nothing waiting")
            transport.replies = [.success(#"{"error":"Room is unavailable."}"#)]
            do { _ = try await handoff.current(room: room); throw Failure(description: "outsider saw a snapshot") } catch RoomProjectHandoff.HandoffError.unavailable {}

            func part(_ index: Int, _ bytes: Data, sha: String = digest) -> String {
                #"{"snapshot_id":"\#(snapshotID.uuidString)","chunk_index":\#(index),"chunk_count":2,"sha256":"\#(sha)","data":"\#(bytes.base64EncodedString())"}"#
            }
            var download = RoomProjectHandoff.Download(snapshot: snapshot)
            transport.replies = [.success(part(0, bundle.prefix(262_144))), .failure(CommunityError.transport("offline"))]
            do { _ = try await handoff.receive(room: room, &download); throw Failure(description: "offline hidden") } catch CommunityError.transport {}
            try require(download.chunks.count == 1, "verified part kept for resume")
            transport.replies = [.success(part(1, bundle.suffix(from: 262_144)))]
            let received = try await handoff.receive(room: room, &download)
            try require(received == bundle && transport.calls.last?.params["chunk_index"] as? Int == 1 && transport.calls.last?.params["snapshot"] as? String == snapshotID.uuidString, "resumed and verified")

            var tampered = RoomProjectHandoff.Download(snapshot: snapshot)
            var bad = Data(bundle.suffix(from: 262_144)); bad[bad.startIndex] ^= 0xFF
            transport.replies = [.success(part(0, bundle.prefix(262_144))), .success(part(1, bad))]
            do { _ = try await handoff.receive(room: room, &tampered); throw Failure(description: "tampered project accepted") }
            catch RoomProjectHandoff.HandoffError.corrupt { try require(tampered.chunks.isEmpty, "tampered download discarded") }
            var swapped = RoomProjectHandoff.Download(snapshot: snapshot)
            transport.replies = [.success(part(0, bundle.prefix(262_144), sha: String(repeating: "c", count: 64)))]
            do { _ = try await handoff.receive(room: room, &swapped); throw Failure(description: "different snapshot accepted") } catch RoomProjectHandoff.HandoffError.corrupt {}
            var own = RoomProjectHandoff.Download(snapshot: try CommunityCoding.decode(RoomSnapshotResponse.self,
                from: Data(#"{"chunk_size":262144,"snapshot":\#(snapshotJSON(digest, bytes: 300_000, chunks: 2, mine: true))}"#.utf8)).snapshot!)
            do { _ = try await handoff.receive(room: room, &own); throw Failure(description: "owner downloaded own project") } catch RoomProjectHandoff.HandoffError.unavailable {}

            transport.calls = []
            transport.replies = [.success(#"{"status":"recorded","server_copy":"retained"}"#)]
            try require(try await handoff.confirmReceipt(room: room, snapshot: snapshot) == .serverCopyRetained, "copy kept for other members")
            try require(transport.calls[0].params["action"] as? String == "receipt" && transport.calls[0].params["sha256"] as? String == digest, "receipt names the verified digest")
            transport.replies = [.success(#"{"status":"recorded","server_copy":"deleted","verified":true}"#)]
            try require(try await handoff.confirmReceipt(room: room, snapshot: snapshot) == .serverCopyDeleted(verified: true), "last member's receipt deletes the copy")
            transport.replies = [.success(#"{"status":"revoked","verified":true}"#)]
            try require(try await handoff.revoke(room: room, snapshot: snapshotID), "owner withdrawal verified")
            transport.replies = [.success(#"{"error":"Only the room owner can withdraw the shared project."}"#)]
            do { _ = try await handoff.revoke(room: room, snapshot: snapshotID); throw Failure(description: "member revoked") } catch RoomProjectHandoff.HandoffError.refused {}
        }

        await test("room project links record imports as new projects and never replace an earlier one") {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-room-links-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: base) }
            let store = RoomProjectLinkStore(directory: base)
            let ref = "device-project:\(project.uuidString.lowercased())"
            try require(store.all().isEmpty && store.link(room: room, projectRef: ref) == nil, "empty store")
            let first = RoomProjectLink(room: room, projectRef: ref, sha256: String(repeating: "a", count: 64), localProjectID: UUID(), importedAt: Date(timeIntervalSince1970: 1_000))
            let second = RoomProjectLink(room: room, projectRef: ref, sha256: String(repeating: "b", count: 64), localProjectID: UUID(), importedAt: Date(timeIntervalSince1970: 2_000))
            try store.record(first); try store.record(second)
            try require(store.all().count == 2 && store.link(room: room, projectRef: ref) == second, "latest import wins; earlier link kept")
            try require(store.link(room: room, projectRef: "device-project:other") == nil && store.link(room: UUID(), projectRef: ref) == nil && store.link(room: room, projectRef: nil) == nil, "links are per room and per shared project")
            try require(first.localProjectID != project && second.localProjectID != first.localProjectID, "every import has a fresh identity")
        }

        print("COMMUNITY_ROOMS_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed) passed \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
