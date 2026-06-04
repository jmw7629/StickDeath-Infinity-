// ═══════════════════════════════════════════════════════════════════
// WelcomeView — Welcome screen with feature highlights + auth buttons
// Matches: src/pages/WelcomeView.tsx exactly
// - Skull logo at top
// - "STICKDEATH ∞" / "Create. Animate. Annihilate."
// - 4 feature cards (Animation Studio, Messaging, Challenges, Spatter AI)
// - Sign In (red gradient), Create Account (outlined), Continue as Guest
// - Animated background circles (6 floating, blurred, slow drift)
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct WelcomeView: View {
    let onSignIn: () -> Void
    let onCreateAccount: () -> Void
    let onGuest: () -> Void

    @State private var visible = false
    @State private var bgOffset: Double = 0

    private let features: [(icon: String, title: String, desc: String)] = [
        ("🎨", "Animation Studio", "Full-featured drawing & rigging tools"),
        ("💬", "Messaging", "Channels, DMs, threads & calls"),
        ("🔥", "Challenges", "Weekly battles with the community"),
        ("🧠", "Spatter AI", "Your creative AI assistant"),
    ]

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            // Animated background circles
            GeometryReader { geo in
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill(Color(hex: "C80000").opacity(0.04))
                        .frame(width: 300, height: 300)
                        .blur(radius: 40)
                        .position(
                            x: geo.size.width * (0.5 + sin(bgOffset + Double(i)) * 0.15),
                            y: geo.size.height * (CGFloat(i) * 0.18 + cos(bgOffset + Double(i) * 0.7) * 0.08)
                        )
                }
            }

            VStack(spacing: 0) {
                // Logo section
                VStack(spacing: 0) {
                    Text("☠️")
                        .font(.system(size: 80))
                        .padding(.top, 24)

                    Text("STICKDEATH ∞")
                        .font(.specialElite(28))
                        .tracking(4)
                        .foregroundColor(.sdTextPrimary)
                        .sdRedGlow()
                        .padding(.top, 16)

                    Text("Create. Animate. Annihilate.")
                        .font(.specialElite(15))
                        .tracking(1)
                        .foregroundColor(.sdTextSecondary)
                        .padding(.top, 8)
                }

                Spacer()

                // Feature highlights
                VStack(spacing: 16) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        HStack(spacing: 16) {
                            // Icon box
                            Text(feature.icon)
                                .font(.system(size: 20))
                                .frame(width: 40, height: 40)
                                .background(Color(hex: "C80000").opacity(0.15))
                                .cornerRadius(10)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                    .font(.specialElite(15))
                                    .fontWeight(.semibold)
                                    .foregroundColor(.sdTextPrimary)

                                Text(feature.desc)
                                    .font(.system(size: 13))
                                    .foregroundColor(.sdTextSecondary)
                            }

                            Spacer()
                        }
                        .opacity(visible ? 1 : 0)
                        .offset(x: visible ? 0 : 20)
                        .animation(
                            .easeOut(duration: 0.5).delay(0.2 + Double(index) * 0.1),
                            value: visible
                        )
                    }
                }
                .padding(.horizontal, 32)

                Spacer()

                // Buttons
                VStack(spacing: 12) {
                    // Sign In — Red gradient
                    Button(action: onSignIn) {
                        HStack(spacing: 8) {
                            Text("Sign In")
                                .font(.specialElite(16))
                                .fontWeight(.semibold)
                                .tracking(1)
                            Text("→")
                                .font(.system(size: 18))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.sdPrimaryGradient)
                        .cornerRadius(14)
                    }

                    // Create Account — Outlined
                    Button(action: onCreateAccount) {
                        Text("Create Account")
                            .font(.specialElite(16))
                            .fontWeight(.semibold)
                            .tracking(1)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                            .cornerRadius(14)
                    }

                    // Continue as Guest
                    Button(action: onGuest) {
                        Text("Continue as Guest")
                            .font(.specialElite(14))
                            .foregroundColor(.sdTextSecondary)
                            .padding(.vertical, 8)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: 400)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 20)
            .animation(.easeOut(duration: 0.6), value: visible)
        }
        .onAppear {
            visible = true
            // Animate background circles
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                bgOffset += 0.02
            }
        }
    }
}
