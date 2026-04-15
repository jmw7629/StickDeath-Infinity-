// SpatterOverlay.swift
// Layer 4 — OVERLAY (never changes navigation state)
//
// RULES from Joe:
//  - Not navigation, it's a contextual assistant
//  - Never replaces screens, enhances current screen
//  - Never redirects unexpectedly
//  - Opens as overlay, uses current screen context, suggests next actions
//  - In Studio: suggest scenes/sounds/backgrounds
//  - In Challenges: suggest entry ideas
//  - In Home: suggest content/creators
//  - Closing returns user exactly where they were
//
// Implemented as a ZStack overlay at RootView level, on top of everything.

import SwiftUI

struct SpatterOverlay: View {
    @EnvironmentObject var router: NavigationRouter
    @State private var prompt = ""
    @State private var loading = false
    @State private var chatMessages: [SpatterChatBubble] = []
    @State private var showQuickActions = true
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dimmed backdrop — tap to close
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                // Spatter panel — slides up from bottom
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 0) {
                        // Drag handle
                        Capsule().fill(.gray.opacity(0.5))
                            .frame(width: 40, height: 4)
                            .padding(.top, 8)

                        panelContent
                    }
                    .frame(maxHeight: geo.size.height * 0.65)
                    .background(ThemeManager.background)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .red.opacity(0.2), radius: 20)
                    .offset(y: dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                if v.translation.height > 0 {
                                    dragOffset = v.translation.height
                                }
                            }
                            .onEnded { v in
                                if v.translation.height > 100 {
                                    close()
                                } else {
                                    withAnimation(.spring()) { dragOffset = 0 }
                                }
                            }
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Panel Content
    var panelContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.2)).frame(width: 28, height: 28)
                        Text("🎨").font(.system(size: 14))
                    }
                    Text("Spatter AI").font(.headline)
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                Spacer()
                // Context indicator
                Text(contextLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.red.opacity(0.1))
                    .clipShape(Capsule())
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.gray)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().background(ThemeManager.border)

            // Chat area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if chatMessages.isEmpty {
                            spatterBubble(contextGreeting, isSpatter: true)
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
                        }
                    }
                }
            }

            // Quick actions (context-aware)
            if showQuickActions && chatMessages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(contextQuickActions, id: \.text) { action in
                            QuickChip(icon: action.icon, text: action.text, color: action.color) {
                                sendQuick(action.prompt)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }

            Divider().background(ThemeManager.border)

            // Input
            HStack(spacing: 8) {
                TextField("Ask Spatter…", text: $prompt)
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

    // MARK: - Context-Aware Content

    var contextLabel: String {
        switch router.spatterContext {
        case .home: return "Home"
        case .challenges: return "Challenges"
        case .studio: return "Studio"
        case .profile: return "Profile"
        }
    }

    var contextGreeting: String {
        switch router.spatterContext {
        case .home:
            return "Hey! 🎬 I can help you discover amazing animations, find creators to follow, or suggest what to create next. What's on your mind?"
        case .challenges:
            return "Yo! 🏆 Looking for challenge ideas? I can suggest entry concepts, help with themes, or break down what makes a winning animation!"
        case .studio:
            return "Let's create something epic! 🎨 I can suggest poses, give animation tips, review your work, or help plan fight scenes!"
        case .profile:
            return "Hey there! 👋 I can help you customize your profile, find new creators to connect with, or suggest ways to grow your audience!"
        }
    }

    struct QuickAction {
        let icon: String; let text: String; let color: Color; let prompt: String
    }

    var contextQuickActions: [QuickAction] {
        switch router.spatterContext {
        case .home:
            return [
                QuickAction(icon: "sparkles", text: "Trending now", color: .red,
                            prompt: "What's trending on StickDeath right now?"),
                QuickAction(icon: "person.fill.badge.plus", text: "Suggest creators", color: .cyan,
                            prompt: "Suggest some cool creators I should follow"),
                QuickAction(icon: "lightbulb.fill", text: "Inspire me", color: .yellow,
                            prompt: "Give me an idea for my next animation"),
            ]
        case .challenges:
            return [
                QuickAction(icon: "trophy.fill", text: "Entry ideas", color: .yellow,
                            prompt: "Give me 3 creative entry ideas for the current challenge"),
                QuickAction(icon: "figure.kickboxing", text: "Winning tips", color: .red,
                            prompt: "What makes a challenge entry stand out? Give me tips!"),
                QuickAction(icon: "wand.and.stars", text: "Theme breakdown", color: .purple,
                            prompt: "Break down the challenge theme and suggest creative angles"),
            ]
        case .studio:
            return [
                QuickAction(icon: "figure.stand", text: "Suggest a pose", color: .red,
                            prompt: "Suggest a cool dynamic pose for my stick figure!"),
                QuickAction(icon: "hand.thumbsup.fill", text: "Review my work", color: .green,
                            prompt: "Give me feedback on my current animation"),
                QuickAction(icon: "lightbulb.fill", text: "Animation tip", color: .yellow,
                            prompt: "Give me a quick animation tip I can use right now"),
                QuickAction(icon: "figure.kickboxing", text: "Fight scene", color: .red,
                            prompt: "Help me create an epic fight scene!"),
            ]
        case .profile:
            return [
                QuickAction(icon: "pencil", text: "Bio ideas", color: .cyan,
                            prompt: "Suggest a creative bio for my StickDeath profile"),
                QuickAction(icon: "chart.line.uptrend.xyaxis", text: "Grow audience", color: .green,
                            prompt: "How can I get more followers on StickDeath?"),
                QuickAction(icon: "paintpalette.fill", text: "Style tips", color: .purple,
                            prompt: "How can I develop a unique animation style?"),
            ]
        }
    }

    // MARK: - Chat
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
                .frame(maxWidth: 280, alignment: isSpatter ? .leading : .trailing)
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

    func sendMessage() {
        guard !prompt.isEmpty, !loading else { return }
        let text = prompt
        prompt = ""
        showQuickActions = false
        chatMessages.append(SpatterChatBubble(text: text, isSpatter: false))
        loading = true

        Task {
            do {
                let history = chatMessages.suffix(10).map { msg -> [String: String] in
                    ["role": msg.isSpatter ? "assistant" : "user", "content": msg.text]
                }
                let response = try await SpatterService.shared.chat(
                    message: "\(text)\n\nContext: User is on \(contextLabel) screen",
                    conversationHistory: history
                )
                let reply = response.message ?? "Hmm, brain glitch. Try again!"
                chatMessages.append(SpatterChatBubble(text: reply, isSpatter: true))
            } catch {
                chatMessages.append(SpatterChatBubble(
                    text: "Ugh, I glitched. \(error.localizedDescription). Try again?",
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

    func close() {
        withAnimation(.spring(response: 0.3)) {
            router.closeSpatter()
        }
        // Clear chat on close for fresh context next time
        chatMessages = []
        showQuickActions = true
        dragOffset = 0
    }
}
