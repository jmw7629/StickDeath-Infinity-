import Foundation

// Foundation-only verification of the social wall and profile clients against
// scripted fake transports. No network, no SwiftUI, no Supabase SDK.

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

private let postA = "11111111-1111-4111-8111-111111111111"
private let postB = "22222222-2222-4222-8222-222222222222"
private let creatorA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let creatorB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private func postJSON(_ id: String, creator: String, likes: Int, liked: Bool = false, following: Bool = false, export: Bool = false, url: String = "https://cdn.example/v.mp4") -> String {
    #"{"id":"\#(id)","creator":"\#(creator)","creator_name":"Creator","caption":"","published_at":"2026-10-12T20:33:11.123456+00:00","allow_export":\#(export),"title":"Clip","url":"\#(url)","likes":\#(likes),"liked":\#(liked),"following":\#(following)}"#
}

@main @MainActor struct CommunityFeedTests {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-community-feed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        await test("PostgREST timestamps parse deterministically with any offset and fraction") {
            let micro = CommunityDates.parse("2026-10-12T20:33:11.123456+00:00")
            try require(micro != nil && abs(micro!.timeIntervalSince1970 - 1_791_837_191.123456) < 0.000_001, "microsecond UTC")
            try require(CommunityDates.parse("2026-10-12T20:33:11Z") == Date(timeIntervalSince1970: 1_791_837_191), "Z suffix")
            try require(CommunityDates.parse("2026-10-13T02:03:11+05:30") == Date(timeIntervalSince1970: 1_791_837_191), "+05:30 offset")
            try require(CommunityDates.parse("2026-10-12T12:33:11-08") == Date(timeIntervalSince1970: 1_791_837_191), "-08 offset")
            try require(CommunityDates.parse("2026-10-12 20:33:11+0000") == Date(timeIntervalSince1970: 1_791_837_191), "space separator and +0000")
            for bad in ["2026-13-01T00:00:00Z", "yesterday", "2026-10-12T20:33:11.Z", "2026-10-12T20:33:11+25:00", ""] {
                try require(CommunityDates.parse(bad) == nil, "accepted \(bad)")
            }
            try require(CommunityDates.string(Date(timeIntervalSince1970: 1_791_837_191.5)) == "2026-10-12T20:33:11.500Z", "canonical encoding")
            try require(CommunityDates.parseHTTPDate("Mon, 12 Oct 2026 20:33:11 GMT") == Date(timeIntervalSince1970: 1_791_837_191), "HTTP Date header")
        }

