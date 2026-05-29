// ═══════════════════════════════════════════════════════════════════
// HomeFeedView — Social feed with Trending/Recent/Following/Featured tabs
// Matches preview exactly: SD logo header, tab bar, Spatter AI posts,
// video thumbnails, hashtag pills, engagement row, pricing ticker
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import Supabase

struct HomeFeedView: View {
    @StateObject private var vm = HomeFeedViewModel()

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header — "SD STICKDEATH" logo
                HStack(spacing: 8) {
                    // SD badge
                    Text("SD")
                        .font(.specialElite(14))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.sdRed)
                        .cornerRadius(4)

                    Text("STICKDEATH")
                        .font(.specialElite(18))
                        .tracking(2)
                        .foregroundColor(.sdTextPrimary)
                        .sdRedGlow(radius: 6, opacity: 0.3)

                    Spacer()

                    Button {} label: {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.sdTextSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Tab bar — Trending / Recent / Following / Featured
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(FeedTab.allCases, id: \.self) { tab in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    vm.selectedTab = tab
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Text(tab.rawValue)
                                        .font(.specialElite(14))
                                        .foregroundColor(vm.selectedTab == tab ? .sdRed : .sdTextSecondary)
                                    Rectangle()
                                        .fill(vm.selectedTab == tab ? Color.sdRed : Color.clear)
                                        .frame(height: 2)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 4)

                // Feed
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(vm.feedPosts) { post in
                            FeedPostCard(post: post)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 100)
                }
                .refreshable {
                    await vm.loadPosts()
                }
            }

            // Pricing ticker toast (bottom-right)
            PricingTickerView()
        }
        .task { await vm.loadPosts() }
    }
}

// MARK: - Feed Tabs
enum FeedTab: String, CaseIterable {
    case trending = "Trending"
    case recent = "Recent"
    case following = "Following"
    case featured = "Featured"
}

// MARK: - Feed Post Card (matches preview exactly)
struct FeedPostCard: View {
    let post: FeedPost

    @State private var liked = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Author row
            HStack(spacing: 10) {
                // Spatter avatar (red circle with skull)
                ZStack {
                    Circle()
                        .fill(Color.sdRed.opacity(0.2))
                        .frame(width: 40, height: 40)
                    Text("💀")
                        .font(.system(size: 20))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(post.author)
                            .font(.specialElite(15))
                            .fontWeight(.semibold)
                            .foregroundColor(.sdRed)

                        if post.isAI {
                            Text("AI")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.sdRed)
                                .cornerRadius(4)
                        }
                    }

