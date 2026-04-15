// CommentSheet.swift
// Layer 3 — ACTION SCREEN (modal sheet)
//
// Why is the user here?  → Tapped comment button on a post
// Next action?           → Write a comment, or read existing ones
// Back?                  → Dismiss sheet → returns to PostDetail exactly as it was
//
// RULE: Modal screens close, not navigate. This never changes the underlying navigation.

import SwiftUI

struct CommentSheet: View {
    let postId: Int
    @Binding var comments: [PostComment]
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var auth: AuthManager
    @State private var newComment = ""
    @State private var sending = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Comment list ──
                if comments.isEmpty && !sending {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.right")
                            .font(.system(size: 40)).foregroundStyle(.gray)
                        Text("No comments yet")
                            .font(.subheadline.bold())
                        Text("Be the first to share your thoughts!")
                            .font(.caption).foregroundStyle(.gray)
                    }
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(comments) { comment in
                                    CommentBubble(comment: comment)
                                        .id(comment.id)
                                }
                            }
                            .padding(16)
                        }
                        .onChange(of: comments.count) { _, _ in
                            if let last = comments.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }

                Divider().background(ThemeManager.border)

                // ── Input bar ──
                HStack(spacing: 8) {
                    // Avatar
                    Circle()
                        .fill(Color.red.opacity(0.2))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Text(String(auth.currentUser?.username?.prefix(1) ?? "?").uppercased())
                                .font(.caption.bold()).foregroundStyle(.red)
                        )

                    TextField("Add a comment…", text: $newComment, axis: .vertical)
                        .font(.subheadline)
                        .lineLimit(1...4)
                        .padding(10)
                        .background(ThemeManager.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .focused($inputFocused)

                    Button {
                        Task { await sendComment() }
                    } label: {
                        if sending {
                            ProgressView().tint(.red).scaleEffect(0.8)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(newComment.isEmpty ? .gray : .red)
                        }
                    }
                    .disabled(newComment.isEmpty || sending)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ThemeManager.surfaceLight)
            }
            .background(ThemeManager.background)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.red)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { inputFocused = true }
    }

    func sendComment() async {
        guard let userId = auth.session?.user.id, !newComment.isEmpty else { return }
        let text = newComment
        newComment = ""
        sending = true

        // Optimistic add
        let tempComment = PostComment(
            id: Int.random(in: 100_000...999_999),
            post_id: postId,
            user_id: userId.uuidString,
            content: text,
            created_at: ISO8601DateFormatter().string(from: Date()),
            user: FeedUser(username: auth.currentUser?.username, avatar_url: nil)
        )
        comments.append(tempComment)

        // Persist
        _ = try? await supabase.from("comments").insert([
            "post_id": "\(postId)",
            "user_id": userId.uuidString,
            "content": text
        ]).execute()

        HapticManager.shared.buttonTap()
        sending = false
    }
}

// MARK: - Comment Bubble
struct CommentBubble: View {
    let comment: PostComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(ThemeManager.surface)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(comment.user?.username?.prefix(1) ?? "?").uppercased())
                        .font(.caption.bold()).foregroundStyle(.red)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(comment.user?.username ?? "User")
                        .font(.caption.bold())
                    if let date = comment.created_at?.prefix(10) {
                        Text("· \(date)")
                            .font(.caption2).foregroundStyle(.gray)
                    }
                }
                Text(comment.content)
                    .font(.subheadline)
            }

            Spacer()
        }
    }
}
