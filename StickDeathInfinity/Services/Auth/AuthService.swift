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

    private let supabase = SupabaseManager.shared.client
    private var appleSignInDelegate: AppleSignInDelegate?

    enum AuthState: Equatable {
        case loading, unauthenticated, authenticated
    }

    var userId: String? { currentUser?.id.uuidString }
    var isAuthenticated: Bool { state == .authenticated }
    var isSuperAdmin: Bool {
        return false
    }
    var displayName: String? { currentProfile?.username }
    var avatarUrl: String? { currentProfile?.avatarURL }

    // MARK: - Initialize (call on app start)
    func initialize() async {
        state = .loading
        do {
            let session = try await supabase.auth.session
            currentUser = session.user
            await fetchProfile(userId: session.user.id.uuidString)
            state = .authenticated
        } catch {
            state = .unauthenticated
        }

        // Listen for auth state changes
        Task {
            for await (event, session) in supabase.auth.authStateChanges {
                switch event {
                case .signedIn:
                    if let user = session?.user {
                        currentUser = user
                        await fetchProfile(userId: user.id.uuidString)
                        state = .authenticated
                    }
                case .signedOut:
                    currentUser = nil
                    currentProfile = nil
                    state = .unauthenticated
                default:
                    break
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Sign In with Apple (Native ASAuthorizationController)
    // ═══════════════════════════════════════════════════════════════

    /// Initiates native Apple Sign In flow using ASAuthorizationController.
    /// Generates a nonce, presents the Apple UI, then exchanges the
    /// Apple ID credential with Supabase for a session.
    func signInWithApple() async throws {
        let nonce = generateNonce()
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
                    Task { @MainActor in
                        try await self?.exchangeAppleToken(idToken: idToken, nonce: nonce)
                    }
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
        currentUser = session.user
        let email = session.user.email
        let username = email?.components(separatedBy: "@").first ?? "AppleUser"
        await ensureProfile(userId: session.user.id.uuidString, email: email, username: username)
        await fetchProfile(userId: session.user.id.uuidString)
        state = .authenticated
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Sign In with Google (GoogleSignIn SDK)
    // ═══════════════════════════════════════════════════════════════

    /// Initiates Google Sign In flow.
    /// Uses GoogleSignIn SDK to get ID token, then exchanges with Supabase.
    /// Requires GoogleSignIn SPM package + GIDClientID in Info.plist.
    func signInWithGoogle() async throws {
        // Build the OAuth URL and open it in Safari.
        // When the user finishes, the app receives the redirect via URL scheme
        // and handleOAuthCallback() completes the sign-in.
        let url = try supabase.auth.getOAuthSignInURL(
            provider: .google,
            redirectTo: URL(string: "stickdeath://auth/callback")
        )
        await UIApplication.shared.open(url)
    }

    /// Handle the OAuth callback URL (call from SceneDelegate/AppDelegate)
    func handleOAuthCallback(url: URL) async throws {
        let session = try await supabase.auth.session(from: url)
        currentUser = session.user
        let email = session.user.email
        let username = email?.components(separatedBy: "@").first ?? "GoogleUser"
        await ensureProfile(userId: session.user.id.uuidString, email: email, username: username)
        await fetchProfile(userId: session.user.id.uuidString)
        state = .authenticated
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Email/Password Auth
    // ═══════════════════════════════════════════════════════════════

    func signUp(email: String, password: String, username: String) async throws {
        let result = try await supabase.auth.signUp(
            email: email,
            password: password,
            data: ["username": .string(username)]
        )
        if let session = result.session {
            currentUser = session.user
            await ensureProfile(userId: session.user.id.uuidString, email: email, username: username)
            await fetchProfile(userId: session.user.id.uuidString)
            state = .authenticated
        }
    }

    func signIn(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(
            email: email,
            password: password
        )
        currentUser = session.user
        await fetchProfile(userId: session.user.id.uuidString)
        state = .authenticated
    }

    // MARK: - Guest
    func signInAsGuest() async throws {
        let session = try await supabase.auth.signInAnonymously()
        currentUser = session.user
        let guestUsername = "Guest_\(session.user.id.uuidString.prefix(6))"
        await ensureProfile(userId: session.user.id.uuidString, email: nil, username: guestUsername)
        await fetchProfile(userId: session.user.id.uuidString)
        state = .authenticated
    }

    // MARK: - Sign Out
    func signOut() async throws {
        try await supabase.auth.signOut()
        currentUser = nil
        currentProfile = nil
        state = .unauthenticated
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
        guard let userId else { throw AuthError.notAuthenticated }
        try await supabase.from("users").delete().eq("id", value: userId).execute()
        try await signOut()
    }

    func resetPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Private Helpers
    // ═══════════════════════════════════════════════════════════════

    private func fetchProfile(userId: String) async {
        do {
            let profile: UserProfile = try await supabase
                .from("users")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            currentProfile = profile
        } catch {
            print("[AuthService] fetchProfile error: \(error)")
        }
    }

    private func ensureProfile(userId: String, email: String?, username: String) async {
        let role = "user"
        do {
            try await supabase.from("users").upsert([
                "id": AnyJSON.string(userId),
                "email": email.map { AnyJSON.string($0) } ?? .null,
                "username": .string(username),
                "role": .string(role),
                "created_at": .string(ISO8601DateFormatter().string(from: Date()))
            ]).execute()
        } catch {
            print("[AuthService] ensureProfile error: \(error)")
        }
    }

    // MARK: - Apple Sign In Helpers

    /// Generate a random nonce for Apple Sign In
    private func generateNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var random: UInt8 = 0
                let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if errorCode != errSecSuccess {
                    fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
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
        case notAuthenticated
        case noPresentingViewController
        case appleSignInFailed(String)
        case googleSignInFailed(String)

        var errorDescription: String? {
            switch self {
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
