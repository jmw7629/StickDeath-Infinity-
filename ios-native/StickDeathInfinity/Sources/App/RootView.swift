// RootView.swift
// Routes: Splash → Onboarding → Auth → Main
// Injects NavigationRouter as environment object (shared across all tabs)
// Adds SpatterOverlay at ZStack top level (Layer 4 — never changes navigation)
// Wrapped in ResponsiveContainer for universal device support

import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var offline: OfflineManager
    @StateObject private var router = NavigationRouter()
    @State private var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    var body: some View {
        ResponsiveContainer { ctx in
            ZStack {
                // Main content
                Group {
                    if auth.isLoading {
                        SplashView()
                    } else if !hasCompletedOnboarding {
                        OnboardingView(isComplete: $hasCompletedOnboarding)
                    } else if auth.isLoggedIn {
                        MainTabView()
                            .environmentObject(router)
                    } else {
                        WelcomeView()
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: auth.isLoggedIn)
                .animation(.easeInOut(duration: 0.3), value: hasCompletedOnboarding)

                // Offline banner
                if !offline.isOnline {
                    VStack {
                        OfflineBanner(pendingActions: offline.pendingActions)
                        Spacer()
                    }
                }

                // Sync indicator
                if offline.isSyncing {
                    VStack {
                        HStack {
                            Spacer()
                            Label("Syncing...", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .padding(6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .padding(8)
                        }
                        Spacer()
                    }
                }

                // ── Layer 4: Spatter AI Overlay ──
                // Never changes navigation state. Sits on top of everything.
                // Closing returns user exactly where they were.
                if router.showSpatter {
                    SpatterOverlay()
                        .environmentObject(router)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .zIndex(100)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .replayOnboarding)) { _ in
            hasCompletedOnboarding = false
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

// MARK: - Splash Screen (matches Joe's original design)
struct SplashView: View {
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.8

    var body: some View {
        ZStack {
            Color(hex: "#0a0a0f").ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "skull.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(ThemeManager.brand)

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

                ProgressView()
                    .tint(.red)
                    .padding(.top, 20)
            }
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                opacity = 1.0
                scale = 1.0
            }
        }
    }
}
