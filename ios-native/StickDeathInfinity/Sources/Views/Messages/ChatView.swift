// ═══════════════════════════════════════════════════════════════════
// ChatRoomView — Individual chat conversation
// Matches: MessagesScreen.tsx MessageBubble exactly
// - Sender name (red for channel), message content, time
// - Reactions (emoji + count), quick reaction bar on tap
// - Reply quotes, voice messages, images, videos
// - Read receipts (✓ ✓✓ colored)
// - Input bar: attach button, text field, send button
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct ChatRoomView: View {
    let room: ChatRoom
    @EnvironmentObject var authVM: AuthViewModel
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var isLoading = true
    @State private var replyTo: ChatMessage? = nil

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    // Room name/icon
                    if let emoji = room.emoji {
                        Text(emoji)
                            .font(.system(size: 24))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name ?? "Chat")
                            .font(.specialElite(16))
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        if let members = room.memberCount {
                            Text("\(members) members")
                                .font(.system(size: 12))
                                .foregroundColor(.sdTextSecondary)
                        }
                    }
                    Spacer()
                    // Phone / Video buttons
                    Button {} label: {
                        Image(systemName: "phone.fill")
                            .foregroundColor(.sdTextSecondary)
                    }
                    Button {} label: {
                        Image(systemName: "video.fill")
                            .foregroundColor(.sdTextSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.sdSurface)
                .overlay(
                    Rectangle().fill(Color.sdBorder).frame(height: 1),
                    alignment: .bottom
                )

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if isLoading {
                                ProgressView()
                                    .tint(.sdRed)
                                    .padding(40)
                            }

                            ForEach(messages) { msg in
                                MessageBubble(
                                    message: msg,
                                    isMe: msg.senderID == authVM.user?.id,
                                    onReact: { emoji in reactToMessage(msg, emoji: emoji) },
                                    onReply: { replyTo = msg }
                                )
                                .id(msg.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                // Reply preview
                if let reply = replyTo {
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(Color.sdRed)
                            .frame(width: 3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(reply.senderUsername ?? "User")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.sdRed)
                            Text(reply.content)
                                .font(.system(size: 11))
                                .foregroundColor(.sdTextSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button { replyTo = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.sdTextMuted)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                }

                // Input bar
                HStack(spacing: 12) {
                    Button {} label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.sdTextMuted)
                    }

                    TextField("Message...", text: $input)
                        .font(.system(size: 14))
                        .foregroundColor(.sdTextPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.sdSurface2)
                        .cornerRadius(20)

                    // Voice record button
                    Button {} label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.sdTextMuted)
                    }

                    // Send
                    Button { sendMessage() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(input.isEmpty ? .sdTextMuted : .sdRed)
                    }
                    .disabled(input.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.sdSurface)
            }
        }
        .navigationBarHidden(true)
        .task { await loadMessages() }
    }

    private func loadMessages() async {
        do {
            messages = try await MessageService.shared.fetchMessages(roomID: room.id)
            isLoading = false
        } catch {
            isLoading = false
        }
    }

    private func sendMessage() {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty,
              let userID = authVM.user?.id else { return }

        let text = input
        input = ""

        Task {
            if let msg = try? await MessageService.shared.sendMessage(
                roomID: room.id,
                senderID: userID,
                content: text,
                replyToID: replyTo?.id
            ) {
                messages.append(msg)
                replyTo = nil
            }
        }
    }

    private func reactToMessage(_ msg: ChatMessage, emoji: String) {
        // Toggle reaction
        Task {
            try? await MessageService.shared.toggleReaction(messageID: msg.id, emoji: emoji)
        }
    }
}

// MARK: - Message Bubble (matches MessageBubble from React)
private struct MessageBubble: View {
    let message: ChatMessage
    let isMe: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void

    @State private var showReactions = false

    private let quickReactions = ["👍", "❤️", "😂", "💀", "🔥", "😮"]

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                if isMe { Spacer(minLength: 60) }

                VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                    // Reply quote
                    if let reply = message.replyTo {
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(Color.sdRed)
                                .frame(width: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reply.sender)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.sdRed)
                                Text(reply.content)
                                    .font(.system(size: 11))
                                    .foregroundColor(.sdTextSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(6)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(6)
                    }

