// ═══════════════════════════════════════════════════════════════════
// SpatterChatView — Full Spatter AI chat interface
// Matches: src/pages/SpatterChat.tsx
// Spatter is NOT a chatbot — it's an AI creative operating system
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SpatterChatView: View {
    @EnvironmentObject var spatterVM: SpatterAIViewModel
    @State private var input = ""
    @State private var isAnimatingOrb = false

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    // Mini orb icon for chat header
                    ZStack {
                        Circle()
                            .fill(RadialGradient(
                                colors: [Color.sdRedBright, Color.sdRedDeep],
                                center: .center, startRadius: 0, endRadius: 16))
                            .frame(width: 40, height: 40)
                            .shadow(color: .sdRed.opacity(0.5), radius: 6)
                        Text("🧠").font(.system(size: 18))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spatter 💀")
                            .font(.specialElite(18))
                            .foregroundColor(.sdTextPrimary)
                        Text(spatterVM.statusText)
                            .font(.system(size: 11))
                            .foregroundColor(.sdTextMuted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.sdSurface)

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(spatterVM.messages) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: spatterVM.messages.count) { _ in
                        if let last = spatterVM.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                // Quick actions
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        quickAction("💡 Animation tips")
                        quickAction("🎬 Scene ideas")
                        quickAction("🔥 Fight choreography")
                        quickAction("🎨 Style advice")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(Color.sdSurface)

                // Input
                HStack(spacing: 12) {
                    TextField("Ask Spatter anything...", text: $input)
                        .font(.system(size: 14))
                        .foregroundColor(.sdTextPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.sdSurface2)
                        .cornerRadius(20)

                    Button {
                        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        Task {
                            await spatterVM.sendMessage(input)
                        }
                        input = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(input.isEmpty ? .sdTextMuted : .sdRed)
                    }
                    .disabled(input.isEmpty || spatterVM.isThinking)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.sdSurface)
            }
        }
    }

    private func quickAction(_ text: String) -> some View {
        Button {
            input = text.replacingOccurrences(of: "💡 ", with: "")
                .replacingOccurrences(of: "🎬 ", with: "")
                .replacingOccurrences(of: "🔥 ", with: "")
                .replacingOccurrences(of: "🎨 ", with: "")
        } label: {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.sdTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.sdSurface2)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.sdBorder, lineWidth: 1)
                )
        }
    }
}

// MARK: - Chat Bubble
private struct ChatBubble: View {
    let message: SpatterMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundColor(message.role == .user ? .white : .sdTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.role == .user
                            ? AnyShapeStyle(LinearGradient(colors: [.sdRed, .sdRedDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(Color.sdSurface2)
                    )
                    .cornerRadius(16)

                Text(message.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundColor(.sdTextMuted)
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Spatter Message Model
struct SpatterMessage: Identifiable {
    let id: String
    let role: SpatterRole
    let content: String
    let timestamp: Date
    var mood: String?

    enum SpatterRole {
        case user, assistant
    }
}
