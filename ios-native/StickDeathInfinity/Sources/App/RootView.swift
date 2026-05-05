// RootView.swift
// Flow: Splash (tap anywhere) → Welcome → Auth → Main App
// No audit bar. Pixel-perfect to reference.

import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var offline: OfflineManager
    @StateObject private var router = NavigationRouter()
    @State private var showSplash = true
    @State private var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    var body: some View {
        ZStack {
            Group {
                if showSplash {
                    SplashView(showSplash: $showSplash)
                } else if auth.isLoading {
                    loadingView
                } else if !hasCompletedOnboarding {
                    OnboardingView(isComplete: $hasCompletedOnboarding)
                } else if auth.isLoggedIn {
                    MainTabView()
                        .environmentObject(router)
                } else {
                    WelcomeView()
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showSplash)
            .animation(.easeInOut(duration: 0.3), value: auth.isLoggedIn)

            // Offline banner
            if !offline.isOnline {
                VStack {
                    OfflineBanner(pendingActions: offline.pendingActions)
                    Spacer()
                }
            }

            // Spatter overlay
            if router.showSpatter {
                SpatterOverlay()
                    .environmentObject(router)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(100)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .replayOnboarding)) { _ in
            hasCompletedOnboarding = false
        }
    }

    var loadingView: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()
            ProgressView()
                .tint(.red)
        }
    }
}

// MARK: - Splash Screen (tap anywhere to continue)
struct SplashView: View {
    @Binding var showSplash: Bool
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.85

    var body: some View {
        ZStack {
            Color(hex: "#0a0a0f").ignoresSafeArea()

            VStack(spacing: 8) {
                Text("💀")
                    .font(.system(size: 48))

                HStack(spacing: 0) {
                    Text("STICK")
                        .foregroundStyle(ThemeManager.brand)
                    Text("DEATH")
                        .foregroundStyle(.white)
                    Text(" ∞")
                        .foregroundStyle(.white)
                }
                .font(.custom("SpecialElite-Regular", size: 28, relativeTo: .title))
                .fontWeight(.black)
                .tracking(2)

                Text("Create. Animate. Annihilate.")
                    .font(.custom("SpecialElite-Regular", size: 14, relativeTo: .caption))
                    .foregroundStyle(ThemeManager.textSecondary)
                    .tracking(1)
            }
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.3)) {
                showSplash = false
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                opacity = 1.0
                scale = 1.0
            }
        }
    }
}

// MARK: - Offline Banner
struct OfflineBanner: View {
    let pendingActions: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption.bold())
            Text("Offline" + (pendingActions > 0 ? " · \(pendingActions) pending" : ""))
                .font(.caption.bold())
            Spacer()
            Text("Changes will sync when back online")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.85))
    }
}
