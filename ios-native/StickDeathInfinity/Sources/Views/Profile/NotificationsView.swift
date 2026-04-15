// NotificationsView.swift
// Layer 2 — CONTEXT SCREEN (within Profile tab)
//
// Why is the user here?  → Tapped Notifications from Profile
// Next action?           → Tap a notification → navigate to related content
// Back?                  → Returns to Profile
// Forward?               → Post detail (pushed within Profile tab), creator profile, challenge
//
// RULE: Notification → content → Back → Notifications → Back → Profile (exact retrace)

import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject var router: NavigationRouter
    @State private var notifications: [AppNotification] = []
    @State private var loading = true

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            if loading && notifications.isEmpty {
                ProgressView().tint(.red)
            } else if notifications.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 48)).foregroundStyle(.gray)
                    Text("No notifications yet")
                        .font(.title3.bold())
                    Text("When someone likes, comments, or follows you, it'll show up here")
                        .font(.subheadline).foregroundStyle(.gray)
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                }
            } else {
                List {
                    ForEach(notifications) { notification in
                        NotificationRow(notification: notification) {
                            handleTap(notification)
                        }
                        .listRowBackground(
                            notification.read ? ThemeManager.background : ThemeManager.surface.opacity(0.3)
                        )
                    }
                }
                .listStyle(.plain)
                .refreshable { await loadNotifications() }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !notifications.isEmpty {
                    Button("Mark All Read") {
                        Task { await markAllRead() }
                    }
                    .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task { await loadNotifications() }
    }

    // MARK: - Handle notification tap → navigate within Profile tab
    func handleTap(_ notification: AppNotification) {
        // Mark as read
        Task { await markRead(notification.id) }

        switch notification.type {
        case "like", "comment":
            // Navigate to the post (pushed within Profile tab)
            if let postId = notification.related_post_id {
                let item = FeedItem(
                    id: postId,
                    title: notification.title,
                    status: "published",
                    created_at: nil, thumbnail_url: nil,
                    like_count: nil, view_count: nil, users: nil
                )
                // For Profile tab we don't have HomeDestination registered,
                // but we have creatorProfile. For post navigation from profile,
                // we'd need to deep link to Home tab.
                router.deepLink(tab: .home, destination: HomeDestination.postDetail(item))
            }
        case "follow":
            if let userId = notification.related_user_id {
                router.profilePath.append(ProfileDestination.creatorProfile(userId))
            }
        case "challenge":
            if let challengeId = notification.related_challenge_id {
                // Switch to challenges tab and push detail
                // Build a minimal challenge object
                let challenge = Challenge(id: challengeId, title: notification.title)
                router.deepLink(tab: .challenges, destination: ChallengesDestination.challengeDetail(challenge))
            }
        default:
            break
        }
    }

    // MARK: - Data
    func loadNotifications() async {
        loading = true
        guard let userId = AuthManager.shared.session?.user.id else {
            loading = false
            return
        }
        notifications = (try? await supabase
            .from("notifications")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .limit(50)
            .execute()
            .value) ?? []
        loading = false
    }

    func markRead(_ id: Int) async {
        _ = try? await supabase.from("notifications")
            .update(["read": true])
            .eq("id", value: id)
            .execute()
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            notifications[idx].read = true
        }
    }

    func markAllRead() async {
        guard let userId = AuthManager.shared.session?.user.id else { return }
        _ = try? await supabase.from("notifications")
            .update(["read": true])
            .eq("user_id", value: userId.uuidString)
            .execute()
        for i in notifications.indices { notifications[i].read = true }
    }
}

// MARK: - Notification Row
struct NotificationRow: View {
    let notification: AppNotification
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Type icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: iconName)
                        .font(.body)
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(notification.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(notification.read ? .gray : .white)
                    if let body = notification.body {
                        Text(body)
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .lineLimit(2)
                    }
                    if let date = notification.created_at?.prefix(10) {
                        Text(String(date))
                            .font(.caption2).foregroundStyle(.gray.opacity(0.6))
                    }
                }

                Spacer()

                if !notification.read {
                    Circle().fill(.red).frame(width: 8, height: 8)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.gray)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    var iconName: String {
        switch notification.type {
        case "like": return "heart.fill"
        case "comment": return "bubble.right.fill"
        case "follow": return "person.badge.plus"
        case "challenge": return "trophy.fill"
        case "system": return "bell.fill"
        default: return "bell"
        }
    }

    var iconColor: Color {
        switch notification.type {
        case "like": return .red
        case "comment": return .cyan
        case "follow": return .green
        case "challenge": return .yellow
        case "system": return .purple
        default: return .gray
        }
    }
}
