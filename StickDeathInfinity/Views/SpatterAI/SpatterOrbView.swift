// ═══════════════════════════════════════════════════════════════════
// SpatterOrbView — Floating AI orb + expandable chat panel
// Matches: src/components/SpatterAI/ (Orb + Panel + Chat)
// - Pulsating red/dark orb in corner
// - Tap to expand into chat panel
// - Brain emoji with glow animation
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SpatterOrbView: View {
    @EnvironmentObject var spatterVM: SpatterAIViewModel
    @State private var pulseScale: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero
    @State private var position: CGPoint = CGPoint(x: UIScreen.main.bounds.width - 50, y: UIScreen.main.bounds.height - 200)

    var body: some View {
        ZStack {
            if spatterVM.isExpanded {
                // Expanded chat panel
                SpatterChatPanel()
                    .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
            }

            // Floating orb
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    if spatterVM.isExpanded {
                        spatterVM.isExpanded = false
                    } else {
                        spatterVM.toggleOrb()
                    }
                }
            } label: {
                ZStack {
                    // Outer glow
                    Circle()
                        .fill(Color.sdRed.opacity(0.2))
                        .frame(width: 64, height: 64)
                        .scaleEffect(pulseScale)
                        .blur(radius: 8)

                    // Inner orb
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.sdRedBright, Color.sdRedDeep, Color.sdBackground],
                                center: .center,
                                startRadius: 0,
                                endRadius: 28
                            )
                        )
                        .frame(width: 52, height: 52)
                        .shadow(color: .sdRed.opacity(0.6), radius: 12)

                    // Brain emoji
                    Text("🧠")
                        .font(.system(size: 24))
                }
            }
            .position(position)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        position = CGPoint(
                            x: position.x + value.translation.width - dragOffset.width,
                            y: position.y + value.translation.height - dragOffset.height
                        )
                        dragOffset = value.translation
                    }
                    .onEnded { _ in dragOffset = .zero }
            )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseScale = 1.15
            }
        }
    }
}

// MARK: - Chat Panel
struct SpatterChatPanel: View {
    @EnvironmentObject var spatterVM: SpatterAIViewModel
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("🧠")
                    .font(.system(size: 20))
                Text("Spatter AI")
                    .font(.specialElite(16))
                    .foregroundColor(.sdTextPrimary)
                Spacer()
                Button {
                    withAnimation { spatterVM.isExpanded = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.sdTextMuted)
                }
            }
            .padding(12)
            .background(Color.sdSurface)

            // Messages
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Welcome message
                    if spatterVM.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hey! I'm Spatter, your creative AI assistant 🎨")
                                .font(.system(size: 14))
                                .foregroundColor(.sdTextPrimary)
                            Text("Ask me anything about animation, drawing tips, or how to use the studio tools.")
                                .font(.system(size: 13))
                                .foregroundColor(.sdTextSecondary)
                        }
                        .padding(12)
                        .background(Color.sdSurface2)
                        .cornerRadius(12)
                    }

                    ForEach(spatterVM.messages) { msg in
                        HStack {
                            if msg.role == .user { Spacer() }
                            Text(msg.content)
                                .font(.system(size: 14))
                                .foregroundColor(.sdTextPrimary)
                                .padding(10)
                                .background(msg.role == .user ? Color.sdRed.opacity(0.2) : Color.sdSurface2)
                                .cornerRadius(12)
                            if msg.role == .assistant { Spacer() }
                        }
                    }

                    if spatterVM.isThinking {
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(Color.sdTextMuted)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .padding(10)
                        .background(Color.sdSurface2)
                        .cornerRadius(12)
                    }
                }
                .padding(12)
            }

            // Input
            HStack(spacing: 8) {
                TextField("Ask Spatter...", text: $inputText)
                    .font(.system(size: 14))
                    .foregroundColor(.sdTextPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(16)

                Button {
                    let text = inputText
                    inputText = ""
                    Task { await spatterVM.sendMessage(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(inputText.isEmpty ? .sdTextMuted : .sdRed)
                }
                .disabled(inputText.isEmpty)
            }
            .padding(8)
            .background(Color.sdSurface)
        }
        .frame(width: 320, height: 440)
        .background(Color.sdBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.sdBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20)
        .padding(.trailing, 16)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
