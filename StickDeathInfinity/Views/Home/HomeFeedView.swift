import SwiftUI
import Supabase

struct HomeFeedView: View {
    @State private var posts: [Post] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showCreatePost = false
    @State private var showNotifications = false
    @State private var notificationCount = 0
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("StickDeath ∞")
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .foregroundColor(.red)
                    
                    Spacer()
                    
                    Button(action: { showNotifications.toggle() }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white.opacity(0.6))
                            if notificationCount > 0 {
                                Text("\(notificationCount)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(3)
                                    .background(Color.red)
                                    .clipShape(Circle())
                                    .offset(x: 6, y: -4)
                            }
                        }
                    }
                    
                    Button(action: { showCreatePost = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.red)
                    }
                    .padding(.leading, 12)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                Divider().background(Color.white.opacity(0.06))
                
                // Feed
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isLoading { ProgressView().tint(.red).padding() }
                        if let loadError { Text(loadError).font(.callout).foregroundColor(.gray).padding() }
                        if !isLoading && posts.isEmpty && loadError == nil {
                            Text("No posts available.").foregroundColor(.gray).padding()
                        }
                        ForEach($posts) { $post in
                            FeedPostCard(post: $post)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showCreatePost) {
            CreatePostView(onBack: { showCreatePost = false }) { content, tags, attachAnimation in
                guard AuthService.shared.isAuthenticated else { throw SocialService.ServiceError.notAuthenticated }
                guard !attachAnimation else { throw FeedActionError.attachmentUnavailable }
                let caption = content + (tags.isEmpty ? "" : "\n\n" + tags.map { "#" + $0 }.joined(separator: " "))
                let post = try await SocialService.shared.createPost(content: caption, mediaURL: nil, projectID: nil)
                posts.insert(post, at: 0)
                showCreatePost = false
            }
        }
        .task { await loadPosts() }
        .refreshable { await loadPosts() }
        .alert("Notifications unavailable", isPresented: $showNotifications) {
            Button("OK", role: .cancel) { }
        } message: { Text("Notifications have not been connected. No unread count is being claimed.") }
    }

    @MainActor private func loadPosts() async {
        guard !isLoading else { return }
        guard AuthService.shared.isAuthenticated else {
            loadError = "Sign in to view the community feed."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            posts = try await SupabaseManager.shared.client.from("posts").select()
                .order("created_at", ascending: false).limit(50).execute().value
            loadError = nil
        } catch {
            loadError = "The feed could not be loaded. Check your connection and account configuration."
        }
    }
}

private enum FeedActionError: LocalizedError {
    case attachmentUnavailable
    var errorDescription: String? { "Select a real rendered Studio file before attaching an animation. Nothing was posted." }
}

