// RealtimeManager.swift
// Supabase Realtime subscriptions — live updates for messages, notifications, feed
// Listens via Supabase Realtime channels and publishes changes to SwiftUI

import Foundation
import Supabase
import Combine

@MainActor
class RealtimeManager: ObservableObject {
    static let shared = RealtimeManager()

    @Published var unreadNotifications = 0
    @Published var unreadMessages = 0
    @Published var liveFeedItems: [LiveFeedEvent] = []

    private var channels: [RealtimeChannelV2] = []
    private var isSubscribed = false

    private init() {}

    // MARK: - Subscribe to all realtime channels
    func subscribeAll() async {
        guard !isSubscribed else { return }
        guard let userId = AuthManager.shared.session?.user.id.uuidString else { return }

        isSubscribed = true

        // 1) Notifications for this user
        await subscribeToNotifications(userId: userId)

        // 2) Messages for this user's conversations
        await subscribeToMessages(userId: userId)

        // 3) New posts in the community feed
        await subscribeToFeed()

        // 4) Challenge entries (live vote updates)
        await subscribeToChallengeEntries()

        print("✅ Realtime: all channels subscribed")
    }

    // MARK: - Notifications
    private func subscribeToNotifications(userId: String) async {
        let channel = supabase.realtimeV2.channel("notifications:\(userId)")

        let changes = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "notifications",
            filter: "user_id=eq.\(userId)"
        )

        await channel.subscribe()
        channels.append(channel)

        Task {
            for await insert in changes {
                await MainActor.run {
                    self.unreadNotifications += 1
                    // Post local notification
                    if let body = try? insert.record["body"]?.stringValue {
                        NotificationCenter.default.post(
                            name: .newNotification,
                            object: body
                        )
                    }
                }
            }
        }
    }

    // MARK: - Messages
    private func subscribeToMessages(userId: String) async {
        let channel = supabase.realtimeV2.channel("messages:\(userId)")

        let changes = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "messages"
        )

        await channel.subscribe()
        channels.append(channel)

        Task {
            for await insert in changes {
                let senderId = try? insert.record["sender_id"]?.stringValue
                if senderId != userId {
                    await MainActor.run {
                        self.unreadMessages += 1
                        NotificationCenter.default.post(
                            name: .newMessage,
                            object: insert.record
                        )
                    }
                }
            }
        }
    }

    // MARK: - Community Feed
    private func subscribeToFeed() async {
        let channel = supabase.realtimeV2.channel("feed")

        let changes = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "studio_projects",
            filter: "published=eq.true"
        )

        await channel.subscribe()
        channels.append(channel)

        Task {
            for await insert in changes {
                let title = try? insert.record["title"]?.stringValue
                let userId = try? insert.record["user_id"]?.stringValue
                await MainActor.run {
                    let event = LiveFeedEvent(
                        id: UUID(),
                        type: .newPost,
                        title: title ?? "New animation",
                        userId: userId ?? "",
                        timestamp: Date()
                    )
                    self.liveFeedItems.insert(event, at: 0)
                    // Keep only last 50
                    if self.liveFeedItems.count > 50 {
                        self.liveFeedItems = Array(self.liveFeedItems.prefix(50))
                    }
                }
            }
        }
    }

    // MARK: - Challenge Entries (live votes)
    private func subscribeToChallengeEntries() async {
        let channel = supabase.realtimeV2.channel("challenge_entries")

        let changes = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "challenge_entries"
        )

        await channel.subscribe()
        channels.append(channel)

        Task {
            for await update in changes {
                NotificationCenter.default.post(
                    name: .challengeEntryUpdated,
                    object: update.record
                )
            }
        }
    }

    // MARK: - Presence (who's online in a Studio project)
    func trackPresence(projectId: String, username: String) async throws -> RealtimeChannelV2 {
        let channel = supabase.realtimeV2.channel("presence:\(projectId)")

        await channel.subscribe()
        try await channel.track(state: ["username": .string(username), "online_at": .string(ISO8601DateFormatter().string(from: Date()))])

        channels.append(channel)
        return channel
    }

    // MARK: - Unsubscribe
    func unsubscribeAll() async {
        for channel in channels {
            await channel.unsubscribe()
        }
        channels.removeAll()
        isSubscribed = false
        print("✅ Realtime: all channels unsubscribed")
    }

    // MARK: - Mark Read
    func markNotificationsRead() {
        unreadNotifications = 0
    }

    func markMessagesRead() {
        unreadMessages = 0
    }
}

// MARK: - Live Feed Event
struct LiveFeedEvent: Identifiable {
    let id: UUID
    let type: LiveFeedEventType
    let title: String
    let userId: String
    let timestamp: Date

    enum LiveFeedEventType {
        case newPost
        case newChallenge
        case newEntry
        case userJoined
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let newNotification = Notification.Name("newNotification")
    static let newMessage = Notification.Name("newMessage")
    static let challengeEntryUpdated = Notification.Name("challengeEntryUpdated")
}
