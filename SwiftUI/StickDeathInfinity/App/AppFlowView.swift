// ═══════════════════════════════════════════════════════════════════
// AppFlowView — Screen flow state machine
// Splash → Welcome → Login/SignUp → Onboarding → ChoosePlan → MainApp
// Matches: React Router flow in App.tsx exactly
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct AppFlowView: View {
    @EnvironmentObject var authVM: AuthViewModel

    enum Screen {
        case splash, welcome, login, signup, onboarding, choosePlan, app
    }

    @State private var screen: Screen = .splash

    var body: some View {
        Group {
            switch screen {
            case .splash:
                SplashScreenView {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        screen = authVM.isAuthenticated ? .app : .welcome
                    }
                }

            case .welcome:
                WelcomeView(
                    onSignIn: { withAnimation { screen = .login } },
                    onCreateAccount: { withAnimation { screen = .signup } },
                    onGuest: {
                        Task {
                            try? await authVM.signInAsGuest()
                            withAnimation { screen = .app }
                        }
                    }
                )

            case .login:
                LoginView(
                    onBack: { withAnimation { screen = .welcome } },
                    onSuccess: {
                        withAnimation {
                            screen = (authVM.user?.onboarded == true) ? .app : .onboarding
                        }
                    }
                )

            case .signup:
                SignUpView(
                    onBack: { withAnimation { screen = .welcome } },
                    onSuccess: { withAnimation { screen = .onboarding } }
                )

            case .onboarding:
                OnboardingView {
                    withAnimation { screen = .choosePlan }
                }

            case .choosePlan:
                ChoosePlanView {
                    withAnimation { screen = .app }
                }

            case .app:
                MainTabView()
            }
        }
        .transition(.opacity)
    }
}