                    Text(post.timeAgo)
                        .font(.system(size: 12))
                        .foregroundColor(.sdTextMuted)
                }

                Spacer()

                Button {} label: {
                    Text("⋯")
                        .font(.system(size: 20))
                        .foregroundColor(.sdTextSecondary)
                }
            }

            // Content text
            Text(post.content)
                .font(.specialElite(15))
                .foregroundColor(.sdTextPrimary)
                .lineSpacing(4)

            // Video thumbnail
            if post.hasVideo {
                ZStack {
                    Rectangle()
                        .fill(Color.sdSurface2)
                        .aspectRatio(16/9, contentMode: .fit)
                        .cornerRadius(12)

                    // Play button
                    Circle()
                        .fill(Color.sdRed.opacity(0.9))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .offset(x: 2)
                        )

                    // Duration badge (top-right)
                    VStack {
                        HStack {
                            Spacer()
                            Text(post.duration)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(4)
                                .padding(8)
                        }
                        Spacer()
                    }
                }
            }

            // Hashtag pills
            if !post.hashtags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(post.hashtags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 13))
                            .foregroundColor(.sdRed)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.sdRed.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
            }

            // Engagement row
            HStack(spacing: 0) {
                // Like
                Button {
                    liked.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(liked ? "♥" : "♡")
                            .font(.system(size: 18))
                            .foregroundColor(liked ? .sdRed : .sdTextSecondary)
                        Text("\(post.likes + (liked ? 1 : 0))")
                            .font(.system(size: 13))
                            .foregroundColor(.sdTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity)

                // Comments
                Button {} label: {
                    HStack(spacing: 6) {
                        Text("⌁")
                            .font(.system(size: 16))
                            .foregroundColor(.sdTextSecondary)
                        Text("\(post.comments)")
                            .font(.system(size: 13))
                            .foregroundColor(.sdTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity)

                // Share
                Button {} label: {
                    HStack(spacing: 6) {
                        Text("↗")
                            .font(.system(size: 16))
                            .foregroundColor(.sdTextSecondary)
                        Text("\(post.shares)")
                            .font(.system(size: 13))
                            .foregroundColor(.sdTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity)

                // Save
                Button {
                    saved.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(saved ? "★" : "☆")
                            .font(.system(size: 16))
                            .foregroundColor(saved ? .sdWarning : .sdTextSecondary)
                        Text("Save")
                            .font(.system(size: 13))
                            .foregroundColor(.sdTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color.sdSurface)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.sdBorder, lineWidth: 1)
        )
    }
}

// MARK: - Flow Layout for hashtags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (positions, CGSize(width: maxWidth, height: y + rowHeight))
    }
}

// MARK: - Feed Post Model
struct FeedPost: Identifiable {
    let id: String
    let author: String
    let isAI: Bool
    let timeAgo: String
    let content: String
    let hasVideo: Bool
    let duration: String
    let hashtags: [String]
    let likes: Int
    let comments: Int
    let shares: Int
}

// MARK: - ViewModel
@MainActor
final class HomeFeedViewModel: ObservableObject {
    @Published var selectedTab: FeedTab = .recent
    @Published var feedPosts: [FeedPost] = []
    @Published var isLoading = false

    private let supabase = SupabaseManager.shared.client

    // Sample data matching preview exactly
    private let samplePosts: [FeedPost] = [
        FeedPost(
            id: "1",
            author: "Spatter",
            isAI: true,
            timeAgo: "just now",
            content: "Jaywalking: Final Episode no stick figures were harmed in the making of this. that's a lie. Tried to cross I-95 on foot. The semi truck had the right of way.",
            hasVideo: true,
            duration: "0s / 12s",
            hashtags: ["death", "highway", "truck", "splat"],
            likes: 88,
            comments: 15,
            shares: 24
        ),
        FeedPost(
            id: "2",
            author: "Spatter",
            isAI: true,
            timeAgo: "30m ago",
            content: "Rooftop Parkour Run calculated every trajectory. then threw the calculations away and vibed. Full-speed. No hesitation. Landed on a satellite dish. Now broadcasting death.",
            hasVideo: true,
            duration: "0s / 8s",
            hashtags: ["parkour", "rooftop", "death", "vibes"],
            likes: 114,
            comments: 19,
            shares: 14
        ),
        FeedPost(
            id: "3",
            author: "Spatter",
            isAI: true,
            timeAgo: "1h ago",
            content: "Don't Text and Walk calculated every step. Then ignored them all. Phone in hand. Bus approaching. Physics don't care about your DMs.",
            hasVideo: true,
            duration: "0s / 10s",
            hashtags: ["superbeast", "effects", "blood", "atmospheric"],
            likes: 67,
            comments: 8,
            shares: 11
        ),
    ]

    func loadPosts() async {
        isLoading = true
        do {
            let result: [Post] = try await supabase
                .from("posts")
                .select("*, users(username, avatar_url)")
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value

            // Convert to FeedPost format
            feedPosts = result.map { post in
                FeedPost(
                    id: "\(post.id)",
                    author: post.username ?? "Unknown",
                    isAI: false,
                    timeAgo: post.createdAt ?? "",
                    content: post.content ?? "",
                    hasVideo: post.mediaURL != nil,
                    duration: "0s / 12s",
                    hashtags: [],
                    likes: post.likeCount,
                    comments: post.commentCount,
                    shares: 0
                )
            }

            // If no posts from Supabase, show sample data
            if feedPosts.isEmpty {
                feedPosts = samplePosts
            }
        } catch {
            print("[HomeFeed] loadPosts error: \(error)")
            feedPosts = samplePosts
        }
        isLoading = false
    }
}
