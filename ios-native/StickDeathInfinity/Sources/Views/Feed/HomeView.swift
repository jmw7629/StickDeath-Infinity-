// HomeView.swift
// Layer 1 ROOT — Home tab (community feed)
//
// Why is the user here?  → Discover content, get inspired
// Next action?           → Tap a post → fullscreen viewer → creator profile
// Back?                  → Returns to same scroll position
// Forward?               → PostDetail → CreatorProfile → Message — all within Home's NavigationStack
//
// Flow: Home → Post → Fullscreen → Creator → Profile → Back → Back → same scroll position

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var router: NavigationRouter
    @EnvironmentObject var offline: OfflineManager
    @Environment(\.horizontalSizeClass) var hSize

    @State private var items: [FeedItem] = []
    @State private var featured: [FeedItem] = []
    @State private var loading = true
    @State private var page = 1
    @State private var searchText = ""

    var isWide: Bool { hSize == .regular }

    var filteredItems: [FeedItem] {
        if searchText.isEmpty { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            ($0.users?.username ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            if loading && items.isEmpty {
                ProgressView().tint(.red)
            } else if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // ── Featured Banner ──
                        if !featured.isEmpty && searchText.isEmpty {
                            FeaturedBanner(items: featured) { item in
                                router.homePath.append(HomeDestination.postDetail(item))
                            }
                            .frame(height: isWide ? 280 : 200)
                        }

                        // ── Content Grid ──
                        if isWide {
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)
                            ], spacing: 12) {
                                ForEach(filteredItems) { item in
                                    HomeFeedCard(item: item, compact: true) {
                                        router.homePath.append(HomeDestination.postDetail(item))
                                    } onCreatorTap: {
                                        if let userId = item.users?.username {
                                            router.homePath.append(HomeDestination.creatorProfile(userId))
                                        }
                                    }
                                }
                            }
                            .padding(16)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredItems) { item in
                                    HomeFeedCard(item: item, compact: false) {
                                        router.homePath.append(HomeDestination.postDetail(item))
                                    } onCreatorTap: {
                                        if let userId = item.users?.username {
                                            router.homePath.append(HomeDestination.creatorProfile(userId))
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                        }

                        // Load more
                        if !loading && !items.isEmpty {
                            Button("Load More") {
                                Task { await loadMore() }
                            }
                            .font(.subheadline).foregroundStyle(.red).padding()
                        }
                    }
                }
                .refreshable { await refresh() }
            }
        }
        .navigationTitle("Home")
        .searchable(text: $searchText, prompt: "Search animations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.openSpatter(context: .home)
                } label: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.red)
                }
            }
        }
        .task { await loadFeed() }
    }

    // MARK: - Empty State (forward action: create)
    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 56)).foregroundStyle(.red.opacity(0.5))
            Text("No animations yet")
                .font(.title3.bold())
            Text("Be the first to publish!")
                .font(.subheadline).foregroundStyle(.gray)
            Button {
                router.selectedTab = .studio
            } label: {
                Label("Create Your First", systemImage: "plus")
                    .font(.headline).foregroundStyle(.black)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.red).clipShape(Capsule())
            }
        }
    }

    // MARK: - Data
    func loadFeed() async {
        loading = true
        if let cached = offline.loadCachedFeed(),
           let cachedItems = try? JSONDecoder().decode([FeedItem].self, from: cached) {
            items = cachedItems
            featured = Array(cachedItems.prefix(3))
            loading = false
        }
        let freshItems = (try? await ProjectService.shared.fetchFeed(page: 1)) ?? []
        if !freshItems.isEmpty {
            items = freshItems
            featured = Array(freshItems.prefix(3))
            if let data = try? JSONEncoder().encode(freshItems) {
                offline.cacheFeed(data)
            }
        }
        page = 1
        loading = false
    }

    func loadMore() async {
        page += 1
        let newItems = (try? await ProjectService.shared.fetchFeed(page: page)) ?? []
        items.append(contentsOf: newItems)
    }

    func refresh() async { await loadFeed() }
}

// MARK: - Featured Banner (tappable — navigates to post)
struct FeaturedBanner: View {
    let items: [FeedItem]
    let onTap: (FeedItem) -> Void
    @State private var currentIndex = 0
    @State private var timer: Timer?

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onTap(item) } label: {
                    ZStack {
                        LinearGradient(
                            colors: [bannerColor(index).opacity(0.4), .black],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        VStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.8))
                            Text(item.title)
                                .font(.title3.bold()).foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                            HStack(spacing: 12) {
                                Label(item.users?.username ?? "Anonymous", systemImage: "person.fill")
                                if let views = item.view_count, views > 0 {
                                    Label("\(views) views", systemImage: "eye")
                                }
                                if let likes = item.like_count, likes > 0 {
                                    Label("\(likes)", systemImage: "heart.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                            Text("🔥 Featured")
                                .font(.caption2.bold()).foregroundStyle(.red)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 12)
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .onAppear { startAutoScroll() }
        .onDisappear { timer?.invalidate() }
    }

    func startAutoScroll() {
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                currentIndex = (currentIndex + 1) % max(items.count, 1)
            }
        }
    }

    func bannerColor(_ index: Int) -> Color {
        [Color.red, .purple, .cyan][index % 3]
    }
}

// MARK: - Feed Card (every element is tappable → forward navigation)
struct HomeFeedCard: View {
    let item: FeedItem
    var compact: Bool = false
    let onTap: () -> Void
    let onCreatorTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Creator row — tappable → creatorProfile
            Button(action: onCreatorTap) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(LinearGradient(colors: [.red.opacity(0.3), .red.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Text(String(item.users?.username?.prefix(1) ?? "?").uppercased())
                                .font(.caption.bold()).foregroundStyle(.white)
                        )
                    VStack(alignment: .leading) {
                        Text(item.users?.username ?? "Anonymous").font(.subheadline.bold())
                        if let date = item.created_at?.prefix(10) {
                            Text(String(date)).font(.caption2).foregroundStyle(.gray)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // Animation preview — tappable → postDetail
            Button(action: onTap) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(ThemeManager.surface)
                    .frame(height: compact ? 140 : 200)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: compact ? 36 : 44))
                                .foregroundStyle(.white.opacity(0.6))
                            Text(item.title)
                                .font(compact ? .caption : .subheadline)
                                .foregroundStyle(.white)
                        }
                    )
            }
            .buttonStyle(.plain)

            // Engagement row — all tappable
            HStack(spacing: 20) {
                Button(action: onTap) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart")
                        Text("\(item.like_count ?? 0)")
                    }
                }
                Button(action: onTap) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.right")
                        Text("0")
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "eye")
                    Text("\(item.view_count ?? 0)")
                }
                Spacer()
                Button(action: {}) {
                    Image(systemName: "bookmark")
                }
                Button(action: {}) {
                    Image(systemName: "paperplane")
                }
            }
            .font(.caption).foregroundStyle(.gray)
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(ThemeManager.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
