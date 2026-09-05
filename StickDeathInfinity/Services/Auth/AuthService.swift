// ═══════════════════════════════════════════════════════════════════
// AuthService — Full Auth Architecture
// Matches: src/services/AuthManager.ts + Supabase OAuth
//
// Sign In with Apple: Native ASAuthorizationController -> Supabase
// Sign In with Google: GoogleSignIn SDK -> Supabase
// Email/Password: Direct Supabase Auth
// Guest: Anonymous Supabase session
//
// Admin authority comes from server claims only.
// No client-local email allowlist.
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
    var displayName: String? { currentProfile?.username }
    var avatarUrl: String? { currentProfile?.avatarURL }

    func fetchSessionToken() async -> String? {
        guard let session = try? await supabase.auth.session else { return nil }
        return session.accessToken
    }

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

    // MARK: - Fetch Profile
    func fetchProfile(userId: String) async {
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
            print("[Auth] Profile fetch error: \(error)")
        }
    }

    // MARK: - Email/Password
    func signIn(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(email: email, password: password)
        currentUser = session.user
        await fetchProfile(userId: session.user.id.uuidString)
        state = .authenticated
    }

    func signUp(email: String, password: String, username: String) async throws {
        let session = try await supabase.auth.signUp(email: email, password: password)
        currentUser = session.user
        // Create profile
        try await supabase.from("users").insert([
            "id": AnyJSON.string(session.user.id.uuidString),
            "username": .string(username),
            "email": .string(email),
        ]).execute()
        await fetchProfile(userId: session.user.id.uuidString)
        state = .authenticated
    }

    // MARK: - Guest
    func signInAsGuest() async throws {
        let session = try await supabase.auth.signInAnonymously()
        currentUser = session.user
        state = .authenticated
    }

    // MARK: - Apple Sign In
    func signInWithApple() async throws {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let delegate = AppleSignInDelegate()
        appleSignInDelegate = delegate

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = delegate
        controller.performRequests()

        // Wait for delegate callback (simplified for this architecture)
        // In production, use a continuation
        if let credential = delegate.credential {
            let session = try await supabase.auth.signIn(
                oidcCredential: OpenIDConnectCredentials(
                    providerToken: credential.identityToken.flatMap { String(data: $0, encoding: .utf8) },
                    idToken: credential.identityToken.flatMap { String(data: $0, encoding: .utf8) }
                )
            )
            currentUser = session.user
            await fetchProfile(userId: session.user.id.uuidString)
            state = .authenticated
        }
    }

    // MARK: - Google Sign In
    func signInWithGoogle() async throws {
        try await supabase.auth.signIn(provider: .google)
    }

    // MARK: - Sign Out
    func signOut() async throws {
        try await supabase.auth.signOut()
        currentUser = nil
        currentProfile = nil
        state = .unauthenticated
    }

    // MARK: - Onboarding
    func completeOnboarding(skillLevel: String, interests: [String]) async throws {
        guard let userId else { return }
        try await supabase.from("users").update([
            "skill_level": .string(skillLevel),
            "interests": .string(int interests.joined(separator: ",")),
            "onboarded": .boolean(true),
        ]).eq("id", value: userId).execute()
        await fetchProfile(userId: userId)
    }
}

// MARK: - Apple Sign In Delegate
@MainActor
class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate {
    var credential: ASAuthorizationAppleIDCredential?

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            self.credential = appleIDCredential
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        print("[Auth] Apple Sign In error: \(error)")
    }
}
