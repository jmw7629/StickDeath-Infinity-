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
        let signedOut = CommunityGateway(transport: SupabaseCommunityTransport(provider: { client }, session: transport))
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

    func testConcurrentScopedCallsKeepTheirOwnLeaseAcrossOneHeldSDKRefresh() async throws {
        JourneyFixtureTransport.expireNextPasswordSession()
        let (client, transport) = makeClient()
        defer { transport.invalidateAndCancel() }
        try await client.auth.signIn(email: "journey@example.invalid", password: "fixture-password")
        let gateway = CommunityGateway(transport: SupabaseCommunityTransport(provider: { client }, session: transport))
        let rooms = RoomsClient(gateway: gateway)
        let held = expectation(description: "actual SDK refresh request held")
        JourneyFixtureTransport.holdNext("refresh_token") { held.fulfill() }
        JourneyFixtureTransport.enqueue("sdi_rooms", "[]")
        JourneyFixtureTransport.enqueue("sdi_rooms", "[]") // A second accidental request fails the exact count quickly.
        var windowEpoch = UUID(); let captured = windowEpoch
        let hiddenScope = CommunityOperationScope(account: UUID(uuidString: Self.viewer)) { windowEpoch == captured }
        let first = Task { @MainActor in
            do { _ = try await CommunityOperationContext.run(hiddenScope) { try await rooms.myRooms() }; XCTFail("Hidden lease sent REST after refresh") }
            catch CommunityError.stale { }
            catch { XCTFail("Unexpected scoped failure: \(error)") }
        }
        await fulfillment(of: [held], timeout: 2)
        windowEpoch = UUID()
        let secondStarted = expectation(description: "other call has its own live scope")
        let second = Task { @MainActor in
            try await CommunityOperationContext.run(CommunityOperationScope(account: UUID(uuidString: Self.viewer)) { true }) {
                secondStarted.fulfill()
                return try await rooms.myRooms()
            }
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        JourneyFixtureTransport.releaseHeld()
        await first.value
        let result = try await second.value
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(JourneyFixtureTransport.tokenGrants.filter { $0 == "refresh_token" }.count, 1)
        XCTAssertEqual(JourneyFixtureTransport.rpcCalls.map(\.name), ["sdi_rooms"], "No shared mutable lease may revive the hidden request")
        XCTAssertEqual(JourneyFixtureTransport.rpcCalls.first?.authorization, "Bearer fixture-refreshed")
        XCTAssertEqual(JourneyFixtureTransport.rpcCalls.first?.apiKey, "fixture-publishable", "Refresh replaces Authorization only")
    }

    func testCancelledScopeDuringSDKRefreshSendsNoCommunityRequest() async throws {
        JourneyFixtureTransport.expireNextPasswordSession()
        let (client, transport) = makeClient()
        defer { transport.invalidateAndCancel() }
        try await client.auth.signIn(email: "journey@example.invalid", password: "fixture-password")
        let rooms = RoomsClient(gateway: CommunityGateway(transport: SupabaseCommunityTransport(provider: { client }, session: transport)))
        let held = expectation(description: "refresh suspended before cancellation")
        JourneyFixtureTransport.holdNext("refresh_token") { held.fulfill() }
        let operation = Task { @MainActor in
            do { _ = try await CommunityOperationContext.run(CommunityOperationScope(account: UUID(uuidString: Self.viewer)) { true }) { try await rooms.myRooms() }; XCTFail("Cancelled refresh sent REST") }
            catch CommunityError.stale { }
            catch { XCTFail("Unexpected cancellation failure: \(error)") }
        }
        await fulfillment(of: [held], timeout: 2)
        operation.cancel()
        JourneyFixtureTransport.releaseHeld()
        await operation.value
        XCTAssertEqual(JourneyFixtureTransport.tokenGrants.filter { $0 == "refresh_token" }.count, 1)
        XCTAssertTrue(JourneyFixtureTransport.rpcCalls.isEmpty)
    }

    func testCancellingAnAlreadyResumedScopedDataTaskCompletesOnceAndKeepsTheFixtureSession() async throws {
        let (gateway, transport) = try await signedInGateway()
        defer { transport.invalidateAndCancel() }
        let held = expectation(description: "actual scoped REST data task resumed")
        JourneyFixtureTransport.holdNext("sdi_rooms") { held.fulfill() }
        var completions = 0
        let operation = Task { @MainActor in
            defer { completions += 1 }
            do { _ = try await CommunityOperationContext.run(CommunityOperationScope(account: UUID(uuidString: Self.viewer)) { true }) { try await RoomsClient(gateway: gateway).myRooms() }; XCTFail("Cancelled REST was adopted") }
            catch CommunityError.stale { }
            catch { XCTFail("Unexpected task cancellation: \(error)") }
        }
        await fulfillment(of: [held], timeout: 2)
        operation.cancel()
        await operation.value
        JourneyFixtureTransport.releaseHeld()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(JourneyFixtureTransport.rpcCalls.map(\.name), ["sdi_rooms"])
        XCTAssertEqual(JourneyFixtureTransport.tokenGrants, ["password"])
    }

    /// The production button creates its immutable submission synchronously;
    /// MainActor scheduling cannot turn an old tap into a new identity's request.
    func testQueuedCreateSubmissionCannotAcquireAReplacementAccountAuthOrWindowLease() async throws {
        let (gateway, transport) = try await signedInGateway()
        defer { transport.invalidateAndCancel() }
        let client = RoomsClient(gateway: gateway)
        let viewer = UUID(uuidString: Self.viewer)!
        for boundary in 0..<3 {
            var account = viewer, authRevision = UUID(), windowEpoch = UUID()
            let capturedAuth = authRevision, capturedWindow = windowEpoch
            let scope = CommunityOperationScope(account: viewer) {
                account == viewer && authRevision == capturedAuth && windowEpoch == capturedWindow
            }
            let submission = RoomCreateSubmission(title: "Original tap",
                share: RoomProjectShare(projectID: Self.post, title: "Original project", permissions: [.view]),
                consent: true, scope: scope)
            let queued = Task { @MainActor in
                do { _ = try await submission.execute(using: client); XCTFail("Old tap acquired replacement authority") }
                catch CommunityError.stale { }
                catch { XCTFail("Unexpected queued-create failure: \(error)") }
            }
            // No suspension before replacement: queued runs only after this mutation.
            switch boundary {
            case 0: account = UUID()
            case 1: authRevision = UUID() // same account, new authenticated identity
            default: windowEpoch = UUID() // hide then restore does not renew the tap
            }
            await queued.value
        }
        XCTAssertTrue(JourneyFixtureTransport.rpcCalls.isEmpty)
        XCTAssertEqual(JourneyFixtureTransport.tokenGrants, ["password"])
    }

    func testValidQueuedCreateUsesTheOriginalFormProjectAndConsent() async throws {
        let (gateway, transport) = try await signedInGateway()
        defer { transport.invalidateAndCancel() }
        JourneyFixtureTransport.enqueue("sdi_room_action", #"{"status":"created","room_id":"\#(Self.room.uuidString)"}"#)
        JourneyFixtureTransport.enqueue("sdi_room_manage", #"{"status":"updated","project_revision":2}"#)
        var title = "Original tap", consent = true
        var project = RoomProjectShare(projectID: Self.post, title: "Original project", permissions: [.view])
        let submission = RoomCreateSubmission(title: title, share: project, consent: consent,
            scope: CommunityOperationScope(account: UUID(uuidString: Self.viewer)) { true })
        let queued = Task { @MainActor in try await submission.execute(using: RoomsClient(gateway: gateway)) }
        title = "Later form"; consent = false
        project = RoomProjectShare(projectID: Self.match, title: "Later project", permissions: [.view, .edit])
        let outcome = try await queued.value
        XCTAssertEqual(outcome, .created(room: Self.room, projectRevision: 2))
        XCTAssertEqual(JourneyFixtureTransport.rpcCalls.map(\.name), ["sdi_room_action", "sdi_room_manage"])
        XCTAssertEqual(JourneyFixtureTransport.rpcCalls[0].body["title"] as? String, "Original tap")
        XCTAssertEqual(JourneyFixtureTransport.rpcCalls[0].body["consent"] as? Bool, true)
        XCTAssertEqual(JourneyFixtureTransport.rpcCalls[1].body["project_title"] as? String, "Original project")
        XCTAssertEqual(JourneyFixtureTransport.rpcCalls[1].body["project_ref"] as? String, submission.share.reference)
        XCTAssertNotEqual(project, submission.share)
        XCTAssertNotEqual(title, submission.title); XCTAssertNotEqual(consent, submission.consent)
    }

    func testQueuedReportKeepsItsDraftAndCannotSendAfterWindowReplacement() async throws {
        let (gateway, transport) = try await signedInGateway()
        defer { transport.invalidateAndCancel() }
        var epoch = UUID()
        let captured = epoch
        var draft = RoomReportDraft(reason: .rights, detail: "Original report")
        let submission = RoomReportSubmission(room: Self.room, draft: draft,
            scope: CommunityOperationScope(account: UUID(uuidString: Self.viewer)) { epoch == captured })
        let queued = Task { @MainActor in
            do { try await submission.execute(using: RoomsClient(gateway: gateway)); XCTFail("Revoked report was sent") }
            catch CommunityError.stale { }
            catch { XCTFail("Unexpected queued-report failure: \(error)") }
        }
        draft = RoomReportDraft(reason: .spam, detail: "Later report"); epoch = UUID()
        await queued.value
        XCTAssertEqual(submission.draft.detail, "Original report")
        XCTAssertNotEqual(draft, submission.draft)
        XCTAssertTrue(JourneyFixtureTransport.rpcCalls.isEmpty)
    }

    func testPickerRequestRejectsReplacementAccountAuthEpochAndRevokedWindow() {
        let viewer = UUID(uuidString: Self.viewer)!, epoch = UUID(), auth = UUID()
        var active = true
        let request = RoomAssetPickerRequest(scope: CommunityOperationScope(account: viewer) { active },
            operationEpoch: epoch, account: viewer, authRevision: auth)
        XCTAssertTrue(request.accepts(operationEpoch: epoch, account: viewer, authRevision: auth))
        XCTAssertFalse(request.accepts(operationEpoch: epoch, account: UUID(), authRevision: auth))
        XCTAssertFalse(request.accepts(operationEpoch: epoch, account: viewer, authRevision: UUID()))
        XCTAssertFalse(request.accepts(operationEpoch: UUID(), account: viewer, authRevision: auth))
        active = false
        XCTAssertFalse(request.accepts(operationEpoch: epoch, account: viewer, authRevision: auth))
        let replacement = RoomAssetPickerRequest(scope: CommunityOperationScope(account: viewer) { true },
            operationEpoch: epoch, account: viewer, authRevision: auth)
        XCTAssertNotEqual(replacement.id, request.id, "Old provider callback cannot stand in for a newer presentation")
    }

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
        let gateway = CommunityGateway(transport: SupabaseCommunityTransport(provider: { client }, session: transport))
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
    struct Call { let name: String; let body: [String: Any]; let authorization: String?; let apiKey: String? }
    private static let gate = NSLock()
    private static var queued: [String: [(Int, String)]] = [:]
    private static var calls: [Call] = []
    private static var grants: [String] = []
    private static var expiredPassword = false
    private static var heldName: String?
    private static var whenHeld: (() -> Void)?
    private static var held: JourneyFixtureTransport?
    private var stopped = false
    static var rpcCalls: [Call] { gate.lock(); defer { gate.unlock() }; return calls }
    static var tokenGrants: [String] { gate.lock(); defer { gate.unlock() }; return grants }
    static func reset() { gate.lock(); defer { gate.unlock() }; queued = [:]; calls = []; grants = []; expiredPassword = false; heldName = nil; whenHeld = nil; held = nil }
    static func expireNextPasswordSession() { gate.lock(); defer { gate.unlock() }; expiredPassword = true }
    static func holdNext(_ name: String, callback: @escaping () -> Void) { gate.lock(); defer { gate.unlock() }; heldName = name; whenHeld = callback }
    static func releaseHeld() {
        gate.lock(); let value = held; held = nil; gate.unlock()
        guard let value else { return }
        if value.request.url?.path.hasSuffix("/token") == true { value.tokenResponse(grant: "refresh_token", expired: false) }
        else { value.respond(200, Data("[]".utf8)) }
    }
    private func hold(_ name: String) -> Bool {
        Self.gate.lock()
        guard Self.heldName == name else { Self.gate.unlock(); return false }
        Self.heldName = nil; Self.held = self
        let callback = Self.whenHeld; Self.whenHeld = nil; Self.gate.unlock(); callback?(); return true
    }
    static func enqueue(_ name: String, _ body: String, status: Int = 200) {
        gate.lock(); defer { gate.unlock() }; queued[name, default: []].append((status, body))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { Self.gate.lock(); stopped = true; Self.gate.unlock() }

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
            let grant = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "grant_type" }?.value ?? "unknown"
            Self.gate.lock(); Self.grants.append(grant)
            let expired = grant == "password" && Self.expiredPassword
            if grant == "password" { Self.expiredPassword = false }; Self.gate.unlock()
            if hold(grant) { return }
            tokenResponse(grant: grant, expired: expired)
            return
        }
        let name = url.lastPathComponent
        let body = (try? JSONSerialization.jsonObject(with: requestBody())) as? [String: Any] ?? [:]
        Self.gate.lock()
        Self.calls.append(Call(name: name, body: body, authorization: request.value(forHTTPHeaderField: "Authorization"), apiKey: request.value(forHTTPHeaderField: "apikey")))
        Self.gate.unlock()
        if hold(name) { return }
        Self.gate.lock()
        var next: (Int, String)?
        if var pending = Self.queued[name], !pending.isEmpty { next = pending.removeFirst(); Self.queued[name] = pending }
        Self.gate.unlock()
        guard let next else { respond(503, Data(#"{"message":"No fixture queued"}"#.utf8)); return }
        respond(next.0, Data(next.1.utf8))
    }

    private func tokenResponse(grant: String, expired: Bool) {
        let access = grant == "refresh_token" ? "fixture-refreshed" : "fixture-access"
        let seconds = expired ? -3600 : 3600
        respond(200, Data(#"{"access_token":"\#(access)","refresh_token":"fixture-refresh","token_type":"bearer","expires_in":\#(seconds),"expires_at":\#(Int(Date().timeIntervalSince1970) + seconds),"user":{"id":"abcdefab-cdef-4abc-8def-abcdefabcdef","aud":"authenticated","role":"authenticated","email":"journey@example.invalid","app_metadata":{},"user_metadata":{},"identities":[],"is_anonymous":false,"created_at":"2026-10-06T00:00:00Z","updated_at":"2026-10-06T00:00:00Z"}}"#.utf8))
    }

    private func respond(_ status: Int, _ data: Data) {
        Self.gate.lock(); let stopped = stopped; Self.gate.unlock(); guard !stopped else { return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
