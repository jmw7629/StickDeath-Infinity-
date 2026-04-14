// FeedView.swift — Community feed
// Pulls from community_posts table, shows animations from all creators
// Bold orange-on-dark theme, card-based layout

import SwiftUI

// MARK: - DB Model
struct CommunityPost: Codable, Identifiable {
    let id: Int
    let owner_user_id: String
    let project_id: Int?
    let title: String
    let description: String?
    let thumbnail_url: String?
    let video_url: String?
    let duration_ms: Int?
    let status: String?
    let like_count: Int?
    let save_count: Int?
    let view_count: Int?
    let created_at: String?
}

struct CommunityPostWithAuthor: Identifiable {
    let id: Int
    let post: CommunityPost
    let author: PostAuthor?
}

struct PostAuthor: Codable {
    let username: String?
    let avatar_url: String?
}

// MARK: - Feed View
struct FeedView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var posts: [CommunityPost] = []
    @State private var isLoading = true
    @State private var selectedTab: FeedTab = .trending

    enum FeedTab: String, CaseIterable {
        case trending = "Trending"
        case latest = "Latest"
        case challenges = "Challenges"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    header

                    // Tab picker
                    tabPicker

                    // Content
                    if isLoading {
                        Spacer()
                        ProgressView().tint(.orange).scaleEffect(1.2)
                        Spacer()
                    } else if posts.isEmpty {
                        emptyState
                    } else {
                        feed
                    }
                }
            }
            .navigationBarHidden(true)
            .task { await loadPosts() }
        }
    }

    // MARK: - Header
    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("COMMUNITY")
                    .font(ThemeManager.headlineBold(size: 28))
                    .foregroundStyle(.white)
                Text("See what creators are making")
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.5))
            }
            Spacer()
            // Notification bell
            Button {} label: {
                Image(systemName: "bell.fill")
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
    }

    // MARK: - Tab Picker
    var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(FeedTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue.uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selectedTab == tab ? .black : Color(white: 0.5))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selectedTab == tab ? Color.orange : Color(white: 0.1))
                        .clipShape(Capsule())
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Feed
    var feed: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(posts) { post in
                    PostCard(post: post)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .refreshable { await loadPosts() }
    }

    // MARK: - Empty State
    var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.orange.opacity(0.3))
            Text("NO ANIMATIONS YET")
                .font(ThemeManager.headlineBold(size: 20))
                .foregroundStyle(.white)
            Text("Be the first to publish!")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            Spacer()
        }
    }

    // MARK: - Load Posts
    func loadPosts() async {
        isLoading = true
        do {
            let orderCol = selectedTab == .latest ? "created_at" : "like_count"
            let result: [CommunityPost] = try await supabase
                .from("community_posts")
                .select()
                .eq("status", value: "approved")
                .order(orderCol, ascending: false)
                .limit(50)
                .execute()
                .value
            posts = result
        } catch {
            print("⚠️ Feed load error: \(error)")
            // Show empty state rather than crash
        }
        isLoading = false
    }
}

// MARK: - Post Card
struct PostCard: View {
    let post: CommunityPost

    @State private var liked = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.08))
                    .aspectRatio(16/9, contentMode: .fit)

                if let url = post.thumbnail_url, let imageURL = URL(string: url) {
                    AsyncImage(url: imageURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        thumbnailPlaceholder
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    thumbnailPlaceholder
                }

                // Duration badge
                if let ms = post.duration_ms, ms > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(formatDuration(ms))
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.7))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(8)
                        }
                    }
                }
            }

            // Info row
            VStack(alignment: .leading, spacing: 4) {
                Text(post.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 16) {
                    // Likes
                    HStack(spacing: 4) {
                        Button {
                            liked.toggle()
                        } label: {
                            Image(systemName: liked ? "heart.fill" : "heart")
                                .font(.caption)
                                .foregroundStyle(liked ? .red : Color(white: 0.5))
                        }
                        Text("\(post.like_count ?? 0)")
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.5))
                    }

                    // Views
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.4))
                        Text("\(post.view_count ?? 0)")
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.5))
                    }

                    // Save
                    Button {
                        saved.toggle()
                    } label: {
                        Image(systemName: saved ? "bookmark.fill" : "bookmark")
                            .font(.caption)
                            .foregroundStyle(saved ? .orange : Color(white: 0.5))
                    }

                    Spacer()

                    // Time ago
                    if let created = post.created_at {
                        Text(timeAgo(created))
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.4))
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .padding(8)
        .background(Color(white: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(white: 0.1), lineWidth: 0.5)
        )
    }

    var thumbnailPlaceholder: some View {
        ZStack {
            Color(white: 0.06)
            VStack(spacing: 6) {
                Image(systemName: "figure.run")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange.opacity(0.3))
                Text(post.title)
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.3))
            }
        }
    }

    func formatDuration(_ ms: Int) -> String {
        let secs = ms / 1000
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    func timeAgo(_ dateStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) else { return "" }
        let diff = Date().timeIntervalSince(date)
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        if diff < 604800 { return "\(Int(diff / 86400))d" }
        return "\(Int(diff / 604800))w"
    }
}
