// ═══════════════════════════════════════════════════════════════════
// SpatterBotService — Backend for Spatter Command Center
// Manages bot configs, content queue, analytics via Supabase
// Owner-only — gated by AppConfig.superuserEmails
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class SpatterBotService: ObservableObject {
    static let shared = SpatterBotService()

    // MARK: - Published State
    @Published var botConfigs: [String: BotConfiguration] = [:]
    @Published var contentQueue: [ContentQueueItem] = ContentQueueItem.seeded
    @Published var isLoading = false
    @Published var analytics: [PlatformAnalytics] = []

    // MARK: - Settings (persisted to UserDefaults for now, Supabase later)
    @Published var slackWebhook: String = ""
    @Published var globalPaused: Bool = false

    private let supabase = SupabaseManager.shared.client

    // MARK: - Owner Check
    var isOwner: Bool {
        guard let email = AuthService.shared.currentProfile?.email else { return false }
        return AppConfig.superuserEmails.contains(email.lowercased())
    }

    // MARK: - Load All Bot Configs
    func loadBotConfigs() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let configs: [BotConfiguration] = try await supabase
                .from("spatter_bot_configs")
                .select()
                .execute()
                .value

            for config in configs {
                botConfigs[config.platform] = config
            }
        } catch {
            // Table may not exist yet — use empty configs
            print("[SpatterBotService] Could not load configs: \(error.localizedDescription)")
        }
    }

    // MARK: - Save Bot Config
    func saveBotConfig(_ config: BotConfiguration) async throws {
        if config.id != nil {
            // Update
            try await supabase
                .from("spatter_bot_configs")
                .update(config)
                .eq("id", value: config.id!)
                .execute()
        } else {
            // Insert
            let saved: BotConfiguration = try await supabase
                .from("spatter_bot_configs")
                .insert(config)
                .select()
                .single()
                .execute()
                .value
            botConfigs[saved.platform] = saved
        }
        botConfigs[config.platform] = config
    }

    // MARK: - Toggle Bot Active
    func toggleBot(platform: BotPlatform) async {
        var config = botConfigs[platform.rawValue] ?? BotConfiguration(
            platform: platform.rawValue,
            isActive: false,
            credentials: [:],
            enabledFeatures: []
        )
        config.isActive.toggle()
        try? await saveBotConfig(config)
    }

    // MARK: - Content Queue
    func loadContentQueue() async {
        do {
            let items: [ContentQueueItem] = try await supabase
                .from("spatter_content_queue")
                .select()
                .order("scheduled_at", ascending: true)
                .execute()
                .value
            if !items.isEmpty {
                contentQueue = items
            }
        } catch {
            // Use seeded content if table doesn't exist yet
        }
    }

    func updateContentStatus(id: Int, status: ContentStatus) {
        if let idx = contentQueue.firstIndex(where: { $0.id == id }) {
            contentQueue[idx].status = status
        }
    }

    func deleteContentItem(id: Int) {
        contentQueue.removeAll { $0.id == id }
    }

    // MARK: - Analytics
    func loadAnalytics(days: Int = 7) async {
        // Build from content queue engagement data for now
        var platformStats: [String: PlatformAnalytics] = [:]
        for item in contentQueue where item.status == .posted {
            guard let platform = BotPlatform(rawValue: item.platform) else { continue }
            var stats = platformStats[item.platform] ?? PlatformAnalytics(
                platform: platform, followers: 0, posts: 0,
                likes: 0, comments: 0, shares: 0, views: 0, engagementRate: 0
            )
            stats.posts += 1
            if let eng = item.engagement {
                stats.likes += eng.likes
                stats.comments += eng.comments
                stats.shares += eng.shares
                stats.views += eng.views
            }
            platformStats[item.platform] = stats
        }
        analytics = Array(platformStats.values)
    }

    // MARK: - Stats
    var activeBotCount: Int {
        botConfigs.values.filter(\.isActive).count
    }

    var configuredBotCount: Int {
        botConfigs.values.filter { !$0.credentials.isEmpty }.count
    }

    var postsToday: Int {
        contentQueue.filter { $0.status == .posted }.count
    }

    var totalFollowers: Int {
        analytics.reduce(0) { $0 + $1.followers }
    }

    var contentQueuedCount: Int {
        contentQueue.filter { $0.status == .queued || $0.status == .draft }.count
    }

    // MARK: - Emergency Stop
    func emergencyStopAll() async {
        for key in botConfigs.keys {
            botConfigs[key]?.isActive = false
        }
        globalPaused = true
    }

    func resumeAll() {
        globalPaused = false
    }
}
