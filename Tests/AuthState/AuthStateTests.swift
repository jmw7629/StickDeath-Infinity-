import XCTest
import Combine
import Supabase
@testable import StickDeathInfinity

/// Native unit tests execute the actual AuthService and AuthViewModel against
/// the pinned SDK's injected URLSession. No external provider or host is called.
@MainActor final class AuthStateTests: XCTestCase {
    func testTypedProfileEditConfirmsExactFieldsAndPreservesAccountFacts() async throws {
        let (service, model, transport, _, _) = try await profileFixture()
        defer { transport.invalidateAndCancel() }
        let capture = try XCTUnwrap(model.captureProfileEdit())
        let old = try XCTUnwrap(service.currentProfile)
        let saved = try await model.saveProfile(username: "  New name  ", bio: "A real bio", capture: capture)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.user?.username, "New name"); XCTAssertEqual(model.user?.bio, "A real bio")
        XCTAssertEqual(model.user?.id, old.id); XCTAssertEqual(model.user?.role, old.role)
        XCTAssertEqual(model.user?.subscriptionTier, old.subscriptionTier)
        XCTAssertEqual(AuthFixtureTransport.profileFields, ["username", "bio"])
        XCTAssertEqual(AuthFixtureTransport.profileFilter?.lowercased(), "eq." + AuthFixtureTransport.alpha)
        XCTAssertEqual(AuthFixtureTransport.profileSelect, "id,username,bio")
        XCTAssertEqual(UUID(uuidString: old.id), UUID(uuidString: capture.userID))
        XCTAssertNotEqual(old.id, capture.userID, "Fixture must expose lowercase database versus uppercase SDK UUID")
        XCTAssertEqual(AuthFixtureTransport.profileWrites, 1)
        let current = try XCTUnwrap(model.captureProfileEdit())
        _ = try await model.saveProfile(username: "New name", bio: "A real bio", capture: current)
        XCTAssertEqual(AuthFixtureTransport.profileWrites, 1, "No-op issued a new write")
        do { _ = try await model.saveProfile(username: "", bio: "", capture: current); XCTFail("Invalid name sent") }
        catch AuthService.ProfileEditFailure.invalid { }
        do { _ = try await model.saveProfile(username: "Stale", bio: "", capture: capture); XCTFail("Old draft sent") }
        catch AuthService.ProfileEditFailure.stale { }
        XCTAssertEqual(AuthFixtureTransport.profileWrites, 1)
    }

    func testProfileEditRequiresConfirmedOwnedRowAndPreservesPriorProfileOnError() async throws {
        for mode in ["failure", "wrong", "empty", "malformed"] {
            let (service, model, transport, _, _) = try await profileFixture(mode: mode)
            let before = service.currentProfile?.username
            let capture = try XCTUnwrap(model.captureProfileEdit())
            do { _ = try await model.saveProfile(username: "Updated", bio: "Bio", capture: capture); XCTFail("Unconfirmed update accepted: \(mode)") }
            catch { }
            XCTAssertEqual(service.currentProfile?.username, before)
            XCTAssertEqual(service.currentProfile.flatMap { UUID(uuidString: $0.id) }, UUID(uuidString: capture.userID))
            transport.invalidateAndCancel()
        }
    }

    func testProfileEditLateAccountSwitchAndCancellationCannotPublishOldProfile() async throws {
        let (service, model, transport, _, _) = try await profileFixture(mode: "hold")
        defer { AuthFixtureTransport.releaseProfileWrites(); transport.invalidateAndCancel() }
        let capture = try XCTUnwrap(model.captureProfileEdit())
        let pending = Task { try await model.saveProfile(username: "Delayed", bio: "Old account", capture: capture) }
        try await waitFor { AuthFixtureTransport.hasProfileWrite }
        do { _ = try await model.saveProfile(username: "Overlap", bio: "", capture: capture); XCTFail("Overlapping write accepted") }
        catch AuthService.ProfileEditFailure.busy { }
        try await service.signIn(email: "second@example.invalid", password: "fixture-password")
        AuthFixtureTransport.releaseProfileWrites()
        do { _ = try await pending.value; XCTFail("Old account response published") } catch { }
        XCTAssertEqual(model.userId?.lowercased(), AuthFixtureTransport.second)
        XCTAssertNil(model.user)
        let (cancelService, cancelModel, cancelTransport, expiryStorage, _) = try await profileFixture(mode: "hold")
        defer { AuthFixtureTransport.releaseProfileWrites(); cancelTransport.invalidateAndCancel() }
        let cancelCapture = try XCTUnwrap(cancelModel.captureProfileEdit())
        let originalName = cancelService.currentProfile?.username
        let inFlight = Task { try await cancelModel.saveProfile(username: "Cancelled update", bio: "", capture: cancelCapture) }
        try await waitFor { AuthFixtureTransport.hasProfileWrite }
        inFlight.cancel()
        // No actor suspension between cancellation and this call: the original
        // production worker still owns its lease until it actually unwinds.
        do { _ = try await cancelModel.saveProfile(username: "Overlap", bio: "", capture: cancelCapture); XCTFail("Cancelled live worker lost lease") }
        catch AuthService.ProfileEditFailure.busy { }
        AuthFixtureTransport.releaseProfileWrites()
        do { _ = try await inFlight.value; XCTFail("Cancelled in-flight edit published") } catch { }
        XCTAssertEqual(cancelService.currentProfile?.username, originalName)
        AuthFixtureTransport.resetProfileWrites("success")
        _ = try await cancelModel.saveProfile(username: "Retry confirmed", bio: "", capture: cancelCapture)
        XCTAssertEqual(cancelService.currentProfile?.username, "Retry confirmed")
        let beforeExpiry = try XCTUnwrap(cancelModel.captureProfileEdit())
        AuthFixtureTransport.resetProfileWrites("hold")
        let expiring = Task { try await cancelModel.saveProfile(username: "Late expired", bio: "", capture: beforeExpiry) }
        try await waitFor { AuthFixtureTransport.hasProfileWrite }
        try expiryStorage.expireStoredSessions()
        AuthFixtureTransport.releaseProfileWrites()
        do { _ = try await expiring.value; XCTFail("Expired in-flight response published") }
        catch AuthService.ProfileEditFailure.stale { }
        XCTAssertEqual(cancelService.currentProfile?.username, "Retry confirmed")
        XCTAssertNil(cancelModel.captureProfileEdit())
        let writes = AuthFixtureTransport.profileWrites
        do { _ = try await cancelModel.saveProfile(username: "Expired", bio: "", capture: beforeExpiry); XCTFail("Expired session wrote") }
        catch AuthService.ProfileEditFailure.stale { }
        XCTAssertEqual(AuthFixtureTransport.profileWrites, writes)
    }

    private func profileFixture(mode: String = "success") async throws -> (AuthService, AuthViewModel, URLSession, AuthFixtureStorage, SupabaseClient) {
        AuthFixtureTransport.resetProfileWrites(mode)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthFixtureTransport.self]
        let transport = URLSession(configuration: config)
        let storage = AuthFixtureStorage()
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                global: .init(session: transport)))
        let service = AuthService(client: client)
        let model = AuthViewModel(auth: service, initializeOnStart: false)
        try await service.signIn(email: "alpha@example.invalid", password: "fixture-password")
        return (service, model, transport, storage, client)
    }

    func testStartupRetryUsesStoredSDKSessionAndSerializesRequests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthFixtureTransport.self]
        let transport = URLSession(configuration: config)
        defer { AuthFixtureTransport.releaseStartupRefresh(); transport.invalidateAndCancel() }
        let storage = AuthFixtureStorage()
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                global: .init(headers: ["X-SDI-Startup-Probe": "true"], session: transport)))
        _ = try await client.auth.signIn(email: "first@example.invalid", password: "fixture-password")
        try storage.expireStoredSessions()
        XCTAssertTrue(try XCTUnwrap(client.auth.currentSession).isExpired)
        AuthFixtureTransport.setStartupMode("failure")
        let service = AuthService(client: client)
        let model = AuthViewModel(auth: service, initializeOnStart: false)
        await model.initialize()
        XCTAssertEqual(model.restoration, .retryableFailure)
        XCTAssertEqual(model.state, .unauthenticated)
        XCTAssertNil(model.userId)
        XCTAssertNotNil(client.auth.currentSession, "Recoverable failure erased the stored session")
        service.reconcileAuthStateChange(.initialSession)
        XCTAssertFalse(model.isAuthenticated, "Expired cached session was promoted after refresh failure")
        let failedRequests = AuthFixtureTransport.startupRequestCount
        await model.initialize()
        XCTAssertEqual(AuthFixtureTransport.startupRequestCount, failedRequests, "Repeated appearance implicitly retried")
        AuthFixtureTransport.setStartupMode("hold")
        let retry = Task { await model.retryRestoration() }
        try await waitFor { AuthFixtureTransport.hasStartupRefresh }
        XCTAssertEqual(model.restoration, .restoring)
        let inFlightRequests = AuthFixtureTransport.startupRequestCount
        await model.retryRestoration()
        XCTAssertEqual(AuthFixtureTransport.startupRequestCount, inFlightRequests, "Double Retry started another refresh")
        do { try await service.signOut(); XCTFail("Identity mutation raced an active restoration") }
        catch AuthService.AuthError.operationInProgress { }
        AuthFixtureTransport.releaseStartupRefresh()
        await retry.value
        XCTAssertEqual(model.restoration, .ready)
        XCTAssertTrue(model.isAuthenticated)
        XCTAssertEqual(model.userId?.lowercased(), AuthFixtureTransport.first)
        XCTAssertFalse(try XCTUnwrap(client.auth.currentSession).isExpired)
    }

    func testStartupRevokedSessionRequiresNewSignInWithoutRetryLoop() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthFixtureTransport.self]
        let transport = URLSession(configuration: config)
        defer { AuthFixtureTransport.releaseStartupRefresh(); transport.invalidateAndCancel() }
        let storage = AuthFixtureStorage()
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                global: .init(headers: ["X-SDI-Startup-Probe": "true"], session: transport)))
        _ = try await client.auth.signIn(email: "first@example.invalid", password: "fixture-password")
        try storage.expireStoredSessions()
        AuthFixtureTransport.setStartupMode("revoked")
        let service = AuthService(client: client)
        await service.initialize()
        XCTAssertEqual(service.restoration, .signInRequired)
        XCTAssertFalse(service.isAuthenticated); XCTAssertNil(service.currentUser)
        XCTAssertNil(client.auth.currentSession, "Pinned SDK must clear the rejected refresh session")
        let count = AuthFixtureTransport.startupRequestCount
        await service.retryRestoration()
        XCTAssertEqual(AuthFixtureTransport.startupRequestCount, count)
        AuthFixtureTransport.setStartupMode("success")
        try await service.signIn(email: "second@example.invalid", password: "fixture-password")
        XCTAssertEqual(service.restoration, .ready)
        XCTAssertEqual(service.userId?.lowercased(), AuthFixtureTransport.second)
    }

    func testSessionExpiringDuringRestorationProfileNeverCommitsAuthenticated() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthFixtureTransport.self]
        let transport = URLSession(configuration: config)
        defer { AuthFixtureTransport.releaseProfiles(); transport.invalidateAndCancel() }
        let storage = AuthFixtureStorage()
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                global: .init(headers: ["X-SDI-Delay-Profile": "first"], session: transport)))
        _ = try await client.auth.signIn(email: "first@example.invalid", password: "fixture-password")
        let service = AuthService(client: client)
        var observedStates: [AuthService.AuthState] = []
        let observation = service.$state.sink { observedStates.append($0) }
        defer { observation.cancel() }
        let restoration = Task { await service.initialize() }
        try await waitFor { AuthFixtureTransport.hasDelayedProfile }
        XCTAssertEqual(service.restoration, .restoring)
        try storage.expireStoredSessions()
        XCTAssertTrue(try XCTUnwrap(client.auth.currentSession).isExpired)
        AuthFixtureTransport.releaseProfiles()
        await restoration.value
        XCTAssertEqual(service.restoration, .retryableFailure)
        XCTAssertEqual(service.state, .unauthenticated)
        XCTAssertFalse(observedStates.contains(.authenticated), "Expired session briefly committed authenticated before observer correction")
        XCTAssertNil(service.currentUser); XCTAssertNil(service.currentProfile)
        XCTAssertNotNil(client.auth.currentSession, "Retryable failure must preserve SDK credentials")
    }

    func testStartupWithoutStoredSessionFinishesWithoutRefresh() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthFixtureTransport.self]
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        AuthFixtureTransport.setStartupMode("failure")
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: AuthFixtureStorage(), autoRefreshToken: false),
                global: .init(headers: ["X-SDI-Startup-Probe": "true"], session: transport)))
        let service = AuthService(client: client)
        await service.initialize(); await service.retryRestoration()
        XCTAssertEqual(service.restoration, .ready)
        XCTAssertEqual(service.state, .unauthenticated)
        XCTAssertEqual(AuthFixtureTransport.startupRequestCount, 0)
    }

    func testServiceEventsProfileFailureAndLogoutFailureStayTruthful() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthFixtureTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: AuthFixtureStorage(), autoRefreshToken: false), global: .init(session: session)))
        let service = AuthService(client: client)
        let model = AuthViewModel(auth: service, initializeOnStart: false)
        await service.initialize()
        XCTAssertEqual(model.state, .unauthenticated)
        await model.signIn(email: "first@example.invalid", password: "fixture-password")
        XCTAssertTrue(model.isAuthenticated)
        XCTAssertEqual(model.user?.username, "Existing owner-chosen name")
        // The second auth succeeds, but its profile is unavailable. The first
        // account's displayed profile must disappear rather than leaking across.
        await model.signIn(email: "second@example.invalid", password: "fixture-password")
        XCTAssertTrue(model.isAuthenticated)
        XCTAssertNil(model.user)
        XCTAssertEqual(model.userId?.lowercased(), AuthFixtureTransport.second)
        await model.signOut()
        XCTAssertNotNil(model.error, "Remote revocation failure must be reported")
        XCTAssertEqual(model.state, .unauthenticated, "Pinned SDK has actually cleared local credentials")
        XCTAssertNil(model.userId)
        XCTAssertNil(model.user)
        XCTAssertNil(client.auth.currentSession)
    }

    func testDelayedProfileAndOldNotificationsCannotReplaceNewSDKIdentity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthFixtureTransport.self]
        let session = URLSession(configuration: configuration)
        defer { AuthFixtureTransport.releaseProfiles(); session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: AuthFixtureStorage(), autoRefreshToken: false),
                global: .init(headers: ["X-SDI-Delay-Profile": "first"], session: session)))
        let service = AuthService(client: client)
        let model = AuthViewModel(auth: service, initializeOnStart: false)
        await service.initialize()
        let firstSignIn = Task { try await service.signIn(email: "first@example.invalid", password: "fixture-password") }
        try await waitFor { AuthFixtureTransport.hasDelayedProfile }
        // Actual SDK changes while the first profile request remains suspended.
        // The observer must consume this notification without waiting for HTTP.
        _ = try await client.auth.signIn(email: "second@example.invalid", password: "fixture-password")
        try await waitFor { model.userId?.lowercased() == AuthFixtureTransport.second }
        XCTAssertNil(model.user)
        // Deterministically replay old queued notifications: their payload is
        // not authoritative after the SDK has established the newer identity.
        service.reconcileAuthStateChange(.signedOut)
        service.reconcileAuthStateChange(.initialSession)
        XCTAssertTrue(model.isAuthenticated)
        XCTAssertEqual(model.userId?.lowercased(), AuthFixtureTransport.second)
        AuthFixtureTransport.releaseProfiles()
        do { try await firstSignIn.value; XCTFail("Obsolete sign-in profile completed as current") }
        catch is CancellationError { }
        XCTAssertEqual(model.userId?.lowercased(), AuthFixtureTransport.second)
        XCTAssertNil(model.user, "Delayed first-account profile was attached to second account")
        try? await client.auth.signOut()
        service.reconcileAuthStateChange(.signedIn)
        XCTAssertEqual(model.state, .unauthenticated, "Stale signed-in notification restored cleared SDK credentials")
        XCTAssertNil(model.userId)
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NSError(domain: "AuthStateTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected auth transition did not arrive"])
    }

    func testOAuthAvailabilityAndMicrosoftTenantFailClosed() {
        XCTAssertTrue(AppConfig.oauthConfiguration(from: [:]).enabledProviders.isEmpty)
        XCTAssertTrue(AppConfig.oauthConfiguration(from: ["SDI_OAUTH_PROVIDERS": "google,unknown"]).enabledProviders.isEmpty)
        XCTAssertFalse(AppConfig.oauthConfiguration(from: ["SDI_OAUTH_PROVIDERS": "microsoft"]).enabledProviders.contains(.microsoft))
        let configured = AppConfig.oauthConfiguration(from: ["SDI_OAUTH_PROVIDERS": "google,github,microsoft", "SDI_MICROSOFT_TENANT": "organizations"])
        XCTAssertEqual(configured.enabledProviders, [.google, .github, .microsoft])
        XCTAssertEqual(configured.microsoftTenant, "organizations")
    }
    func testOAuthPKCEIdentityScopesCancellationAndRejectedCallback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthFixtureTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: AuthFixtureStorage(), flowType: .pkce, autoRefreshToken: false), global: .init(session: session)))
        let unavailable = AuthService(client: client, oauthConfiguration: .init(enabledProviders: [], microsoftTenant: nil))
        do {
            try await unavailable.signIn(provider: .github, launch: { _ in XCTFail("Disabled provider opened browser"); throw CancellationError() })
            XCTFail("Disabled provider accepted")
        } catch AuthService.AuthError.providerUnavailable { }
        let service = AuthService(client: client, oauthConfiguration: .init(enabledProviders: [.github], microsoftTenant: nil))
        do {
            try await service.signIn(provider: .github, launch: { url in
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "provider" }?.value, "github")
                XCTAssertEqual(query.first { $0.name == "scopes" }?.value, "read:user user:email")
                XCTAssertFalse(query.contains { $0.name == "scopes" && ($0.value ?? "").contains("repo") })
                XCTAssertFalse(query.first { $0.name == "code_challenge" }?.value?.isEmpty ?? true)
                XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "s256")
                throw CancellationError()
            })
            XCTFail("Cancelled browser exchange succeeded")
        } catch is CancellationError { }
        // A fresh attempt proves the operation lock was released after cancel.
        do {
            try await service.signIn(provider: .github, launch: { _ in URL(string: "stickdeath://auth/wrong?code=fixture")! })
            XCTFail("Wrong callback exchanged credentials")
        } catch AuthService.AuthError.invalidCallback { }
        XCTAssertNil(client.auth.currentSession)
        // The actual view model's completion belongs to this attempt, not to
        // a previously authenticated session which survives cancellation.
        let model = AuthViewModel(auth: service, initializeOnStart: false)
        let signedIn = await model.signIn(email: "first@example.invalid", password: "fixture-password")
        XCTAssertTrue(signedIn)
        let cancelled = await model.signIn(provider: .github, launch: { _ in throw CancellationError() })
        XCTAssertFalse(cancelled)
        XCTAssertTrue(model.isAuthenticated)
        XCTAssertEqual(model.userId?.lowercased(), AuthFixtureTransport.first)
        let rejected = await model.signIn(provider: .github, launch: { _ in URL(string: "stickdeath://auth/wrong?code=fixture")! })
        XCTAssertFalse(rejected)
        XCTAssertTrue(model.isAuthenticated)
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.error)
        do {
            try await service.handleOAuthCallback(url: URL(string: "stickdeath://auth/callback?code=replayed")!)
            XCTFail("Unsolicited callback exchanged credentials")
        } catch AuthService.AuthError.invalidCallback { }
    }

    func testWrongCallbackAndUnavailableDeletionNeverMutateAccount() async throws {
        let service = AuthService()
        do {
            try await service.handleOAuthCallback(url: URL(string: "https://attacker.invalid/auth/callback?code=fixture")!)
            XCTFail("Wrong callback accepted")
        } catch AuthService.AuthError.invalidCallback { }
        do {
            try await service.deleteAccount()
            XCTFail("Profile-only account deletion claimed success")
        } catch AuthService.AuthError.accountDeletionUnavailable { }
        XCTAssertNil(service.currentUser)
    }
}
private final class AuthFixtureStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func expireStoredSessions() throws {
        lock.lock(); defer { lock.unlock() }
        var expired = 0
        for (key, bytes) in values {
            if var session = try? JSONDecoder().decode(Session.self, from: bytes) {
                session.expiresAt = Date().timeIntervalSince1970 - 3600
                values[key] = try JSONEncoder().encode(session); expired += 1
            }
        }
        XCTAssertEqual(expired, 1, "Fixture must expire the actual SDK-owned stored session")
    }
    func store(key: String, value: Data) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func retrieve(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}
