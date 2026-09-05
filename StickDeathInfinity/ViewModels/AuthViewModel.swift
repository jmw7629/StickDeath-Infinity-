// ═══════════════════════════════════════════════════════════════════
// AuthViewModel — Auth state for SwiftUI views
// Matches: src/contexts/AuthContext.tsx useAuth()
//
// Handles: Email/Password, Apple, Google, Guest, Sign Out
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var state: AuthService.AuthState = .loading
    @Published var user: UserProfile?
    @Published var isLoading = false
    @Published var error: String?

    private let auth = AuthService.shared

    var isAuthenticated: Bool { state == .authenticated }
    var userId: String? { auth.userId }
    var displayName: String? { auth.displayName }

    init() {
        Task { await initialize() }
    }

    func initialize() async {
        await auth.initialize()
        state = auth.state
        user = auth.currentProfile
    }

    // MARK: - Email/Password

    func signIn(email: String, password: String) async {
        isLoading = true
        error = nil
        do {
            try await auth.signIn(email: email, password: password)
            state = auth.state
            user = auth.currentProfile
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func signUp(email: String, password: String, username: String) async {
        isLoading = true
        error = nil
        do {
            try await auth.signUp(email: email, password: password, username: username)
            state = auth.state
            user = auth.currentProfile
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Guest

    func signInAsGuest() async throws {
        isLoading = true
        error = nil
        do {
            try await auth.signInAsGuest()
            state = auth.state
            user = auth.currentProfile
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            throw error
        }
        isLoading = false
    }

    // MARK: - Apple Sign In (Full native flow)

    func signInWithApple() async {
        isLoading = true
        error = nil
        do {
            try await auth.signInWithApple()
            state = auth.state
            user = auth.currentProfile
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Google Sign In (Supabase OAuth flow)

    func signInWithGoogle() async {
        isLoading = true
        error = nil
        do {
            try await auth.signInWithGoogle()
            // Auth state listener will update when redirect completes
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Sign Out

    func signOut() async {
        try? await auth.signOut()
        state = .unauthenticated
        user = nil
    }

    // MARK: - Onboarding

    func completeOnboarding(skillLevel: String, interests: [String]) async {
        try? await auth.completeOnboarding(skillLevel: skillLevel, interests: interests)
        user = auth.currentProfile
    }
}
