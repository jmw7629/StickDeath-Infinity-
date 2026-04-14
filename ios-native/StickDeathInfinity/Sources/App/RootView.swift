// RootView.swift
// Routes: Splash → Onboarding → Auth → Main
// Wrapped in ResponsiveContainer for universal device support
// 5-second rule: animated splash hooks users instantly

import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var offline: OfflineManager
    @State private var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    var body: some View {
        ResponsiveContainer { ctx in
            ZStack {
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

// MARK: - Splash Screen (5-second rule: instant visual hook)
struct SplashView: View {
    @State private var pulse = false
    @State private var textOpacity = 0.0
    @State private var taglineOffset: CGFloat = 20

    var body: some View {
        ZStack {
            // Dark gradient background
            RadialGradient(
                colors: [Color(hex: "#1a0005"), .black],
                center: .center, startRadius: 50, endRadius: 400
            ).ignoresSafeArea()

            VStack(spacing: 16) {
                ZStack {
                    // Outer glow rings
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(.red.opacity(0.15 - Double(i) * 0.04), lineWidth: 1.5)
                            .frame(width: CGFloat(100 + i * 40), height: CGFloat(100 + i * 40))
                            .scaleEffect(pulse ? 1.2 : 0.9)
                            .opacity(pulse ? 0 : 0.6)
                            .animation(
                                .easeInOut(duration: 1.5)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.3),
                                value: pulse
                            )
                    }

                    // Main icon
                    Image(systemName: "figure.run")
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(colors: [.red, .red], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .shadow(color: .red.opacity(0.5), radius: 20)
                }

                Text("STICKDEATH INFINITY")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .opacity(textOpacity)

                Text("Create. Animate. Annihilate.")
                    .font(.subheadline)
                    .foregroundStyle(.red.opacity(0.8))
                    .offset(y: taglineOffset)
                    .opacity(textOpacity)

                ProgressView()
                    .tint(.red)
                    .padding(.top, 24)
            }
        }
        .onAppear {
            pulse = true
            withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                textOpacity = 1.0
                taglineOffset = 0
            }
        }
    }
}
