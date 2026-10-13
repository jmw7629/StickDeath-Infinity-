// ═══════════════════════════════════════════════════════════════════
// AuthViewModel — Auth state for SwiftUI views
//
// Handles: Email/Password, Apple, Google/GitHub/Microsoft, Guest, Sign Out,
// password recovery, deep-link classification and account notices.
// Sign-out closes the open Studio project back to the library (#172); it
// never deletes anything on the device.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import Combine

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var state: AuthService.AuthState = .loading
    @Published var user: UserProfile?
    @Published var isLoading = false
    @Published var error: String?
    /// Non-failure information (sign-up confirmation pending, taken username,
    /// unsupported link). Shown as a dismissible notice, never as an error.
    @Published var notice: String?
    @Published private(set) var restoration: AuthService.Restoration = .restoring
    @Published private(set) var passwordRecoveryPending = false
    /// Earliest time another reset email may be requested (60 s cooldown).
    @Published private(set) var passwordResetAvailableAt: Date?

    private let auth: AuthService
    private var subscriptions = Set<AnyCancellable>()
    static let passwordResetCooldown: TimeInterval = 60
    /// Studio hand-offs around sign-out. The defaults use the shared editor's
    /// own flush/save and back-to-library paths, so no edit is discarded and no
    /// file is deleted; tests inject counters instead of touching the editor.
    private let flushOpenProject: @MainActor () async -> Void
    private let closeOpenProject: @MainActor () async -> Void

    var isAuthenticated: Bool { state == .authenticated }
    var isSuperAdmin: Bool { auth.isSuperAdmin }
    var userId: String? { auth.userId }
    var displayName: String? { auth.displayName }
    var microsoftTenant: String? { auth.microsoftTenant }
    var appleSignInUnavailableReason: String? { auth.appleSignInUnavailableReason }

    init(auth: AuthService? = nil, initializeOnStart: Bool = true,
         flushOpenProject: @escaping @MainActor () async -> Void = { await StudioViewModel.shared.flush() },
         closeOpenProject: @escaping @MainActor () async -> Void = { await StudioViewModel.shared.backToProjects() }) {
        let auth = auth ?? .shared
        self.auth = auth
        self.flushOpenProject = flushOpenProject
        self.closeOpenProject = closeOpenProject
        auth.$restoration.sink { [weak self] in self?.restoration = $0 }.store(in: &subscriptions)
        auth.$state.sink { [weak self] in self?.state = $0 }.store(in: &subscriptions)
        auth.$currentProfile.sink { [weak self] in self?.user = $0 }.store(in: &subscriptions)
        auth.$currentUser.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        auth.$passwordRecoveryPending.sink { [weak self] in self?.passwordRecoveryPending = $0 }.store(in: &subscriptions)
        auth.$profileNotice.sink { [weak self] value in
            if let value { self?.notice = value }
        }.store(in: &subscriptions)
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

    func captureProfileEdit() -> AuthService.ProfileEditCapture? { auth.captureProfileEdit() }

    @discardableResult
    func saveProfile(username: String, bio: String, capture: AuthService.ProfileEditCapture) async throws -> Bool {
        try await auth.saveProfile(username: username, bio: bio, capture: capture)
        return true
    }

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
            if !completed {
                // The server created the account but returned no session: the
                // address must be confirmed first. This is not a failure.
                notice = "Check your email to confirm your account, then sign in."
            }
            return completed && auth.state == .authenticated
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Neutral by design: the same confirmation is shown whether or not an
    /// account exists, so this screen cannot be used to enumerate addresses.
    @discardableResult
    func requestPasswordReset(email: String) async -> Bool {
        guard !isLoading else { return false }
        if let availableAt = passwordResetAvailableAt, availableAt > Date() {
            let seconds = Int(availableAt.timeIntervalSinceNow.rounded(.up))
            notice = "Wait \(seconds) s before requesting another reset email."
            return false
        }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            try await auth.resetPassword(email: email)
            passwordResetAvailableAt = Date().addingTimeInterval(Self.passwordResetCooldown)
            notice = "If an account exists for that email, a password reset link has been sent. Open it on this device."
            return true
        } catch AuthService.AuthError.invalidEmail {
            self.error = AuthService.AuthError.invalidEmail.localizedDescription
            return false
        } catch {
            // Do not reveal whether the address is registered; a transport
            // failure still starts the cooldown so the button cannot be hammered.
            passwordResetAvailableAt = Date().addingTimeInterval(Self.passwordResetCooldown)
            notice = "If an account exists for that email, a password reset link has been sent. Open it on this device."
            return false
        }
    }

    @discardableResult
    func updatePassword(_ password: String) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            try await auth.updatePassword(password)
            notice = "Your password was updated."
            return true
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
        }
        catch is CancellationError { error = nil } // Closed sheet: no banner.
        catch { self.error = error.localizedDescription }
        return false
    }

    // MARK: - Google / GitHub / Microsoft (Supabase OAuth flow)

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
        catch is CancellationError { error = nil } // Closed browser sheet: no banner.
        catch { self.error = error.localizedDescription }
        return false
    }
    func rejectUnsolicitedOAuthCallback() { error = "This sign-in link has expired or was not requested. Start sign-in again." }

    /// Classifies first, acts second. Only a recovery link can perform work, and
    /// only through the SDK verifier stored by this device's own reset request.
    func handleDeepLink(_ url: URL) async {
        switch DeepLinkRouter.route(url) {
        case .authCallback:
            rejectUnsolicitedOAuthCallback()
        case .passwordReset:
            guard !isLoading else { return }
            isLoading = true; error = nil
            defer { isLoading = false }
            do {
                try await auth.completePasswordRecovery(url: url)
                notice = "Set a new password to finish recovering your account."
            } catch {
                self.error = "This password reset link could not be used on this device. Request a new link from Forgot Password."
            }
        case .unsupported:
            notice = "Unsupported link. StickDeath Infinity only opens its own sign-in and password reset links."
        }
    }

    // MARK: - Account deletion (#262)

    /// Last known server-side deletion request for the signed-in account.
    /// Nil means none is known; refresh before relying on it.
    @Published private(set) var accountDeletion: AuthService.AccountDeletionStatus?

    static func deletionSummary(_ status: AuthService.AccountDeletionStatus) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let when = status.scheduledFor.map { formatter.string(from: $0) + " UTC" } ?? "the scheduled time"
        switch status.state {
        case .pending: return "Account deletion is scheduled for \(when). Cancel before then to keep the account. Projects on this device are untouched; subscriptions must be cancelled through the App Store or billing portal."
        case .processing: return "Account deletion is in progress and can no longer be cancelled from the app. Projects on this device are untouched."
        case .blocked: return "Account deletion is waiting on a retained record. Contact support if it stays blocked. Projects on this device are untouched."
        case .completed: return "This account's server records were deleted."
        case .cancelled: return "Account deletion was cancelled. Nothing was removed."
        }
    }
    /// Informational: a failure leaves the last known state and never shows an error.
    func refreshAccountDeletion() async {
        guard isAuthenticated else { accountDeletion = nil; return }
        if let status = try? await auth.accountDeletionStatus() { accountDeletion = status }
    }
    /// Files the request with the server; nothing is removed now and nothing local is touched.
    func requestAccountDeletion() async {
        guard !isLoading else { return }
        isLoading = true; error = nil; notice = nil
        defer { isLoading = false }
        do {
            let status = try await auth.requestAccountDeletion()
            accountDeletion = status
            notice = Self.deletionSummary(status)
        } catch { self.error = error.localizedDescription }
    }
    func cancelAccountDeletion() async {
        guard !isLoading, let status = accountDeletion, status.state == .pending, let revision = status.revision else { return }
        isLoading = true; error = nil; notice = nil
        defer { isLoading = false }
        do {
            try await auth.cancelAccountDeletion(revision: revision)
            accountDeletion = .init(state: .cancelled, scheduledFor: nil, revision: nil)
            notice = Self.deletionSummary(.init(state: .cancelled, scheduledFor: nil, revision: nil))
        } catch {
            self.error = error.localizedDescription
            await refreshAccountDeletion()
        }
    }

    // MARK: - Sign Out

    func signOut() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        // Persist the open document before the account changes. A dirty project
        // is saved through the normal revision path; nothing is removed.
        await flushOpenProject()
        do { try await auth.signOut() }
        catch { self.error = error.localizedDescription }
        state = auth.state
        user = auth.currentProfile
        if state != .authenticated { accountDeletion = nil }
        // Once the account is gone, leave the editor for the library. The
        // project stays on the device and reopens from the same library.
        if state != .authenticated { await closeOpenProject() }
    }

    // MARK: - Onboarding

    func completeOnboarding(skillLevel: String, interests: [String]) async {
        try? await auth.completeOnboarding(skillLevel: skillLevel, interests: interests)
        user = auth.currentProfile
    }
}
