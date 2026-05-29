// ═══════════════════════════════════════════════════════════════════
// SplashScreenView — Animated skull splash
// Matches: src/pages/SplashScreen.tsx exactly
// - Skull emoji springs in (0.3→1.0 scale, 0.8s spring)
// - Title fades in at 500ms
// - Subtitle + spinner at 900ms
// - Auto-transition at 2800ms
// - Background: blood splatter particles (12 circles, blurred)
// - Red glow animation on skull
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SplashScreenView: View {
    let onFinish: () -> Void

    @State private var skullScale: CGFloat = 0.3
    @State private var skullOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0
    @State private var glowPulse = false
    @State private var spinRotation: Double = 0

    // Random blood splatter positions (matches React Math.random() seeded particles)
    private let particles: [(width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat, opacity: Double)] = (0..<12).map { _ in
        (
            width: CGFloat.random(in: 40...200),
            height: CGFloat.random(in: 40...200),
            x: CGFloat.random(in: 0.2...0.8),
            y: CGFloat.random(in: 0.1...0.9),
            opacity: Double.random(in: 0.03...0.08)
        )
    }

    var body: some View {
        ZStack {
            // Background
            Color.sdBackground.ignoresSafeArea()

            // Blood splatter particles
            GeometryReader { geo in
                ForEach(0..<particles.count, id: \.self) { i in
                    let p = particles[i]
                    Circle()
                        .fill(Color(hex: "C80000").opacity(p.opacity))
                        .frame(width: p.width, height: p.height)
                        .blur(radius: 30)
                        .position(
                            x: geo.size.width * p.x,
                            y: geo.size.height * p.y
                        )
                }
            }

            // Content
            VStack(spacing: 0) {
                Spacer()

                // Skull emoji with red glow
                Text("☠️")
                    .font(.system(size: 96))
                    .scaleEffect(skullScale)
                    .opacity(skullOpacity)
                    .shadow(color: .sdGlowRed.opacity(glowPulse ? 0.7 : 0.3), radius: glowPulse ? 40 : 20)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: glowPulse)

                // Title
                Text("STICKDEATH ∞")
                    .font(.specialElite(32))
                    .tracking(6)
                    .foregroundColor(.sdTextPrimary)
                    .sdRedGlow()
                    .opacity(titleOpacity)
                    .padding(.top, 24)

                // Subtitle
                Text("ANIMATION STUDIO")
                    .font(.specialElite(14))
                    .tracking(8)
                    .foregroundColor(.sdTextSecondary)
                    .opacity(subtitleOpacity)
                    .padding(.top, 8)

                // Loading spinner
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.sdRedDeep, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(spinRotation))
                    .opacity(subtitleOpacity)
                    .padding(.top, 40)

                Spacer()
            }
        }
        .onAppear {
            // Skull springs in (100ms delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) {
                    skullScale = 1.0
                    skullOpacity = 1
                }
                glowPulse = true
            }

            // Title fades in (500ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeIn(duration: 0.6)) {
                    titleOpacity = 1
                }
            }

            // Subtitle + spinner (900ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeIn(duration: 0.6)) {
                    subtitleOpacity = 1
                }
                // Start spinner
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    spinRotation = 360
                }
            }

            // Transition out (2800ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                onFinish()
            }
        }
    }
}
