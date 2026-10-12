import SwiftUI

/// Guests reach sign-in from inside the app without losing Studio work. The
/// action flushes the shared editor's pending save, then presents Login; Back
/// and success both return to the app shell.
struct RequestSignInAction {
    let handler: @MainActor () -> Void
    @MainActor func callAsFunction() { handler() }
}
private struct RequestSignInKey: EnvironmentKey {
    static let defaultValue = RequestSignInAction(handler: {})
}
extension EnvironmentValues {
    var requestSignIn: RequestSignInAction {
        get { self[RequestSignInKey.self] }
        set { self[RequestSignInKey.self] = newValue }
    }
}

/// Local Studio access is independent of an account. Session restoration owns
/// account readiness; a short cancellable presentation keeps cold-start branding visible.
/// Viewing the guide never records server-side consent.
struct AppFlowView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @AppStorage("sdi.guide.completed.v1") private var guideCompleted = false
    /// Remembered "Continue as Guest". A returning guest opens the app directly;
    /// sign-in stays one tap away in Rooms, Calendar and Profile.
    @AppStorage("sdi.guest.chosen.v1") private var guestChosen = false

    /// Intentional branding hold (#136). The splash shows the actual restoration
    /// state for at least this long; Open Studio Offline, Retry and Sign In stay
    /// enabled during it, so no one is stranded. Leaving via an action cancels it.
    static let minimumBrandingPresentation: UInt64 = 1_000_000_000

    enum Screen { case splash, welcome, login, signup, onboarding, app }
    @State private var screen: Screen = .splash
    @State private var accountUnavailable = false
    @State private var splashPresentationComplete = false
    /// Login opened from inside the app returns there on Back or success.
    @State private var loginReturnsToApp = false

    var body: some View {
        Group {
            switch screen {
            case .splash:
                SplashScreenView(onContinueOffline: { rememberGuest(); navigate(to: .app) },
                    restoration: authVM.restoration,
                    onRetry: { Task { await authVM.retryRestoration() } },
                    onSignIn: { navigate(to: .login) })
                    .task {
                        // Begin after the splash is mounted, not during auth startup.
                        // Leaving via an explicit action cancels this view-owned task.
                        do { try await Task.sleep(nanoseconds: Self.minimumBrandingPresentation) }
                        catch { return }
                        guard !Task.isCancelled else { return }
                        splashPresentationComplete = true
                        finishRestorationIfReady()
                    }
            case .welcome:
                WelcomeView(
                    onSignIn: { navigate(to: .login) },
                    onCreateAccount: { navigate(to: .signup) },
                    onGuest: { rememberGuest(); navigate(to: .app) },
                    onGuide: { navigate(to: .onboarding) },
                    accountUnavailable: accountUnavailable,
                    isAuthenticated: authVM.isAuthenticated
                )
            case .login:
                LoginView(onBack: { navigate(to: loginReturnsToApp ? .app : .welcome) },
                          onSuccess: { loginReturnsToApp ? navigate(to: .app) : routeSignedInUser() },
                          backLabel: loginReturnsToApp ? "Back to Studio" : "Back to Welcome")
            case .signup:
                SignUpView(onBack: { navigate(to: .welcome) }, onSuccess: routeSignedInUser)
            case .onboarding:
                OnboardingView(
                    onComplete: { navigate(to: .app) },
                    onBack: { navigate(to: .welcome) }
                )
            case .app:
                MainTabView(initialTab: .studio)
                    .environment(\.requestSignIn, RequestSignInAction(handler: requestSignIn))
            }
        }
        .overlay(alignment: .top) { noticeBanner }
        .onAppear(perform: finishRestorationIfReady)
        .onChange(of: authVM.state) { finishRestorationIfReady() }
        .onChange(of: authVM.restoration) { finishRestorationIfReady() }
        .onChange(of: authVM.passwordRecoveryPending) { _, pending in
            // A recovery link established a session; the new password is set on Login.
            if pending, screen == .app || screen == .welcome { loginReturnsToApp = screen == .app; navigate(to: .login) }
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = authVM.notice {
            HStack(alignment: .top, spacing: 12) {
                Text(notice).font(.specialElite(13)).foregroundColor(.sdTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Dismiss") { authVM.notice = nil }
                    .font(.specialElite(13)).foregroundColor(.sdRed)
            }
            .padding(14)
            .background(Color.sdSurface)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.sdBorder, lineWidth: 1))
            .cornerRadius(12)
            .padding(.horizontal, 16).padding(.top, 8)
            .accessibilityIdentifier("app.notice")
        }
    }

    private func rememberGuest() { guestChosen = true }

    private func requestSignIn() {
        loginReturnsToApp = true
        Task {
            // Persist the open document before leaving the app shell; the shared
            // editor keeps its state, so returning restores the same project.
            await StudioViewModel.shared.flush()
            navigate(to: .login)
        }
    }

    private func finishRestorationIfReady() {
        // A late restoration result must not interrupt an explicit offline choice.
        guard screen == .splash, splashPresentationComplete, authVM.state != .loading, authVM.restoration == .ready else { return }
        accountUnavailable = authVM.error != nil
        if authVM.isAuthenticated { routeSignedInUser() }
        else if guestChosen { navigate(to: .app) }
        else { navigate(to: .welcome) }
    }

    private func routeSignedInUser() {
        guard authVM.isAuthenticated else { return }
        loginReturnsToApp = false
        navigate(to: guideCompleted || authVM.user?.onboarded == true ? .app : .onboarding)
    }

    private func navigate(to destination: Screen) {
        // Route changes replace the interactive screen immediately. Decorative
        // child animations must not retain an outgoing route's hit-test tree.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            screen = destination
        }
    }
}
