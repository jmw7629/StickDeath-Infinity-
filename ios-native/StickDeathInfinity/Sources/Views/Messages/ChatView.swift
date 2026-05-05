// ChatView.swift
// Pixel-perfect match to reference #general — colored initial-circle avatars,
// colored reaction badges, thread replies, typing indicator, hamburger menu header

import SwiftUI

struct ChatView: View {
    let conversationId: Int
    let otherUsername: String
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var router: NavigationRouter
    @State private var messageText = ""
    @State private var messages = ChatMessage.sampleMessages
    @State private var showSearch = false
    @State private var showPinned = false
    @State private var showMembers = false
    @State private var searchQuery = ""

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            VStack(spacing: 0) {
                channelHeader

                if showSearch { searchBar }
                if showPinned { pinnedPanel }
                if showMembers { membersPanel }

                dateDivider

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredMessages) { msg in
                                MessageBubble(message: msg, onReact: { emoji in
                                    toggleReaction(msgId: msg.id, emoji: emoji)
                                })
                                .id(msg.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo(messages.last?.id, anchor: .bottom)
                        }
                    }
                }

                typingIndicator
                messageInput
            }
        }
        .navigationBarHidden(true)
    }

    var filteredMessages: [ChatMessage] {
        guard !searchQuery.isEmpty else { return messages }
        return messages.filter {
            $0.text.localizedCaseInsensitiveContains(searchQuery) ||
            $0.author.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    func toggleReaction(msgId: Int, emoji: String) {
        guard let idx = messages.firstIndex(where: { $0.id == msgId }) else { return }
        if let rIdx = messages[idx].reactions.firstIndex(where: { $0.emoji == emoji }) {
            messages[idx].reactions[rIdx].count += 1
        } else {
            messages[idx].reactions.append(ChatMessage.Reaction(emoji: emoji, count: 1))
        }
    }

    // MARK: - Channel Header (matches reference: ≡ # general 👥 23 / subtitle / 🔍 📌 👥)
    var channelHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Hamburger / back
                Button { dismiss() } label: {
                    Text("≡")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("#")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: "#9090a8"))
                        Text(otherUsername)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        HStack(spacing: 3) {
                            Text("👥")
                                .font(.system(size: 12))
                            Text("23")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: "#72728a"))
                        }
                    }
                    Text("General community chat")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "#72728a"))
                }

                Spacer()

                // Header icons
                Button { showSearch.toggle(); showPinned = false; showMembers = false } label: {
                    Text("🔍")
                        .font(.system(size: 18))
                        .opacity(showSearch ? 1.0 : 0.6)
                }
                Button { showPinned.toggle(); showSearch = false; showMembers = false } label: {
                    Text("📌")
                        .font(.system(size: 18))
                        .opacity(showPinned ? 1.0 : 0.6)
                }
                Button { showMembers.toggle(); showSearch = false; showPinned = false } label: {
                    Text("👥")
                        .font(.system(size: 18))
                        .opacity(showMembers ? 1.0 : 0.6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ThemeManager.card)

            Rectangle().fill(ThemeManager.border).frame(height: 0.5)
        }
    }

    // MARK: - Search Bar
    var searchBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $searchQuery, prompt: Text("Search messages...").foregroundStyle(Color(hex: "#5a5a6e")))
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(hex: "#1a1a24"))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button { showSearch = false; searchQuery = "" } label: {
                Text("✕").foregroundStyle(Color(hex: "#72728a"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ThemeManager.card)
        .overlay(Rectangle().fill(ThemeManager.border).frame(height: 0.5), alignment: .bottom)
    }

    // MARK: - Pinned Panel
    var pinnedPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PINNED MESSAGES")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "#72728a"))

            ForEach(["📌 Challenge rules: Max 120 frames, original work only",
                      "📌 Export fix coming in next update — stay tuned!",
                      "📌 Welcome new members! Read #tips-tricks to get started"], id: \.self) { pin in
                Text(pin)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#9090a8"))
                    .padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(ThemeManager.card)
        .overlay(Rectangle().fill(ThemeManager.border).frame(height: 0.5), alignment: .bottom)
    }

    // MARK: - Members Panel
    var membersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MEMBERS — 7")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "#72728a"))

            ForEach(ChatMember.allMembers) { member in
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        Circle()
                            .fill(member.color)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Text(member.initials)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                        Circle()
                            .fill(member.status == "online" ? .green :
                                  member.status == "idle" ? .yellow : Color(hex: "#5a5a6e"))
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(ThemeManager.card, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
                    Text(member.name)
                        .font(.system(size: 13))
                        .foregroundStyle(member.status == "offline" ? Color(hex: "#72728a") : .white)
                }
            }
        }
        .padding(12)
        .frame(maxHeight: 200)
        .background(ThemeManager.card)
        .overlay(Rectangle().fill(ThemeManager.border).frame(height: 0.5), alignment: .bottom)
    }

    // MARK: - Date Divider
    var dateDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(ThemeManager.border).frame(height: 0.5)
            Text("Today")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "#72728a"))
            Rectangle().fill(ThemeManager.border).frame(height: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Typing Indicator
    var typingIndicator: some View {
        HStack(spacing: 0) {
            Text("StickMasterFlex is typing...")
                .font(.system(size: 13).italic())
                .foregroundStyle(Color(hex: "#72728a"))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Message Input (📎 · input · 😀 · ▶)
    var messageInput: some View {
        HStack(spacing: 8) {
            Button {} label: {
                Text("📎").font(.system(size: 20))
            }

            ZStack(alignment: .trailing) {
                TextField("", text: $messageText, prompt: Text("Message #\(otherUsername)").foregroundStyle(Color(hex: "#5a5a6e")))
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.trailing, 32)
                    .padding(.vertical, 10)
                    .background(Color(hex: "#1a1a24"))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(ThemeManager.border, lineWidth: 0.5)
                    )

                Button {} label: {
                    Text("😀")
                        .font(.system(size: 18))
                }
                .padding(.trailing, 10)
            }

            Button {
                guard !messageText.isEmpty else { return }
                let now = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                let msg = ChatMessage(
                    id: messages.count + 100,
                    initials: "JW", author: "joe_willis",
                    text: messageText, time: formatter.string(from: now),
                    reactions: [], thread: nil
                )
                messages.append(msg)
                messageText = ""
            } label: {
                Circle()
                    .fill(messageText.isEmpty ? Color(hex: "#1a1a24") : ThemeManager.brand)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text("▶")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Message Bubble (colored initial avatar, colored reactions, thread replies)
    struct MessageBubble: View {
        let message: ChatMessage
        let onReact: (String) -> Void
        @State private var showEmojiPicker = false

        static let avatarColors: [String: Color] = [
            "AD": Color(hex: "#8b5cf6"), "NS": Color(hex: "#3b82f6"),
            "XB": Color(hex: "#ef4444"), "JW": Color(hex: "#22c55e"),
            "SM": Color(hex: "#f59e0b"), "AO": Color(hex: "#ec4899"),
            "SP": Color(hex: "#6366f1"), "NE": Color(hex: "#14b8a6"),
        ]

        static let reactionColors: [String: Color] = [
            "👍": Color(hex: "#3b82f6"), "🔥": Color(hex: "#ef4444"),
            "😁": Color(hex: "#eab308"), "👏": Color(hex: "#22c55e"),
            "⚔️": Color(hex: "#8b5cf6"), "🤖": Color(hex: "#6366f1"),
            "😮": Color(hex: "#f59e0b"), "💯": Color(hex: "#ef4444"),
        ]

        var avatarColor: Color {
            Self.avatarColors[message.initials] ?? Color(hex: "#1a1a24")
        }

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                // Colored initial circle avatar
                Circle()
                    .fill(avatarColor)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Text(message.initials)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    // Author + time
                    HStack(spacing: 8) {
                        Text(message.author)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text(message.time)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "#5a5a6e"))
                    }

                    // Message text
                    Text(message.text)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    // Colored reactions
                    if !message.reactions.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.reactions) { reaction in
                                let color = Self.reactionColors[reaction.emoji] ?? .white
                                Button { onReact(reaction.emoji) } label: {
                                    HStack(spacing: 4) {
                                        Text(reaction.emoji)
                                            .font(.system(size: 14))
                                        Text("\(reaction.count)")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background(color.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20)
                                            .stroke(color.opacity(0.25), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 20))
                                }
                            }

                            // Add reaction +
                            Button { showEmojiPicker.toggle() } label: {
                                Circle()
                                    .fill(Color(hex: "#1a1a24"))
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(ThemeManager.border, lineWidth: 1)
                                    )
                                    .overlay(
                                        Text("+")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color(hex: "#72728a"))
                                    )
                            }
                        }
                        .padding(.top, 4)
                    }

                    // Thread replies
                    if let thread = message.thread {
                        HStack(spacing: 6) {
                            Text("💬")
                                .font(.system(size: 13))
                            Text("\(thread.replies) replies")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: "#3b82f6"))
                            Text("·")
                                .foregroundStyle(Color(hex: "#5a5a6e"))
                            Text(thread.lastReply)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: "#5a5a6e"))
                        }
                        .padding(.top, 4)
                    }

                    // Emoji picker
                    if showEmojiPicker {
                        let emojis = ["👍","🔥","😁","👏","💯","❤️","😮","💀","⚔️","🤖","😂","🙏"]
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 4) {
                            ForEach(emojis, id: \.self) { e in
                                Button {
                                    onReact(e)
                                    showEmojiPicker = false
                                } label: {
                                    Text(e)
                                        .font(.system(size: 18))
                                        .frame(width: 34, height: 34)
                                        .background(Color(hex: "#1a1a24"))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .padding(8)
                        .background(ThemeManager.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(ThemeManager.border, lineWidth: 0.5)
                        )
                        .padding(.top, 4)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Chat Member
struct ChatMember: Identifiable {
    let id = UUID()
    let initials: String
    let name: String
    let color: Color
    let status: String // online, idle, offline

    static let allMembers: [ChatMember] = [
        ChatMember(initials: "AD", name: "AnimateOrDie", color: Color(hex: "#8b5cf6"), status: "online"),
        ChatMember(initials: "NS", name: "NeonStick", color: Color(hex: "#3b82f6"), status: "online"),
        ChatMember(initials: "XB", name: "xBladeRunner", color: Color(hex: "#ef4444"), status: "online"),
        ChatMember(initials: "JW", name: "joe_willis", color: Color(hex: "#22c55e"), status: "online"),
        ChatMember(initials: "SM", name: "StickMasterFlex", color: Color(hex: "#f59e0b"), status: "online"),
        ChatMember(initials: "SP", name: "ShadowPuppet", color: Color(hex: "#6366f1"), status: "idle"),
        ChatMember(initials: "NE", name: "NeonGhost", color: Color(hex: "#14b8a6"), status: "offline"),
    ]
}

// MARK: - Chat Message Model
struct ChatMessage: Identifiable {
    let id: Int
    let initials: String
    let author: String
    let text: String
    let time: String
    var reactions: [Reaction]
    let thread: ThreadInfo?

    struct Reaction: Identifiable {
        let id = UUID()
        let emoji: String
        var count: Int
    }

    struct ThreadInfo {
        let replies: Int
        let lastReply: String
    }
}

extension ChatMessage {
    static let sampleMessages: [ChatMessage] = [
        ChatMessage(id: 1, initials: "AD", author: "AnimateOrDie",
                    text: "Just submitted my Free Fall entry. 60fps smooth baby 🥳",
                    time: "11:42 AM",
                    reactions: [Reaction(emoji: "👍", count: 4), Reaction(emoji: "🔥", count: 2), Reaction(emoji: "😁", count: 1)],
                    thread: nil),
        ChatMessage(id: 2, initials: "NS", author: "NeonStick",
                    text: "Anyone else having trouble with the export? Keeps dropping to 480p even on Pro tier",
                    time: "11:45 AM",
                    reactions: [],
                    thread: ThreadInfo(replies: 3, lastReply: "Last reply 5 min ago")),
        ChatMessage(id: 3, initials: "XB", author: "xBladeRunner",
                    text: "yo anyone doing the challenge? need a collab partner for a two-person fight scene",
                    time: "11:48 AM",
                    reactions: [Reaction(emoji: "⚔️", count: 1)],
                    thread: nil),
        ChatMessage(id: 4, initials: "JW", author: "joe_willis",
                    text: "I'm down. DM me the storyboard @xBladeRunner",
                    time: "11:50 AM",
                    reactions: [],
                    thread: nil),
        ChatMessage(id: 5, initials: "SM", author: "StickMasterFlex",
                    text: "bruh the Spatter AI just gave me a perfect walk cycle suggestion. game changer 🤖",
                    time: "11:53 AM",
                    reactions: [Reaction(emoji: "🤖", count: 6), Reaction(emoji: "😮", count: 3)],
                    thread: nil),
    ]
}
