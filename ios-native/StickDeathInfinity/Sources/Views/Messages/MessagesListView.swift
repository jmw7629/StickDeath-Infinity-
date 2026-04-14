// MessagesListView.swift
// Chat/DM list — community messaging

import SwiftUI

struct MessagesListView: View {
    @State private var conversations: [ConversationPreview] = []
    @State private var loading = true
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                if loading {
                    ProgressView().tint(.red)
                } else if conversations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 48))
                            .foregroundStyle(.gray)
                        Text("No messages yet")
                            .font(.title3.bold())
                        Text("Start a conversation with another creator")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                    }
                } else {
                    List {
                        ForEach(conversations) { convo in
                            NavigationLink {
                                ChatView(conversationId: convo.id, otherUsername: convo.username)
                            } label: {
                                HStack(spacing: 12) {
                                    // Avatar
                                    Circle()
                                        .fill(ThemeManager.surface)
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Text(String(convo.username.prefix(1)).uppercased())
                                                .font(.headline)
                                                .foregroundStyle(.red)
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(convo.username)
                                            .font(.subheadline.bold())
                                        Text(convo.lastMessage)
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if convo.unread {
                                        Circle()
                                            .fill(.red)
                                            .frame(width: 8, height: 8)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(ThemeManager.background)
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "Search messages")
                }
            }
            .navigationTitle("Messages")
            .task { await loadConversations() }
        }
    }

    func loadConversations() async {
        loading = true
        // Load from Supabase conversations table
        do {
            guard let userId = AuthManager.shared.session?.user.id else { return }
            struct ConvoRow: Decodable {
                let id: Int
                let user1_id: String
                let user2_id: String
                let last_message: String?
                let updated_at: String?
            }
            let rows: [ConvoRow] = try await supabase
                .from("conversations")
                .select()
                .or("user1_id.eq.\(userId.uuidString),user2_id.eq.\(userId.uuidString)")
                .order("updated_at", ascending: false)
                .execute()
                .value

            conversations = rows.map {
                ConversationPreview(
                    id: $0.id,
                    username: "User",
                    lastMessage: $0.last_message ?? "...",
                    unread: false
                )
            }
        } catch {
            print("Messages error: \(error)")
        }
        loading = false
    }
}

struct ConversationPreview: Identifiable {
    let id: Int
    let username: String
    let lastMessage: String
    let unread: Bool
}

// MARK: - Chat View
struct ChatView: View {
    let conversationId: Int
    let otherUsername: String
    @State private var messages: [Message] = []
    @State private var newMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { msg in
                            ChatBubble(
                                text: msg.content,
                                isOwn: msg.sender_id == AuthManager.shared.session?.user.id.uuidString,
                                time: String(msg.created_at.suffix(8).prefix(5))
                            )
                            .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            // Input
            HStack(spacing: 8) {
                TextField("Message...", text: $newMessage)
                    .padding(10)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Button {
                    Task { await sendMessage() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(.red)
                        .padding(10)
                }
                .disabled(newMessage.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ThemeManager.surfaceLight)
        }
        .navigationTitle(otherUsername)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMessages() }
    }

    func loadMessages() async {
        messages = (try? await supabase
            .from("messages")
            .select()
            .eq("conversation_id", value: conversationId)
            .order("created_at")
            .execute()
            .value) ?? []
    }

    func sendMessage() async {
        guard let userId = AuthManager.shared.session?.user.id else { return }
        let text = newMessage
        newMessage = ""
        _ = try? await supabase
            .from("messages")
            .insert([
                "conversation_id": "\(conversationId)",
                "sender_id": userId.uuidString,
                "content": text
            ])
            .execute()
        await loadMessages()
    }
}

struct ChatBubble: View {
    let text: String
    let isOwn: Bool
    let time: String

    var body: some View {
        HStack {
            if isOwn { Spacer() }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
                Text(text)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isOwn ? Color.red : ThemeManager.surface)
                    .foregroundStyle(isOwn ? .black : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(time)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }
            if !isOwn { Spacer() }
        }
    }
}
