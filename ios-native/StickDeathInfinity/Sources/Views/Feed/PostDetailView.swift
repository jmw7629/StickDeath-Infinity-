// PostDetailView.swift
// Layer 2 — CONTEXT SCREEN (within Home tab)
//
// Why is the user here?  → Tapped a post in the feed to see it fullscreen
// Next action?           → Like, comment, tap creator, share
// Back?                  → Returns to Home feed at same scroll position
// Forward?               → Creator profile, comment sheet

import SwiftUI

struct PostDetailView: View {
    let item: FeedItem
    @EnvironmentObject var router: NavigationRouter
    @EnvironmentObject var auth: AuthManager
    @State private var liked = false
    @State private var likeCount: Int = 0
    @State private var comments: [PostComment] = []
    @State private var showComments = false
    @State private var showShare = false
    @State private var isPlaying = false
    @State private var viewCounted = false

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // ── Fullscreen Animation Player ──
                    ZStack {
                        RoundedRectangle(cornerRadius: 0)
                            .fill(Color.black)
                            .frame(height: 400)
                            .overlay(
                                VStack(spacing: 12) {
                                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 64))
                                        .foregroundStyle(.white.opacity(0.8))
                                    Text(item.title)
                                        .font(.title2.bold())
                                        .foregroundStyle(.white)
                                }
                            )
                            .onTapGesture {
                                isPlaying.toggle()
                                HapticManager.shared.buttonTap()
                            }

                        // View count on first display
                        Color.clear.onAppear {
                            if !viewCounted {
                                viewCounted = true
                                Task { await incrementViewCount() }
                            }
                        }
                    }

                    VStack(spacing: 16) {
                        // ── Creator Row (tappable → forward to creator profile) ──
                        Button {
                            if let userId = item.users?.username {
                                router.push(HomeDestination.creatorProfile(userId))
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(LinearGradient(colors: [.red.opacity(0.4), .red.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Text(String(item.users?.username?.prefix(1) ?? "?").uppercased())
                                            .font(.headline.bold()).foregroundStyle(.white)
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.users?.username ?? "Anonymous")
                                        .font(.headline)
                                    if let date = item.created_at?.prefix(10) {
                                        Text(String(date))
                                            .font(.caption).foregroundStyle(.gray)
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.gray)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // ── Engagement Bar ──
                        HStack(spacing: 32) {
                            // Like
                            Button {
                                liked.toggle()
                                likeCount += liked ? 1 : -1
                                HapticManager.shared.buttonTap()
                                Task { await toggleLike() }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: liked ? "heart.fill" : "heart")
                                        .font(.title2)
                                        .foregroundStyle(liked ? .red : .white)
                                    Text("\(likeCount)")
                                        .font(.caption.bold())
                                }
                            }

                            // Comment
                            Button { showComments = true } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "bubble.right")
                                        .font(.title2)
                                    Text("\(comments.count)")
                                        .font(.caption.bold())
                                }
                            }

                            // Share
                            Button { showShare = true } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "paperplane")
                                        .font(.title2)
                                    Text("Share")
                                        .font(.caption.bold())
                                }
                            }

                            Spacer()

                            // Views
                            VStack(spacing: 4) {
                                Image(systemName: "eye")
                                    .font(.title2)
                                Text("\(item.view_count ?? 0)")
                                    .font(.caption.bold())
                            }
                            .foregroundStyle(.gray)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(ThemeManager.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 16)

                        // ── What to do next: related actions ──
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Up Next").font(.headline).padding(.horizontal, 16)

                            // "Create something like this" — forward to Studio
                            Button {
                                router.selectedTab = .studio
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "paintbrush.pointed.fill")
                                        .foregroundStyle(.red).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Create Your Own").font(.subheadline.bold())
                                        Text("Inspired? Make something like this")
                                            .font(.caption).foregroundStyle(.gray)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.gray)
                                }
                                .padding(14)
                                .background(ThemeManager.surfaceLight)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)

                            // "Ask Spatter" — opens overlay, not navigation
                            Button {
                                router.openSpatter(context: .home)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.purple).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Ask Spatter").font(.subheadline.bold())
                                        Text("Get AI suggestions for your next creation")
                                            .font(.caption).foregroundStyle(.gray)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.gray)
                                }
                                .padding(14)
                                .background(ThemeManager.surfaceLight)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showComments) {
            CommentSheet(postId: item.id, comments: $comments)
        }
        .onAppear {
            likeCount = item.like_count ?? 0
            Task { await loadComments() }
        }
    }

    // MARK: - Data
    func loadComments() async {
        comments = (try? await supabase
            .from("comments")
            .select("*, user:users(username, avatar_url)")
            .eq("post_id", value: item.id)
            .order("created_at")
            .execute()
            .value) ?? []
    }

    func toggleLike() async {
        guard let userId = auth.session?.user.id else { return }
        if liked {
            _ = try? await supabase.from("likes").insert([
                "post_id": "\(item.id)", "user_id": userId.uuidString
            ]).execute()
        } else {
            _ = try? await supabase.from("likes")
                .delete()
                .eq("post_id", value: item.id)
                .eq("user_id", value: userId.uuidString)
                .execute()
        }
    }

    func incrementViewCount() async {
        _ = try? await supabase.rpc("increment_view_count", params: ["post_id": item.id]).execute()
    }
}
