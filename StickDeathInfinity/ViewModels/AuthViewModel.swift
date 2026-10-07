// ═══════════════════════════════════════════════════════════════════
// AuthViewModel — Auth state for SwiftUI views
// Matches: src/contexts/AuthContext.tsx useAuth()
//
// Handles: Email/Password, Apple, Google, Guest, Sign Out
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import Combine

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var state: AuthService.AuthState = .loading
    @Published var user: UserProfile?
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var restoration: AuthService.Restoration = .restoring

    private let auth: AuthService
    private var subscriptions = Set<AnyCancellable>()

    var isAuthenticated: Bool { state == .authenticated }
    var isSuperAdmin: Bool { auth.isSuperAdmin }
    var userId: String? { auth.userId }
    var displayName: String? { auth.displayName }

    init(auth: AuthService? = nil, initializeOnStart: Bool = true) {
        let auth = auth ?? .shared
        self.auth = auth
        auth.$restoration.sink { [weak self] in self?.restoration = $0 }.store(in: &subscriptions)
        auth.$state.sink { [weak self] in self?.state = $0 }.store(in: &subscriptions)
        auth.$currentProfile.sink { [weak self] in self?.user = $0 }.store(in: &subscriptions)
        auth.$currentUser.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        auth.$configurationError.sink { [weak self] value in
            if let value { self?.error = value }
        }.store(in: &subscriptions)
        if initializeOnStart { Task { await initialize() } }
    }

    func initialize() async {
        await auth.initialize()
        state = auth.state
        user = auth.currentProfile
        error = auth.configurationError
    }

    func retryRestoration() async { await auth.retryRestoration() }

    // MARK: - Email/Password

    @discardableResult
    func signIn(email: String, password: String) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await auth.signIn(email: email, password: password)
            state = auth.state
            user = auth.currentProfile
            return auth.state == .authenticated
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func signUp(email: String, password: String, username: String) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let completed = try await auth.signUp(email: email, password: password, username: username)
            state = auth.state
            user = auth.currentProfile
            return completed && auth.state == .authenticated
        } catch {
            self.error = error.localizedDescription
            return false
        }
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

    @discardableResult
    func signInWithApple() async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await auth.signInWithApple()
            state = auth.state
            user = auth.currentProfile
            return auth.state == .authenticated
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Google Sign In (Supabase OAuth flow)

    func providerUnavailableReason(_ provider: AppConfig.OAuthProvider) -> String? { auth.providerUnavailableReason(provider) }
    @discardableResult
    func signInWithGoogle() async -> Bool { await signIn(provider: .google) }
    @discardableResult
    func signIn(provider: AppConfig.OAuthProvider, launch: AuthService.OAuthLaunch? = nil) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            try await auth.signIn(provider: provider, launch: launch)
            return auth.state == .authenticated
        }
        catch is CancellationError { error = "Sign-in was cancelled." }
        catch { self.error = error.localizedDescription }
        return false
    }
    func rejectUnsolicitedOAuthCallback() { error = "This sign-in link has expired or was not requested. Start sign-in again." }

    // MARK: - Sign Out

    func signOut() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { try await auth.signOut() }
        catch { self.error = error.localizedDescription }
        state = auth.state
        user = auth.currentProfile
    }

    // MARK: - Onboarding

    func completeOnboarding(skillLevel: String, interests: [String]) async {
        try? await auth.completeOnboarding(skillLevel: skillLevel, interests: interests)
        user = auth.currentProfile
    }
}
