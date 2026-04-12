// OnboardingView.swift
// Animated first-launch walkthrough — shows once, stored in UserDefaults

import SwiftUI

struct OnboardingPage: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
    let features: [String]
    let color: Color
}

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentPage = 0
    @State private var animateIcon = false

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "figure.run",
            title: "Welcome to\nStickDeath ∞",
            subtitle: "The ultimate stick figure animation studio",
            features: [
                "Create epic stick figure animations",
                "Share with millions on our channels",
                "Join a global creator community"
            ],
            color: .orange
        ),
        OnboardingPage(
            icon: "pencil.and.outline",
            title: "Create",
            subtitle: "A studio built for simplicity",
            features: [
                "Pose mode — drag joints to pose your figures",
                "Draw mode — sketch backgrounds and effects",
                "Move mode — pan and zoom the canvas",
                "Timeline — add frames, set timing, preview",
                "Layers — multiple figures, reorder anytime"
            ],
            color: .cyan
        ),
        OnboardingPage(
            icon: "sparkles",
            title: "AI Assistant",
            subtitle: "Let AI help you create",
            features: [
                "\"Make a walking cycle\" — AI builds poses",
                "\"Add a fight scene\" — instant action",
                "Suggest improvements to your animation",
                "Available with Pro subscription ($4.99/mo)"
            ],
            color: .purple
        ),
        OnboardingPage(
            icon: "paperplane.fill",
            title: "Publish",
            subtitle: "Your creation goes everywhere",
            features: [
                "Videos upload to StickDeath channels automatically",
                "YouTube, TikTok, Instagram, Discord & more",
                "You can also send to your own accounts",
                "Every view builds ad revenue for the community",
                "All videos are branded with StickDeath ∞"
            ],
            color: .green
        ),
        OnboardingPage(
            icon: "star.fill",
            title: "Go Pro",
            subtitle: "Unlock the full experience",
            features: [
                "AI Animation Assistant",
                "Unlimited projects",
                "HD export (1080p+)",
                "Custom stick figure skins",
                "Remove watermark on your personal exports",
                "Priority publishing"
            ],
            color: .orange
        ),
    ]

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Page content
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        ScrollView {
                            VStack(spacing: 24) {
                                Spacer().frame(height: 40)

                                // Animated icon
                                ZStack {
                                    Circle()
                                        .fill(page.color.opacity(0.12))
                                        .frame(width: 120, height: 120)
                                        .scaleEffect(animateIcon ? 1.1 : 0.9)

                                    Image(systemName: page.icon)
                                        .font(.system(size: 48))
                                        .foregroundStyle(page.color)
                                        .scaleEffect(animateIcon ? 1.0 : 0.8)
                                }
                                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: animateIcon)

                                // Title
                                Text(page.title)
                                    .font(.system(size: 28, weight: .bold))
                                    .multilineTextAlignment(.center)

                                // Subtitle
                                Text(page.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                    .multilineTextAlignment(.center)

                                // Features
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(page.features, id: \.self) { feature in
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(page.color)
                                                .font(.subheadline)
                                                .padding(.top, 1)
                                            Text(feature)
                                                .font(.subheadline)
                                                .foregroundStyle(.white.opacity(0.85))
                                        }
                                    }
                                }
                                .padding(.horizontal, 32)
                                .padding(.top, 8)

                                Spacer()
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Bottom controls
                VStack(spacing: 20) {
                    // Page dots
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { i in
                            Circle()
                                .fill(i == currentPage ? pages[currentPage].color : Color.gray.opacity(0.3))
                                .frame(width: i == currentPage ? 10 : 6, height: i == currentPage ? 10 : 6)
                                .animation(.spring(response: 0.3), value: currentPage)
                        }
                    }

                    // Action buttons
                    HStack(spacing: 16) {
                        if currentPage > 0 {
                            Button {
                                withAnimation { currentPage -= 1 }
                            } label: {
                                Text("Back")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.gray)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(ThemeManager.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }

                        Button {
                            if currentPage < pages.count - 1 {
                                withAnimation { currentPage += 1 }
                            } else {
                                completeOnboarding()
                            }
                        } label: {
                            Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(pages[currentPage].color)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(.horizontal, 24)

                    // Skip
                    if currentPage < pages.count - 1 {
                        Button("Skip") {
                            completeOnboarding()
                        }
                        .font(.caption)
                        .foregroundStyle(.gray)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear { animateIcon = true }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        withAnimation(.easeInOut(duration: 0.4)) {
            isComplete = true
        }
    }
}
