// RootView.swift
// Routes between Onboarding → Auth → Main app based on state

import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    var body: some View {
        Group {
            if auth.isLoading {
                SplashView()
            } else if !hasCompletedOnboarding {
                OnboardingView(isComplete: $hasCompletedOnboarding)
            } else if auth.isLoggedIn {
                MainTabView()
            } else {
                WelcomeView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: auth.isLoggedIn)
        .animation(.easeInOut(duration: 0.3), value: hasCompletedOnboarding)
    }
}

// MARK: - Splash Screen
struct SplashView: View {
    @State private var pulse = false
    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                ZStack {
                    // Glow ring
                    Circle()
                        .stroke(.orange.opacity(0.2), lineWidth: 2)
                        .frame(width: 100, height: 100)
                        .scaleEffect(pulse ? 1.3 : 1.0)
                        .opacity(pulse ? 0 : 0.5)

                    Image(systemName: "figure.run")
                        .font(.system(size: 48))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(rotation))
                }
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)

                Text("StickDeath ∞")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                ProgressView()
                    .tint(.orange)
            }
        }
        .onAppear {
            pulse = true
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
