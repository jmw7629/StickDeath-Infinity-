import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("sdi.guide.completed.v1") private var guideCompleted = false
    @State private var currentPage = 0
    @State private var finishing = false

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "Welcome to StickDeath ∞",
            subtitle: "Your Studio starts on this device",
            icon: "💀",
            features: [
                "Create editable frame-by-frame animations",
                "Keep original projects on your device",
                "Explore Studio without an account",
            ],
            gradient: [Color(hex: "#CC1100"), Color(hex: "#FF3322")]
        ),
        OnboardingPage(
            title: "Professional Studio",
            subtitle: "Draw, organize and export your animation",
            icon: "🎨",
            features: [
                "Frame-by-frame with onion skinning",
                "Layers, selection, text and brush settings",
                "Export GIF, MP4, PNG sequences and spritesheets",
            ],
            gradient: [Color(hex: "#3388FF"), Color(hex: "#00CCFF")]
        ),
        OnboardingPage(
            title: "Collaborate & Compete",
            subtitle: "Planned next · not connected in this build",
            icon: "⚔️",
            features: [
                "Room invites will require both creators to agree",
                "War Room will let viewers pick their favorite",
                "Shared projects only — no chat or calls",
            ],
            gradient: [Color(hex: "#FF8800"), Color(hex: "#FFCC00")],
            available: false
        ),
        OnboardingPage(
            title: "Spatter AI Assistant",
            subtitle: "Local help and reversible Studio commands",
            icon: "🤖",
            features: [
                "Ask about the current tool or project",
                "Try editable local motion recipes",
                "Cloud AI needs a configured, signed-in service",
            ],
            gradient: [Color(hex: "#8833FF"), Color(hex: "#FF33FF")]
        ),
        OnboardingPage(
            title: "Ready to Create?",
            subtitle: "Your artwork, audio and edits stay with you",
            icon: "🚀",
            features: [
                "Import images or choose licensed library assets",
                "Preview and mix licensed sounds on the timeline",
                "Save locally and reopen to keep creating",
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
                HStack {
                    Button {
                        if currentPage == 0 { onBack() }
                        else { goTo(currentPage - 1) }
                    } label: {
                        Label(currentPage == 0 ? "Back to Welcome" : "Back", systemImage: "chevron.left")
                            .font(.specialElite(14))
                            .foregroundColor(.sdTextSecondary)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("onboarding.back")
                    Spacer()
                    Text("\(currentPage + 1) of \(pages.count)")
                        .font(.caption)
                        .foregroundColor(.sdTextSecondary)
                        .accessibilityIdentifier("onboarding.position")
                }
                .padding(.horizontal, 24)
                // Page content (swipeable)
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, pg in
                        pageContent(pg)
                            .tag(index)
                            .accessibilityIdentifier("onboarding.page.\(index)")
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Bottom section
                VStack(spacing: 0) {
                    // Pagination dots
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { i in
                            Button { goTo(i) } label: {
                                Circle()
                                    .fill(i == currentPage ? page.gradient[0] : Color.white.opacity(0.25))
                                    .frame(width: i == currentPage ? 10 : 6,
                                           height: i == currentPage ? 10 : 6)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Page \(i + 1): \(pages[i].title)")
                            .accessibilityValue(i == currentPage ? "Selected" : "")
                            .accessibilityIdentifier("onboarding.dot.\(i)")
                        }
                    }
                    .padding(.bottom, 8)

                    // Next / Open Studio button
                    Button {
                        if isLast {
                            finishOnboarding()
                        } else {
                            goTo(currentPage + 1)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(isLast ? "Open Studio" : "Next")
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
                    .disabled(finishing)
                    .accessibilityIdentifier("onboarding.next")

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
                    .disabled(finishing)
                    .accessibilityIdentifier("onboarding.skip")
                }
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Page Content
    @ViewBuilder
    private func pageContent(_ pg: OnboardingPage) -> some View {
        ScrollView {
            VStack(spacing: 0) {
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

                                Image(systemName: pg.available ? "checkmark" : "clock")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            }

                            Text(feature)
                                .font(.system(size: 15))
                                .foregroundColor(Color(hex: "#CCCCCC"))
                                .padding(.top, 3)

                            Spacer()
                        }

                    }
                }
                .frame(maxWidth: 320)
                .padding(.horizontal, 32)

            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Navigation
    private func goTo(_ index: Int) {
        guard index >= 0 && index < pages.count else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            currentPage = index
        }
    }

    private func finishOnboarding() {
        guard !finishing else { return }
        finishing = true
        // Local guide completion is not account consent or a guessed skill profile.
        guideCompleted = true
        onComplete()
    }
}

// MARK: - Onboarding Page Model
private struct OnboardingPage {
    let title: String
    let subtitle: String
    let icon: String
    let features: [String]
    let gradient: [Color]
    var available = true
}
