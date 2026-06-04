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

struct CreatePostView: View {
    @State private var caption = ""
    @State private var selectedType = "animation"
    @State private var visibility = "public"
    @Environment(\.dismiss) var dismiss
    
    let mediaTypes = [
        ("animation", "🎬", "Animation"),
        ("image", "🖼️", "Image"),
        ("video", "📹", "Video"),
        ("audio", "🎵", "Audio"),
    ]
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0A0A0F").ignoresSafeArea()
                
                VStack(spacing: 16) {
                    // Media type picker
                    HStack(spacing: 8) {
                        ForEach(mediaTypes, id: \.0) { type in
                            Button(action: { selectedType = type.0 }) {
                                VStack(spacing: 4) {
                                    Text(type.1)
                                        .font(.system(size: 24))
                                    Text(type.2)
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(selectedType == type.0 ? Color.red.opacity(0.15) : Color(hex: "1A1A24"))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(selectedType == type.0 ? Color.red : Color.clear, lineWidth: 1)
                                )
                            }
                        }
                    }
                    
                    // Caption
                    TextEditor(text: $caption)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .frame(height: 100)
                        .padding(12)
                        .background(Color(hex: "1A1A24"))
                        .cornerRadius(12)
                    
                    // Visibility
                    HStack(spacing: 8) {
                        ForEach(["public", "followers", "private"], id: \.self) { v in
                            Button(action: { visibility = v }) {
                                Text(v == "public" ? "🌍 Public" : v == "followers" ? "👥 Followers" : "🔒 Private")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(visibility == v ? .white : .white.opacity(0.4))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(visibility == v ? Color.red : Color(hex: "1A1A24"))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Post button
                    Button(action: { dismiss() }) {
                        Text("Post")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .cornerRadius(14)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Create Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct FeedPost: Identifiable {
    let id: String
    let username: String
    let avatar: String
    let timeAgo: String
    let title: String
    let previewEmoji: String
    let caption: String
    var likes: Int
    var liked: Bool
    var comments: [PostComment]
    let coins: Int
    let frameCount: Int?
    let fps: Int?
    
    static let samples: [FeedPost] = [
        FeedPost(id: "fp1", username: "StickNinja99", avatar: "🥷", timeAgo: "2h ago", title: "Last Stand", previewEmoji: "⚔️",
                 caption: "My entry for the Last Stand challenge! 48 frames of pure chaos 💀",
                 likes: 127, liked: false,
                 comments: [
                    PostComment(id: "c1", username: "AnimKing", avatar: "👑", text: "The timing on that combo is insane!", timeAgo: "1h ago"),
                    PostComment(id: "c2", username: "xDeathArtist", avatar: "💀", text: "Clean af 🔥", timeAgo: "45m ago"),
                 ],
                 coins: 45, frameCount: 48, fps: 12),
        FeedPost(id: "fp2", username: "FightClubArt", avatar: "🥊", timeAgo: "4h ago", title: "Speed Run", previewEmoji: "🏃",
                 caption: "Fastest run I've ever animated — 0.8 seconds flat",
                 likes: 89, liked: true,
                 comments: [
                    PostComment(id: "c3", username: "PixelWarrior", avatar: "🛡️", text: "How did you get the motion blur effect?", timeAgo: "3h ago"),
                 ],
                 coins: 22, frameCount: 24, fps: 24),
        FeedPost(id: "fp3", username: "StickLord", avatar: "⚡", timeAgo: "6h ago", title: "Meteor Strike", previewEmoji: "☄️",
                 caption: "New effect technique: layered glow + smudge = meteor trail 🌠",
                 likes: 234, liked: false,
                 comments: [],
                 coins: 78, frameCount: 36, fps: 12),
    ]
}

struct PostComment: Identifiable {
    let id: String
    let username: String
    let avatar: String
    let text: String
    let timeAgo: String
}

struct HomeFeedView_Previews: PreviewProvider {
    static var previews: some View {
        HomeFeedView()
    }
}
