import Foundation

// Foundation-only verification of War Room presentation/voting, challenge
// phases, the Calendar range placement (DST-safe) and the server clock.

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}

final class FakeTransport: CommunityTransport {
    struct Call { let name: String; let params: [String: Any] }
    var replies: [Result<String, Error>] = []
    var calls: [Call] = []
    var hasSession = true
    var serverDate: Date?
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
        case .success(let json): return CommunityReply(data: Data(json.utf8), serverDate: serverDate, sentAt: Date(), receivedAt: Date())
        case .failure(let error): throw error
        }
    }
}

private let creator = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
private let opponent = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
private let viewer = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
private let match = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let media = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let now = Date(timeIntervalSince1970: 1_791_837_191)
private func matchJSON(status: String, endsAt: Date?, left: Int = 2, right: Int = 5, outcome: String? = nil, myVote: String? = nil) -> String {
    let ends = endsAt.map { "\"\(CommunityDates.string($0))\"" } ?? "null"
    let result = outcome.map { "\"\($0)\"" } ?? "null"
    let vote = myVote.map { "\"\($0)\"" } ?? "null"
    return #"{"id":"\#(match.uuidString)","creator":"\#(creator.uuidString)","opponent":"\#(opponent.uuidString)","status":"\#(status)","ends_at":\#(ends),"left_title":"Left","left_url":"https://cdn.example/l.mp4","right_title":"Right","right_url":"https://cdn.example/r.mp4","left_votes":\#(left),"right_votes":\#(right),"my_vote":\#(vote),"outcome":\#(result)}"#
}
private func decodeMatch(_ json: String) throws -> WarMatch { try CommunityCoding.decoder().decode(WarMatch.self, from: Data(json.utf8)) }

@main @MainActor struct CommunityContestsTests {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-community-contests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        await test("matchup presentation follows server status and never computes a winner from running tallies") {
            let pending = try decodeMatch(matchJSON(status: "pending", endsAt: nil))
            let asOpponent = WarMatchPresentation(match: pending, viewer: opponent, now: now)
            try require(asOpponent.canAccept && asOpponent.canWithdraw && !asOpponent.canVote && !asOpponent.showsTallies && asOpponent.phase == .proposal, "invited opponent may accept")
            let asCreator = WarMatchPresentation(match: pending, viewer: creator, now: now)
            try require(!asCreator.canAccept && asCreator.canWithdraw && asCreator.phase == .awaitingOpponent, "creator waits for consent")
            let active = try decodeMatch(matchJSON(status: "active", endsAt: now.addingTimeInterval(3600)))
            let asViewer = WarMatchPresentation(match: active, viewer: viewer, now: now)
            try require(asViewer.canVote && !asViewer.canWithdraw && asViewer.showsTallies && asViewer.phase == .voting, "viewer may vote")
            let participant = WarMatchPresentation(match: active, viewer: creator, now: now)
            try require(!participant.canVote && participant.canWithdraw && participant.isParticipant, "participants cannot vote on their own matchup")
            let ended = try decodeMatch(matchJSON(status: "active", endsAt: now.addingTimeInterval(-1), left: 1, right: 9))
            let awaiting = WarMatchPresentation(match: ended, viewer: viewer, now: now)
            try require(awaiting.phase == .awaitingFinalisation && awaiting.resultText == nil && !awaiting.canVote && !awaiting.canWithdraw, "ended but unfinalised shows no winner")
            try require(WarMatchPresentation(match: try decodeMatch(matchJSON(status: "completed", endsAt: now, outcome: "tie")), viewer: viewer, now: now).resultText == "Tie — no winner or loser", "tie text")
            try require(WarMatchPresentation(match: try decodeMatch(matchJSON(status: "completed", endsAt: now, outcome: "right")), viewer: viewer, now: now).resultText == "Winner: Right", "right winner")
            try require(WarMatchPresentation(match: try decodeMatch(matchJSON(status: "completed", endsAt: now)), viewer: viewer, now: now).resultText == "Result not yet recorded by the server", "completed without outcome is explicit")
            try require(WarMatchPresentation(match: try decodeMatch(matchJSON(status: "withdrawn", endsAt: nil)), viewer: viewer, now: now).phase == .unavailable, "withdrawn unavailable")
            try require(WarMatchPresentation(match: active, viewer: nil, now: now).canVote == false, "signed-out viewer cannot vote")
        }