        await test("timeline merges pages by identity, rejects out-of-order pages and negative counts, caps at 40 pages") {
            var timeline = FeedTimeline()
            let decoder = CommunityCoding.decoder()
            let a = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 3).utf8))
            let b = try decoder.decode(FeedPost.self, from: Data(postJSON(postB, creator: creatorB, likes: 1).utf8))
            let aUpdated = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 4).utf8))
            try timeline.merge(page: 0, posts: [a, b], hasMore: true, asOf: "2026-10-13T01:00:00+00:00")
            try require(timeline.asOf == "2026-10-13T01:00:00+00:00", "page 0 snapshot kept")
            do { try timeline.merge(page: 1, posts: [], hasMore: true, asOf: "2026-10-13T02:00:00+00:00"); throw Failure(description: "accepted a page from another snapshot") } catch CommunityError.stale {}
            try timeline.merge(page: 1, posts: [aUpdated], hasMore: true, asOf: "2026-10-13T01:00:00+00:00")
            try require(timeline.posts.count == 2 && timeline.posts[0].likes == 4 && timeline.nextPage == 2, "identity merge kept position and refreshed count")
            do { try timeline.merge(page: 5, posts: [], hasMore: true); throw Failure(description: "accepted out-of-order page") } catch CommunityError.stale {}
            let negative = try decoder.decode(FeedPost.self, from: Data(postJSON(postB, creator: creatorB, likes: -1).utf8))
            do { try timeline.merge(page: 2, posts: [negative], hasMore: true); throw Failure(description: "accepted negative likes") } catch CommunityError.invalidResponse {}
            var capped = FeedTimeline()
            for page in 0..<40 { try capped.merge(page: page, posts: [], hasMore: true) }
            try require(!capped.canLoadMore && capped.nextPage == 40, "40-page cap")
            timeline.reset()
            try require(timeline.asOf == nil && timeline.nextPage == 0, "reset drops the snapshot")
        }

        await test("optimistic like and follow change only the tapped card by one and roll back when unconfirmed") {
            var timeline = FeedTimeline()
            let decoder = CommunityCoding.decoder()
            let a = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 3).utf8))
            let b = try decoder.decode(FeedPost.self, from: Data(postJSON(postB, creator: creatorA, likes: 1).utf8))
            try timeline.merge(page: 0, posts: [a, b], hasMore: false)
            let like = timeline.beginLike(a.id, enabled: true)
            try require(like != nil && timeline.posts[0].liked && timeline.posts[0].likes == 4 && timeline.posts[1].likes == 1, "optimistic like applied to one card")
            try require(timeline.beginLike(a.id, enabled: false) == nil, "second tap while in flight is ignored (retry deduplication)")
            timeline.finish(a.id, confirmed: false, snapshot: like)
            try require(!timeline.posts[0].liked && timeline.posts[0].likes == 3, "rollback restored the server count")
            let again = timeline.beginLike(a.id, enabled: true)
            timeline.finish(a.id, confirmed: true, snapshot: again)
            try require(timeline.posts[0].liked && timeline.posts[0].likes == 4 && timeline.inFlight.isEmpty, "confirmed like retained")
            let follow = timeline.beginFollow(a.creator, enabled: true)
            try require(follow != nil && timeline.posts.allSatisfy(\.following), "follow applied across the creator's cards")
            timeline.finish(a.creator, confirmed: false, snapshot: follow)
            try require(timeline.posts.allSatisfy { !$0.following }, "follow rolled back")
            timeline.removeCreator(a.creator)
            try require(timeline.posts.isEmpty, "blocked creator removed")
        }

        await test("feed client lists real pages, caches only page 0 for the offline label and never serves later pages from cache") {
            let transport = FakeTransport()
            let client = FeedClient(gateway: CommunityGateway(transport: transport), cache: .init(name: "feed", directory: root.appendingPathComponent("feed")))
            transport.replies = [.success(#"{"posts":[\#(postJSON(postA, creator: creatorA, likes: 2))],"has_more":true,"as_of":"2026-10-13T01:00:00.123456+00:00"}"#)]
            let page = try await client.page(.trending, page: 0, account: "acct", asOf: "ignored-on-page-0")
            try require(page.posts.count == 1 && page.hasMore && page.source == .server, "server page")
            try require(page.asOf == "2026-10-13T01:00:00.123456+00:00", "snapshot returned verbatim")
            let call = transport.calls[0]
            try require(call.name == "sdi_feed_action" && call.params["action"] as? String == "list" && call.params["category"] as? String == "trending" && call.params["page"] as? Int == 0, "list parameters")
            try require(call.params["as_of"] == nil, "page 0 never sends a snapshot")
            transport.replies = [.success(#"{"posts":[],"has_more":false,"as_of":"2026-10-13T01:00:00.123456+00:00"}"#)]
            _ = try await client.page(.trending, page: 1, account: "acct", asOf: page.asOf)
            try require(transport.calls.last?.params["as_of"] as? String == "2026-10-13T01:00:00.123456+00:00" && transport.calls.last?.params["page"] as? Int == 1, "later pages carry the page-0 snapshot")
            transport.replies = [.failure(CommunityError.transport("offline"))]
            let cached = try await client.page(.trending, page: 0, account: "acct")
            if case .cache = cached.source {} else { throw Failure(description: "offline page 0 did not come from the protected cache") }
            try require(!cached.hasMore, "cached page never claims more pages")
            transport.replies = [.failure(CommunityError.transport("offline"))]
            do { _ = try await client.page(.trending, page: 1, account: "acct"); throw Failure(description: "page 1 served from cache") } catch CommunityError.transport {}
            transport.replies = [.failure(CommunityError.transport("offline"))]
            do { _ = try await client.page(.recent, page: 0, account: "other"); throw Failure(description: "another account read the cache") } catch CommunityError.transport {}
            transport.replies = [.success(#"{"posts":[],"has_more":false}"#)]
            let empty = try await client.page(.following, page: 0, account: "acct")
            try require(empty.posts.isEmpty && !empty.hasMore, "empty state is a real empty page")
            do { _ = try await client.page(.recent, page: 40, account: "acct"); throw Failure(description: "page 40 requested") } catch CommunityError.invalidResponse {}
        }

        await test("reactions are confirmed only by the server, surface server refusals and never run without a session") {
            let transport = FakeTransport()
            let client = FeedClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"status":"confirmed"}"#)]
            try require(try await client.like(UUID(uuidString: postA)!, enabled: true), "confirmed like")
            try require(transport.calls.last?.params["enabled"] as? Bool == true && transport.calls.last?.params["post_id"] as? String == postA, "like payload")
            transport.replies = [.success(#"{"error":"Post unavailable."}"#)]
            do { _ = try await client.like(UUID(uuidString: postA)!, enabled: true); throw Failure(description: "server error swallowed") }
            catch CommunityError.server(let message, _) { try require(message == "Post unavailable.", "server message surfaced") }
            transport.replies = [.success(#"{"status":"recorded"}"#)]
            try require(try await client.report(UUID(uuidString: postA)!, reason: .rights) == false, "non-confirmed status is not success")
            transport.hasSession = false
            let before = transport.calls.count
            do { _ = try await client.follow(UUID(uuidString: creatorB)!, enabled: true); throw Failure(description: "signed-out call sent") } catch CommunityError.signedOut {}
            try require(transport.calls.count == before, "no request without a session")
        }

        await test("export is offered only with creator permission and refuses oversized downloads") {
            let decoder = CommunityCoding.decoder()
            let denied = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0).utf8))
            let allowed = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true).utf8))
            let insecure = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, url: "http://cdn.example/v.mp4").utf8))
            try require(!FeedExportPolicy.canExport(denied) && FeedExportPolicy.canExport(allowed) && !FeedExportPolicy.canExport(insecure), "export policy")
            let client = FeedClient(gateway: CommunityGateway(transport: FakeTransport()))
            do { _ = try await client.exportFile(for: denied) { _ in throw Failure(description: "download attempted") }; throw Failure(description: "export without permission") } catch CommunityError.server {}
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let big = root.appendingPathComponent("big.mp4"); try Data([1]).write(to: big)
            do { _ = try await client.exportFile(for: allowed) { _ in (big, FeedExportPolicy.maximumDownloadBytes + 1) }; throw Failure(description: "oversized export accepted") } catch CommunityError.invalidResponse {}
            try require(!FileManager.default.fileExists(atPath: big.path), "oversized temporary file removed")
            let ok = root.appendingPathComponent("ok.mp4"); try Data([1]).write(to: ok)
            try require(try await client.exportFile(for: allowed) { _ in (ok, 1) } == ok, "permitted export returns the file")
        }

        await test("handle rules, avatar bounds, records completeness and achievement grouping") {
            try require(CreatorHandle.validate("stick_fan_01") == nil, "valid handle")
            try require(CreatorHandle.validate("ab") != nil && CreatorHandle.validate("_lead") != nil && CreatorHandle.validate("bad name") != nil, "length/start/space rules")
            try require(CreatorHandle.validate("Admin") != nil && CreatorHandle.validate("ünïcode") != nil, "reserved and non-ASCII rejected")
            try require(CreatorHandle.validate(String(repeating: "a", count: 31)) != nil, "maximum length")
            let size = AvatarImagePolicy.targetSize(width: 3000, height: 1500)
            try require(size.width == 512 && size.height == 256, "aspect-preserving downscale")
            try require(AvatarImagePolicy.validate(byteCount: 10_000, width: 512, height: 512) == nil && AvatarImagePolicy.validate(byteCount: 400_000, width: 512, height: 512) != nil, "byte bound")
            let transport = FakeTransport()
            let profile = ProfileClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"show_records":false,"show_badges":false,"revision":1,"wins":0,"losses":0,"ties":0,"badges":[]}"#)]
            let records = try await profile.readRecords()
            try require(records.wins == 0 && records.show_records == false, "own record decoded with defaults off")
            transport.replies = [.success(#"{"show_records":false,"show_badges":false,"revision":null,"wins":null,"losses":null,"ties":null,"badges":null}"#)]
            do { _ = try await profile.readRecords(); throw Failure(description: "incomplete record accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"show_records":false,"show_badges":true,"revision":2,"wins":0,"losses":0,"ties":0,"badges":[]}"#)]
            do { _ = try await profile.saveRecords(revision: 1, showRecords: true, showBadges: true); throw Failure(description: "mismatched save accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"achievements":[{"badge_key":"war_first_win","title":"Crowd Favorite","description":"d","criterion_version":"1","kind":"war_wins","threshold":1,"earned_at":"2026-10-01T00:00:00Z","badge_id":"\#(postA)"},{"badge_key":"war_five_wins","title":"Five","description":"d","criterion_version":"1","kind":"war_wins","threshold":5,"earned_at":null,"badge_id":null},{"badge_key":"challenge_first_win","title":"Challenge Winner","description":"d","criterion_version":"1","kind":"challenge_wins","threshold":1,"earned_at":null,"badge_id":null}]}"#)]
            let groups = try await profile.achievements()
            try require(groups.map(\.category) == ["Challenges", "War Room"], "categories sorted")
            try require(groups[1].earned.map(\.badge_key) == ["war_first_win"] && groups[1].locked.map(\.badge_key) == ["war_five_wins"], "earned/locked split")
            transport.replies = [.success(#"[{"id":"\#(postA)","title":"B","url":"https://cdn.example/b.mp4","duration":3,"expires_at":null,"approved":true},{"id":"\#(postB)","title":"A","url":"http://insecure/a.mp4","duration":3,"expires_at":null,"approved":true}]"#)]
            let portfolio = try await profile.portfolio(account: UUID(uuidString: creatorA)!)
            try require(portfolio.count == 1 && portfolio[0].title == "B", "portfolio keeps only HTTPS approved renditions")
            try require((transport.calls.last?.params["filters"] as? [String])?.first == "owner_id=\(creatorA)", "portfolio filtered to the owner")
        }

        print("COMMUNITY_FEED_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed) passed \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
