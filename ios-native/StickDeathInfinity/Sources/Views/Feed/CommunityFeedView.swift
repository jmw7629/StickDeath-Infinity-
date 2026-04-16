// CommunityFeedView.swift
// Home tab now has 2 sub-tabs: Feed (published animations) + Community Chat
// Gap analysis said "feed not community chat" — this adds real-time community chat

import SwiftUI

struct CommunityFeedView: View {
    @EnvironmentObject var auth: AuthManager
    @StateObject private var realtime = RealtimeManager.shared
    @State private var selectedSegment = 0  // 0 = Feed, 1 = Chat
    @State private var chatMessage = ""
    @State private var chatMessages: [CommunityChatMessage] = []
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            // Segmented control: Feed | Chat
            Picker("", selection: $selectedSegment) {
                HStack(spacing: 4) {
                    Image(systemName: "film.fill")
                    Text("Feed")
                }.tag(0)
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text("Chat")
                    if realtime.unreadMessages > 0 {
                        Text("\(realtime.unreadMessages)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .background(.red)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }.tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Content
            if selectedSegment == 0 {
                // Original feed (HomeView already handles this)
                feedPlaceholder
            } else {
                communityChatView
            }
        }
        .task {
            await realtime.subscribeAll()
            await loadChatHistory()
        }
    }

    // MARK: - Feed Placeholder (delegates to existing HomeView scroll content)
    var feedPlaceholder: some View {
        VStack {
            // Live indicator
            if !realtime.liveFeedItems.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("\(realtime.liveFeedItems.count) new animations")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.08))
            }

            Text("Animation feed renders here via HomeView\'s existing PostCard list")
                .font(.caption)
                .foregroundStyle(.gray)
                .padding(.top, 40)

            Spacer()
        }
    }

    // MARK: - Community Chat
    var communityChatView: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(chatMessages) { msg in
                            chatBubble(msg)
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: chatMessages.count) { _, _ in
                    if let last = chatMessages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input
            HStack(spacing: 8) {
                TextField("Say something...", text: $chatMessage)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onSubmit { sendMessage() }

                Button { sendMessage() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .disabled(chatMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    func chatBubble(_ msg: CommunityChatMessage) -> some View {
        let isMe = msg.userId == auth.session?.user.id.uuidString

        HStack(alignment: .top, spacing: 6) {
            if isMe { Spacer() }

            if !isMe {
                // Avatar
                Circle()
                    .fill(.gray.opacity(0.3))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text(String(msg.username.prefix(1)).uppercased())
                            .font(.system(size: 12, weight: .bold))
                    )
            }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                if !isMe {
                    Text(msg.username)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                }

                Text(msg.content)
                    .font(.subheadline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isMe ? Color.red.opacity(0.2) : ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Text(msg.timestamp, style: .time)
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
            }

            if !isMe { Spacer() }
        }
    }

    // MARK: - Actions
    func sendMessage() {
        let text = chatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let userId = auth.session?.user.id.uuidString else { return }

        let newMsg = CommunityChatMessage(
            id: UUID(),
            userId: userId,
            username: auth.currentUser?.username ?? "anon",
            content: text,
            timestamp: Date()
        )

        chatMessages.append(newMsg)
        chatMessage = ""

        Task {
            do {
                try await supabase.from("messages").insert([
                    "sender_id": userId,
                    "conversation_id": "00000000-0000-0000-0000-000000000001",  // Community channel
                    "content": text,
                ]).execute()
            } catch {
                print("⚠️ Failed to send community message: \(error)")
            }
        }
    }

    func loadChatHistory() async {
        do {
            struct ChatRow: Decodable {
                let id: UUID
                let sender_id: String
                let content: String
                let created_at: String
            }

            let rows: [ChatRow] = try await supabase
                .from("messages")
                .select("id, sender_id, content, created_at")
                .eq("conversation_id", value: "00000000-0000-0000-0000-000000000001")
                .order("created_at", ascending: true)
                .limit(100)
                .execute()
                .value

            chatMessages = rows.map { row in
                CommunityChatMessage(
                    id: row.id,
                    userId: row.sender_id,
                    username: row.sender_id.prefix(8).description,
                    content: row.content,
                    timestamp: ISO8601DateFormatter().date(from: row.created_at) ?? Date()
                )
            }
        } catch {
            print("⚠️ Failed to load chat: \(error)")
        }
    }
}

// MARK: - Community Chat Message
struct CommunityChatMessage: Identifiable {
    let id: UUID
    let userId: String
    let username: String
    let content: String
    let timestamp: Date
}
