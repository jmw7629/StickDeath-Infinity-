// FeedView.swift
// Community feed — 5-second rule: instant visual value on open
// Featured auto-play banner at top, adaptive grid on iPad, pull-to-refresh
// "Variable reward" — unpredictable featured content + like counts

import SwiftUI

struct FeedView: View {
    @State private var items: [FeedItem] = []
    @State private var featured: [FeedItem] = []
    @State private var loading = true
    @State private var page = 1
    @EnvironmentObject var offline: OfflineManager
    @Environment(\.horizontalSizeClass) var hSize

    var isWide: Bool { hSize == .regular }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                if loading && items.isEmpty {
                    ProgressView().tint(.red)
                } else if items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            // ── Featured Banner (auto-play, instant value — 5-second rule) ──
                            if !featured.isEmpty {
                                FeaturedBanner(items: featured)
                                    .frame(height: isWide ? 280 : 200)
                            }

                            // ── Content Grid ──
                            if isWide {
                                // iPad/Mac: 2-column grid
                                LazyVGrid(columns: [
                                    GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)
                                ], spacing: 12) {
                                    ForEach(items) { item in
                                        FeedCard(item: item, compact: true)
                                    }
                                }
                                .padding(16)
                            } else {
                                // iPhone: single column
                                LazyVStack(spacing: 12) {
                                    ForEach(items) { item in
                                        FeedCard(item: item, compact: false)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                            }

                            // Load more
                            if !loading {
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
            .navigationTitle("Feed")
            .task { await loadFeed() }
        }
    }

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 56)).foregroundStyle(.red.opacity(0.5))
            Text("No animations yet")
                .font(.title3.bold())
            Text("Be the first to publish!")
                .font(.subheadline).foregroundStyle(.gray)
            Button {
                // Quick-create — instant gratification
            } label: {
                Label("Create Your First", systemImage: "plus")
                    .font(.headline).foregroundStyle(.black)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.red).clipShape(Capsule())
            }
        }
    }

    func loadFeed() async {
        loading = true

        // Try cache first for instant render (5-second rule)
        if let cached = offline.loadCachedFeed(),
           let cachedItems = try? JSONDecoder().decode([FeedItem].self, from: cached) {
            items = cachedItems
            featured = Array(cachedItems.prefix(3))
            loading = false
        }

        // Then fetch fresh
        let freshItems = (try? await ProjectService.shared.fetchFeed(page: 1)) ?? []
        if !freshItems.isEmpty {
            items = freshItems
            featured = Array(freshItems.prefix(3))
            // Cache for offline
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

// MARK: - Featured Banner (auto-playing carousel — 5-second rule)
struct FeaturedBanner: View {
    let items: [FeedItem]
    @State private var currentIndex = 0
    @State private var timer: Timer?

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ZStack {
                    // Background gradient
                    LinearGradient(
                        colors: [bannerColor(index).opacity(0.4), .black],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )

                    // Content
                    VStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.8))

                        Text(item.title)
                            .font(.title3.bold())
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
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))

                        Text("🔥 Featured")
                            .font(.caption2.bold())
                            .foregroundStyle(.red)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 12)
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
                currentIndex = (currentIndex + 1) % items.count
            }
        }
    }

    func bannerColor(_ index: Int) -> Color {
        [Color.red, .purple, .cyan][index % 3]
    }
}

// MARK: - Feed Card
struct FeedCard: View {
    let item: FeedItem
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // User row
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

                Menu {
                    Button("Report", systemImage: "exclamationmark.triangle") {}
                    Button("Share", systemImage: "square.and.arrow.up") {}
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.gray)
                }
            }

            // Animation preview
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

            // Actions
            HStack(spacing: 20) {
                HStack(spacing: 4) {
                    Image(systemName: "heart")
                    Text("\(item.like_count ?? 0)")
                }
                HStack(spacing: 4) {
                    Image(systemName: "bubble.right")
                    Text("0")
                }
                HStack(spacing: 4) {
                    Image(systemName: "eye")
                    Text("\(item.view_count ?? 0)")
                }
                Spacer()
                Image(systemName: "bookmark")
                Image(systemName: "paperplane")
            }
            .font(.caption)
            .foregroundStyle(.gray)
        }
        .padding(14)
        .background(ThemeManager.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
