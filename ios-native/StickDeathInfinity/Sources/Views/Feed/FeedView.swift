// FeedView.swift
// Community feed — browse published animations

import SwiftUI

struct FeedView: View {
    @State private var items: [FeedItem] = []
    @State private var loading = true
    @State private var page = 1

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                if loading && items.isEmpty {
                    ProgressView().tint(.orange)
                } else if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.gray)
                        Text("No animations yet")
                            .font(.title3.bold())
                        Text("Be the first to publish!")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(items) { item in
                                FeedCard(item: item)
                            }

                            // Load more
                            if !loading {
                                Button("Load More") {
                                    Task { await loadMore() }
                                }
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .padding()
                            }
                        }
                        .padding()
                    }
                    .refreshable { await refresh() }
                }
            }
            .navigationTitle("Feed")
            .task { await loadFeed() }
        }
    }

    func loadFeed() async {
        loading = true
        items = (try? await ProjectService.shared.fetchFeed(page: 1)) ?? []
        page = 1
        loading = false
    }

    func loadMore() async {
        page += 1
        let newItems = (try? await ProjectService.shared.fetchFeed(page: page)) ?? []
        items.append(contentsOf: newItems)
    }

    func refresh() async {
        await loadFeed()
    }
}

struct FeedCard: View {
    let item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // User row
            HStack(spacing: 8) {
                Circle()
                    .fill(ThemeManager.surface)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    )

                VStack(alignment: .leading) {
                    Text(item.users?.username ?? "Anonymous")
                        .font(.subheadline.bold())
                    if let date = item.created_at?.prefix(10) {
                        Text(String(date))
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                }

                Spacer()

                Image(systemName: "ellipsis")
                    .foregroundStyle(.gray)
            }

            // Animation preview placeholder
            RoundedRectangle(cornerRadius: 12)
                .fill(ThemeManager.surface)
                .frame(height: 200)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(item.title)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                )

            // Actions
            HStack(spacing: 24) {
                Label("Like", systemImage: "heart")
                Label("Comment", systemImage: "bubble.right")
                Label("Share", systemImage: "paperplane")
                Spacer()
                Image(systemName: "bookmark")
            }
            .font(.caption)
            .foregroundStyle(.gray)
        }
        .padding(14)
        .background(ThemeManager.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
