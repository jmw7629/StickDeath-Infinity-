// ═══════════════════════════════════════════════════════════════════
// AuthService — Full Auth Architecture
// Matches: src/services/AuthManager.ts + Supabase OAuth
//
// Sign In with Apple: Native ASAuthorizationController → Supabase
// Sign In with Google: GoogleSignIn SDK → Supabase
// Email/Password: Direct Supabase Auth
// Guest: Anonymous Supabase session
// ═══════════════════════════════════════════════════════════════════

import Foundation
import SwiftUI
import Supabase
import AuthenticationServices
import CryptoKit

// MARK: - AuthService

@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var state: AuthState = .loading
    @Published var currentUser: User?
    @Published var currentProfile: UserProfile?
    @Published private(set) var configurationError: String?

    private let injectedClient: SupabaseClient?
    private let injectedOAuthConfiguration: AppConfig.OAuthConfiguration?
    init(client: SupabaseClient? = nil, oauthConfiguration: AppConfig.OAuthConfiguration? = nil) {
        injectedClient = client; injectedOAuthConfiguration = oauthConfiguration
    }
    private var supabase: SupabaseClient {
        get throws { if let injectedClient { return injectedClient }; return try SupabaseManager.shared.client }
    }
    private var identityRevision = UUID()
    private var initialized = false
    private var authenticationInProgress = false
    private var profileTask: Task<Void, Never>?

    private func beginAuthentication() throws {
        guard !authenticationInProgress else { throw AuthError.operationInProgress }
        authenticationInProgress = true
    }
    private func setIdentity(_ user: User?) {
        profileTask?.cancel()
        profileTask = nil
        identityRevision = UUID()
        if currentUser?.id != user?.id || user == nil { currentProfile = nil }
        currentUser = user
        if user == nil { state = .unauthenticated }
    }
    private func finishAuthentication(_ user: User, ensureUsername: String? = nil) async throws {
        guard let live = try supabase.auth.currentSession?.user, live.id == user.id else { throw CancellationError() }
        if currentUser?.id != live.id { setIdentity(live) } else { currentUser = live }
        // A direct operation owns its profile fetch; the event observer must
        // never race a second fetch or wait for this network request.
        profileTask?.cancel(); profileTask = nil
        let revision = identityRevision
        if let ensureUsername { await ensureProfile(userId: user.id.uuidString, email: user.email, username: ensureUsername) }
        guard revision == identityRevision, currentUser?.id == user.id,
              try supabase.auth.currentSession?.user.id == user.id else { throw CancellationError() }
        await fetchProfile(userId: user.id.uuidString)
        guard revision == identityRevision, currentUser?.id == user.id,
              try supabase.auth.currentSession?.user.id == user.id else { throw CancellationError() }
        state = .authenticated
    }
    private var appleSignInDelegate: AppleSignInDelegate?
    private var authStateTask: Task<Void, Never>?

    enum AuthState: Equatable {
        case loading, unauthenticated, authenticated
    }

    var userId: String? { currentUser?.id.uuidString }
    var isAuthenticated: Bool { state == .authenticated }
    var isSuperAdmin: Bool {
        // Display hint only: server app metadata, never editable profile/email data.
        // Backend/RLS authorization must still enforce every privileged operation.
        return isAuthenticated && currentUser?.appMetadata["role"] == .string("superadmin")
    }
    var displayName: String? { currentProfile?.username }
    var avatarUrl: String? { currentProfile?.avatarURL }

    // MARK: - Initialize (call on app start)
    func initialize() async {
        guard !initialized else { return }
        initialized = true
        state = .loading
        configurationError = nil
        authStateTask?.cancel()
        authStateTask = nil
        let supabase: SupabaseClient
        do {
            supabase = try self.supabase
        } catch {
            setIdentity(nil)
            configurationError = error.localizedDescription
            state = .unauthenticated
            return
        }
        do {
            let session = try await supabase.auth.session
            try await finishAuthentication(session.user)
        } catch {
            reconcileAuthStateChange(.initialSession)
        }

        // The SDK event queue is only a notification. Its payload may be older
        // than a completed direct sign-in/sign-out. Always reconcile current SDK
        // state, and never hold this queue behind profile network requests.
        authStateTask = Task {
            for await (event, _) in supabase.auth.authStateChanges {
                guard !Task.isCancelled else { return }
                reconcileAuthStateChange(event)
            }
        }
    }

    /// Internal so native tests can deterministically replay a delayed SDK
    /// notification against the actual SDK session, without a mirrored model.
    func reconcileAuthStateChange(_ event: AuthChangeEvent) {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated, .signedOut, .userDeleted:
            guard let client = try? supabase else { setIdentity(nil); return }
            guard let live = client.auth.currentSession?.user else {
                setIdentity(nil)
                return
            }
            let changed = currentUser?.id != live.id
            if changed { setIdentity(live) } else { currentUser = live }
            state = .authenticated
            if changed {
                profileTask = Task { [weak self] in
                    await self?.fetchProfile(userId: live.id.uuidString)
                }
            }
        default: break
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Sign In with Apple (Native ASAuthorizationController)
    // ═══════════════════════════════════════════════════════════════

    /// Initiates native Apple Sign In flow using ASAuthorizationController.
    /// Generates a nonce, presents the Apple UI, then exchanges the
    /// Apple ID credential with Supabase for a session.
    func signInWithApple() async throws {
        try beginAuthentication()
        defer { authenticationInProgress = false; appleSignInDelegate = nil }
        // Report missing backend configuration before presenting external auth UI.
        _ = try supabase
        let nonce = try generateNonce()
        let hashedNonce = sha256(nonce)

        return try await withCheckedThrowingContinuation { continuation in
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = hashedNonce

            let delegate = AppleSignInDelegate(
                nonce: nonce,
                continuation: continuation,
                onCredential: { [weak self] idToken, nonce in
                    guard let self else { throw CancellationError() }
                    try await self.exchangeAppleToken(idToken: idToken, nonce: nonce)
                }
            )
            self.appleSignInDelegate = delegate

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = delegate

            // Get the presentation anchor from the key window
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                let contextProvider = AppleSignInContextProvider(anchor: window)
                controller.presentationContextProvider = contextProvider
                delegate.contextProvider = contextProvider
            }

            controller.performRequests()
        }
    }

    /// Exchange Apple ID token with Supabase
    private func exchangeAppleToken(idToken: String, nonce: String) async throws {
        let session = try await supabase.auth.signInWithIdToken(
            credentials: .init(
                provider: .apple,
                idToken: idToken,
                nonce: nonce
            )
        )
        let username = session.user.email?.components(separatedBy: "@").first ?? "AppleUser"
        try await finishAuthentication(session.user, ensureUsername: username)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Sign In with Google (GoogleSignIn SDK)
    // ═══════════════════════════════════════════════════════════════

    typealias OAuthProvider = AppConfig.OAuthProvider
    typealias OAuthLaunch = @MainActor @Sendable (URL) async throws -> URL
    private static let oauthRedirect = URL(string: "stickdeath://auth/callback")!
    private var webAuthentication: OAuthBrowserSession?

    func providerUnavailableReason(_ provider: OAuthProvider) -> String? {
        guard (injectedOAuthConfiguration ?? AppConfig.oauthConfiguration).enabledProviders.contains(provider) else {
            return "\(provider.title) sign-in is not configured for this build."
        }
        guard (try? supabase) != nil else { return "Account sign-in is not configured for this build." }
        return nil
    }
    func signInWithGoogle() async throws { try await signIn(provider: .google) }
    func signInWithGitHub() async throws { try await signIn(provider: .github) }
    func signInWithMicrosoft() async throws { try await signIn(provider: .microsoft) }

    /// Uses the existing Supabase PKCE verifier and server user UUID; never
    /// merges accounts by email, username or a browser-provided identity claim.
    func signIn(provider: OAuthProvider, launch: OAuthLaunch? = nil) async throws {
        if let reason = providerUnavailableReason(provider) { throw AuthError.providerUnavailable(reason) }
        try beginAuthentication()
        defer { authenticationInProgress = false; webAuthentication = nil }
        let client = try supabase
        let sdkProvider: Provider
        let scopes: String
        switch provider {
        case .google: sdkProvider = .google; scopes = "openid email profile"
        case .github: sdkProvider = .github; scopes = "read:user user:email"
        case .microsoft: sdkProvider = .azure; scopes = "openid email profile"
        }
        let result = try await client.auth.signInWithOAuth(provider: sdkProvider,
            redirectTo: Self.oauthRedirect, scopes: scopes, launchFlow: { [weak self] url in
                guard let self else { throw CancellationError() }
                let callback: URL
                if let launch { callback = try await launch(url) }
                else {
                    let browser = OAuthBrowserSession()
                    self.webAuthentication = browser
                    callback = try await browser.open(url, callbackScheme: "stickdeath")
                }
                try Task.checkCancellation()
                guard Self.isExpectedOAuthCallback(callback) else { throw AuthError.invalidCallback }
                return callback
            })
        try Task.checkCancellation()
        let username = "Creator_" + result.user.id.uuidString.prefix(8)
        try await finishAuthentication(result.user, ensureUsername: String(username))
    }
    private static func isExpectedOAuthCallback(_ url: URL) -> Bool {
        guard url.scheme == "stickdeath", url.host == "auth", url.path == "/callback",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let codes = components.queryItems?.filter { $0.name == "code" } ?? []
        // Denied/expired exchanges surface as errors; implicit access-token
        // fragments and duplicate codes are never accepted by this PKCE path.
        return codes.count == 1 && !(codes[0].value ?? "").isEmpty
    }
    /// ASWebAuthenticationSession owns completion. Unsolicited deep links and
    /// replayed callbacks cannot perform an independent credential exchange.
    func handleOAuthCallback(url: URL) async throws { throw AuthError.invalidCallback }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Email/Password Auth
    // ═══════════════════════════════════════════════════════════════

    @discardableResult
    func signUp(email: String, password: String, username: String) async throws -> Bool {
        try beginAuthentication()
        defer { authenticationInProgress = false }
        let result = try await supabase.auth.signUp(
            email: email,
            password: password,
            data: ["username": .string(username)]
        )
        if let session = result.session {
            try await finishAuthentication(session.user, ensureUsername: username)
            return true
        }
        return false // Email confirmation pending; an older session is not this attempt.
    }

    func signIn(email: String, password: String) async throws {
        try beginAuthentication()
        defer { authenticationInProgress = false }
        let session = try await supabase.auth.signIn(
            email: email,
            password: password
        )
        try await finishAuthentication(session.user)
    }

    // MARK: - Guest
    func signInAsGuest() async throws {
        try beginAuthentication()
        defer { authenticationInProgress = false }
        let session = try await supabase.auth.signInAnonymously()
        let guestUsername = "Guest_\(session.user.id.uuidString.prefix(6))"
        try await finishAuthentication(session.user, ensureUsername: guestUsername)
    }

    // MARK: - Sign Out
    func signOut() async throws {
        try beginAuthentication()
        defer { authenticationInProgress = false }
        let client = try supabase
        do {
            try await client.auth.signOut()
            setIdentity(nil)
        } catch {
            // The pinned SDK clears local credentials before remote revocation.
            // Reflect that actual local outcome, but do not hide remote failure.
            if client.auth.currentSession == nil { setIdentity(nil) }
            throw error
        }
    }

    // MARK: - Profile Management
    func updateProfile(_ updates: [String: AnyJSON]) async throws {
        guard let userId else { throw AuthError.notAuthenticated }
        try await supabase.from("users").update(updates).eq("id", value: userId).execute()
        await fetchProfile(userId: userId)
    }

    func completeOnboarding(skillLevel: String, interests: [String]) async throws {
        try await updateProfile([
            "onboarded": .bool(true),
            "skill_level": .string(skillLevel),
            "interests": .array(interests.map { .string($0) })
        ])
    }

    func deleteAccount() async throws {
        // Deleting a profile row does not delete the authentication identity,
        // revoke every session, or erase related records. Never claim it does.
        throw AuthError.accountDeletionUnavailable
    }

    func resetPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Private Helpers
    // ═══════════════════════════════════════════════════════════════

    private func fetchProfile(userId: String) async {
        guard !Task.isCancelled, currentUser?.id.uuidString == userId,
              (try? supabase.auth.currentSession?.user.id.uuidString) == userId else { return }
        let revision = identityRevision
        currentProfile = nil
        do {
            let profile: UserProfile = try await supabase
                .from("users")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            guard !Task.isCancelled, revision == identityRevision, currentUser?.id.uuidString == userId,
                  (try? supabase.auth.currentSession?.user.id.uuidString) == userId else { return }
            currentProfile = profile
        } catch {
            guard !Task.isCancelled, revision == identityRevision, currentUser?.id.uuidString == userId,
                  (try? supabase.auth.currentSession?.user.id.uuidString) == userId else { return }
            currentProfile = nil
        }
    }

    private func ensureProfile(userId: String, email: String?, username: String) async {
        do {
            try await supabase.from("users").upsert([
                "id": AnyJSON.string(userId),
                "email": email.map { AnyJSON.string($0) } ?? .null,
                "username": .string(username),
                "created_at": .string(ISO8601DateFormatter().string(from: Date()))
            ], onConflict: "id", ignoreDuplicates: true).execute()
        } catch {
            // Profile availability is separate from authentication. The fenced
            // fetch leaves it unavailable without displaying a prior account.
        }
    }

    // MARK: - Apple Sign In Helpers

    /// Generate a random nonce for Apple Sign In
    private func generateNonce(length: Int = 32) throws -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            let randoms: [UInt8] = try (0..<16).map { _ in
                var random: UInt8 = 0
                let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if errorCode != errSecSuccess {
                    throw AuthError.appleSignInFailed("Secure random generation is unavailable. Try again.")
                }
                return random
            }
            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    /// SHA256 hash for Apple Sign In nonce
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Errors
    enum AuthError: LocalizedError {
        case providerUnavailable(String)
        case operationInProgress, invalidCallback, accountDeletionUnavailable
        case notAuthenticated
        case noPresentingViewController
        case appleSignInFailed(String)
        case googleSignInFailed(String)

        var errorDescription: String? {
            switch self {
            case .providerUnavailable(let reason): return reason
            case .operationInProgress: return "Another sign-in or sign-out is still finishing. Wait before trying again."
            case .invalidCallback: return "This sign-in callback is not for StickDeath Infinity."
            case .accountDeletionUnavailable: return "Account deletion is unavailable until secure identity and data deletion is configured. Your account has not been deleted."
            case .notAuthenticated: return "Not authenticated"
            case .noPresentingViewController: return "No presenting view controller available"
            case .appleSignInFailed(let msg): return "Apple Sign In failed: \(msg)"
            case .googleSignInFailed(let msg): return "Google Sign In failed: \(msg)"
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Apple Sign In Delegate
// ═══════════════════════════════════════════════════════════════════

private class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate {
    let nonce: String
    let continuation: CheckedContinuation<Void, Error>
    let onCredential: (String, String) async throws -> Void
    var contextProvider: AppleSignInContextProvider?

    init(nonce: String,
         continuation: CheckedContinuation<Void, Error>,
         onCredential: @escaping (String, String) async throws -> Void) {
        self.nonce = nonce
        self.continuation = continuation
        self.onCredential = onCredential
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let idTokenData = appleIDCredential.identityToken,
              let idToken = String(data: idTokenData, encoding: .utf8) else {
            continuation.resume(throwing: AuthService.AuthError.appleSignInFailed("Missing ID token"))
            return
        }

        Task {
            do {
                try await onCredential(idToken, nonce)
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        continuation.resume(throwing: AuthService.AuthError.appleSignInFailed(error.localizedDescription))
    }
}

// MARK: - Apple Sign In Context Provider
private class AppleSignInContextProvider: NSObject, ASAuthorizationControllerPresentationContextProviding {
    let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor
    }
}

/// Main-actor-owned browser lifetime, one terminal result, real cancellation.
@MainActor private final class OAuthBrowserSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var anchor: ASPresentationAnchor?
    func open(_ url: URL, callbackScheme: String) async throws -> URL {
        try Task.checkCancellation()
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw AuthService.AuthError.noPresentingViewController
        }
        anchor = window
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
                    Task { @MainActor in
                        if let error { self?.finish(.failure(error)) }
                        else if let url { self?.finish(.success(url)) }
                        else { self?.finish(.failure(AuthService.AuthError.invalidCallback)) }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() { finish(.failure(AuthService.AuthError.noPresentingViewController)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.session?.cancel()
                self?.finish(.failure(CancellationError()))
            }
        }
    }
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil; session = nil
        continuation.resume(with: result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