private final class AuthFixtureTransport: URLProtocol {
    private static let gate = NSLock()
    private static var patchMode = "success"
    private static var patchRequests: [(AuthFixtureTransport, [String: Any])] = []
    private static var patchCount = 0
    private static var patchKeys: Set<String> = []
    private static var patchFilter: String?
    private static var patchSelect: String?
    static let alpha = "abcdefab-cdef-4abc-8def-abcdefabcdef"
    static var profileFilter: String? { gate.lock(); defer { gate.unlock() }; return patchFilter }
    static var profileSelect: String? { gate.lock(); defer { gate.unlock() }; return patchSelect }
    static var profileWrites: Int { gate.lock(); defer { gate.unlock() }; return patchCount }
    static var profileFields: Set<String> { gate.lock(); defer { gate.unlock() }; return patchKeys }
    static var hasProfileWrite: Bool { gate.lock(); defer { gate.unlock() }; return !patchRequests.isEmpty }
    static func resetProfileWrites(_ mode: String) { gate.lock(); defer { gate.unlock() }; patchMode = mode; patchCount = 0; patchKeys = [] }
    static func releaseProfileWrites() {
        gate.lock(); let requests = patchRequests; patchRequests = []; gate.unlock()
        for (request, row) in requests { request.respond(200, row) }
    }
    private func requestBody() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable && result.count <= 16_384 {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }; result.append(bytes, count: count)
        }
        return result
    }
    private static var delayed: [AuthFixtureTransport] = []
    private static var startupMode = "success"
    private static var startupRequests = 0
    private static var startupPending: [AuthFixtureTransport] = []
    static var startupRequestCount: Int { gate.lock(); defer { gate.unlock() }; return startupRequests }
    static var hasStartupRefresh: Bool { gate.lock(); defer { gate.unlock() }; return !startupPending.isEmpty }
    static func setStartupMode(_ mode: String) { gate.lock(); defer { gate.unlock() }; startupMode = mode; startupRequests = 0 }
    static func releaseStartupRefresh() {
        gate.lock(); let pending = startupPending; startupPending = []; startupMode = "success"; gate.unlock()
        for request in pending { request.startLoading() }
    }
    static var hasDelayedProfile: Bool { gate.lock(); defer { gate.unlock() }; return !delayed.isEmpty }
    static func releaseProfiles() {
        gate.lock(); let requests = delayed; delayed = []; gate.unlock()
        for request in requests { request.respond(200, ["id": first, "username": "Delayed old profile"]) }
    }
    static let first = "10000000-0000-4000-8000-000000000001"
    static let second = "20000000-0000-4000-8000-000000000002"
    private let loadingLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "sdi-auth.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let url = request.url!
        if url.path.hasSuffix("/users"), request.httpMethod == "PATCH" {
            let fields = (try? JSONSerialization.jsonObject(with: requestBody())) as? [String: Any] ?? [:]
            Self.gate.lock(); Self.patchCount += 1; Self.patchKeys = Set(fields.keys); let mode = Self.patchMode
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            Self.patchFilter = query.first(where: { $0.name == "id" })?.value
            Self.patchSelect = query.first(where: { $0.name == "select" })?.value
            Self.gate.unlock()
            if mode == "failure" { respond(403, ["message": "Fixture ownership rejected"]); return }
            if mode == "empty" { respond(406, ["message": "Zero returned rows"]); return }
            var row = fields; row["id"] = mode == "wrong" ? Self.second : (mode == "malformed" ? "invalid-identity" : Self.alpha)
            if mode == "hold" { Self.gate.lock(); Self.patchRequests.append((self,row)); Self.gate.unlock(); return }
            respond(200, row); return
        }
        if url.path.hasSuffix("/logout") {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        if url.path.hasSuffix("/token"), url.query?.contains("grant_type=refresh_token") == true,
           request.value(forHTTPHeaderField: "X-SDI-Startup-Probe") == "true" {
            Self.gate.lock(); Self.startupRequests += 1; let mode = Self.startupMode
            if mode == "hold" { Self.startupPending.append(self) }
            Self.gate.unlock()
            if mode == "hold" { return }
            if mode == "failure" {
                // A real SDK API error, not an injected AuthService result.
                respond(400, ["code": "unexpected_failure", "msg": "Fixture restoration unavailable"]); return
            }
            if mode == "revoked" {
                respond(400, ["code": "refresh_token_not_found", "msg": "Fixture refresh token revoked"]); return
            }
        }
        if url.path.hasSuffix("/token") {
            let body: Data
            if let data = request.httpBody { body = data }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096), collected = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }; collected.append(bytes, count: count)
                }
                body = collected
            } else { body = Data() }
            let isSecond = String(decoding: body, as: UTF8.self).contains("second@example.invalid")
            let isAlpha = String(decoding: body, as: UTF8.self).contains("alpha@example.invalid")
            let id = isSecond ? Self.second : (isAlpha ? Self.alpha : Self.first)
            respond(200, ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "token_type": "bearer",
                "expires_in": 3600, "expires_at": Int(Date().timeIntervalSince1970) + 3600,
                "user": ["id": id, "aud": "authenticated", "role": "authenticated",
                    "email": isSecond ? "second@example.invalid" : "first@example.invalid",
                    "app_metadata": [:], "user_metadata": [:], "identities": [], "is_anonymous": false,
                    "created_at": "2026-10-06T00:00:00Z", "updated_at": "2026-10-06T00:00:00Z"]])
        } else if url.path.hasSuffix("/users"), url.query?.lowercased().contains(Self.alpha) == true {
            respond(200, ["id": Self.alpha, "username": "Existing owner-chosen name"])
        } else if url.path.hasSuffix("/users"), url.query?.lowercased().contains(Self.first) == true {
            if request.value(forHTTPHeaderField: "X-SDI-Delay-Profile") == "first" {
                Self.gate.lock(); Self.delayed.append(self); Self.gate.unlock(); return
            }
            respond(200, ["id": Self.first, "username": "Existing owner-chosen name"])
        } else { respond(503, ["message": "Fixture profile unavailable"]) }
    }
    private func respond(_ status: Int, _ value: [String: Any]) {
        loadingLock.lock(); let cancelled = stopped; loadingLock.unlock()
        guard !cancelled else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { loadingLock.lock(); stopped = true; loadingLock.unlock() }
}
