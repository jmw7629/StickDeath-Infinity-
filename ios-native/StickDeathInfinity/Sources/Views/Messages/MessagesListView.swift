// MessagesListView.swift — DM thread list + conversation
// Pulls from dm_threads, dm_messages tables
// Bold orange-on-dark theme, matches messaging apps

import SwiftUI

// MARK: - DB Models
struct DMThread: Codable, Identifiable {
    let id: String
    let user_a_id: String
    let user_b_id: String
    let created_at: String?
    let updated_at: String?
}

struct DMMessage: Codable, Identifiable {
    let id: String
    let thread_id: String
    let sender_user_id: String
    let body: String
    let status: String?
    let created_at: String?
}

struct DMThreadDisplay: Identifiable {
    let id: String
    let thread: DMThread
    let otherUserId: String
    let otherUsername: String
    let otherAvatarURL: String?
    let lastMessage: String?
    let lastMessageTime: String?
    let unread: Bool
}

// MARK: - Messages List
struct MessagesListView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var threads: [DMThreadDisplay] = []
    @State private var isLoading = true
    @State private var selectedThread: DMThreadDisplay?
    @State private var showNewMessage = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("MESSAGES")
                            .font(ThemeManager.headlineBold(size: 28))
                            .foregroundStyle(.white)
                        Spacer()
                        Button { showNewMessage = true } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.title3)
                                .foregroundStyle(.orange)
                                .frame(width: 40, height: 40)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    Divider().background(Color(white: 0.15))

                    if isLoading {
                        Spacer()
                        ProgressView().tint(.orange)
                        Spacer()
                    } else if threads.isEmpty {
                        emptyState
                    } else {
                        threadList
                    }
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(item: $selectedThread) { thread in
                ConversationView(thread: thread)
            }
            .task { await loadThreads() }
        }
    }

    // MARK: - Thread List
    var threadList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(threads) { display in
                    Button { selectedThread = display } label: {
                        threadRow(display)
                    }
                    Divider().background(Color(white: 0.1)).padding(.leading, 64)
                }
            }
        }
    }

    func threadRow(_ display: DMThreadDisplay) -> some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(String(display.otherUsername.prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(display.otherUsername)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Spacer()
                    if let time = display.lastMessageTime {
                        Text(timeAgo(time))
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.4))
                    }
                }
                if let msg = display.lastMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                        .lineLimit(1)
                }
            }

            if display.unread {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Empty State
    var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.orange.opacity(0.3))
            Text("NO MESSAGES YET")
                .font(ThemeManager.headlineBold(size: 20))
                .foregroundStyle(.white)
            Text("Start a conversation with a fellow creator")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            Button { showNewMessage = true } label: {
                Text("New Message")
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Load Threads
    func loadThreads() async {
        guard let userId = auth.session?.user.id.uuidString else {
            isLoading = false
            return
        }

        isLoading = true
        do {
            // Get threads where user is participant
            let allThreads: [DMThread] = try await supabase
                .from("dm_threads")
                .select()
                .or("user_a_id.eq.\(userId),user_b_id.eq.\(userId)")
                .order("updated_at", ascending: false)
                .limit(50)
                .execute()
                .value

            var displays: [DMThreadDisplay] = []
            for thread in allThreads {
                let otherId = thread.user_a_id == userId ? thread.user_b_id : thread.user_a_id

                // Get other user's info
                var username = "User"
                if let user: UserProfile = try? await supabase
                    .from("users")
                    .select("id,username,avatar_url,role")
                    .eq("id", value: otherId)
                    .single()
                    .execute()
                    .value {
                    username = user.username ?? "User"
                }

                // Get last message
                let messages: [DMMessage] = try await supabase
                    .from("dm_messages")
                    .select()
                    .eq("thread_id", value: thread.id)
                    .order("created_at", ascending: false)
                    .limit(1)
                    .execute()
                    .value

                displays.append(DMThreadDisplay(
                    id: thread.id,
                    thread: thread,
                    otherUserId: otherId,
                    otherUsername: username,
                    otherAvatarURL: nil,
                    lastMessage: messages.first?.body,
                    lastMessageTime: messages.first?.created_at ?? thread.updated_at,
                    unread: false
                ))
            }
            threads = displays
        } catch {
            print("⚠️ Messages load error: \(error)")
        }
        isLoading = false
    }

    func timeAgo(_ dateStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) else { return "" }
        let diff = Date().timeIntervalSince(date)
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        return "\(Int(diff / 86400))d"
    }
}

// MARK: - Conversation View
struct ConversationView: View {
    let thread: DMThreadDisplay
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var messages: [DMMessage] = []
    @State private var newMessage = ""
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.bold())
                            .foregroundStyle(.orange)
                    }
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 32, height: 32)
                        Text(String(thread.otherUsername.prefix(1)).uppercased())
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    Text(thread.otherUsername)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.05))

                // Messages
                if isLoading {
                    Spacer()
                    ProgressView().tint(.orange)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(messages) { msg in
                                    messageBubble(msg)
                                        .id(msg.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: messages.count) { _, _ in
                            if let last = messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                // Input bar
                inputBar
            }
        }
        .navigationBarHidden(true)
        .task { await loadMessages() }
    }

    func messageBubble(_ msg: DMMessage) -> some View {
        let isMe = msg.sender_user_id == auth.session?.user.id.uuidString
        return HStack {
            if isMe { Spacer(minLength: 60) }
            Text(msg.body)
                .font(.subheadline)
                .foregroundStyle(isMe ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isMe ? Color.orange : Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if !isMe { Spacer(minLength: 60) }
        }
    }

    var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message...", text: $newMessage)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .tint(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.1))
                .clipShape(Capsule())

            Button { Task { await sendMessage() } } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(newMessage.isEmpty ? Color(white: 0.3) : .orange)
            }
            .disabled(newMessage.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.05))
    }

    func loadMessages() async {
        isLoading = true
        do {
            messages = try await supabase
                .from("dm_messages")
                .select()
                .eq("thread_id", value: thread.id)
                .order("created_at", ascending: true)
                .limit(100)
                .execute()
                .value
        } catch {
            print("⚠️ Load messages error: \(error)")
        }
        isLoading = false
    }

    func sendMessage() async {
        let text = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let userId = auth.session?.user.id.uuidString else { return }
        newMessage = ""

        do {
            try await supabase
                .from("dm_messages")
                .insert([
                    "thread_id": thread.id,
                    "sender_user_id": userId,
                    "body": text
                ])
                .execute()
            await loadMessages()
        } catch {
            print("⚠️ Send message error: \(error)")
        }
    }
}

// Make DMThreadDisplay Hashable for NavigationDestination
extension DMThreadDisplay: Hashable {
    static func == (lhs: DMThreadDisplay, rhs: DMThreadDisplay) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
