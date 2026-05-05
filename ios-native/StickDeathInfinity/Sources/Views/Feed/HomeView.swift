// HomeView.swift
// "Community Feed" — matches reference exactly
// Post cards with avatar, play button overlay, duration badge, stats row

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var router: NavigationRouter
    @State private var feedItems = FeedItem.sampleFeed

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    // ── Header ──
                    Text("Community Feed")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    // ── Feed Posts ──
                    ForEach(feedItems) { item in
                        FeedPostCard(item: item)
                            .onTapGesture {
                                router.push(HomeDestination.postDetail(item))
                            }
                        Divider()
                            .background(ThemeManager.border)
                    }

                    // Bottom padding for tab bar
                    Spacer().frame(height: 80)
                }
            }
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Feed Post Card (matches reference)
struct FeedPostCard: View {
    let item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Author Row ──
            HStack(spacing: 10) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(ThemeManager.surface)
                        .frame(width: 36, height: 36)
                    Text(item.authorEmoji)
                        .font(.system(size: 18))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.authorName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(item.timeAgo)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "#9090a8"))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // ── Video Thumbnail ──
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: "#1a1a24"))
                    .aspectRatio(16/10, contentMode: .fill)

                // Play button
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .offset(x: 2)
                    )

                // Duration badge
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(item.duration)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(8)
            }
            .padding(.horizontal, 16)

            // ── Title ──
            Text("\(item.title) — \(item.frameCount) frames")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            // ── Stats Row ──
            HStack(spacing: 16) {
                Label("\(item.likes)", systemImage: "heart.fill")
                    .foregroundStyle(.red)
                Label("\(item.comments)", systemImage: "bubble.left.fill")
                    .foregroundStyle(Color(hex: "#9090a8"))
                Label("\(item.views)", systemImage: "eye.fill")
                    .foregroundStyle(Color(hex: "#9090a8"))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }
}

// MARK: - Sample Data
extension FeedItem {
    static let sampleFeed: [FeedItem] = [
        FeedItem(id: 1, title: "Epic Sword Fight", authorName: "xBladeRunner", authorEmoji: "⚔️",
                 timeAgo: "2h ago", duration: "0:04", frameCount: 48,
                 likes: 342, comments: 28, views: 1240),
        FeedItem(id: 2, title: "Parkour Chase Scene", authorName: "StickMasterFlex", authorEmoji: "💀",
                 timeAgo: "4h ago", duration: "0:04", frameCount: 64,
                 likes: 215, comments: 12, views: 890),
        FeedItem(id: 3, title: "Ninja Star Throw", authorName: "AnimateOrDie", authorEmoji: "🔥",
                 timeAgo: "6h ago", duration: "0:03", frameCount: 36,
                 likes: 189, comments: 9, views: 720),
        FeedItem(id: 4, title: "Matrix Dodge", authorName: "BoneBreaker", authorEmoji: "💥",
                 timeAgo: "8h ago", duration: "0:05", frameCount: 60,
                 likes: 456, comments: 34, views: 2100),
        FeedItem(id: 5, title: "Stick Figure Dance", authorName: "FlipMaster", authorEmoji: "🕺",
                 timeAgo: "12h ago", duration: "0:06", frameCount: 72,
                 likes: 567, comments: 45, views: 3200),
        FeedItem(id: 6, title: "Explosion Effect", authorName: "DeathFrame", authorEmoji: "💣",
                 timeAgo: "1d ago", duration: "0:02", frameCount: 24,
                 likes: 123, comments: 7, views: 450),
    ]
}
