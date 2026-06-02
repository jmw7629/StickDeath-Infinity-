// ═══════════════════════════════════════════════════════════════════
// AppTutorialView — First-run tutorial overlay
// Matches: src/components/AppTutorial.tsx
// Shows once on first launch with tab highlights and tips
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

private struct TutorialStep {
    let icon: String
    let title: String
    let description: String
    let tab: String
}

private let tutorialSteps: [TutorialStep] = [
    TutorialStep(icon: "🏠", title: "Home Feed", description: "Browse animations from the community. Like, comment, and share your favorites.", tab: "home"),
    TutorialStep(icon: "⚔️", title: "Challenges", description: "Enter weekly animation battles. Vote on entries and win prizes.", tab: "challenges"),
    TutorialStep(icon: "🎨", title: "Studio", description: "Create stick figure animations with brushes, layers, and frames. Your creative playground.", tab: "studio"),
    TutorialStep(icon: "💬", title: "Messages", description: "Chat with other creators. Start video calls, watch parties, and collaborate.", tab: "messages"),
    TutorialStep(icon: "👤", title: "Profile", description: "Your portfolio. Edit your profile, view achievements, and manage settings.", tab: "profile"),
]

struct AppTutorialView: View {
    @State private var currentStep = 0
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Skull icon
                Text("☠️")
                    .font(.system(size: 48))

                Text("Welcome to StickDeath ∞")
                    .font(.specialElite(22))
                    .foregroundColor(.sdTextPrimary)

                // Current step card
                VStack(spacing: 12) {
                    Text(tutorialSteps[currentStep].icon)
                        .font(.system(size: 40))

                    Text(tutorialSteps[currentStep].title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.sdTextPrimary)

                    Text(tutorialSteps[currentStep].description)
                        .font(.system(size: 15))
                        .foregroundColor(.sdTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .padding(24)
                .background(Color.sdSurface)
                .cornerRadius(16)
                .padding(.horizontal, 32)

                // Progress dots
                HStack(spacing: 8) {
                    ForEach(0..<tutorialSteps.count, id: \.self) { i in
                        Circle()
                            .fill(i == currentStep ? Color.sdRed : Color.sdTextMuted)
                            .frame(width: 8, height: 8)
                    }
                }

                // Buttons
                HStack(spacing: 16) {
                    if currentStep > 0 {
                        Button {
                            withAnimation { currentStep -= 1 }
                        } label: {
                            Text("Back")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.sdTextSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.sdSurface)
                                .cornerRadius(12)
                        }
                    }

                    Button {
                        if currentStep < tutorialSteps.count - 1 {
                            withAnimation { currentStep += 1 }
                        } else {
                            UserDefaults.standard.set(true, forKey: "tutorial_completed")
                            withAnimation { isPresented = false }
                        }
                    } label: {
                        Text(currentStep < tutorialSteps.count - 1 ? "Next" : "Get Started!")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(colors: [Color.sdRed, Color(hex: "CC1100")],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 32)

                // Skip
                Button {
                    UserDefaults.standard.set(true, forKey: "tutorial_completed")
                    withAnimation { isPresented = false }
                } label: {
                    Text("Skip Tutorial")
                        .font(.system(size: 13))
                        .foregroundColor(.sdTextMuted)
                }

                Spacer()
            }
        }
    }
}
