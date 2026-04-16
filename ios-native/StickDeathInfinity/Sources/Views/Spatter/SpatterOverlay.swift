// SpatterOverlay.swift
// Layer 4 — OVERLAY (never changes navigation state)
// Matches web SpatterOverlay.tsx exactly
//
// RULES from Joe:
//  - Not navigation, it's a contextual assistant
//  - Never replaces screens, enhances current screen
//  - Never redirects unexpectedly
//  - Opens as overlay, uses current screen context, suggests next actions
//  - Closing returns user exactly where they were

import SwiftUI

// MARK: - Mode Tabs (match web)
private enum SpatterTab: String, CaseIterable {
    case chat = "Chat"
    case generate = "Generate"
    case assets = "Assets"
    case history = "History"

    var icon: String {
        switch self {
        case .chat: return "sparkles"
        case .generate: return "lightbulb.fill"
        case .assets: return "paintpalette.fill"
        case .history: return "clock.fill"
        }
    }
}

struct SpatterOverlay: View {
    @EnvironmentObject var router: NavigationRouter
    @State private var prompt = ""
    @State private var loading = false
    @State private var chatMessages: [SpatterChatBubble] = []
    @State private var activeTab: SpatterTab = .chat
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dimmed backdrop — tap to close
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                // Panel — slides up from bottom
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 0) {
                        // Handle bar
                        Capsule()
                            .fill(Color(hex: "#3a3a4a"))
                            .frame(width: 40, height: 4)
                            .padding(.top, 8)
                            .padding(.bottom, 4)

                        // Header
                        panelHeader

                        Divider().background(ThemeManager.border)

                        // Chat area
                        chatArea

                        // Quick chips
                        quickChips

                        // Input
                        inputBar
                    }
                    .frame(maxHeight: geo.size.height * 0.8)
                    .background(ThemeManager.surfaceLight)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(ThemeManager.border, lineWidth: 1)
                    )
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
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Header (matches web: blood drop + name + online + mode tabs)
    var panelHeader: some View {
        HStack {
            // Left: Blood drop + "Spatter" + online indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(ThemeManager.brand.opacity(0.2))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "drop.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(ThemeManager.brand)
                    )

                Text("Spatter")
                    .font(.custom("SpecialElite-Regular", size: 14, relativeTo: .subheadline))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                HStack(spacing: 3) {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                    Text("online")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            // Right: Mode tabs (match web)
            HStack(spacing: 1) {
                ForEach(SpatterTab.allCases, id: \.self) { tab in
                    Button {
                        activeTab = tab
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 9))
                            Text(tab.rawValue)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(activeTab == tab ? .white : ThemeManager.textDim)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(activeTab == tab ? ThemeManager.brand : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(2)
            .background(ThemeManager.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Chat Area
    var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // Context greeting (always shown first)
                    spatterBubble(contextGreeting, isSpatter: true)

                    // Chat messages
                    ForEach(chatMessages) { msg in
                        spatterBubble(msg.text, isSpatter: msg.isSpatter)
                            .id(msg.id)
                    }

                    // Typing indicator
                    if loading {
                        HStack(spacing: 6) {
                            bloodDropAvatar
                            HStack(spacing: 4) {
                                ForEach(0..<3, id: \.self) { i in
                                    Circle()
                                        .fill(ThemeManager.textDim)
                                        .frame(width: 5, height: 5)
                                        .offset(y: loading ? -3 : 0)
                                        .animation(
                                            .easeInOut(duration: 0.4)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(i) * 0.15),
                                            value: loading
                                        )
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(ThemeManager.border, lineWidth: 1)
                            )
                        }
                        .padding(.horizontal, 12)
                        .id("loading")
                    }
                }
                .padding(.vertical, 10)
            }
            .frame(minHeight: 200)
            .onChange(of: chatMessages.count) { _, _ in
                withAnimation {
                    if let lastId = chatMessages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Quick Chips (context-aware, match web)
    var quickChips: some View {
        Group {
            if chatMessages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(contextChips, id: \.self) { chip in
                            Button {
                                prompt = chip
                                sendMessage()
                            } label: {
                                Text(chip)
                                    .font(.system(size: 10))
                                    .foregroundStyle(ThemeManager.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(ThemeManager.surface)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(ThemeManager.border, lineWidth: 1)
                                    )
                            }
                            .disabled(loading)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Input Bar
    var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask Spatter anything...", text: $prompt)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .submitLabel(.send)
                .onSubmit { sendMessage() }

            Button(action: sendMessage) {
                if loading {
                    ProgressView().tint(.red).scaleEffect(0.7)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(prompt.isEmpty ? ThemeManager.border : ThemeManager.brand)
                }
            }
            .disabled(prompt.isEmpty || loading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ThemeManager.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(ThemeManager.border, lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 4)
    }

    // MARK: - Chat Bubbles (match web styling)
    @ViewBuilder
    func spatterBubble(_ text: String, isSpatter: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if isSpatter {
                bloodDropAvatar
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "#c0c0d0"))
                    .lineSpacing(2)
                    .padding(10)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(ThemeManager.border, lineWidth: 1)
                    )
                    .frame(maxWidth: 280, alignment: .leading)
                Spacer(minLength: 20)
            } else {
                Spacer(minLength: 40)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineSpacing(2)
                    .padding(10)
                    .background(ThemeManager.brand)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
    }

    var bloodDropAvatar: some View {
        Circle()
            .fill(ThemeManager.brand.opacity(0.2))
            .frame(width: 26, height: 26)
            .overlay(
                Image(systemName: "drop.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ThemeManager.brand)
            )
    }

    // MARK: - Context-Aware Content (match web getContextGreeting)
    var contextGreeting: String {
        switch router.spatterContext {
        case .home:
            return "Need inspiration? Ask me about trending styles, animation ideas, or how to grow your audience."
        case .challenges:
            return "Looking at challenges? I can help with concepts, techniques, or planning your entry."
        case .studio(let project):
            if project != nil {
                return "I'm your studio assistant — poses, tips, fight choreography, tool help, anything. What do you need?"
            }
            return "Need help picking a project or getting started? Ask me anything about animation!"
        case .profile:
            return "I can help you grow your audience, optimize your profile, or plan your next content."
        }
    }

    var contextChips: [String] {
        switch router.spatterContext {
        case .home:
            return ["What's trending?", "Content ideas", "How to go viral", "Inspiration"]
        case .challenges:
            return ["Challenge tips", "How to win", "Brainstorm ideas", "Remix strategy"]
        case .studio(let project):
            if project != nil {
                return ["Suggest a pose", "Animation tip", "Fight scene help", "How to use onion skinning"]
            }
            return ["Start a project", "What should I animate?", "Template ideas", "Studio shortcuts"]
        case .profile:
            return ["Grow followers", "Best post times", "Profile tips", "Content ideas"]
        }
    }

    // MARK: - Send Message
    func sendMessage() {
        guard !prompt.isEmpty, !loading else { return }
        let text = prompt
        prompt = ""
        chatMessages.append(SpatterChatBubble(text: text, isSpatter: false))
        loading = true

        Task {
            do {
                let history = chatMessages.suffix(10).map { msg -> [String: String] in
                    ["role": msg.isSpatter ? "assistant" : "user", "content": msg.text]
                }
                let contextLabel: String
                switch router.spatterContext {
                case .home: contextLabel = "Home"
                case .challenges: contextLabel = "Challenges"
                case .studio: contextLabel = "Studio"
                case .profile: contextLabel = "Profile"
                }
                let response = try await SpatterService.shared.chat(
                    message: "\(text)\n\nContext: User is on \(contextLabel) screen",
                    conversationHistory: history
                )
                let reply = response.message ?? "Hmm, brain glitch 💀 Try again?"
                chatMessages.append(SpatterChatBubble(text: reply, isSpatter: true))
            } catch {
                chatMessages.append(SpatterChatBubble(
                    text: "Connection hiccup 💀 Try again?",
                    isSpatter: true
                ))
            }
            loading = false
        }
    }

    func close() {
        withAnimation(.spring(response: 0.3)) {
            router.closeSpatter()
        }
        chatMessages = []
        activeTab = .chat
        dragOffset = 0
    }
}

// SpatterChatBubble, TypingIndicator, QuickChip defined in SpatterStudioPanel.swift
