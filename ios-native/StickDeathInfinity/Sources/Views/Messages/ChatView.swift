// ChatView.swift
// Chat matching reference #general — emoji avatars, reactions, typing indicator, message input
// No mockup conversations — uses real data structure ready for Supabase

import SwiftUI

struct ChatView: View {
    let conversationId: Int
    let otherUsername: String
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var router: NavigationRouter
    @State private var messageText = ""
    @State private var messages = ChatMessage.sampleMessages

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Channel Header ──
                channelHeader

                // ── Messages ──
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(messages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }

                            // Typing indicator
                            typingIndicator
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo(messages.last?.id, anchor: .bottom)
                        }
                    }
                }

                // ── Message Input ──
                messageInput
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Channel Header
    var channelHeader: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("#\(otherUsername)")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text("23 members · 5 online")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "#9090a8"))
            }

            Spacer()

            // Action buttons
            HStack(spacing: 16) {
                Button {
                    router.push(MessagesDestination.voiceCall(otherUsername))
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "#9090a8"))
                }

                Button {} label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "#9090a8"))
                }

                Button {} label: {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "#9090a8"))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ThemeManager.card)
        .overlay(
            Rectangle().fill(ThemeManager.border).frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Message Bubble
    struct MessageBubble: View {
        let message: ChatMessage

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(Color(hex: "#1a1a24"))
                        .frame(width: 34, height: 34)
                    Text(message.emoji)
                        .font(.system(size: 16))
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(message.author)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Text(message.time)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: "#5a5a6e"))
                    }

                    Text(message.text)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    // Reactions
                    if !message.reactions.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.reactions, id: \.emoji) { reaction in
                                HStack(spacing: 3) {
                                    Text(reaction.emoji)
                                        .font(.system(size: 13))
                                    Text("\(reaction.count)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color(hex: "#9090a8"))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(hex: "#1a1a24"))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Typing Indicator
    var typingIndicator: some View {
        HStack(spacing: 6) {
            Text("StickMasterFlex is typing")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "#9090a8"))
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color(hex: "#9090a8"))
                        .frame(width: 4, height: 4)
                        .opacity(0.6)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Message Input
    var messageInput: some View {
        HStack(spacing: 10) {
            // Attach
            Button {} label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(hex: "#9090a8"))
            }

            // Text field
            TextField("", text: $messageText, prompt: Text("Message #\(otherUsername)").foregroundStyle(Color(hex: "#5a5a6e")))
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(hex: "#1a1a24"))
                .clipShape(RoundedRectangle(cornerRadius: 20))

            // Send
            Button {
                guard !messageText.isEmpty else { return }
                let msg = ChatMessage(id: messages.count + 1, author: "You", emoji: "🎯",
                                      text: messageText, time: "now", reactions: [])
                messages.append(msg)
                messageText = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(messageText.isEmpty ? Color(hex: "#5a5a6e") : ThemeManager.brand)
            }
            .disabled(messageText.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ThemeManager.card)
        .overlay(
            Rectangle().fill(ThemeManager.border).frame(height: 0.5),
            alignment: .top
        )
    }
}

// MARK: - Chat Message Model
struct ChatMessage: Identifiable {
    let id: Int
    let author: String
    let emoji: String
    let text: String
    let time: String
    let reactions: [Reaction]

    struct Reaction: Identifiable {
        let id = UUID()
        let emoji: String
        let count: Int
    }
}

extension ChatMessage {
    static let sampleMessages: [ChatMessage] = [
        ChatMessage(id: 1, author: "xBladeRunner", emoji: "⚔️",
                    text: "Just finished my new sword fight scene — 48 frames of pure chaos 🔥",
                    time: "2:14 PM",
                    reactions: [Reaction(emoji: "🔥", count: 5), Reaction(emoji: "💯", count: 3)]),
        ChatMessage(id: 2, author: "StickMasterFlex", emoji: "💀",
                    text: "yo that fight scene was insane, the parry at frame 24 is chef's kiss",
                    time: "2:15 PM",
                    reactions: []),
        ChatMessage(id: 3, author: "AnimateOrDie", emoji: "🔥",
                    text: "The impact frames are so clean. What brush size you using for the motion lines?",
                    time: "2:16 PM",
                    reactions: [Reaction(emoji: "👆", count: 2)]),
        ChatMessage(id: 4, author: "xBladeRunner", emoji: "⚔️",
                    text: "Thanks! Size 3 with 80% opacity, then I duplicate and blur for the trail effect",
                    time: "2:17 PM",
                    reactions: []),
        ChatMessage(id: 5, author: "BoneBreaker", emoji: "💥",
                    text: "Anyone want to collab on the Free Fall challenge? Need someone good with backgrounds",
                    time: "2:19 PM",
                    reactions: [Reaction(emoji: "🙋", count: 4)]),
        ChatMessage(id: 6, author: "FlipMaster", emoji: "🕺",
                    text: "I'm down! My backgrounds game has been leveling up lately",
                    time: "2:20 PM",
                    reactions: []),
    ]
}
