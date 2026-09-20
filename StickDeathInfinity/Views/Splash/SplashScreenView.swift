import SwiftUI

/// Shown only while the existing session is being restored. There is no
/// decorative loading delay, and local projects remain reachable while offline.
struct SplashScreenView: View {
    let onContinueOffline: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowPulse = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.sdBackground.ignoresSafeArea()
                RadialGradient(colors: [Color.sdRed.opacity(0.16), .clear],
                               center: .center, startRadius: 20, endRadius: 280)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                ScrollView {
                    VStack(spacing: 20) {
                        Spacer(minLength: 24)
                        Text("☠️")
                            .font(.system(size: 96))
                            .shadow(color: .sdGlowRed.opacity(glowPulse ? 0.6 : 0.3),
                                    radius: glowPulse ? 36 : 20)
                            .accessibilityHidden(true)
                        Text("STICKDEATH ∞")
                            .font(.specialElite(32))
                            .tracking(4)
                            .foregroundColor(.sdTextPrimary)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.7)
                            .accessibilityAddTraits(.isHeader)
                        Text("ANIMATION STUDIO")
                            .font(.specialElite(14))
                            .tracking(5)
                            .foregroundColor(.sdTextSecondary)
                        ProgressView("Restoring your session…")
                            .tint(.sdRed)
                            .foregroundColor(.sdTextSecondary)
                            .padding(.top, 20)
                            .accessibilityIdentifier("startup.restoring")
                        Button("Open Studio Offline", action: onContinueOffline)
                            .font(.specialElite(15))
                            .foregroundColor(.white)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("startup.offline")
                        Text("Your local projects do not require sign-in.")
                            .font(.footnote)
                            .foregroundColor(.sdTextSecondary)
                            .multilineTextAlignment(.center)
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
            }
        }
        .task(id: reduceMotion) {
            glowPulse = false
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
    }
}
