// OnboardingView.swift
// v3: "Show don't tell" onboarding — 86/100 top apps have zero tutorial screens
// Interactive mini-studio on page 2, instant value within 5 seconds
// Adaptive sizing for all devices (iPhone/iPad/Mac)

import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @Environment(\.deviceContext) var ctx
    @State private var currentPage = 0
    @State private var animateHero = false
    @State private var miniPoses: [String: CGPoint] = StickFigure.defaultJoints
    @State private var dragging: String?

    private let pageCount = 4

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Pages ──
                TabView(selection: $currentPage) {
                    welcomePage.tag(0)
                    interactiveDemoPage.tag(1)
                    publishPage.tag(2)
                    goPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // ── Bottom controls ──
                VStack(spacing: 16) {
                    // Page dots
                    HStack(spacing: 6) {
                        ForEach(0..<pageCount, id: \.self) { i in
                            Capsule()
                                .fill(i == currentPage ? Color.red : Color.gray.opacity(0.3))
                                .frame(width: i == currentPage ? 20 : 6, height: 6)
                                .animation(.spring(response: 0.3), value: currentPage)
                        }
                    }

                    HStack(spacing: 12) {
                        if currentPage > 0 {
                            Button { withAnimation { currentPage -= 1 } } label: {
                                Text("Back").font(.subheadline.bold()).foregroundStyle(.gray)
                                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                                    .background(ThemeManager.surface).clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        Button {
                            if currentPage < pageCount - 1 {
                                withAnimation { currentPage += 1 }
                            } else {
                                completeOnboarding()
                            }
                        } label: {
                            Text(currentPage < pageCount - 1 ? "Next" : "Let's Go!")
                                .font(.headline).foregroundStyle(.black)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(.red).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .frame(maxWidth: ctx.maxContentWidth)
                    .padding(.horizontal, 24)

                    if currentPage < pageCount - 1 {
                        Button("Skip") { completeOnboarding() }
                            .font(.caption).foregroundStyle(.gray)
                    }
                }
                .padding(.bottom, ctx.current == .phoneCompact ? 30 : 40)
            }
        }
        .onAppear { animateHero = true }
    }

    // MARK: - Page 1: Welcome (5-second rule — instant visual wow)
    var welcomePage: some View {
        ScrollView {
            VStack(spacing: ctx.current == .phoneCompact ? 20 : 30) {
                Spacer().frame(height: ctx.current == .phoneCompact ? 40 : 60)

                // Animated hero
                ZStack {
                    // Outer glow rings
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(.red.opacity(0.1 - Double(i) * 0.03), lineWidth: 2)
                            .frame(width: CGFloat(120 + i * 40), height: CGFloat(120 + i * 40))
                            .scaleEffect(animateHero ? 1.0 : 0.7)
                            .animation(
                                .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                                    .delay(Double(i) * 0.2),
                                value: animateHero
                            )
                    }

                    // Icon
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [.red, .red.opacity(0.6)], center: .center, startRadius: 0, endRadius: 50))
                            .frame(width: 100, height: 100)
                        Image(systemName: "figure.run")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)
                            .scaleEffect(animateHero ? 1.0 : 0.85)
                            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: animateHero)
                    }
                }

                // Title: animated staggered text
                VStack(spacing: 4) {
                    Text("StickDeath")
                        .font(.system(size: ctx.current == .phoneCompact ? 32 : 40, weight: .bold))
                        .offset(y: animateHero ? 0 : 20)
                        .opacity(animateHero ? 1 : 0)
                        .animation(.easeOut(duration: 0.8).delay(0.2), value: animateHero)
                    Text("Infinity ∞")
                        .font(.system(size: ctx.current == .phoneCompact ? 28 : 36, weight: .bold))
                        .foregroundStyle(.red)
                        .offset(y: animateHero ? 0 : 20)
                        .opacity(animateHero ? 1 : 0)
                        .animation(.easeOut(duration: 0.8).delay(0.5), value: animateHero)
                }

                Text("Create. Animate. Share with millions.")
                    .font(.subheadline).foregroundStyle(.gray)
                    .opacity(animateHero ? 1 : 0)
                    .animation(.easeOut(duration: 0.8).delay(0.8), value: animateHero)

                Spacer()
            }
            .frame(maxWidth: ctx.maxContentWidth)
        }
    }

    // MARK: - Page 2: Interactive Mini-Studio (SHOW don't tell!)
    var interactiveDemoPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Try it — drag the joints!")
                    .font(.headline)
                    .padding(.top, ctx.current == .phoneCompact ? 24 : 40)

                Text("This is how you'll pose stick figures in the studio")
                    .font(.caption).foregroundStyle(.gray)

                // Mini canvas with interactive stick figure
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black)
                        .frame(height: ctx.current == .phoneCompact ? 280 : 360)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(ThemeManager.border, lineWidth: 1)
                        )

                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)

                        // Draw bones
                        for (from, to) in StickFigure.bones {
                            if let a = miniPoses[from], let b = miniPoses[to] {
                                var path = Path()
                                path.move(to: CGPoint(x: center.x + a.x, y: center.y + a.y))
                                path.addLine(to: CGPoint(x: center.x + b.x, y: center.y + b.y))
                                context.stroke(path, with: .color(.white), lineWidth: 3)
                            }
                        }

                        // Draw head
                        if let head = miniPoses["head"] {
                            let headRect = CGRect(
                                x: center.x + head.x - 12,
                                y: center.y + head.y - 12,
                                width: 24, height: 24
                            )
                            context.fill(Path(ellipseIn: headRect), with: .color(.white))
                        }

                        // Draw joints as orange dots
                        for (name, pos) in miniPoses {
                            let dotSize: CGFloat = name == dragging ? 16 : 10
                            let dotRect = CGRect(
                                x: center.x + pos.x - dotSize / 2,
                                y: center.y + pos.y - dotSize / 2,
                                width: dotSize, height: dotSize
                            )
                            context.fill(Path(ellipseIn: dotRect), with: .color(.red))
                        }
                    }
                    .frame(height: ctx.current == .phoneCompact ? 280 : 360)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let canvasCenter = CGPoint(
                                    x: (UIScreen.main.bounds.width - 48) / 2,
                                    y: (ctx.current == .phoneCompact ? 280 : 360) / 2
                                )
                                let touchOffset = CGPoint(
                                    x: value.location.x - canvasCenter.x,
                                    y: value.location.y - canvasCenter.y
                                )

                                // Find nearest joint
                                if dragging == nil {
                                    var closest: String?
                                    var closestDist: CGFloat = 40 // hit radius
                                    for (name, pos) in miniPoses {
                                        let dist = hypot(pos.x - touchOffset.x, pos.y - touchOffset.y)
                                        if dist < closestDist { closest = name; closestDist = dist }
                                    }
                                    dragging = closest
                                }

                                if let joint = dragging {
                                    miniPoses[joint] = touchOffset
                                }
                            }
                            .onEnded { _ in dragging = nil }
                    )

                    // Hint pulse
                    if dragging == nil {
                        VStack {
                            Spacer()
                            HStack {
                                Image(systemName: "hand.point.up.left.fill")
                                    .font(.caption)
                                Text("Drag the orange dots")
                                    .font(.caption)
                            }
                            .foregroundStyle(.red.opacity(0.6))
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.bottom, 12)
                        }
                    }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }

    // MARK: - Page 3: Publish to Everywhere
    var publishPage: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: ctx.current == .phoneCompact ? 40 : 60)

                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)

                Text("Your Art\nGoes Everywhere")
                    .font(.system(size: ctx.current == .phoneCompact ? 26 : 32, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("Every animation you publish uploads to StickDeath channels across all major platforms")
                    .font(.subheadline).foregroundStyle(.gray).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Platform icons
                VStack(spacing: 12) {
                    platformRow("YouTube", icon: "play.rectangle.fill", color: .red)
                    platformRow("TikTok", icon: "music.note", color: .pink)
                    platformRow("Instagram", icon: "camera.fill", color: .purple)
                    platformRow("Facebook", icon: "person.2.fill", color: .blue)
                    platformRow("Discord", icon: "bubble.left.and.bubble.right.fill", color: .indigo)
                    platformRow("+ Your Own Accounts", icon: "person.circle", color: .red)
                }
                .padding(.horizontal, 40)

                Spacer()
            }
        }
    }

    func platformRow(_ name: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            Text(name).font(.subheadline)
            Spacer()
            Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
        .background(ThemeManager.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Page 4: Go!
    var goPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: ctx.current == .phoneCompact ? 40 : 60)

                Image(systemName: "star.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)

                Text("Ready to Create?")
                    .font(.system(size: ctx.current == .phoneCompact ? 26 : 32, weight: .bold))

                Text("Join thousands of stick figure animators.\nYour first animation is just a few taps away.")
                    .font(.subheadline).foregroundStyle(.gray).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(alignment: .leading, spacing: 10) {
                    benefitRow("✨ Free to start — no credit card needed")
                    benefitRow("🎬 Publish to millions of viewers instantly")
                    benefitRow("🤖 AI assistant available with Pro ($4.99/mo)")
                    benefitRow("🏆 Earn achievements as you create")
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
    }

    func benefitRow(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.85))
    }

    // MARK: - Complete
    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        withAnimation(.easeInOut(duration: 0.4)) { isComplete = true }
    }
}