struct FeedPostCard: View {
    @Binding var post: Post
    @State private var comments: [Comment] = []
    @State private var liked: Bool?
    @State private var isUpdating = false
    @State private var actionError: String?
    @State private var showComments = false
    @State private var newComment = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Author header
            HStack(spacing: 10) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(Color(hex: "1A1A24"))
                        .frame(width: 36, height: 36)
                    Image(systemName: "person.fill").foregroundColor(.gray)
                        .font(.system(size: 18))
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.username ?? "Member")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(post.createdAt ?? "Date unavailable")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                
                Spacer()
                
                Image(systemName: "ellipsis")
                    .foregroundColor(.white.opacity(0.3))
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            
            // Content preview
            ZStack {
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color(hex: "12121A"))
                    .frame(height: 280)
                
                VStack(spacing: 8) {
                    if let raw = post.mediaURL, let url = URL(string: raw), url.scheme == "https" {
                        Link(destination: url) {
                            VStack(spacing: 12) {
                                Image(systemName: "play.rectangle").font(.system(size: 54))
                                Text("Open attached media").font(.system(size: 14, weight: .bold, design: .monospaced))
                            }.foregroundColor(.white)
                        }
                    } else {
                        Image(systemName: "text.alignleft").font(.system(size: 40)).foregroundColor(.gray)
                        Text(post.content ?? "").font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white).lineLimit(5).padding()
                    }
                }
            }
            
            // Action bar
            HStack(spacing: 20) {
                // Like
                Button(action: { Task { await toggleLike() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: liked == nil ? "questionmark.circle" : liked == true ? "heart.fill" : "heart")
                            .foregroundColor(liked == true ? .red : .white.opacity(0.5))
                        Text("\(post.likeCount)")
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .font(.system(size: 13))
                }
                .disabled(isUpdating || liked == nil)
                .accessibilityLabel(liked == nil ? "Like status unavailable" : liked == true ? "Unlike post" : "Like post")
                
                // Comments
                Button(action: { showComments.toggle(); if showComments { Task { await loadComments() } } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.right")
                        Text("\(post.commentCount)")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
                }
                
                // Share an actual public media URL, when present.
                if let raw = post.mediaURL, let url = URL(string: raw), url.scheme == "https" {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 13)).foregroundColor(.white.opacity(0.5))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            
            // Caption
            if let caption = post.content, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            
            // Comments section
            if showComments {
                VStack(spacing: 0) {
                    ForEach(comments) { comment in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "person.fill").foregroundColor(.gray)
                                .font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(comment.userID == AuthService.shared.userId ? "You" : "Member")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                Text(comment.content)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            Spacer()
                            Text(comment.createdAt ?? "")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                    
                    // Add comment
                    HStack(spacing: 8) {
                        TextField("Add a comment...", text: $newComment)
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color(hex: "1A1A24"))
                            .cornerRadius(8)
                            .disabled(isUpdating)
                        
                        Button(action: { Task { await submitComment() } }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.red)
                        }
                        .disabled(isUpdating)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(Color(hex: "0D0D14"))
            }
            
            if let actionError { Text(actionError).font(.caption).foregroundColor(.red).padding(.horizontal, 16) }
            if liked == nil {
                Button("Retry like status") { Task { await loadLikeStatus() } }
                    .font(.caption)
                    .disabled(isUpdating)
                    .padding(.horizontal, 16)
            }
            Divider().background(Color.white.opacity(0.04))
        }
        .task(id: post.id) { await loadLikeStatus() }
    }

    @MainActor private func loadLikeStatus() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            liked = try await SocialService.shared.isPostLiked(postID: post.id)
            actionError = nil
        } catch {
            liked = nil
            actionError = "Like status could not be loaded. Retry before changing this reaction."
        }
    }

    @MainActor private func toggleLike() async {
        guard !isUpdating, let confirmedLiked = liked else { return }
        guard AuthService.shared.isAuthenticated else { actionError = "Sign in to like a post."; return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            if confirmedLiked { try await SocialService.shared.unlikePost(postID: post.id) }
            else { try await SocialService.shared.likePost(postID: post.id) }
            let refreshedLike = try await SocialService.shared.isPostLiked(postID: post.id)
            let refreshedPost: Post = try await SupabaseManager.shared.client.from("posts").select().eq("id", value: post.id).single().execute().value
            liked = refreshedLike
            post = refreshedPost
            actionError = nil
        } catch {
            liked = nil
            actionError = "The reaction could not be confirmed. Retry like status before changing it again."
        }
    }

    @MainActor private func loadComments() async {
        do {
            comments = try await SocialService.shared.getComments(postID: post.id)
            actionError = nil
        } catch { actionError = "Comments could not be loaded." }
    }

    @MainActor private func submitComment() async {
        let content = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, content.count <= 500, !isUpdating else { return }
        guard AuthService.shared.isAuthenticated, AuthService.shared.userId != nil else { actionError = "Sign in to comment."; return }
        isUpdating = true
        defer { isUpdating = false }
        var insertionConfirmed = false
        do {
            try await SocialService.shared.addComment(postID: post.id, content: content)
            insertionConfirmed = true
            comments = try await SocialService.shared.getComments(postID: post.id)
            post = try await SupabaseManager.shared.client.from("posts").select().eq("id", value: post.id).single().execute().value
            newComment = ""
            actionError = nil
        } catch {
            if insertionConfirmed {
                newComment = ""
                actionError = "Your comment was saved, but the updated conversation could not be loaded. Refresh to see it; do not resend it."
            } else {
                actionError = "The comment could not be confirmed. Your draft is still here. Refresh before trying again."
            }
        }
    }
}
