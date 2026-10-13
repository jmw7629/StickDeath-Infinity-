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
            try require(sync.lastProblem?.contains("2 remote edits") == true, "conflict explanation names the count")
            for remote in sync.remoteCommandsToApply(author: owner) { sync.acknowledgeRemote(remote) }
            try require(sync.head == 6 && sync.nextAppend()?.base_revision == 6, "head rebased after applying remote edits")
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
            try require(await coordinator.drain() == .conflict(2) && coordinator.head == 3 && coordinator.pendingLocalCount == 1 && coordinator.pendingRemoteCount == 2, "first edit applied, second blocked by conflict")
            try require(transport.calls.count == 2 && transport.calls[1].params["base_revision"] as? Int == 3, "second append fenced on the advanced head")
            var applied: [Int] = []
            coordinator.applyRemote = { record in applied.append(record.revision); return true }
            transport.replies = [.success(#"{"commands":[],"head":5}"#)]
            _ = await coordinator.catchUp()
            try require(applied == [4, 5] && coordinator.head == 5 && coordinator.pendingRemoteCount == 0, "remote edits applied in order through the hook")
            transport.replies = [.success(#"{"status":"applied","revision":6}"#)]
            try require(await coordinator.drain() == .sent(1) && coordinator.head == 6, "blocked edit sent after rebasing")
            transport.replies = [.success(#"{"error":"Room is unavailable."}"#)]
            _ = coordinator.publishLocalEdit(kind: "frame.add", payload: .object([:]))
            try require(await coordinator.drain() == .stopped("Room is unavailable.") && coordinator.session == nil, "revoked access ends the session")
            try require(await coordinator.drain() == .idle, "no session means nothing is sent")
        }

        print("COMMUNITY_ROOMS_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed) passed \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
