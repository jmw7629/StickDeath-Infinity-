import SwiftUI

struct HomeFeedView: View {
    @State private var posts: [FeedPost] = FeedPost.samples
    @State private var showCreatePost = false
    @State private var showNotifications = false
    @State private var notificationCount = 3
    
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
                        ForEach($posts) { $post in
                            FeedPostCard(post: $post)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showCreatePost) {
            CreatePostView()
        }
    }
}

struct FeedPostCard: View {
    @Binding var post: FeedPost
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
                    Text(post.avatar)
                        .font(.system(size: 18))
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.username)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(post.timeAgo)
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
                    Text(post.previewEmoji)
                        .font(.system(size: 64))
                    Text(post.title)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    if let frames = post.frameCount {
                        Text("\(frames) frames · \(post.fps ?? 12) FPS")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            
            // Action bar
            HStack(spacing: 20) {
                // Like
                Button(action: {
                    post.liked.toggle()
                    post.likes += post.liked ? 1 : -1
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: post.liked ? "heart.fill" : "heart")
                            .foregroundColor(post.liked ? .red : .white.opacity(0.5))
                        Text("\(post.likes)")
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .font(.system(size: 13))
                }
                
                // Comments
                Button(action: { showComments.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.right")
                        Text("\(post.comments.count)")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
                }
                
                // Share
                Button(action: {}) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                }
                
                Spacer()
                
                // Coins
                HStack(spacing: 2) {
                    Text("🪙")
                        .font(.system(size: 10))
                    Text("\(post.coins)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.yellow)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            
            // Caption
            if !post.caption.isEmpty {
                Text(post.caption)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            
            // Comments section
            if showComments {
                VStack(spacing: 0) {
                    ForEach(post.comments) { comment in
                        HStack(alignment: .top, spacing: 8) {
                            Text(comment.avatar)
                                .font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(comment.username)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                Text(comment.text)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            Spacer()
                            Text(comment.timeAgo)
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
                        
                        Button(action: {
                            if !newComment.isEmpty {
                                let comment = PostComment(
                                    id: UUID().uuidString,
                                    username: "J_Willy_Style",
                                    avatar: "👑",
                                    text: newComment,
                                    timeAgo: "now"
                                )
                                post.comments.append(comment)
                                newComment = ""
                            }
                        }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(Color(hex: "0D0D14"))
            }
            
            Divider().background(Color.white.opacity(0.04))
        }
    }
}

