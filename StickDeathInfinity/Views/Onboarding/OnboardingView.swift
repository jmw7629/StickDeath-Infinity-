// ═══════════════════════════════════════════════════════════════════
// OnboardingView — 5 swipeable pages with animated icons
// Matches: src/pages/OnboardingView.tsx exactly
// - 5 pages: Welcome, Studio, Collab, Spatter AI, Ready
// - Feature checklists with gradient checkmarks
// - Pagination dots (5)
// - Next / Get Started button with page-specific gradient
// - Skip always visible
// - Swipe support via TabView
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @EnvironmentObject var authVM: AuthViewModel
    @State private var currentPage = 0
    @State private var featuresVisible = true

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "Welcome to StickDeath ∞",
            subtitle: "The ultimate stick-figure animation platform",
            icon: "💀",
            features: [
                "Create stunning stick-figure animations",
                "Battle other creators in War Room",
                "Join a community of 100,000+ artists",
            ],
            gradient: [Color(hex: "#CC1100"), Color(hex: "#FF3322")]
        ),
        OnboardingPage(
            title: "Professional Studio",
            subtitle: "Full-featured animation tools at your fingertips",
            icon: "🎨",
            features: [
                "Frame-by-frame with onion skinning",
                "18+ drawing tools including bone rigging",
                "Export in GIF, MP4, PNG Sequence & more",
            ],
            gradient: [Color(hex: "#3388FF"), Color(hex: "#00CCFF")]
        ),
        OnboardingPage(
            title: "Collaborate & Compete",
            subtitle: "Create together or battle head-to-head",
            icon: "⚔️",
            features: [
                "Real-time Creator Rooms with live canvas",
                "War Room: 1v1 animation battles with voting",
                "Watch Together: synced animation playback",
            ],
            gradient: [Color(hex: "#FF8800"), Color(hex: "#FFCC00")]
        ),
        OnboardingPage(
            title: "Spatter AI Assistant",
            subtitle: "Your AI-powered animation companion",
            icon: "🤖",
            features: [
                "Get animation tips and technique advice",
                "Generate scene ideas and storyboards",
                "Powered by GPT-4o for expert guidance",
            ],
            gradient: [Color(hex: "#8833FF"), Color(hex: "#FF33FF")]
        ),
        OnboardingPage(
            title: "Ready to Create?",
            subtitle: "Join the stickverse and unleash your creativity",
            icon: "🚀",
            features: [
                "1,200+ gallery assets ready to use",
                "Cloud sync across all your devices",
                "Weekly challenges with prizes",
            ],
            gradient: [Color(hex: "#00CC44"), Color(hex: "#00FFAA")]
        ),
    ]

    private var page: OnboardingPage { pages[currentPage] }
    private var isLast: Bool { currentPage == pages.count - 1 }

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Page content (swipeable)
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, pg in
                        pageContent(pg)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: currentPage) { _ in
                    featuresVisible = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        featuresVisible = true
                    }
                }

                // Bottom section
                VStack(spacing: 0) {
                    // Pagination dots
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { i in
                            Circle()
                                .fill(i == currentPage ? page.gradient[0] : Color.white.opacity(0.25))
                                .frame(
                                    width: i == currentPage ? 10 : 6,
                                    height: i == currentPage ? 10 : 6
                                )
                                .animation(.easeInOut(duration: 0.3), value: currentPage)
                                .onTapGesture { goTo(i) }
                        }
                    }
                    .padding(.bottom, 20)

                    // Next / Get Started button
                    Button {
                        if isLast {
                            finishOnboarding()
                        } else {
                            goTo(currentPage + 1)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(isLast ? "Get Started" : "Next")
                                .font(.specialElite(16))
                                .fontWeight(.semibold)
                                .tracking(1)
                            Text("→")
                                .font(.system(size: 18))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: page.gradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .cornerRadius(14)
                    }
                    .padding(.horizontal, 24)

                    // Skip button
                    Button {
                        finishOnboarding()
                    } label: {
                        Text("Skip")
                            .font(.specialElite(14))
                            .foregroundColor(.sdTextMuted)
                            .padding(.vertical, 12)
                    }
                    .padding(.top, 4)
                }
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Page Content
    @ViewBuilder
    private func pageContent(_ pg: OnboardingPage) -> some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon with glow circle
            ZStack {
                // Glow circle
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [pg.gradient[0].opacity(0.2), pg.gradient[1].opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                    .blur(radius: 20)

                Text(pg.icon)
                    .font(.system(size: 64))
            }
            .padding(.bottom, 24)

            // Title
            Text(pg.title)
                .font(.specialElite(24))
                .fontWeight(.bold)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            // Subtitle
            Text(pg.subtitle)
                .font(.system(size: 15))
                .foregroundColor(.sdTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.bottom, 32)

            // Feature checklist
            VStack(spacing: 16) {
                ForEach(Array(pg.features.enumerated()), id: \.offset) { index, feature in
                    HStack(alignment: .top, spacing: 12) {
                        // Gradient checkmark circle
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: pg.gradient,
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 28, height: 28)

                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }

                        Text(feature)
                            .font(.system(size: 15))
                            .foregroundColor(Color(hex: "#CCCCCC"))
                            .padding(.top, 3)

                        Spacer()
                    }
                    .opacity(featuresVisible ? 1 : 0)
                    .offset(x: featuresVisible ? 0 : 20)
                    .animation(
                        .easeOut(duration: 0.4).delay(Double(index) * 0.15),
                        value: featuresVisible
                    )
                }
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Navigation
    private func goTo(_ index: Int) {
        guard index >= 0 && index < pages.count else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage = index
        }
    }

    private func finishOnboarding() {
        onComplete()
        // Background: persist onboarding status
        Task {
            await authVM.completeOnboarding(
                skillLevel: "intermediate",
                interests: ["animation", "community"]
            )
        }
    }
}

// MARK: - Onboarding Page Model
private struct OnboardingPage {
    let title: String
    let subtitle: String
    let icon: String
    let features: [String]
    let gradient: [Color]
}
