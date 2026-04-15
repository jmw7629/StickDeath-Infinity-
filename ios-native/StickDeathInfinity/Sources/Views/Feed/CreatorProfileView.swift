// CreatorProfileView.swift
// Layer 2 — CONTEXT SCREEN (reachable from Home, Challenges, or Profile tabs)
//
// Why is the user here?  → Tapped a creator's name/avatar
// Next action?           → Follow, message, view their animations
// Back?                  → Returns to exact prior context (post, challenge, etc.)
// Forward?               → Tap animation → PostDetail, or Message → Chat

import SwiftUI

struct CreatorProfileView: View {
    let userId: String  // username or user_id
    @EnvironmentObject var router: NavigationRouter
    @EnvironmentObject var auth: AuthManager

    @State private var profile: UserProfile?
    @State private var animations: [FeedItem] = []
    @State private var isFollowing = false
    @State private var loading = true
    @State private var followerCount = 0
    @State private var followingCount = 0

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            if loading {
                ProgressView().tint(.red)
            } else if let profile = profile {
                ScrollView {
                    VStack(spacing: 20) {
                        // ── Profile Header ──
                        VStack(spacing: 12) {
                            Circle()
                                .fill(LinearGradient(colors: [.red.opacity(0.4), .red.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 80, height: 80)
                                .overlay(
                                    Text(String(profile.username?.prefix(1) ?? "?").uppercased())
                                        .font(.system(size: 32, weight: .bold))
                                        .foregroundStyle(.white)
                                )

                            Text(profile.username ?? "Unknown")
                                .font(.title2.bold())

                            if let bio = profile.bio, !bio.isEmpty {
                                Text(bio)
                                    .font(.subheadline).foregroundStyle(.gray)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            }

                            // Stats
                            HStack(spacing: 24) {
                                VStack {
                                    Text("\(animations.count)").font(.headline.bold())
                                    Text("Animations").font(.caption2).foregroundStyle(.gray)
                                }
                                VStack {
                                    Text("\(followerCount)").font(.headline.bold())
                                    Text("Followers").font(.caption2).foregroundStyle(.gray)
                                }
                                VStack {
                                    Text("\(followingCount)").font(.headline.bold())
                                    Text("Following").font(.caption2).foregroundStyle(.gray)
                                }
                            }

                            // Action buttons (clear forward actions)
                            HStack(spacing: 12) {
                                Button {
                                    isFollowing.toggle()
                                    HapticManager.shared.buttonTap()
                                    Task { await toggleFollow() }
                                } label: {
                                    Text(isFollowing ? "Following" : "Follow")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(isFollowing ? .white : .black)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(isFollowing ? ThemeManager.surface : Color.red)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }

                                Button {
                                    startConversation()
                                } label: {
                                    Image(systemName: "bubble.left.fill")
                                        .foregroundStyle(.red)
                                        .padding(10)
                                        .background(ThemeManager.surface)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            .padding(.horizontal, 40)
                        }
                        .padding(.top, 20)

                        Divider().background(ThemeManager.border).padding(.horizontal)

                        // ── Their Animations (tappable → forward to PostDetail) ──
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Animations")
                                .font(.headline)
                                .padding(.horizontal, 16)

                            if animations.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "film")
                                        .font(.title).foregroundStyle(.gray)
                                    Text("No published animations yet")
                                        .font(.subheadline).foregroundStyle(.gray)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                            } else {
                                LazyVGrid(columns: [
                                    GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)
                                ], spacing: 8) {
                                    ForEach(animations) { anim in
                                        Button {
                                            router.push(HomeDestination.postDetail(anim))
                                        } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(ThemeManager.surface)
                                                    .frame(height: 100)
                                                    .overlay(
                                                        Image(systemName: "play.circle.fill")
                                                            .font(.title2)
                                                            .foregroundStyle(.white.opacity(0.5))
                                                    )
                                                Text(anim.title)
                                                    .font(.caption.bold())
                                                    .lineLimit(1)
                                                    .foregroundStyle(.white)
                                                HStack(spacing: 8) {
                                                    Label("\(anim.like_count ?? 0)", systemImage: "heart")
                                                    Label("\(anim.view_count ?? 0)", systemImage: "eye")
                                                }
                                                .font(.system(size: 10))
                                                .foregroundStyle(.gray)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 48)).foregroundStyle(.gray)
                    Text("User not found").font(.subheadline).foregroundStyle(.gray)
                }
            }
        }
        .navigationTitle(profile?.username ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadProfile() }
    }

    // MARK: - Data
    func loadProfile() async {
        loading = true
        do {
            // Try loading by username first, then by ID
            let rows: [UserProfile] = try await supabase
                .from("users")
                .select()
                .or("username.eq.\(userId),id.eq.\(userId)")
                .limit(1)
                .execute()
                .value
            profile = rows.first

            if let uid = profile?.id {
                // Load their published animations
                let items: [FeedItem] = try await supabase
                    .from("studio_projects")
                    .select("*, users(username, avatar_url)")
                    .eq("user_id", value: uid)
                    .eq("status", value: "published")
                    .order("created_at", ascending: false)
                    .execute()
                    .value
                animations = items

                // Follower/following counts
                let followers: [[String: Int]] = (try? await supabase
                    .from("follows").select("id", head: true, count: .exact)
                    .eq("following_id", value: uid).execute().value) ?? []
                followerCount = followers.count

                let following: [[String: Int]] = (try? await supabase
                    .from("follows").select("id", head: true, count: .exact)
                    .eq("follower_id", value: uid).execute().value) ?? []
                followingCount = following.count

                // Check if current user follows them
                if let myId = auth.session?.user.id {
                    let check: [[String: String]] = (try? await supabase
                        .from("follows")
                        .select("id")
                        .eq("follower_id", value: myId.uuidString)
                        .eq("following_id", value: uid)
                        .execute().value) ?? []
                    isFollowing = !check.isEmpty
                }
            }
        } catch {
            print("Error loading creator profile: \(error)")
        }
        loading = false
    }

    func toggleFollow() async {
        guard let uid = profile?.id, let myId = auth.session?.user.id else { return }
        if isFollowing {
            _ = try? await supabase.from("follows").insert([
                "follower_id": myId.uuidString, "following_id": uid
            ]).execute()
            followerCount += 1
        } else {
            _ = try? await supabase.from("follows")
                .delete()
                .eq("follower_id", value: myId.uuidString)
                .eq("following_id", value: uid)
                .execute()
            followerCount = max(0, followerCount - 1)
        }
    }

    func startConversation() {
        // Navigate to messages within current tab context
        // For now, switch to profile → messages
        router.selectedTab = .profile
        router.profilePath.append(ProfileDestination.messages)
    }
}