        await test("one mutable vote: pending until confirmed, restored on refusal, no double submission") {
            var machine = WarVoteMachine(serverVote: "left")
            try require(machine.isSelected(.left) && !machine.isPending, "server vote loaded")
            try require(machine.tap(.right) && machine.isPending && machine.isPendingChoice(.right) && machine.serverChoice == nil, "pending tap is not shown as a confirmed vote")
            try require(!machine.tap(.left), "second tap refused while pending")
            machine.fail("Voting is unavailable.", previous: .left)
            try require(machine.isSelected(.left) && !machine.isPending, "refusal restores the previous server vote")
            _ = machine.tap(.right); machine.confirm(.right)
            try require(machine.isSelected(.right), "confirmed vote shown")
            try require(WarVoteMachine(serverVote: nil).serverChoice == nil && WarVoteMachine(serverVote: "bogus").serverChoice == nil, "unknown vote values ignored")
            try require(WarPlaybackMode.preferred(forWidth: 390) == .sequential && WarPlaybackMode.preferred(forWidth: 820) == .sideBySide, "playback mode by width")
        }

        await test("war client confirms only server-confirmed actions and validates locally first") {
            let transport = FakeTransport()
            let client = WarRoomClient(gateway: CommunityGateway(transport: transport))
            do { try await client.propose(media: media, opponent: opponent, agreed: false); throw Failure(description: "proposed without agreement") } catch CommunityError.server {}
            try require(transport.calls.isEmpty, "no request without agreement")
            transport.replies = [.success(#"{"status":"confirmed"}"#)]
            try await client.vote(match: match, choice: .right)
            try require(transport.calls.last?.params["choice"] as? String == "right" && transport.calls.last?.params["action"] as? String == "vote", "vote payload")
            transport.replies = [.success(#"{"error":"Voting is not available to this account."}"#)]
            do { try await client.vote(match: match, choice: .left); throw Failure(description: "refused vote accepted") } catch CommunityError.server {}
            transport.replies = [.success(#"{"matches":[\#(matchJSON(status: "active", endsAt: now, left: -1))]}"#)]
            do { _ = try await client.matches(); throw Failure(description: "negative tally accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"matches":[\#(matchJSON(status: "active", endsAt: now))]}"#)]
            try require(try await client.matches().count == 1, "matches decoded")
            do { try await client.report(match: match, reason: "   "); throw Failure(description: "empty report sent") } catch CommunityError.server {}
            transport.replies = [.success(#"{"status":"recorded"}"#)]
            try await client.report(match: match, reason: "Vote brigading")
            transport.replies = [.success(#"{"notices":[{"id":"\#(media.uuidString)","match_id":"\#(match.uuidString)","message":"Matchup removed after administrator review.","created_at":"2026-10-01T00:00:00Z","appeal_state":null,"appeal_deadline":"2026-10-31T00:00:00Z"}]}"#)]
            try require(try await client.notices().first?.appeal_state == nil, "notice decoded")
            transport.replies = [.success(#"[{"id":"\#(media.uuidString)","title":"Mine","url":"https://cdn.example/m.mp4","duration":4,"expires_at":null}]"#)]
            try require(try await client.ownedMedia(account: creator).count == 1 && (transport.calls.last?.params["filters"] as? [String])?.first == "owner_id=\(creator.uuidString.lowercased())", "owned media filtered")
        }

        await test("challenge phases use the server clock, one entry per creator and schedule rules hold before any request") {
            let decoder = CommunityCoding.decoder()
            let summary = try decoder.decode(ChallengeSummary.self, from: Data(#"{"id":"\#(match.uuidString)","title":"Loop jam","brief":"","reward_text":" ","starts_at":"2026-10-20T00:00:00Z","submissions_close_at":"2026-10-22T00:00:00Z","voting_ends_at":"2026-10-23T00:00:00Z","revision":1,"phase":"upcoming","entry_count":0,"my_entry":false,"outcome":null,"winner_entry":null}"#.utf8))
            let starts = CommunityDates.parse("2026-10-20T00:00:00Z")!
            try require(summary.phase(at: starts.addingTimeInterval(-1)) == .upcoming && summary.phase(at: starts) == .active, "upcoming → active at start")
            try require(summary.phase(at: starts.addingTimeInterval(2 * 86_400)) == .voting && summary.phase(at: starts.addingTimeInterval(3 * 86_400)) == .completed, "voting → completed")
            try require(!summary.hasReward && summary.outcomeText == nil, "blank reward text is not a prize")
            let clock = ChallengeClock(serverTime: starts, receivedAt: now)
            try require(clock.now(deviceNow: now.addingTimeInterval(90)) == starts.addingTimeInterval(90) && clock.now(deviceNow: now.addingTimeInterval(-90)) == starts, "server clock advances monotonically")
            let transport = FakeTransport()
            let client = ChallengeLifecycleClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"challenges":[],"server_time":"2026-10-12T20:33:11.5+00:00"}"#)]
            let listing = try await client.list(now: now)
            try require(listing.challenges.isEmpty && abs(listing.clock.serverTime.timeIntervalSince(now) - 0.5) < 0.001, "server time anchored")
            transport.replies = [.success(#"{"challenges":[]}"#)]
            do { _ = try await client.list(now: now); throw Failure(description: "list without server time accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"status":"entered"}"#)]
            try await client.submit(challenge: match, media: media)
            transport.replies = [.success(#"{"error":"One entry per creator. Withdraw it to change your entry."}"#)]
            do { try await client.submit(challenge: match, media: media); throw Failure(description: "second entry accepted") } catch CommunityError.server {}
            transport.replies = [.success(#"{"phase":"voting","entries":[{"id":"\#(media.uuidString)","creator":"\#(creator.uuidString)","title":"E","url":"https://cdn.example/e.mp4","created_at":"2026-10-21T00:00:00Z","votes":3,"my_vote":false}]}"#)]
            let entries = try await client.entries(challenge: match)
            try require(entries.phase == .voting && entries.entries.first?.votes == 3, "entries decoded with phase")
            let before = transport.calls.count
            let bad = ChallengeScheduleDraft(startsAt: now.addingTimeInterval(600), closesAt: now.addingTimeInterval(1200), endsAt: now.addingTimeInterval(1800))
            do { _ = try await client.schedule(challenge: match, revision: 1, draft: bad, now: now); throw Failure(description: "short submissions window sent") } catch CommunityError.server {}
            try require(transport.calls.count == before, "invalid schedule never sent")
            let long = ChallengeScheduleDraft(startsAt: now.addingTimeInterval(600), closesAt: now.addingTimeInterval(86_400), endsAt: now.addingTimeInterval(61 * 86_400))
            try require(long.validation(now: now)?.contains("sixty") == true, "sixty-day bound")
            transport.replies = [.success(#"{"status":"confirmed","revision":2}"#)]
            let good = ChallengeScheduleDraft(startsAt: now.addingTimeInterval(600), closesAt: now.addingTimeInterval(86_400), endsAt: now.addingTimeInterval(2 * 86_400))
            try require(try await client.schedule(challenge: match, revision: 1, draft: good, now: now) == 2, "schedule confirmed")
            try require((transport.calls.last?.params["starts_at"] as? String)?.hasSuffix("Z") == true, "timestamps encoded in UTC")
            do { _ = try await client.cancel(challenge: match, revision: 2, reason: ""); throw Failure(description: "cancel without reason") } catch CommunityError.server {}
        }

        await test("calendar range stays within 62 days and places items on the correct civil day across DST") {
            guard let zone = TimeZone(identifier: "America/New_York") else { throw Failure(description: "tz database unavailable") }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let march = CommunityDates.parse("2027-03-10T12:00:00Z")!
            guard let bounds = CalendarMonthPlacement.monthBounds(containing: march, calendar: calendar) else { throw Failure(description: "no bounds") }
            try require(bounds.end.timeIntervalSince(bounds.start) <= 62 * 86_400 && bounds.end.timeIntervalSince(bounds.start) >= 30 * 86_400, "visible month within the server bound")
            func item(_ id: UUID, _ iso: String) -> CalendarItem {
                CalendarItem(kind: "challenge", recordID: id, title: "T", occurs_at: CommunityDates.parse(iso)!, milestone: "opens", status: "upcoming")
            }
            let early = item(match, "2027-03-14T06:30:00Z") // 01:30 EST before the spring-forward gap
            let late = item(media, "2027-03-14T07:30:00Z") // 03:30 EDT after the gap
            let evening = item(creator, "2027-03-15T03:59:00Z") // 23:59 EDT on 14 March
            let next = item(opponent, "2027-03-15T04:00:00Z") // 00:00 EDT on 15 March
            let placement = CalendarMonthPlacement(start: bounds.start, end: bounds.end, items: [late, early, evening, next, early])
            try require(placement.items.count == 4 && placement.items.first?.recordID == match, "deduplicated and sorted")
            let day14 = CommunityDates.parse("2027-03-14T17:00:00Z")!
            try require(placement.items(on: day14, calendar: calendar).map(\.recordID) == [match, media, creator], "three items on the transition day")
            try require(placement.items(on: CommunityDates.parse("2027-03-15T17:00:00Z")!, calendar: calendar).map(\.recordID) == [opponent], "midnight boundary respected")
            let fall = CalendarMonthPlacement(start: CommunityDates.parse("2027-11-01T04:00:00Z")!, end: CommunityDates.parse("2027-12-01T05:00:00Z")!,
                                              items: [item(match, "2027-11-07T05:30:00Z"), item(media, "2027-11-07T06:30:00Z")]) // 01:30 EDT and 01:30 EST
            try require(fall.items(on: CommunityDates.parse("2027-11-07T15:00:00Z")!, calendar: calendar).count == 2, "repeated hour stays on 7 November")
            try require(CalendarMonthPlacement.monthKey(march, calendar: calendar) == "2027-03", "month key")
            let transport = FakeTransport()
            let client = CalendarClient(gateway: CommunityGateway(transport: transport), cache: .init(name: "calendar", directory: root.appendingPathComponent("calendar")))
            transport.replies = [.success(#"{"items":[{"kind":"war_match","id":"\#(match.uuidString)","title":"Left","occurs_at":"2027-03-20T12:00:00Z","milestone":"voting_ends","status":"active"}],"range_start":"2027-03-01T05:00:00Z","range_end":"2027-04-01T04:00:00Z","truncated":false}"#)]
            let month = try await client.month(containing: march, calendar: calendar, account: "acct")
            try require(month.placement.items.count == 1 && month.source == .server && month.placement.items[0].kindText == "War Room", "server month")
            let sent = transport.calls[0].params
            let start = CommunityDates.parse(sent["range_start"] as? String ?? "")!, end = CommunityDates.parse(sent["range_end"] as? String ?? "")!
            try require(end.timeIntervalSince(start) <= 62 * 86_400 && sent["page_size"] as? Int == 500, "range request bounded")
            transport.replies = [.failure(CommunityError.transport("offline"))]
            let offline = try await client.month(containing: march, calendar: calendar, account: "acct")
            if case .cache = offline.source {} else { throw Failure(description: "offline month not served from cache") }
            transport.replies = [.failure(CommunityError.transport("offline"))]
            do { _ = try await client.month(containing: CommunityDates.parse("2027-05-10T12:00:00Z")!, calendar: calendar, account: "acct"); throw Failure(description: "uncached month invented") } catch CommunityError.transport {}
        }

        await test("server clock keeps the lowest round-trip sample, ignores missing headers and derives shared positions") {
            var clock = ServerClockEstimator()
            clock.record(sentAt: now, receivedAt: now.addingTimeInterval(2), serverDate: nil)
            try require(clock.best == nil && clock.offset == 0 && clock.isStale(at: now), "missing header ignored")
            clock.record(sentAt: now, receivedAt: now.addingTimeInterval(2), serverDate: now.addingTimeInterval(11))
            try require(abs(clock.offset - 10) < 0.001 && abs(clock.uncertainty - 2) < 0.001, "offset from midpoint")
            clock.record(sentAt: now.addingTimeInterval(5), receivedAt: now.addingTimeInterval(5.2), serverDate: now.addingTimeInterval(15.1))
            try require(abs(clock.offset - 10) < 0.01 && abs((clock.best?.roundTrip ?? 0) - 0.2) < 0.001, "lower round trip replaces the sample")
            clock.record(sentAt: now.addingTimeInterval(6), receivedAt: now.addingTimeInterval(9), serverDate: now.addingTimeInterval(100))
            try require(abs(clock.offset - 10) < 0.01, "worse sample ignored while fresh")
            try require(!clock.isStale(at: now.addingTimeInterval(60)) && clock.isStale(at: now.addingTimeInterval(700)), "staleness window")
            let position = clock.sharedPosition(position: 10, playing: true, updatedAt: now.addingTimeInterval(10), duration: 60, deviceNow: now.addingTimeInterval(5))
            try require(abs(position - 15) < 0.01, "playing position uses server now (device 5 s + offset 10 s − updated 10 s)")
            try require(clock.sharedPosition(position: 10, playing: false, updatedAt: now, duration: 60, deviceNow: now.addingTimeInterval(500)) == 10, "paused position holds")
            try require(clock.sharedPosition(position: 55, playing: true, updatedAt: now, duration: 60, deviceNow: now.addingTimeInterval(500)) == 60, "clamped to duration")
            try require(clock.sharedPosition(position: .nan, playing: true, updatedAt: now, duration: 60, deviceNow: now) == 0, "non-finite input rejected")
        }

        print("COMMUNITY_CONTESTS_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed) passed \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
