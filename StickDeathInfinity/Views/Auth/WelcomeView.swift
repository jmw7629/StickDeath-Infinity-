import SwiftUI

/// Keeps the supplied skull, wordmark, feature rows and red action hierarchy.
/// All entry actions remain reachable on compact and landscape displays.
struct WelcomeView: View {
    let onSignIn: () -> Void
    let onCreateAccount: () -> Void
    let onGuest: () -> Void
    let onGuide: () -> Void
    let accountUnavailable: Bool
    let isAuthenticated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var backgroundDrift = false
    @AppStorage("sdi.guide.completed.v1") private var guideCompleted = false

    private let features: [(icon: String, title: String, detail: String)] = [
        ("pencil.and.outline", "Animation Studio", "Draw, layer, animate and export"),
        ("square.stack.3d.up", "Rooms & War Room", "Collaboration and voting · not connected yet"),
        ("waveform", "Sound Library", "Search, preview and mix licensed sounds"),
        ("sparkles", "Spatter", "Local help and editable motion recipes"),
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.sdBackground.ignoresSafeArea()
                Circle()
                    .fill(Color.sdRed.opacity(0.07))
                    .frame(width: 300, height: 300)
                    .blur(radius: 50)
                    .offset(x: backgroundDrift ? 35 : -35, y: -80)
                    .accessibilityHidden(true)
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 0)
                        VStack(spacing: 12) {
                            Text("☠️").font(.system(size: 72)).accessibilityHidden(true)
                            Text("STICKDEATH ∞")
                                .font(.specialElite(28))
                                .tracking(3)
                                .foregroundColor(.sdTextPrimary)
                                .sdRedGlow()
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.75)
                                .accessibilityAddTraits(.isHeader)
                            Text("Create. Animate. Annihilate.")
                                .font(.specialElite(15))
                                .foregroundColor(.sdTextSecondary)
                                .multilineTextAlignment(.center)
                        }
                        if accountUnavailable {
                            Text("Sign-in is unavailable. Your local Studio is ready.")
                                .font(.footnote)
                                .foregroundColor(.sdTextSecondary)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("welcome.account-unavailable")
                        }
                        VStack(spacing: 16) {
                            ForEach(features, id: \.title) { feature in
                                HStack(spacing: 14) {
                                    Image(systemName: feature.icon)
                                        .font(.system(size: 20))
                                        .foregroundColor(.sdRed)
                                        .frame(width: 40, height: 40)
                                        .background(Color.sdRed.opacity(0.12))
                                        .cornerRadius(10)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(feature.title)
                                            .font(.specialElite(15))
                                            .foregroundColor(.sdTextPrimary)
                                        Text(feature.detail)
                                            .font(.subheadline)
                                            .foregroundColor(.sdTextSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.horizontal, 8)
                        VStack(spacing: 12) {
                            Button(action: onSignIn) {
                                Label("Sign In", systemImage: "arrow.right")
                                    .font(.specialElite(16))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 54)
                                    .background(Color.sdPrimaryGradient)
                                    .cornerRadius(14)
                            }
                            .accessibilityIdentifier("welcome.sign-in")
                            Button(action: onCreateAccount) {
                                Text("Create Account")
                                    .font(.specialElite(16))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 54)
                                    .background(Color.white.opacity(0.05))
                                    .overlay(RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1))
                                    .cornerRadius(14)
                            }
                            .accessibilityIdentifier("welcome.create-account")
                            Button(isAuthenticated ? "Open Studio" : "Continue as Guest", action: onGuest)
                                .font(.specialElite(14))
                                .foregroundColor(.sdTextSecondary)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("welcome.guest")
                            Button(guideCompleted ? "Review Studio Guide" : "Studio Guide", action: onGuide)
                                .font(.specialElite(14))
                                .foregroundColor(.sdTextSecondary)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("welcome.guide")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
                .accessibilityIdentifier("welcome.content")
            }
        }
        .buttonStyle(.plain)
        .task(id: reduceMotion) {
            backgroundDrift = false
            guard !reduceMotion else { return }
            // SwiftUI owns this animation. No repeating timer survives dismissal.
            withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) {
                backgroundDrift = true
            }
        }
    }
}
