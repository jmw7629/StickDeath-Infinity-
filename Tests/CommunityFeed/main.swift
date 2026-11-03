import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

// Every request in these transfer cases is intercepted, including unexpected
// hosts or redirects. No fixture ever falls through to a public media host.
private final class ExportFixtureProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case body(status: Int, headers: [String: String], chunks: [Data], finishes: Bool)
        case redirect(URL)
    }
    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var requests: [URLRequest] = []
    private static var stops = 0
    private let stateLock = NSLock()
    private var stopped = false
    private var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopped }
    static func install(_ replies: [String: Reply]) {
        lock.lock(); defer { lock.unlock() }
        Self.replies = replies; requests = []; stops = 0
    }
    static func snapshot() -> (requests: [URLRequest], stops: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, stops)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.replies[request.url?.path ?? ""]
        Self.lock.unlock()
        guard let url = request.url, let reply else { client?.urlProtocol(self, didFailWithError: Failure(description: "Unscripted media request")); return }
        switch reply {
        case .body(let status, let headers, let chunks, let finishes):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                guard !isStopped else { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            if finishes && !isStopped { client?.urlProtocolDidFinishLoading(self) }
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var next = URLRequest(url: target)
            next.setValue("synthetic-fixture-credential", forHTTPHeaderField: "Authorization")
            next.setValue("synthetic-fixture-cookie", forHTTPHeaderField: "Cookie")
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        }
    }
    override func stopLoading() {
        stateLock.lock(); stopped = true; stateLock.unlock()
        Self.lock.lock(); Self.stops += 1; Self.lock.unlock()
    }
}
private final class ExportProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FeedExportDownload.Progress] = []
    func record(_ value: FeedExportDownload.Progress) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [FeedExportDownload.Progress] { lock.lock(); defer { lock.unlock() }; return values }
}
private func waitForExportBytes(_ probe: ExportProgressProbe, atLeast count: Int64) async throws {
    for _ in 0..<200 {
        if probe.snapshot().last?.receivedBytes ?? 0 >= count { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw Failure(description: "The local media fixture did not report progress")
}
private func waitForExportPartial(_ directory: URL, byteCount: Int64) async throws -> URL {
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: directory.path) {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let partials = files.filter { $0.pathExtension == "part" }
            try require(files.count == partials.count && partials.count <= 1, "An unfinished export must own only one partial file")
            if let partial = partials.first {
                let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
                guard let size = (attributes[.size] as? NSNumber)?.int64Value else { throw Failure(description: "The partial export file has no byte length") }
                try require(size <= byteCount, "The held export wrote bytes beyond its delivered prefix")
                if size == byteCount { return partial }
            }
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw Failure(description: "The local media fixture did not write its partial prefix")
}
private func waitForExportStop() async throws {
    for _ in 0..<200 {
        if ExportFixtureProtocol.snapshot().stops > 0 { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw Failure(description: "The cancelled local media request did not stop")
}
private func noExportFiles(_ directory: URL) throws -> Bool {
    if !FileManager.default.fileExists(atPath: directory.path) { return true }
    return try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
}

private let postA = "11111111-1111-4111-8111-111111111111"
private let postB = "22222222-2222-4222-8222-222222222222"
private let creatorA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let creatorB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private func postJSON(_ id: String, creator: String, likes: Int, liked: Bool = false, following: Bool = false, export: Bool = false, download: Bool? = nil, url: String = "https://cdn.example/v.mp4") -> String {
    let downloadField = download.map { #","can_download":\#($0)"# } ?? ""
    return #"{"id":"\#(id)","creator":"\#(creator)","creator_name":"Creator","caption":"","published_at":"2026-10-12T20:33:11.123456+00:00","allow_export":\#(export),"title":"Clip","url":"\#(url)","likes":\#(likes),"liked":\#(liked),"following":\#(following)\#(downloadField)}"#
}
private let cursorA = "0|2026-10-12T20:33:11.123456Z|11111111-1111-4111-8111-111111111111"

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
            transport.replies = [.success(#"{"posts":[\#(postJSON(postA, creator: creatorA, likes: 2))],"has_more":true,"next_cursor":"\#(cursorA)","as_of":"2026-10-13T01:00:00.123456+00:00","download_requires_plan":true}"#)]
            let page = try await client.page(.trending, page: 0, account: "acct", asOf: "ignored-on-page-0", cursor: "ignored-on-page-0")
            try require(page.posts.count == 1 && page.hasMore && page.source == .server && page.downloadRequiresPlan, "server page")
            try require(page.asOf == "2026-10-13T01:00:00.123456+00:00" && page.cursor == cursorA, "snapshot and cursor returned verbatim")
            let call = transport.calls[0]
            try require(call.name == "sdi_feed_page" && call.params["category"] as? String == "trending" && call.params["action"] == nil, "keyset list parameters")
            try require(call.params["as_of"] == nil && call.params["page_cursor"] == nil, "page 0 never sends a snapshot or cursor")
            transport.replies = [.success(#"{"posts":[],"has_more":false,"next_cursor":null,"as_of":"2026-10-13T01:00:00.123456+00:00"}"#)]
            _ = try await client.page(.trending, page: 1, account: "acct", asOf: page.asOf, cursor: page.cursor)
            try require(transport.calls.last?.params["as_of"] as? String == "2026-10-13T01:00:00.123456+00:00" && transport.calls.last?.params["page_cursor"] as? String == cursorA, "later pages carry the cursor and page-0 snapshot")
            let sent = transport.calls.count
            do { _ = try await client.page(.trending, page: 1, account: "acct", asOf: page.asOf, cursor: nil); throw Failure(description: "later page without cursor sent") } catch CommunityError.stale {}
            try require(transport.calls.count == sent, "no request without a cursor")
            transport.replies = [.success(#"{"posts":[],"has_more":true,"as_of":"2026-10-13T01:00:00.123456+00:00"}"#)]
            do { _ = try await client.page(.recent, page: 0, account: "acct"); throw Failure(description: "has_more without cursor accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.failure(CommunityError.transport("offline"))]
            let cached = try await client.page(.trending, page: 0, account: "acct")
            if case .cache = cached.source {} else { throw Failure(description: "offline page 0 did not come from the protected cache") }
            try require(!cached.hasMore, "cached page never claims more pages")
            transport.replies = [.failure(CommunityError.transport("offline"))]
            do { _ = try await client.page(.trending, page: 1, account: "acct", asOf: page.asOf, cursor: cursorA); throw Failure(description: "page 1 served from cache") } catch CommunityError.transport {}
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
            let allowed = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, download: true).utf8))
            let freePlan = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, download: false).utf8))
            let legacy = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true).utf8))
            let insecure = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, download: true, url: "http://cdn.example/v.mp4").utf8))
            try require(!FeedExportPolicy.canExport(denied) && FeedExportPolicy.canExport(allowed) && !FeedExportPolicy.canExport(insecure), "export policy")
            try require(FeedExportPolicy.state(freePlan) == .needsPaidPlan && FeedExportPolicy.state(legacy) == .needsPaidPlan, "free plan or missing server decision never downloads")
            try require(FeedExportPolicy.state(denied) == .notPermitted && FeedExportPolicy.state(insecure) == .notPermitted, "creator permission checked first")
            let client = FeedClient(gateway: CommunityGateway(transport: FakeTransport()))
            do { _ = try await client.exportFile(for: denied) { _ in throw Failure(description: "download attempted") }; throw Failure(description: "export without permission") } catch CommunityError.server {}
            do { _ = try await client.exportFile(for: freePlan) { _ in throw Failure(description: "download attempted") }; throw Failure(description: "export without a paid plan") }
            catch CommunityError.server(let message, _) { try require(message.contains("paid plan"), "plan message") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let big = root.appendingPathComponent("big.mp4"); try Data([1]).write(to: big)
            do { _ = try await client.exportFile(for: allowed) { _ in (big, FeedExportPolicy.maximumDownloadBytes + 1) }; throw Failure(description: "oversized export accepted") } catch CommunityError.invalidResponse {}
            try require(!FileManager.default.fileExists(atPath: big.path), "oversized temporary file removed")
            let ok = root.appendingPathComponent("ok.mp4"); try Data([1]).write(to: ok)
            try require(try await client.exportFile(for: allowed) { _ in (ok, 1) } == ok, "permitted export returns the file")
        }

        await test("bounded export streams exact and unknown-length bodies without account headers") {
            let directory = root.appendingPathComponent("bounded-success")
            let probe = ExportProgressProbe()
            ExportFixtureProtocol.install(["/exact": .body(status: 200, headers: ["Content-Length": "8"], chunks: [Data([1, 2, 3]), Data([4, 5, 6, 7, 8])], finishes: true)])
            let (file, count) = try await FeedExportDownload.fetch(URL(string: "https://cdn.example/exact")!, directory: directory,
                maximumBytes: 8, protocolClasses: [ExportFixtureProtocol.self], progress: { probe.record($0) })
            try require(count == 8 && (try Data(contentsOf: file)) == Data([1, 2, 3, 4, 5, 6, 7, 8]), "the completed file contains the exact transferred bytes")
            let requests = ExportFixtureProtocol.snapshot().requests
            try require(requests.count == 1 && requests[0].value(forHTTPHeaderField: "Authorization") == nil &&
                requests[0].value(forHTTPHeaderField: "Cookie") == nil && !requests[0].httpShouldHandleCookies, "media requests carry no account credentials or cookies")
            try require(probe.snapshot().last?.receivedBytes == 8 && probe.snapshot().last?.expectedBytes == 8, "actual download progress reaches the declared length")
            try FileManager.default.removeItem(at: file)
            ExportFixtureProtocol.install(["/chunked": .body(status: 200, headers: [:], chunks: [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])], finishes: true)])
            let (chunked, actual) = try await FeedExportDownload.fetch(URL(string: "https://cdn.example/chunked")!, directory: directory,
                maximumBytes: 8, protocolClasses: [ExportFixtureProtocol.self])
            try require(actual == 8 && (try Data(contentsOf: chunked)).count == 8, "unknown-length bodies may finish at the exact cap")
            try FileManager.default.removeItem(at: chunked)
            try require(try noExportFiles(directory), "success leaves no partial files")
        }

        await test("bounded export rejects declared, chunked and dishonest oversized bodies and incomplete files") {
            let directory = root.appendingPathComponent("bounded-refused")
            let cases: [(String, [String: String], [Data])] = [
                ("declared", ["Content-Length": "9"], [Data(repeating: 1, count: 9)]),
                ("chunked", [:], [Data(repeating: 1, count: 4), Data(repeating: 2, count: 4), Data([3])]),
                ("dishonest", ["Content-Length": "4"], [Data(repeating: 1, count: 4), Data(repeating: 2, count: 5)]),
                ("truncated", ["Content-Length": "8"], [Data(repeating: 1, count: 4)]),
                ("empty", ["Content-Length": "0"], [])
            ]
            for (path, headers, chunks) in cases {
                let probe = ExportProgressProbe()
                ExportFixtureProtocol.install(["/" + path: .body(status: 200, headers: headers, chunks: chunks, finishes: true)])
                do {
                    _ = try await FeedExportDownload.fetch(URL(string: "https://cdn.example/" + path)!, directory: directory,
                        maximumBytes: 8, protocolClasses: [ExportFixtureProtocol.self], progress: { probe.record($0) })
                    throw Failure(description: "Accepted " + path)
                } catch CommunityError.invalidResponse {}
                try require(try noExportFiles(directory), path + " left a partial or completed file")
                try require(probe.snapshot().allSatisfy { $0.receivedBytes <= 8 }, path + " wrote beyond the byte ceiling")
            }
        }

        await test("bounded export rejects HTTP errors, partial responses and an unhandled redirect") {
            let directory = root.appendingPathComponent("bounded-status")
            for status in [206, 302, 403, 500] {
                ExportFixtureProtocol.install(["/status": .body(status: status, headers: ["Location": "http://unavailable.example/video"], chunks: [Data([1])], finishes: true)])
                do {
                    _ = try await FeedExportDownload.fetch(URL(string: "https://cdn.example/status")!, directory: directory,
                        maximumBytes: 8, protocolClasses: [ExportFixtureProtocol.self])
                    throw Failure(description: "Accepted status \(status)")
                } catch CommunityError.invalidResponse {}
                try require(try noExportFiles(directory), "a refused HTTP response left a file")
                try require(ExportFixtureProtocol.snapshot().requests.count == 1, "a refused response opened another media request")
            }
            for raw in ["http://cdn.example/video", "https://user:password@cdn.example/video"] {
                ExportFixtureProtocol.install([:])
                do {
                    _ = try await FeedExportDownload.fetch(URL(string: raw)!, directory: directory,
                        maximumBytes: 8, protocolClasses: [ExportFixtureProtocol.self])
                    throw Failure(description: "Accepted unsafe initial URL")
                } catch CommunityError.invalidResponse {}
                try require(ExportFixtureProtocol.snapshot().requests.isEmpty, "unsafe URLs must be refused before opening a connection")
            }
        }

        #if !canImport(FoundationNetworking)
        // corelibs URLProtocol explicitly does not implement wasRedirectedTo.
        // These real delegate redirect cases run on Darwin alongside native QA.
        await test("bounded export follows only sanitized HTTPS redirects") {
            let directory = root.appendingPathComponent("bounded-redirect")
            let secure = URL(string: "https://second.example/target")!
            ExportFixtureProtocol.install(["/start": .redirect(secure), "/target": .body(status: 200, headers: ["Content-Length": "1"], chunks: [Data([7])], finishes: true)])
            let (file, _) = try await FeedExportDownload.fetch(URL(string: "https://cdn.example/start")!, directory: directory,
                maximumBytes: 8, protocolClasses: [ExportFixtureProtocol.self])
            let requests = ExportFixtureProtocol.snapshot().requests
            try require(requests.count == 2 && requests[1].url == secure && requests[1].value(forHTTPHeaderField: "Authorization") == nil &&
                requests[1].value(forHTTPHeaderField: "Cookie") == nil, "a cross-host HTTPS redirect must use a fresh credential-free request")
            try FileManager.default.removeItem(at: file)
            for target in [URL(string: "http://second.example/target")!, URL(string: "https://user:password@second.example/target")!] {
                ExportFixtureProtocol.install(["/start": .redirect(target)])
                do {
                    _ = try await FeedExportDownload.fetch(URL(string: "https://cdn.example/start")!, directory: directory,
                        maximumBytes: 8, protocolClasses: [ExportFixtureProtocol.self])
                    throw Failure(description: "Accepted an unsafe redirect")
                } catch CommunityError.invalidResponse {}
                try require(ExportFixtureProtocol.snapshot().requests.count == 1 && (try noExportFiles(directory)), "unsafe redirects cannot open their target or leave a file")
            }
            ExportFixtureProtocol.install(["/loop": .redirect(URL(string: "https://cdn.example/loop")!)])
            do {
                _ = try await FeedExportDownload.fetch(URL(string: "https://cdn.example/loop")!, directory: directory,
                    maximumBytes: 8, protocolClasses: [ExportFixtureProtocol.self])
                throw Failure(description: "An endless redirect was accepted")
            } catch CommunityError.invalidResponse {}
            try require(ExportFixtureProtocol.snapshot().requests.count <= 6 && (try noExportFiles(directory)), "redirect loops must stop within the transfer's request budget")
        }
        #endif

        await test("bounded export cancels an active transfer and enforces a complete-transfer deadline") {
            let directory = root.appendingPathComponent("bounded-cancel")
            let probe = ExportProgressProbe()
            let declaredBytes = 128 * 1024
            let prefix = Data(repeating: 7, count: 64 * 1024)
            ExportFixtureProtocol.install(["/held": .body(status: 200,
                headers: ["Content-Type": "video/mp4", "Content-Length": String(declaredBytes)], chunks: [prefix], finishes: false)])
            let task = Task {
                try await FeedExportDownload.fetch(URL(string: "https://cdn.example/held")!, directory: directory,
                    maximumBytes: Int64(declaredBytes), protocolClasses: [ExportFixtureProtocol.self], progress: { probe.record($0) })
            }
            defer { task.cancel() }
            try await waitForExportBytes(probe, atLeast: 4)
            let partial = try await waitForExportPartial(directory, byteCount: Int64(prefix.count))
            try require(probe.snapshot().last?.expectedBytes == Int64(declaredBytes), "The held transfer must report its declared complete length")
            try require(try Data(contentsOf: partial) == prefix, "Cancellation must interrupt an actually written, incomplete body prefix")
            task.cancel()
            do { _ = try await task.value; throw Failure(description: "Cancelled export returned a file") } catch is CancellationError {}
            try require(try noExportFiles(directory), "cancellation must remove a partially written file before returning")
            try await waitForExportStop()
            let timeoutProbe = ExportProgressProbe()
            ExportFixtureProtocol.install(["/held": .body(status: 200, headers: [:], chunks: [Data([1])], finishes: false)])
            do {
                _ = try await FeedExportDownload.fetch(URL(string: "https://cdn.example/held")!, directory: directory,
                    maximumBytes: 8, timeout: 0.15, protocolClasses: [ExportFixtureProtocol.self], progress: { timeoutProbe.record($0) })
                throw Failure(description: "A stalled export outlived its deadline")
            } catch CommunityError.transport {}
            try require(try noExportFiles(directory), "timeout must remove its partial file")
            try await waitForExportStop()
        }

        await test("export context guards reject queued and completed work after scope changes") {
            let client = FeedClient(gateway: CommunityGateway(transport: FakeTransport()))
            let post = try CommunityCoding.decoder().decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, download: true).utf8))
            var generation = UUID()
            let captured = generation
            generation = UUID()
            do {
                _ = try await client.exportFile(for: post, isCurrent: { generation == captured }) { _ in throw Failure(description: "Stale queued export started") }
                throw Failure(description: "Stale queued export was accepted")
            } catch is CancellationError {}
            let file = root.appendingPathComponent("stale-completion.mp4")
            try Data([1]).write(to: file)
            let current = generation
            do {
                _ = try await client.exportFile(for: post, isCurrent: { generation == current }) { _ in generation = UUID(); return (file, 1) }
                throw Failure(description: "Stale completion was accepted")
            } catch is CancellationError {}
            try require(!FileManager.default.fileExists(atPath: file.path), "a completed export from an old account generation must be removed")
            let cancelled = root.appendingPathComponent("cancelled-completion.mp4")
            try Data([1]).write(to: cancelled)
            let task = Task {
                try await client.exportFile(for: post) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return (cancelled, 1)
                }
            }
            do { _ = try await task.value; throw Failure(description: "Cancelled completion was accepted") } catch is CancellationError {}
            try require(!FileManager.default.fileExists(atPath: cancelled.path), "post-await cancellation must remove a returned temporary file")
        }

        await test("export listing authorization rejects stale viewer cards and replaced same-ID decisions before download") {
            let client = FeedClient(gateway: CommunityGateway(transport: FakeTransport()))
            let decoder = CommunityCoding.decoder()
            let allowedA = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, download: true).utf8))
            let deniedB = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, download: false).utf8))
            let replacedDenied = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, download: false, url: "https://cdn.example/replaced.mp4").utf8))
            let replacedAllowed = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, download: true, url: "https://cdn.example/new-approved.mp4").utf8))
            let requestA = FeedExportListing.Context(account: creatorA, generation: UUID())
            var current: FeedExportListing.Context? = requestA
            var visible = [allowedA]
            var listing = FeedExportListing.commit(rows: visible, captured: requestA, current: current)
            let oldATap = listing!.capture(for: allowedA)!
            var downloads = 0
            var downloadedURL: URL?
            @MainActor func attempt(_ rendered: FeedPost, tap: FeedExportListing.Tap?) async throws -> Bool {
                guard let tap, let permission = listing?.authorize(tap, rendered: rendered, current: current, visibleRows: visible) else { return false }
                let file = try await client.exportFile(for: permission, isCurrent: {
                    listing?.contains(permission, current: current, visibleRows: visible) == true
                }) { url in
                    downloads += 1; downloadedURL = url
                    let file = root.appendingPathComponent("bound-listing-export-" + UUID().uuidString + ".mp4")
                    try Data([1]).write(to: file)
                    return (file, 1)
                }
                try FileManager.default.removeItem(at: file)
                return true
            }

            // Publish B synchronously and revoke the binding, deliberately
            // retaining A's visible card while the identity reset is held.
            let requestB = FeedExportListing.Context(account: creatorB, generation: UUID())
            current = requestB; listing = nil
            try require(try await attempt(allowedA, tap: oldATap) == false && downloads == 0, "B must never download using A's retained card before task reset")
            try require(FeedExportListing.commit(rows: [allowedA], captured: requestA, current: current) == nil, "an in-flight A page cannot authorize B")
            visible = [deniedB]
            listing = FeedExportListing.commit(rows: visible, captured: requestB, current: current)
            try require(try await attempt(allowedA, tap: oldATap) == false && downloads == 0, "B's fresh no-plan decision cannot be replaced by A's old argument")

            // A returns before any reset/fetch completes. Equal account IDs do
            // not revive either the old card or A's old in-flight page result.
            let returnedA = FeedExportListing.Context(account: creatorA, generation: UUID())
            current = returnedA; listing = nil
            try require(try await attempt(allowedA, tap: oldATap) == false && downloads == 0, "A → B → A requires a fresh committed listing")
            try require(FeedExportListing.commit(rows: [allowedA], captured: requestA, current: current) == nil, "the first A generation cannot commit into the returned A session")
            visible = [allowedA]
            listing = FeedExportListing.commit(rows: visible, captured: returnedA, current: current)
            try require(try await attempt(allowedA, tap: oldATap) == false && downloads == 0, "fresh A rows do not revive an obsolete card revision")
            let currentATap = listing!.capture(for: allowedA)!

            visible = [replacedDenied]
            listing = FeedExportListing.commit(rows: visible, captured: returnedA, current: current)
            try require(try await attempt(allowedA, tap: currentATap) == false && downloads == 0, "same-ID permission and URL replacement must revoke an old allowed card")
            try require(try await attempt(replacedDenied, tap: listing!.capture(for: replacedDenied)) == false && downloads == 0, "fresh no-plan rows remain denied by the existing policy")
            // A reaction rollback can restore an old visible row. Paging must
            // preserve the committed denied decision instead of trusting it.
            visible = [allowedA]
            listing = FeedExportListing.commit(rows: [], previous: listing, captured: returnedA, current: current)
            try require(listing!.capture(for: allowedA) == nil && downloads == 0, "later pages cannot reauthorize a stale optimistic timeline snapshot")

            visible = [replacedAllowed]
            listing = FeedExportListing.commit(rows: visible, captured: returnedA, current: current)
            let replacementTap = listing!.capture(for: replacedAllowed)!
            try require(try await attempt(allowedA, tap: replacementTap) == false && downloads == 0, "an obsolete row argument cannot borrow the current row's token")
            // Replacing a committed snapshot also revokes old tokens when all
            // fields happen to compare equal; row identity alone is insufficient.
            listing = FeedExportListing.commit(rows: visible, captured: returnedA, current: current)
            try require(try await attempt(replacedAllowed, tap: replacementTap) == false && downloads == 0, "an obsolete listing revision cannot start a transfer")
            let freshTap = listing!.capture(for: replacedAllowed)!
            try require(try await attempt(replacedAllowed, tap: freshTap) && downloads == 1 && downloadedURL == replacedAllowed.safeURL, "a fresh correctly bound listing exports only its current approved URL")
        }

        await test("listing replacement revokes completed pending shares while retaining an offered consumer input") {
            let client = FeedClient(gateway: CommunityGateway(transport: FakeTransport()))
            let decoder = CommunityCoding.decoder()
            let allowed = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, download: true).utf8))
            let denied = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0, export: true, download: false).utf8))
            let context = FeedExportListing.Context(account: creatorA, generation: UUID())
            let original = FeedExportListing.commit(rows: [allowed], captured: context, current: context)!
            let tap = original.capture(for: allowed)!
            let permission = original.authorize(tap, rendered: allowed, current: context, visibleRows: [allowed])!
            var downloads = 0
            var current = original
            var visible = [allowed]
            @MainActor func completedFile(_ name: String, permission: FeedExportListing.Authorization) async throws -> FeedExportFile {
                let url = try await client.exportFile(for: permission, isCurrent: {
                    current.contains(permission, current: context, visibleRows: visible)
                }) { _ in
                    downloads += 1
                    let file = root.appendingPathComponent(name + ".mp4")
                    try Data([1, 2, 3]).write(to: file)
                    return (file, 3)
                }
                return FeedExportFile(url: url, title: "Clip", account: context.account, generation: context.generation)
            }
            let pending = try await completedFile("pending-before-policy-replacement", permission: permission)
            defer { pending.ownerClosed() }
            current = FeedExportListing.commit(rows: [denied], captured: context, current: context)!
            visible = [denied]
            try require(!current.contains(permission, current: context, visibleRows: visible), "same-account replacement must revoke the completed file's listing authorization")
            try require(pending.revokePendingShare(), "a completed unoffered file must be revoked when the listing is replaced")
            try require(!FileManager.default.fileExists(atPath: pending.url.path) && !pending.offerToShare(), "a queued share host must refuse the revoked file and its output must be removed")

            current = FeedExportListing.commit(rows: [allowed], captured: context, current: context)!
            visible = [allowed]
            let secondTap = current.capture(for: allowed)!
            let secondPermission = current.authorize(secondTap, rendered: allowed, current: context, visibleRows: visible)!
            let offered = try await completedFile("offered-before-policy-replacement", permission: secondPermission)
            defer { offered.consumerFinished(); offered.ownerClosed() }
            try require(offered.offerToShare(), "the original permitted file must be reserved before UIKit receives its URL")
            current = FeedExportListing.commit(rows: [denied], captured: context, current: context)!
            visible = [denied]
            try require(!current.contains(secondPermission, current: context, visibleRows: visible), "the offered file's former permission is also replaced")
            try require(!offered.revokePendingShare(), "listing replacement cannot revoke an input already offered to a consumer")
            offered.ownerClosed()
            try require(FileManager.default.fileExists(atPath: offered.url.path) && FeedExportFile.hasOutstandingConsumer, "the existing consumer retains its file after listing replacement and owner teardown")
            offered.consumerFinished()
            try require(!FileManager.default.fileExists(atPath: offered.url.path) && !FeedExportFile.hasOutstandingConsumer && downloads == 2, "only the consumer callback releases its input; both files came from completed exports")
        }

        await test("file sharing retains the consumer file across owner dismissal with one outstanding lease") {
            let url = root.appendingPathComponent("share-lifetime.mp4")
            try Data([1, 2]).write(to: url)
            var owner: FeedExportFile? = FeedExportFile(url: url, title: "Clip")
            weak var lease = owner
            try require(owner!.offerToShare(), "the first consumer must reserve its file")
            owner!.ownerClosed(); owner = nil
            try require(lease != nil && FileManager.default.fileExists(atPath: url.path), "clearing the view owner cannot remove a file offered to UIKit")
            let secondURL = root.appendingPathComponent("share-second.mp4")
            try Data([3]).write(to: secondURL)
            let second = FeedExportFile(url: secondURL, title: "Second")
            try require(!second.offerToShare(), "unfinished consumer leases must remain bounded to one")
            second.ownerClosed()
            try require(!FileManager.default.fileExists(atPath: secondURL.path), "an unoffered file must clean up when its owner closes")
            lease!.consumerFinished()
            try require(!FileManager.default.fileExists(atPath: url.path) && !FeedExportFile.hasOutstandingConsumer, "the actual consumer callback releases the file and slot")
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

        await test("timeline keeps the keyset cursor, refuses unusable cursors and clears it on reset") {
            var timeline = FeedTimeline()
            let decoder = CommunityCoding.decoder()
            let a = try decoder.decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0).utf8))
            try timeline.merge(page: 0, posts: [a], hasMore: true, asOf: "s", cursor: cursorA)
            try require(timeline.nextCursor == cursorA && timeline.canLoadMore, "cursor stored")
            do { try timeline.merge(page: 1, posts: [], hasMore: true, asOf: "s", cursor: ""); throw Failure(description: "empty cursor accepted") } catch CommunityError.invalidResponse {}
            do { try timeline.merge(page: 1, posts: [], hasMore: true, asOf: "s", cursor: String(repeating: "x", count: 121)); throw Failure(description: "oversized cursor accepted") } catch CommunityError.invalidResponse {}
            try timeline.merge(page: 1, posts: [a], hasMore: false, asOf: "s", cursor: nil)
            try require(timeline.posts.count == 1 && timeline.nextCursor == nil && !timeline.canLoadMore, "repeat row de-duplicated; last page ends paging")
            timeline.reset()
            try require(timeline.nextCursor == nil && timeline.asOf == nil, "reset clears cursor")
        }

        await test("poster thumbnails decode from the page and fall back to a placeholder when absent or unsafe") {
            let transport = FakeTransport()
            let client = FeedClient(gateway: CommunityGateway(transport: transport), cache: .init(name: "feed-poster", directory: root.appendingPathComponent("feed-poster")))
            let withPoster = postJSON(postA, creator: creatorA, likes: 0).dropLast() + #","poster_url":"https://cdn.example/feed/a.poster.jpg"}"#
            let nullPoster = postJSON(postB, creator: creatorB, likes: 0).dropLast() + #","poster_url":null}"#
            transport.replies = [.success(#"{"posts":[\#(withPoster),\#(nullPoster)],"has_more":true,"next_cursor":"\#(cursorA)","as_of":"2026-10-13T01:00:00.123456+00:00","download_requires_plan":true}"#)]
            let page = try await client.page(.recent, page: 0, account: creatorA)
            try require(page.posts[0].poster == .image(URL(string: "https://cdn.example/feed/a.poster.jpg")!), "recorded poster shown")
            try require(page.posts[1].poster == .placeholder, "null poster shows the placeholder")
            try require(page.cursor == cursorA, "keyset cursor carried with posters")
            try require(FeedPoster.resolve("http://cdn.example/a.jpg") == .placeholder, "insecure poster refused")
            try require(FeedPoster.resolve("https://user:pw@cdn.example/a.jpg") == .placeholder, "credentialed poster refused")
            try require(FeedPoster.resolve("https://cdn.example/" + String(repeating: "a", count: 2048)) == .placeholder, "oversized poster URL refused")
            let legacy = try CommunityCoding.decoder().decode(FeedPost.self, from: Data(postJSON(postA, creator: creatorA, likes: 0).utf8))
            try require(legacy.poster == .placeholder, "older listing without the field shows the placeholder")
        }

        await test("later pages send only the opaque cursor and snapshot, never a page offset") {
            let transport = FakeTransport()
            let client = FeedClient(gateway: CommunityGateway(transport: transport), cache: .init(name: "feed-keyset", directory: root.appendingPathComponent("feed-keyset")))
            transport.replies = [.success(#"{"posts":[\#(postJSON(postB, creator: creatorB, likes: 0))],"has_more":false,"next_cursor":null,"as_of":"s0","download_requires_plan":true}"#)]
            _ = try await client.page(.trending, page: 1, account: creatorA, asOf: "s0", cursor: cursorA)
            let params = transport.calls.last?.params ?? [:]
            try require(transport.calls.last?.name == "sdi_feed_page", "keyset RPC")
            try require(params["page_cursor"] as? String == cursorA && params["as_of"] as? String == "s0" && params["category"] as? String == "trending", "cursor and snapshot sent")
            try require(params["page"] == nil && params["offset"] == nil, "no offset paging parameter")
            do { _ = try await client.page(.recent, page: 2, account: creatorA, asOf: "s0", cursor: nil); throw Failure(description: "page without cursor sent") } catch CommunityError.stale {}
        }

        await test("creator totals come only from a complete server reply") {
            let transport = FakeTransport()
            let profile = ProfileClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"subject":"\#(creatorA)","published_videos":3,"likes_received":7,"followers":2,"following":4}"#)]
            let own = try await profile.stats()
            try require(own.published_videos == 3 && own.likes_received == 7 && own.followers == 2 && own.following == 4, "own totals")
            try require(transport.calls.last?.name == "sdi_creator_stats" && transport.calls.last?.params["subject"] == nil, "own totals send no subject")
            transport.replies = [.success(#"{"subject":"\#(creatorB)","published_videos":1,"likes_received":0,"followers":0,"following":null}"#)]
            let other = try await profile.stats(of: UUID(uuidString: creatorB)!)
            try require(other.following == nil && (transport.calls.last?.params["subject"] as? String)?.lowercased() == creatorB, "other creator: following hidden")
            transport.replies = [.success(#"{"subject":"\#(creatorA)","published_videos":1,"likes_received":0,"followers":0,"following":null}"#)]
            do { _ = try await profile.stats(of: UUID(uuidString: creatorB)!); throw Failure(description: "totals for another account accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"subject":"\#(creatorA)","published_videos":null,"likes_received":0,"followers":0,"following":0}"#)]
            do { _ = try await profile.stats(); throw Failure(description: "incomplete totals accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"subject":"\#(creatorA)","published_videos":1,"likes_received":-1,"followers":0,"following":0}"#)]
            do { _ = try await profile.stats(); throw Failure(description: "negative totals accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"error":"Profile unavailable."}"#)]
            do { _ = try await profile.stats(of: UUID(uuidString: creatorB)!); throw Failure(description: "blocked profile shown") } catch CommunityError.server {}
        }

        await test("playback state is derived from the player and never claims playing before it is ready") {
            typealias S = FeedPlaybackState
            try require(S.resolve(itemReady: false, itemFailed: false, waiting: true, playing: false, ended: false, elapsed: 1, failureText: nil) == .loading, "loading")
            try require(S.resolve(itemReady: false, itemFailed: false, waiting: true, playing: false, ended: false, elapsed: FeedPlaybackPolicy.slowStartSeconds, failureText: nil) == .slow, "slow start")
            try require(S.resolve(itemReady: true, itemFailed: false, waiting: true, playing: false, ended: false, elapsed: 1, failureText: nil) == .buffering, "buffering")
            try require(S.resolve(itemReady: true, itemFailed: false, waiting: false, playing: true, ended: false, elapsed: 1, failureText: nil) == .playing, "playing")
            try require(S.resolve(itemReady: true, itemFailed: false, waiting: false, playing: false, ended: true, elapsed: 1, failureText: nil) == .ended, "ended")
            if case .failed(let text) = S.resolve(itemReady: true, itemFailed: true, waiting: false, playing: true, ended: false, elapsed: 1, failureText: nil) {
                try require(text.contains("could not be played"), "failure wins over playing")
            } else { throw Failure(description: "failure not reported") }
            try require(S.playing.message == nil && S.loading.message != nil, "overlay only while not playing")
            try require(FeedPlaybackPolicy.expensiveNetworkPeakBitRate > 0 && FeedPlaybackPolicy.forwardBufferSeconds <= 30, "bandwidth bounds set")
        }

        print("COMMUNITY_FEED_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed) passed \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
