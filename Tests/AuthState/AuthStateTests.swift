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
        // Sign-out hands the open Studio project back to the library (#172):
        // flush before the account changes, close after it is gone, delete nothing.
        var studioEvents: [String] = []
        let model = AuthViewModel(auth: service, initializeOnStart: false,
            flushOpenProject: { studioEvents.append("flush:\(service.isAuthenticated)") },
            closeOpenProject: { studioEvents.append("close:\(service.isAuthenticated)") })
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
        XCTAssertEqual(studioEvents, ["flush:true", "close:false"], "Flush while signed in, close once signed out")
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

    func testProviderDenialCallbackIsReportedNotExchangedEvenWithCode() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthFixtureTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: AuthFixtureStorage(), flowType: .pkce, autoRefreshToken: false), global: .init(session: session)))
        let service = AuthService(client: client, oauthConfiguration: .init(enabledProviders: [.google, .microsoft], microsoftTenant: "organizations"))
        XCTAssertEqual(service.microsoftTenant, "organizations")
        for callback in ["stickdeath://auth/callback?error=access_denied&error_description=User+declined",
                         "stickdeath://auth/callback?error=access_denied&code=fixture-code"] {
            do {
                try await service.signIn(provider: .google, launch: { _ in URL(string: callback)! })
                XCTFail("Denied callback exchanged credentials: \(callback)")
            } catch AuthService.AuthError.providerDenied(let reason) {
                XCTAssertFalse(reason.isEmpty); XCTAssertFalse(reason.contains("not for StickDeath"))
            }
            XCTAssertNil(client.auth.currentSession)
        }
        let microsoft = URL(string: "stickdeath://auth/callback?error=invalid_request&error_description=AADSTS50020%3A+User+account+from+identity+provider")!
        XCTAssertEqual(AuthService.oauthCallbackDenial(microsoft)?.hasPrefix("Microsoft declined"), true)
        XCTAssertNil(AuthService.oauthCallbackDenial(URL(string: "stickdeath://auth/callback?code=fixture")!))
        XCTAssertNil(AuthService.oauthCallbackDenial(URL(string: "https://attacker.invalid/auth/callback?error=x")!))
        // Browser cancellation produces no banner; a denial does.
        let model = AuthViewModel(auth: service, initializeOnStart: false)
        let cancelled = await model.signIn(provider: .google, launch: { _ in throw CancellationError() })
        XCTAssertFalse(cancelled)
        XCTAssertNil(model.error)
        let denied = await model.signIn(provider: .google, launch: { _ in URL(string: "stickdeath://auth/callback?error=access_denied")! })
        XCTAssertFalse(denied)
        XCTAssertNotNil(model.error)
    }

    func testAppleUsernameFallsBackForPrivateRelayAndDisplayNameIsBounded() async throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let relay = try decoder.decode(User.self, from: Data("""
        {"id":"\(AuthFixtureTransport.first)","aud":"authenticated","role":"authenticated","email":"abc123@privaterelay.appleid.com","app_metadata":{},"user_metadata":{},"identities":[],"is_anonymous":false,"created_at":"2026-10-06T00:00:00Z","updated_at":"2026-10-06T00:00:00Z"}
        """.utf8))
        XCTAssertEqual(AuthService.appleUsername(for: relay), "Creator_10000000")
        let direct = try decoder.decode(User.self, from: Data("""
        {"id":"\(AuthFixtureTransport.second)","aud":"authenticated","role":"authenticated","email":"Joe@example.invalid","app_metadata":{},"user_metadata":{},"identities":[],"is_anonymous":false,"created_at":"2026-10-06T00:00:00Z","updated_at":"2026-10-06T00:00:00Z"}
        """.utf8))
        XCTAssertEqual(AuthService.appleUsername(for: direct), "joe")
        var name = PersonNameComponents(); name.givenName = " Joe "; name.familyName = "Willis"
        XCTAssertEqual(AuthService.appleDisplayName(name), "Joe Willis")
        XCTAssertNil(AuthService.appleDisplayName(nil))
        XCTAssertNil(AuthService.appleDisplayName(PersonNameComponents()))
        var control = PersonNameComponents(); control.givenName = "Bad\u{0007}Name"
        XCTAssertNil(AuthService.appleDisplayName(control))
        // Apple's subject identifier comes only from the server identity list.
        XCTAssertNil(AuthService.appleUserIdentifier(for: relay))
        let linked = try decoder.decode(User.self, from: Data("""
        {"id":"\(AuthFixtureTransport.first)","aud":"authenticated","role":"authenticated","email":"abc123@privaterelay.appleid.com","app_metadata":{},"user_metadata":{},"identities":[{"identity_id":"30000000-0000-4000-8000-000000000003","id":"001234.fixtureapplesubject.0001","user_id":"\(AuthFixtureTransport.first)","identity_data":{},"provider":"apple","created_at":"2026-10-06T00:00:00Z","last_sign_in_at":"2026-10-06T00:00:00Z","updated_at":"2026-10-06T00:00:00Z"}],"is_anonymous":false,"created_at":"2026-10-06T00:00:00Z","updated_at":"2026-10-06T00:00:00Z"}
        """.utf8))
        XCTAssertEqual(AuthService.appleUserIdentifier(for: linked), "001234.fixtureapplesubject.0001")
        XCTAssertTrue(AuthService.appleCredentialRequiresSignOut(.revoked))
        XCTAssertFalse(AuthService.appleCredentialRequiresSignOut(.authorized))
        XCTAssertFalse(AuthService.appleCredentialRequiresSignOut(.notFound))
        XCTAssertFalse(AuthService.appleCredentialRequiresSignOut(.transferred))
        // Replays Apple's credential-state answer against a real signed-in SDK
        // session: only `.revoked` clears it, locally, with a notice and no error.
        let (service, model, transport, _, client) = try await profileFixture()
        defer { transport.invalidateAndCancel() }
        await service.handleAppleCredentialState(.authorized)
        XCTAssertTrue(service.isAuthenticated); XCTAssertNotNil(client.auth.currentSession)
        await service.handleAppleCredentialState(.notFound)
        XCTAssertTrue(service.isAuthenticated, "notFound is not a revocation")
        await service.handleAppleCredentialState(.revoked)
        XCTAssertEqual(service.state, .unauthenticated); XCTAssertNil(service.currentUser)
        XCTAssertNil(client.auth.currentSession, "Revoked Apple grant must clear the stored session")
        XCTAssertEqual(service.restoration, .signInRequired)
        XCTAssertEqual(model.notice, AuthService.appleRevokedNotice)
        XCTAssertNil(model.error, "Revocation is a notice, not an error banner")
        // Already signed out: a second answer changes nothing and throws nothing.
        await service.handleAppleCredentialState(.revoked)
        XCTAssertEqual(service.state, .unauthenticated)
    }

    func testInstallMarkerClearsStoredSessionOnceAfterReinstall() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthFixtureTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "sdi.authtests.install." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = AuthFixtureStorage()
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                global: .init(headers: ["X-SDI-Startup-Probe": "true"], session: session)))
        // A valid session "left in the Keychain" by a previous installation.
        _ = try await client.auth.signIn(email: "first@example.invalid", password: "fixture-password")
        XCTAssertNotNil(client.auth.currentSession)
        XCTAssertNil(defaults.string(forKey: AuthService.installMarkerKey))
        let fresh = AuthService(client: client, defaults: defaults)
        await fresh.initialize()
        XCTAssertEqual(fresh.restoration, .ready, "Reinstall must present as a clean install, not a revoked session")
        XCTAssertEqual(fresh.state, .unauthenticated); XCTAssertNil(fresh.currentUser)
        XCTAssertNil(client.auth.currentSession, "Stored session from the previous install was adopted")
        XCTAssertNotNil(defaults.string(forKey: AuthService.installMarkerKey))
        // Subsequent launches with the marker keep the session the person creates.
        try await fresh.signIn(email: "second@example.invalid", password: "fixture-password")
        let relaunch = AuthService(client: client, defaults: defaults)
        await relaunch.initialize()
        XCTAssertTrue(relaunch.isAuthenticated)
        XCTAssertEqual(relaunch.userId?.lowercased(), AuthFixtureTransport.second)
    }

    func testDeepLinkRouterClassifiesBeforeNavigation() {
        // Cold-launch routing (#136): pure decision used by AppFlowView after restoration settles.
        XCTAssertEqual(AppFlowView.startupDestination(isAuthenticated: true, guestChosen: false, guideCompleted: true, onboarded: false), .app)
        XCTAssertEqual(AppFlowView.startupDestination(isAuthenticated: true, guestChosen: false, guideCompleted: false, onboarded: true), .app)
        XCTAssertEqual(AppFlowView.startupDestination(isAuthenticated: true, guestChosen: true, guideCompleted: false, onboarded: false), .onboarding)
        XCTAssertEqual(AppFlowView.startupDestination(isAuthenticated: false, guestChosen: true, guideCompleted: false, onboarded: false), .app)
        XCTAssertEqual(AppFlowView.startupDestination(isAuthenticated: false, guestChosen: false, guideCompleted: true, onboarded: true), .welcome)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "stickdeath://auth/callback?code=abc")!), .authCallback)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "STICKDEATH://auth/callback/")!), .authCallback)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "stickdeath://auth/reset?code=abc")!), .passwordReset)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "stickdeath://auth/reset?code=abc&code=def")!), .unsupported)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "stickdeath://auth/reset?code=")!), .unsupported)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "stickdeath://auth/reset?code=abc&error=access_denied")!), .unsupported)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "stickdeath://auth/reset#access_token=x")!), .unsupported)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "stickdeath://messages/thread/1")!), .unsupported)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "stickdeath://rooms/invite/abcdef")!), .unsupported)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "https://stickdeath.invalid/auth/callback?code=abc")!), .unsupported)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "stickdeath://user:pw@auth/callback")!), .unsupported)
        XCTAssertEqual(DeepLinkRouter.route(URL(string: "stickdeath://")!), .unsupported)
    }

    func testUnsupportedAndCallbackDeepLinksNeverAuthenticate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthFixtureTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: AuthFixtureStorage(), flowType: .pkce, autoRefreshToken: false), global: .init(session: session)))
        let service = AuthService(client: client)
        let model = AuthViewModel(auth: service, initializeOnStart: false)
        await service.initialize()
        await model.handleDeepLink(URL(string: "stickdeath://messages/thread/1")!)
        XCTAssertEqual(model.notice?.hasPrefix("Unsupported link"), true); XCTAssertNil(model.error)
        model.notice = nil
        await model.handleDeepLink(URL(string: "stickdeath://auth/callback?code=replayed")!)
        XCTAssertNotNil(model.error); XCTAssertNil(model.notice)
        // A recovery link with no matching verifier on this device cannot sign in.
        await model.handleDeepLink(URL(string: "stickdeath://auth/reset?code=unsolicited")!)
        XCTAssertFalse(model.isAuthenticated); XCTAssertNil(client.auth.currentSession)
        XCTAssertNotNil(model.error); XCTAssertFalse(service.passwordRecoveryPending)
    }

    func testPasswordResetIsNeutralAndRateLimited() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthFixtureTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://sdi-auth.invalid")!, supabaseKey: "fixture-publishable",
            options: .init(auth: .init(storage: AuthFixtureStorage(), flowType: .pkce, autoRefreshToken: false), global: .init(session: session)))
        let model = AuthViewModel(auth: AuthService(client: client), initializeOnStart: false)
        let invalid = await model.requestPasswordReset(email: "not-an-address")
        XCTAssertFalse(invalid)
        XCTAssertNotNil(model.error); XCTAssertNil(model.passwordResetAvailableAt)
        // The fixture answers /recover with a transport failure for unknown and known
        // addresses alike; the person sees the same neutral notice either way.
        _ = await model.requestPasswordReset(email: "unknown@example.invalid")
        let neutral = model.notice
        XCTAssertEqual(neutral?.hasPrefix("If an account exists"), true)
        XCTAssertNil(model.error, "Reset must not reveal whether the address is registered")
        let availableAt = try XCTUnwrap(model.passwordResetAvailableAt)
        XCTAssertGreaterThan(availableAt.timeIntervalSinceNow, 50)
        let blocked = await model.requestPasswordReset(email: "unknown@example.invalid")
        XCTAssertFalse(blocked)
        XCTAssertEqual(model.passwordResetAvailableAt, availableAt, "Cooldown restarted by a blocked request")
        XCTAssertEqual(model.notice?.hasPrefix("Wait"), true)
        XCTAssertFalse(model.isAuthenticated)
    }

    func testScheduledChallengeOverlapAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func challenge(_ id: Int, _ start: String, _ end: String?) -> Challenge {
            Challenge(id: id, title: "DST \(id)", description: nil, thumbnailURL: nil, startDate: start, endDate: end,
                      status: nil, submissionCount: nil, prizeDescription: nil)
        }
        func day(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
        // 8 March 2026: clocks jump from 02:00 to 03:00 EST→EDT; the civil day is 23 hours.
        let springForward = day("2026-03-08T12:00:00Z")
        let spanning = try XCTUnwrap(ScheduledChallenge(challenge(1, "2026-03-08T06:30:00Z", "2026-03-08T07:30:00Z"))) // 01:30 EST → 03:30 EDT
        XCTAssertTrue(spanning.overlaps(springForward, calendar: calendar))
        XCTAssertFalse(spanning.overlaps(day("2026-03-07T12:00:00Z"), calendar: calendar))
        XCTAssertFalse(spanning.overlaps(day("2026-03-09T12:00:00Z"), calendar: calendar))
        // Ends exactly at local midnight of 9 March (04:00Z after the change): not on the 9th.
        let untilMidnight = try XCTUnwrap(ScheduledChallenge(challenge(2, "2026-03-08T20:00:00Z", "2026-03-09T04:00:00Z")))
        XCTAssertTrue(untilMidnight.overlaps(springForward, calendar: calendar))
        XCTAssertFalse(untilMidnight.overlaps(day("2026-03-09T12:00:00Z"), calendar: calendar))
        // 1 November 2026: 01:00–02:00 EDT repeats; the civil day is 25 hours.
        let fallBack = day("2026-11-01T12:00:00Z")
        let repeated = try XCTUnwrap(ScheduledChallenge(challenge(3, "2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"))) // 01:30 EDT → 01:30 EST
        XCTAssertTrue(repeated.overlaps(fallBack, calendar: calendar))
        XCTAssertFalse(repeated.overlaps(day("2026-10-31T12:00:00Z"), calendar: calendar))
        let lateEvening = try XCTUnwrap(ScheduledChallenge(challenge(4, "2026-11-02T04:30:00Z", nil))) // 23:30 EST on 1 Nov
        XCTAssertTrue(lateEvening.overlaps(fallBack, calendar: calendar))
        XCTAssertFalse(lateEvening.overlaps(day("2026-11-02T12:00:00Z"), calendar: calendar))
        XCTAssertNil(ScheduledChallenge(challenge(5, "2026-11-01T06:30:00Z", "2026-11-01T05:30:00Z")), "End before start accepted")
        XCTAssertNil(ScheduledChallenge(challenge(6, "2026-11-01T06:30:00Z", "not a date")), "Malformed end accepted")
        XCTAssertEqual(ChallengeScheduleCache.monthKey(springForward, calendar: calendar), "2026-03")
    }

    func testWrongCallbackAndDeletionRequestsNeverDeleteFromTheClient() async throws {
        let unauthenticated = AuthService()
        do {
            try await unauthenticated.handleOAuthCallback(url: URL(string: "https://attacker.invalid/auth/callback?code=fixture")!)
            XCTFail("Wrong callback accepted")
        } catch AuthService.AuthError.invalidCallback { }
        do {
            _ = try await unauthenticated.requestAccountDeletion()
            XCTFail("Deletion request without an account claimed success")
        } catch AuthService.AuthError.notAuthenticated { }
        XCTAssertNil(unauthenticated.currentUser)

        // Signed in: the client only files, reads and cancels a server request (#262).
        let (service, model, transport, _, _) = try await profileFixture()
        defer { transport.invalidateAndCancel() }
        AuthFixtureTransport.resetLifecycle()
        let initialDeletionStatus = try await service.accountDeletionStatus()
        XCTAssertNil(initialDeletionStatus, "No request yet must read as nil, not as a state")
        await model.requestAccountDeletion()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.accountDeletion?.state, .pending)
        XCTAssertEqual(model.accountDeletion?.revision, 1)
        XCTAssertEqual(model.accountDeletion?.scheduledFor, ISO8601DateFormatter().date(from: "2026-10-20T01:00:00Z"))
        XCTAssertEqual(model.notice, "Account deletion is scheduled for 2026-10-20 01:00 UTC. Cancel before then to keep the account. Projects on this device are untouched; subscriptions must be cancelled through the App Store or billing portal.")
        let pendingDeletionStatus = try await service.accountDeletionStatus()
        XCTAssertEqual(pendingDeletionStatus?.state, .pending)
        await model.cancelAccountDeletion()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.accountDeletion?.state, .cancelled)
        XCTAssertEqual(AuthFixtureTransport.lifecycleActions, ["status", "request_deletion", "status", "cancel_deletion"])
        XCTAssertEqual(AuthFixtureTransport.lifecycleCancelRevision, 1)
        // A server refusal is reported verbatim and changes nothing locally.
        AuthFixtureTransport.lifecycleRefusal = "Administrator accounts use the separate owner procedure."
        await model.requestAccountDeletion()
        XCTAssertEqual(model.error, "Administrator accounts use the separate owner procedure.")
        XCTAssertEqual(model.accountDeletion?.state, .cancelled)
        XCTAssertNil(AuthFixtureTransport.deletionRow, "A refused request must not have been stored")
        XCTAssertNotNil(service.currentUser, "Deletion flows must not sign the account out or delete anything client-side")
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
    private static var lifecycleLog: [String] = []
    private static var lifecycleRefusalText: String?
    private static var lifecycleCancelledRevision: Int?
    private static var lifecycleRow: [String: Any]?
    static var lifecycleActions: [String] { gate.lock(); defer { gate.unlock() }; return lifecycleLog }
    static var lifecycleCancelRevision: Int? { gate.lock(); defer { gate.unlock() }; return lifecycleCancelledRevision }
    static var deletionRow: [String: Any]? { gate.lock(); defer { gate.unlock() }; return lifecycleRow }
    static var lifecycleRefusal: String? {
        get { gate.lock(); defer { gate.unlock() }; return lifecycleRefusalText }
        set { gate.lock(); defer { gate.unlock() }; lifecycleRefusalText = newValue }
    }
    static func resetLifecycle() {
        gate.lock(); defer { gate.unlock() }
        lifecycleLog = []; lifecycleRefusalText = nil; lifecycleCancelledRevision = nil; lifecycleRow = nil
    }
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
        if url.path.hasSuffix("/rpc/sdi_account_lifecycle") {
            let fields = (try? JSONSerialization.jsonObject(with: requestBody())) as? [String: Any] ?? [:]
            let action = fields["action"] as? String ?? ""
            Self.gate.lock(); defer { Self.gate.unlock() }
            Self.lifecycleLog.append(action)
            if let refusal = Self.lifecycleRefusalText { respond(200, ["error": refusal]); return }
            switch action {
            case "status":
                respond(200, ["deletion": Self.lifecycleRow.map { $0 as Any } ?? NSNull(), "exports_remaining_today": 3, "note": "fixture"])
            case "request_deletion":
                // Postgres timestamptz text carries microseconds; the client must parse it.
                let row: [String: Any] = ["state": "pending", "scheduled_for": "2026-10-20T01:00:00.000000+00:00", "revision": 1, "requested_at": "2026-10-13T01:00:00+00:00"]
                Self.lifecycleRow = row
                respond(200, ["status": "pending", "scheduled_for": row["scheduled_for"]!, "revision": 1])
            case "cancel_deletion":
                Self.lifecycleCancelledRevision = fields["revision"] as? Int
                guard let row = Self.lifecycleRow, row["state"] as? String == "pending", row["revision"] as? Int == Self.lifecycleCancelledRevision else {
                    respond(200, ["error": "No pending deletion request can be cancelled."]); return
                }
                Self.lifecycleRow = nil
                respond(200, ["status": "cancelled"])
            default:
                respond(200, ["error": "Unsupported account operation."])
            }
            return
        }
        if url.path.hasSuffix("/logout") || url.path.hasSuffix("/recover") {
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
        if url.path.hasSuffix("/token"),
           URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "grant_type" })?.value == "pkce" {
            // No authorization codes/verifier pairs are issued by this fixture.
            // The SDK submits an exchange even when its verifier is absent;
            // emulate the server's rejection instead of minting a test session.
            respond(400, ["code": "bad_code_verifier", "msg": "Fixture PKCE grant was not issued"])
            return
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
