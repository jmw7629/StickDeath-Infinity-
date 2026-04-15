// ChatView.swift
// Layer 2 — CONTEXT (pushed from Messages within Profile tab)
// Back returns to MessagesListView

import SwiftUI

struct ChatView: View {
    let conversationId: Int
    let otherUsername: String
    @EnvironmentObject var auth: AuthManager
    @State private var messages: [Message] = []
    @State private var newMessage = ""
    @State private var loading = true
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { msg in
                            let isMe = msg.sender_id == auth.session?.user.id.uuidString
                            HStack {
                                if isMe { Spacer() }
                                Text(msg.content)
                                    .font(.subheadline)
                                    .padding(10)
                                    .background(isMe ? Color.red.opacity(0.2) : ThemeManager.surface)
                                    .foregroundStyle(isMe ? .red : .white)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: 260, alignment: isMe ? .trailing : .leading)
                                if !isMe { Spacer() }
                            }
                            .padding(.horizontal, 12)
                            .id(msg.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider().background(ThemeManager.border)

            // Input
            HStack(spacing: 8) {
                TextField("Message…", text: $newMessage)
                    .font(.subheadline)
                    .padding(10)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await sendMessage() } }

                Button {
                    Task { await sendMessage() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(newMessage.isEmpty ? .gray : .red)
                }
                .disabled(newMessage.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ThemeManager.surfaceLight)
        }
        .background(ThemeManager.background)
        .navigationTitle(otherUsername)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMessages() }
    }

    func loadMessages() async {
        loading = true
        messages = (try? await supabase
            .from("messages")
            .select()
            .eq("conversation_id", value: conversationId)
            .order("created_at")
            .execute()
            .value) ?? []
        loading = false
    }

    func sendMessage() async {
        guard let userId = auth.session?.user.id, !newMessage.isEmpty else { return }
        let text = newMessage
        newMessage = ""

        let temp = Message(id: Int.random(in: 100000...999999), conversation_id: conversationId,
                           sender_id: userId.uuidString, content: text, created_at: ISO8601DateFormatter().string(from: Date()))
        messages.append(temp)

        _ = try? await supabase.from("messages").insert([
            "conversation_id": "\(conversationId)",
            "sender_id": userId.uuidString,
            "content": text
        ]).execute()
    }
}