                    // Sender name (for channel messages)
                    if !isMe, let username = message.senderUsername {
                        Text(username)
                            .font(.specialElite(12))
                            .fontWeight(.bold)
                            .foregroundColor(.sdRed)
                    }

                    // Content
                    if message.type == .voice {
                        VoiceMessageBubble(duration: message.voiceDuration ?? 5, isMe: isMe)
                    } else {
                        Text(message.content)
                            .font(.specialElite(14))
                            .foregroundColor(.white)
                            .lineSpacing(4)
                    }

                    // Reactions
                    if !message.reactions.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(Array(message.reactions.keys.sorted()), id: \.self) { emoji in
                                if let data = message.reactions[emoji] {
                                    Button { onReact(emoji) } label: {
                                        HStack(spacing: 2) {
                                            Text(emoji).font(.system(size: 11))
                                            Text("\(data.count)")
                                                .font(.specialElite(10))
                                                .foregroundColor(data.reacted ? .sdRed : .sdTextMuted)
                                        }
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            data.reacted
                                                ? Color.sdRed.opacity(0.15)
                                                : Color.white.opacity(0.05)
                                        )
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(
                                                    data.reacted ? Color.sdRed : Color.sdBorder,
                                                    lineWidth: 1
                                                )
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.top, 2)
                    }

                    // Footer: time + read receipt
                    HStack(spacing: 4) {
                        if message.edited == true {
                            Text("Edited")
                                .font(.system(size: 9))
                                .italic()
                                .foregroundColor(.sdTextMuted)
                        }
                        Text(message.timeString)
                            .font(.specialElite(10))
                            .foregroundColor(.sdTextMuted)
                        if isMe {
                            ReadReceiptView(status: message.readStatus ?? .sent)
                        }
                    }
                }
                .padding(12)
                .background(
                    isMe
                        ? Color.sdRed.opacity(0.25)
                        : Color.sdSurfaceLight
                )
                .cornerRadius(12, corners: isMe ? [.topLeft, .bottomLeft, .bottomRight] : [.topRight, .bottomLeft, .bottomRight])
                .onTapGesture { showReactions.toggle() }
                .onLongPressGesture { showReactions = true }

                if !isMe { Spacer(minLength: 60) }
            }

            // Quick reactions
            if showReactions {
                HStack(spacing: 2) {
                    ForEach(quickReactions, id: \.self) { emoji in
                        Button {
                            onReact(emoji)
                            showReactions = false
                        } label: {
                            Text(emoji)
                                .font(.system(size: 14))
                                .frame(width: 30, height: 30)
                                .background(Color.sdSurfaceLight)
                                .clipShape(Circle())
                        }
                    }

                    Button {
                        onReply()
                        showReactions = false
                    } label: {
                        HStack(spacing: 4) {
                            Text("↩️")
                            Text("Reply")
                                .font(.specialElite(11))
                                .foregroundColor(.sdBlue)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color.sdSurfaceLight)
                        .cornerRadius(15)
                    }
                }
                .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
                .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Voice Message Bubble
private struct VoiceMessageBubble: View {
    let duration: Int
    let isMe: Bool

    @State private var playing = false

    var body: some View {
        HStack(spacing: 10) {
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(isMe ? .white : .sdRed)
            }

            // Waveform bars
            HStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isMe ? Color.white.opacity(0.6) : Color.sdRed.opacity(0.5))
                        .frame(width: 3, height: CGFloat.random(in: 6...24))
                }
            }

            Text(formatDuration(duration))
                .font(.specialElite(12))
                .foregroundColor(isMe ? .white.opacity(0.7) : .sdTextSecondary)
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Read Receipt
private struct ReadReceiptView: View {
    let status: MessageReadStatus

    var body: some View {
        switch status {
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10))
                .foregroundColor(.sdTextMuted)
        case .delivered:
            HStack(spacing: -4) {
                Image(systemName: "checkmark").font(.system(size: 10))
                Image(systemName: "checkmark").font(.system(size: 10))
            }
            .foregroundColor(.sdTextMuted)
        case .read:
            HStack(spacing: -4) {
                Image(systemName: "checkmark").font(.system(size: 10))
                Image(systemName: "checkmark").font(.system(size: 10))
            }
            .foregroundColor(.sdBlue)
        }
    }
}

// MARK: - Corner radius helper
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

// MARK: - Color extension
private extension Color {
    static let sdBlue = Color(hex: "#3B82F6")
}
