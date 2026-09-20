import SwiftUI

/// Local Studio access is independent of an account. Session restoration owns
/// the splash lifetime; viewing the guide never records server-side consent.
struct AppFlowView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @AppStorage("sdi.guide.completed.v1") private var guideCompleted = false

    enum Screen { case splash, welcome, login, signup, onboarding, app }
    @State private var screen: Screen = .splash
    @State private var accountUnavailable = false

    var body: some View {
        Group {
            switch screen {
            case .splash:
                SplashScreenView(onContinueOffline: { navigate(to: .app) })
            case .welcome:
                WelcomeView(
                    onSignIn: { navigate(to: .login) },
                    onCreateAccount: { navigate(to: .signup) },
                    onGuest: { navigate(to: .app) },
                    onGuide: { navigate(to: .onboarding) },
                    accountUnavailable: accountUnavailable,
                    isAuthenticated: authVM.isAuthenticated
                )
            case .login:
                LoginView(onBack: { navigate(to: .welcome) }, onSuccess: routeSignedInUser)
            case .signup:
                SignUpView(onBack: { navigate(to: .welcome) }, onSuccess: routeSignedInUser)
            case .onboarding:
                OnboardingView(
                    onComplete: { navigate(to: .app) },
                    onBack: { navigate(to: .welcome) }
                )
            case .app:
                MainTabView(initialTab: .studio)
            }
        }
        .onAppear(perform: finishRestorationIfReady)
        .onChange(of: authVM.state) { finishRestorationIfReady() }
    }

    private func finishRestorationIfReady() {
        // A late restoration result must not interrupt an explicit offline choice.
        guard screen == .splash, authVM.state != .loading else { return }
        accountUnavailable = authVM.error != nil
        if authVM.isAuthenticated { routeSignedInUser() }
        else { navigate(to: .welcome) }
    }

    private func routeSignedInUser() {
        guard authVM.isAuthenticated else { return }
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
