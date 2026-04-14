// SpatterStudioPanel.swift
// Spatter AI integration inside the Studio
// Replaces the generic AI Assist panel with Spatter's personality
// Spatter can: suggest poses, give feedback, generate animations, teach techniques

import SwiftUI

struct SpatterStudioPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var prompt = ""
    @State private var loading = false
    @State private var chatMessages: [SpatterChatBubble] = []
    @State private var showQuickActions = true

    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("Spatter AI", icon: "sparkles", onClose: onClose) {
                // Spatter's mood indicator
                HStack(spacing: 3) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("online").font(.system(size: 9)).foregroundStyle(.green)
                }
            }

            // Chat history
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        // Intro message (always shown)
                        if chatMessages.isEmpty {
                            spatterBubble(
                                "Yo! I'm Spatter. 🎨 I can help with poses, animation tips, or just vibe about stick figures. What're you working on?",
                                isSpatter: true
                            )
                        }

                        ForEach(chatMessages) { msg in
                            spatterBubble(msg.text, isSpatter: msg.isSpatter)
                                .id(msg.id)
                        }

                        if loading {
                            HStack(spacing: 6) {
                                spatterAvatar
                                TypingIndicator()
                            }
                            .padding(.horizontal, 12)
                            .id("loading")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: chatMessages.count) { _, _ in
                    withAnimation {
                        if let lastId = chatMessages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        } else {
                            proxy.scrollTo("loading", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxHeight: 160)

            // Quick action chips (collapsed after first use)
            if showQuickActions && chatMessages.isEmpty {
                quickActions
            }

            Divider().background(ThemeManager.border)

            // Input
            HStack(spacing: 8) {
                TextField("Ask Spatter anything...", text: $prompt)
                    .font(.subheadline)
                    .padding(10)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .submitLabel(.send)
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    if loading {
                        ProgressView().tint(.red).scaleEffect(0.8)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .foregroundStyle(prompt.isEmpty ? .gray : .red)
                    }
                }
                .disabled(prompt.isEmpty || loading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Quick Actions
    var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                QuickChip(icon: "figure.stand", text: "Suggest a pose", color: .red) {
                    sendQuick("Suggest a cool pose for my stick figure. Something dynamic!")
                }
                QuickChip(icon: "hand.thumbsup.fill", text: "Review my work", color: .green) {
                    sendQuick("Look at my animation so far and give me feedback. I have \(vm.frames.count) frames with \(vm.figures.count) figure(s).")
                }
                QuickChip(icon: "wand.and.stars", text: "Auto-tween", color: .purple) {
                    sendQuick("Generate smooth in-between frames for my animation. I have frames \(vm.currentFrameIndex + 1) to \(vm.frames.count).")
                }
                QuickChip(icon: "lightbulb.fill", text: "Animation tip", color: .yellow) {
                    sendQuick("Give me a quick animation tip I can apply right now.")
                }
                QuickChip(icon: "figure.kickboxing", text: "Fight scene", color: .red) {
                    sendQuick("Help me create an epic fight scene. What poses and timing should I use?")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Chat Bubble
    @ViewBuilder
    func spatterBubble(_ text: String, isSpatter: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if isSpatter { spatterAvatar }

            Text(text)
                .font(.subheadline)
                .padding(10)
                .background(isSpatter ? ThemeManager.surface : Color.red.opacity(0.15))
                .foregroundStyle(isSpatter ? .white : .red)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 260, alignment: isSpatter ? .leading : .trailing)

            if !isSpatter { Spacer() }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: isSpatter ? .leading : .trailing)
    }

    var spatterAvatar: some View {
        ZStack {
            Circle().fill(Color.red.opacity(0.2)).frame(width: 24, height: 24)
            Text("🎨").font(.system(size: 12))
        }
    }

    // MARK: - Send
    func sendMessage() {
        guard !prompt.isEmpty, !loading else { return }
        let text = prompt
        prompt = ""
        showQuickActions = false

        chatMessages.append(SpatterChatBubble(text: text, isSpatter: false))
        loading = true

        Task {
            do {
                // Build context about current project state
                let context = buildProjectContext()
                let history = chatMessages.suffix(10).map { msg -> [String: String] in
                    ["role": msg.isSpatter ? "assistant" : "user", "content": msg.text]
                }

                let response = try await SpatterService.shared.chat(
                    message: "\(text)\n\nContext: \(context)",
                    conversationHistory: history
                )

                let replyText = response.message ?? "Hmm, I got nothing. Try asking differently!"

                // If Spatter suggested poses, format them nicely
                var fullReply = replyText
                if let poses = response.poses, !poses.isEmpty {
                    fullReply += "\n\n"
                    for pose in poses {
                        fullReply += "💀 \(pose.name ?? "Pose"): \(pose.description ?? "")\n"
                    }
                }
                if let tips = response.tips, !tips.isEmpty {
                    fullReply += "\n\n" + tips.map { "💡 \($0)" }.joined(separator: "\n")
                }

                chatMessages.append(SpatterChatBubble(text: fullReply, isSpatter: true))
            } catch {
                chatMessages.append(SpatterChatBubble(
                    text: "Ugh, my brain glitched. \(error.localizedDescription). Try again?",
                    isSpatter: true
                ))
            }
            loading = false
        }
    }

    func sendQuick(_ text: String) {
        prompt = text
        sendMessage()
    }

    func buildProjectContext() -> String {
        var parts: [String] = []
        parts.append("Frames: \(vm.frames.count)")
        parts.append("Figures: \(vm.figures.count)")
        parts.append("Current frame: \(vm.currentFrameIndex + 1)")
        parts.append("Mode: \(vm.mode)")
        parts.append("Sound clips: \(vm.soundClips.count)")
        if let fig = vm.selectedFigure {
            parts.append("Selected figure: \(fig.name)")
            if let frame = vm.frames[safe: vm.currentFrameIndex],
               let state = frame.figureStates.first(where: { $0.figureId == fig.id }) {
                parts.append("Current joints: \(state.joints)")
            }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Data
struct SpatterChatBubble: Identifiable {
    let id = UUID().uuidString  // String ID so it works with scrollTo("loading")
    let text: String
    let isSpatter: Bool
}

// MARK: - Quick Action Chip
struct QuickChip: View {
    let icon: String
    let text: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(text).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
        }
    }
}

// MARK: - Typing Indicator (animated dots)
struct TypingIndicator: View {
    @State private var dotIndex = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.red.opacity(i == dotIndex ? 1.0 : 0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(10)
        .background(ThemeManager.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onReceive(timer) { _ in
            dotIndex = (dotIndex + 1) % 3
        }
    }
}
