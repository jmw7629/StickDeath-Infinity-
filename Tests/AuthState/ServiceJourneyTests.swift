import XCTest
import Supabase
@testable import StickDeathInfinity

/// Native service journeys for #265 (feed, collaboration, War Room, owner
/// approval history and onboarding policy acceptance, #273). Each case drives
/// the production client, CommunityGateway and SupabaseCommunityTransport over
/// a real pinned-SDK SupabaseClient with a signed-in session. The SDK's
/// URLSession is a local URLProtocol fixture (the same isolation the auth
/// stage uses): no external host, no live data, no charges, no uploads.
///
/// This is isolated-data evidence for the client/transport/session path. It is
/// not acceptance against a deployed backend, and it does not prove server SQL.
@MainActor final class ServiceJourneyTests: XCTestCase {
    private static let viewer = "abcdefab-cdef-4abc-8def-abcdefabcdef"
    private static let room = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let match = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let post = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let review = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private static let creator = "55555555-5555-4555-8555-555555555555"

    override func setUp() { super.setUp(); JourneyFixtureTransport.reset() }
    override func tearDown() { JourneyFixtureTransport.reset(); super.tearDown() }

    func testFeedJourneyListsServerPageAndConfirmsLikeWithSessionToken() async throws {
        let (gateway, transport) = try await signedInGateway()
        defer { transport.invalidateAndCancel() }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-journey-feed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        JourneyFixtureTransport.enqueue("sdi_feed_page", #"{"posts":[{"id":"\#(Self.post.uuidString)","creator":"\#(Self.creator)","creator_name":"Creator","caption":"","published_at":"2026-10-12T20:33:11.123456+00:00","allow_export":false,"title":"Approved clip","url":"https://cdn.example/v.mp4","likes":2,"liked":false,"following":false}],"has_more":false,"next_cursor":null,"as_of":"2026-10-13T01:00:00.123456+00:00","download_requires_plan":true}"#)
        JourneyFixtureTransport.enqueue("sdi_feed_action", #"{"status":"confirmed"}"#)
        let client = FeedClient(gateway: gateway, cache: .init(name: "feed", directory: cache))
        let page = try await client.page(.trending, page: 0, account: Self.viewer)
        XCTAssertEqual(page.posts.map(\.title), ["Approved clip"])
        XCTAssertEqual(page.source, .server)
        let liked = try await client.like(Self.post, enabled: true)
        XCTAssertTrue(liked, "The server's confirmation is the only success")
        let calls = JourneyFixtureTransport.rpcCalls
        XCTAssertEqual(calls.map(\.name), ["sdi_feed_page", "sdi_feed_action"])
        XCTAssertEqual(calls.last?.body["action"] as? String, "like")
        XCTAssertTrue(calls.allSatisfy { $0.authorization == "Bearer fixture-access" }, "Requests must carry the SDK session token")
    }

    func testRoomsJourneyPreviewsRequestsAdmissionAndListsAcceptedRooms() async throws {
        let (gateway, transport) = try await signedInGateway()
        defer { transport.invalidateAndCancel() }
        let code = String(repeating: "ab12", count: 16)
        JourneyFixtureTransport.enqueue("sdi_room_action", #"{"status":"preview","room_id":"\#(Self.room.uuidString)","title":"Duel"}"#)
        JourneyFixtureTransport.enqueue("sdi_room_action", #"{"status":"pending_owner_approval","room_id":"\#(Self.room.uuidString)"}"#)
        JourneyFixtureTransport.enqueue("sdi_rooms", #"[{"id":"\#(Self.room.uuidString)","owner_id":"\#(Self.creator)","title":"Duel","closed":false,"project_ref":null,"project_title":null,"permissions":["view"],"project_revision":1,"command_revision":0}]"#)
        let client = RoomsClient(gateway: gateway)
        let preview = try await client.previewInvitation(code: code.uppercased())
        XCTAssertEqual(preview.title, "Duel")
        do { _ = try await client.requestAdmission(code: code, consent: false); XCTFail("Admission sent without consent") }
        catch CommunityError.server { }
        let admission = try await client.requestAdmission(code: code, consent: true)
        XCTAssertEqual(admission, .pendingOwnerApproval(room: Self.room))
        let rooms = try await client.myRooms()
        XCTAssertEqual(rooms.map(\.title), ["Duel"])
        let calls = JourneyFixtureTransport.rpcCalls
        XCTAssertEqual(calls.map(\.name), ["sdi_room_action", "sdi_room_action", "sdi_rooms"], "No request without consent")
        XCTAssertEqual(calls[0].body["code"] as? String, code)
        XCTAssertEqual(calls[1].body["consent"] as? Bool, true)
    }

    func testWarRoomJourneyListsMatchupAndCastsOneAuthenticatedVote() async throws {
        let (gateway, transport) = try await signedInGateway()
        defer { transport.invalidateAndCancel() }
        let ends = CommunityDates.string(Date().addingTimeInterval(3600))
        JourneyFixtureTransport.enqueue("sdi_war_action", #"{"matches":[{"id":"\#(Self.match.uuidString)","creator":"\#(Self.creator)","opponent":"66666666-6666-4666-8666-666666666666","status":"active","ends_at":"\#(ends)","left_title":"Left","left_url":"https://cdn.example/l.mp4","right_title":"Right","right_url":"https://cdn.example/r.mp4","left_votes":2,"right_votes":5,"my_vote":null,"outcome":null}]}"#)
        JourneyFixtureTransport.enqueue("sdi_war_action", #"{"status":"confirmed"}"#)
        JourneyFixtureTransport.enqueue("sdi_war_action", #"{"error":"Voting has closed."}"#)
        let client = WarRoomClient(gateway: gateway)
        let matches = try await client.matches()
        XCTAssertEqual(matches.map(\.id), [Self.match])
        try await client.vote(match: Self.match, choice: .right)
        do { try await client.vote(match: Self.match, choice: .left); XCTFail("Server refusal reported as a vote") }
        catch CommunityError.server(let message, _) { XCTAssertEqual(message, "Voting has closed.") }
        let votes = JourneyFixtureTransport.rpcCalls.filter { $0.body["action"] as? String == "vote" }
        XCTAssertEqual(votes.count, 2)
        XCTAssertEqual(votes.first?.body["choice"] as? String, "right")
    }

    func testApprovalJourneyReadsDecisionHistoryForTheExactRender() async throws {
        let (gateway, transport) = try await signedInGateway()
        defer { transport.invalidateAndCancel() }
        let digest = String(repeating: "a", count: 64)
        JourneyFixtureTransport.enqueue("sdi_review_history", #"{"decisions":[{"id":"77777777-7777-4777-8777-777777777777","review_id":"\#(Self.review.uuidString)","actor":"\#(Self.viewer)","owner_at_decision":true,"render_title":"Daily draft","source_revision":"r1","rights_summary":"Licensed library assets","render_digest":"\#(digest)","review_version":2,"consent_version":"publishing-v1","destinations":["feed"],"decision":"approved","note":"","created_at":"2026-10-13T01:00:00.123456+00:00"},{"id":"88888888-8888-4888-8888-888888888888","review_id":"99999999-9999-4999-8999-999999999999","actor":"\#(Self.viewer)","owner_at_decision":true,"render_title":"Other","source_revision":"r2","rights_summary":"","render_digest":"\#(digest)","review_version":1,"consent_version":"publishing-v1","destinations":[],"decision":"rejected","note":"","created_at":"2026-10-12T01:00:00+00:00"}]}"#)
        let result = try await AdminOperationsClient(gateway: gateway).decisions(for: Self.review, pages: 3)
        XCTAssertEqual(result.records.map(\.decision), ["approved"], "Only the exact render's decisions are shown")
        XCTAssertEqual(result.records.first?.render_digest, digest)
        XCTAssertEqual(result.searchedPages, 1, "A short page ends the search; completeness is not implied")
        XCTAssertEqual(JourneyFixtureTransport.rpcCalls.map(\.name), ["sdi_review_history"])
    }

    func testOnboardingPolicyJourneyAcceptsExactlyTheShownCurrentVersions() async throws {
        let (gateway, transport) = try await signedInGateway()
        defer { transport.invalidateAndCancel() }
        JourneyFixtureTransport.enqueue("sdi_consent_action", #"{"policies":[{"policy":"privacy","version":"p-2","summary":"Privacy","metadata":{},"effective_at":"2026-10-01T00:00:00+00:00"},{"policy":"terms","version":"t-1","summary":"Terms","metadata":{},"effective_at":"2026-09-01T00:00:00+00:00"}]}"#)
        JourneyFixtureTransport.enqueue("sdi_consent_action", #"{"consents":[],"publishing_current":false,"marketing_current":false}"#)
        JourneyFixtureTransport.enqueue("sdi_consent_action", #"{"status":"accepted","policy":"terms","version":"t-1"}"#)
        JourneyFixtureTransport.enqueue("sdi_consent_action", #"{"status":"accepted","policy":"privacy","version":"p-2"}"#)
        let client = PrivacyChoicesClient(gateway: gateway)
        let state = try await client.onboardingState()
        XCTAssertEqual(state.pending.map(\.version), ["t-1", "p-2"])
        try await client.acceptOnboarding(state.pending, ageConfirmed: false)
        let accepts = JourneyFixtureTransport.rpcCalls.filter { $0.body["action"] as? String == "accept" }
        XCTAssertEqual(accepts.map { $0.body["version"] as? String }, ["t-1", "p-2"])
        XCTAssertTrue(accepts.allSatisfy { $0.body["source"] as? String == "ios" })
    }

    func testSignedOutGatewaySendsNothingAndServiceFailureIsNotLiveData() async throws {
        let (client, transport) = makeClient()
        defer { transport.invalidateAndCancel() }
        let signedOut = CommunityGateway(transport: SupabaseCommunityTransport(provider: { client }))
        do { _ = try await WarRoomClient(gateway: signedOut).matches(); XCTFail("Signed-out request sent") }
        catch CommunityError.signedOut { }
        XCTAssertTrue(JourneyFixtureTransport.rpcCalls.isEmpty, "No request may leave without a session")
        let (gateway, signedIn) = try await signedInGateway()
        defer { signedIn.invalidateAndCancel() }
        JourneyFixtureTransport.enqueue("sdi_feed_page", #"{"message":"Fixture outage"}"#, status: 503)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-journey-outage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        do { _ = try await FeedClient(gateway: gateway, cache: .init(name: "feed", directory: cache)).page(.recent, page: 0, account: Self.viewer); XCTFail("Outage shown as a page") }
        catch CommunityError.transport { }
    }

    // MARK: Fixture

    private func makeClient() -> (SupabaseClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JourneyFixtureTransport.self]
        let transport = URLSession(configuration: config)
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-journey.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: JourneyFixtureStorage(), autoRefreshToken: false),
                           global: .init(session: transport)))
        return (client, transport)
    }

    private func signedInGateway() async throws -> (CommunityGateway, URLSession) {
        let (client, transport) = makeClient()
        try await client.auth.signIn(email: "journey@example.invalid", password: "fixture-password")
        let gateway = CommunityGateway(transport: SupabaseCommunityTransport(provider: { client }))
        XCTAssertTrue(gateway.transport.hasSession)
        return (gateway, transport)
    }
}

private final class JourneyFixtureStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func retrieve(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

/// Answers only `https://sdi-journey.invalid`. Token requests return a fixture
/// session; REST and RPC requests are answered from the per-test queue in
/// order and recorded with their JSON body and Authorization header. Any
/// unqueued request fails with 503 so a missing fixture cannot pass silently.
private final class JourneyFixtureTransport: URLProtocol {
    struct Call { let name: String; let body: [String: Any]; let authorization: String? }
    private static let gate = NSLock()
    private static var queued: [String: [(Int, String)]] = [:]
    private static var calls: [Call] = []
    static var rpcCalls: [Call] { gate.lock(); defer { gate.unlock() }; return calls }
    static func reset() { gate.lock(); defer { gate.unlock() }; queued = [:]; calls = [] }
    static func enqueue(_ name: String, _ body: String, status: Int = 200) {
        gate.lock(); defer { gate.unlock() }; queued[name, default: []].append((status, body))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func requestBody() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable && result.count <= 65_536 {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }; result.append(bytes, count: count)
        }
        return result
    }

    override func startLoading() {
        guard let url = request.url, url.host == "sdi-journey.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        if url.path.hasSuffix("/token") {
            respond(200, Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","token_type":"bearer","expires_in":3600,"expires_at":\#(Int(Date().timeIntervalSince1970) + 3600),"user":{"id":"abcdefab-cdef-4abc-8def-abcdefabcdef","aud":"authenticated","role":"authenticated","email":"journey@example.invalid","app_metadata":{},"user_metadata":{},"identities":[],"is_anonymous":false,"created_at":"2026-10-06T00:00:00Z","updated_at":"2026-10-06T00:00:00Z"}}"#.utf8))
            return
        }
        let name = url.lastPathComponent
        let body = (try? JSONSerialization.jsonObject(with: requestBody())) as? [String: Any] ?? [:]
        Self.gate.lock()
        Self.calls.append(Call(name: name, body: body, authorization: request.value(forHTTPHeaderField: "Authorization")))
        var next: (Int, String)?
        if var pending = Self.queued[name], !pending.isEmpty { next = pending.removeFirst(); Self.queued[name] = pending }
        Self.gate.unlock()
        guard let next else { respond(503, Data(#"{"message":"No fixture queued"}"#.utf8)); return }
        respond(next.0, Data(next.1.utf8))
    }

    private func respond(_ status: Int, _ data: Data) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
