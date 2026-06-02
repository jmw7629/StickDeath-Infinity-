// ═══════════════════════════════════════════════════════════════════
// SpatterAnalyticsView — Engagement metrics across all platforms
// Matches: spatter-admin /analytics exactly
// - Time range picker (7 / 30 / 90 days)
// - Summary cards (Total Followers, Total Posts, Avg Engagement, Total Views)
// - Engagement breakdown (Likes, Comments, Shares, Views)
// - Per-platform analytics cards
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SpatterAnalyticsView: View {
    @ObservedObject private var botService = SpatterBotService.shared
    @State private var selectedRange: AnalyticsRange = .sevenDays

    enum AnalyticsRange: String, CaseIterable {
        case sevenDays  = "7 Days"
        case thirtyDays = "30 Days"
        case ninetyDays = "90 Days"

        var days: Int {
            switch self {
            case .sevenDays:  return 7
            case .thirtyDays: return 30
            case .ninetyDays: return 90
            }
        }
    }

    // Computed totals
    private var totalFollowers: Int { botService.analytics.reduce(0) { $0 + $1.followers } }
    private var totalPosts: Int { botService.analytics.reduce(0) { $0 + $1.posts } }
    private var totalLikes: Int { botService.analytics.reduce(0) { $0 + $1.likes } }
    private var totalComments: Int { botService.analytics.reduce(0) { $0 + $1.comments } }
    private var totalShares: Int { botService.analytics.reduce(0) { $0 + $1.shares } }
    private var totalViews: Int { botService.analytics.reduce(0) { $0 + $1.views } }
    private var avgEngagement: String {
        guard totalViews > 0 else { return "—" }
        let rate = Double(totalLikes + totalComments + totalShares) / Double(totalViews) * 100
        return String(format: "%.1f%%", rate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Analytics")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.sdTextPrimary)
                Text("Engagement metrics across all platforms")
                    .font(.system(size: 14))
                    .foregroundColor(.sdTextSecondary)
            }

            // Time range picker
            HStack(spacing: 8) {
                ForEach(AnalyticsRange.allCases, id: \.rawValue) { range in
                    Button {
                        selectedRange = range
                        Task { await botService.loadAnalytics(days: range.days) }
                    } label: {
                        Text(range.rawValue)
                            .font(.system(size: 13, weight: selectedRange == range ? .semibold : .regular))
                            .foregroundColor(selectedRange == range ? .white : .sdTextSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(selectedRange == range ? Color.sdRed : Color.sdSurface2)
                            .cornerRadius(8)
                    }
                }
                Spacer()
            }

            // Summary cards
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], spacing: 12) {
                AnalyticsSummaryCard(label: "Total Followers", value: "\(totalFollowers)",
                                     icon: "person.2.fill", color: Color(hex: "1DA1F2"))
                AnalyticsSummaryCard(label: "Total Posts", value: "\(totalPosts)",
                                     icon: "doc.text.fill", color: .sdRed)
                AnalyticsSummaryCard(label: "Avg Engagement", value: avgEngagement,
                                     icon: "chart.line.uptrend.xyaxis", color: Color(hex: "00C853"))
                AnalyticsSummaryCard(label: "Total Views", value: "\(totalViews)",
                                     icon: "eye.fill", color: Color(hex: "FFD600"))
            }

            // Engagement breakdown
            VStack(alignment: .leading, spacing: 12) {
                Text("Engagement Breakdown")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.sdTextPrimary)

                VStack(spacing: 8) {
                    EngagementRow(label: "Likes", value: totalLikes, icon: "heart.fill", color: .sdRed)
                    EngagementRow(label: "Comments", value: totalComments, icon: "bubble.left.fill", color: Color(hex: "1DA1F2"))
                    EngagementRow(label: "Shares", value: totalShares, icon: "arrowshape.turn.up.right.fill", color: Color(hex: "00C853"))
                    EngagementRow(label: "Views", value: totalViews, icon: "eye.fill", color: Color(hex: "FFD600"))
                }
                .padding(16)
                .background(Color.sdSurface)
                .cornerRadius(12)

                if botService.analytics.isEmpty {
                    Text("Metrics will populate as bots post content and gather engagement data")
                        .font(.system(size: 13))
                        .foregroundColor(.sdTextMuted)
                        .italic()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }

            // Per-platform analytics
            VStack(alignment: .leading, spacing: 12) {
                Text("Platform Analytics")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.sdTextPrimary)

                if botService.analytics.isEmpty {
                    // Show all platforms with empty state
                    ForEach(BotPlatform.allCases) { platform in
                        PlatformAnalyticsCard(platform: platform, stats: nil)
                    }
                } else {
                    ForEach(botService.analytics) { stats in
                        PlatformAnalyticsCard(platform: stats.platform, stats: stats)
                    }
                }
            }
        }
        .task {
            await botService.loadAnalytics(days: selectedRange.days)
        }
    }
}

// MARK: - Summary Card

struct AnalyticsSummaryCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                Spacer()
            }

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.sdTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.sdTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color.sdSurface)
        .cornerRadius(12)
    }
}

// MARK: - Engagement Row

struct EngagementRow: View {
    let label: String
    let value: Int
    let icon: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
                .frame(width: 24)

            Text(label)
                .font(.system(size: 14))
                .foregroundColor(.sdTextSecondary)

            Spacer()

            Text("\(value)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.sdTextPrimary)
        }
    }
}

// MARK: - Platform Analytics Card

struct PlatformAnalyticsCard: View {
    let platform: BotPlatform
    let stats: PlatformAnalytics?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(platform.icon)
                    .font(.system(size: 20))
                    .frame(width: 36, height: 36)
                    .background(platform.color.opacity(0.15))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.sdTextPrimary)
                    Text(platform.shortDescription)
                        .font(.system(size: 12))
                        .foregroundColor(.sdTextSecondary)
                }

                Spacer()
            }

            if let stats {
                HStack(spacing: 16) {
                    MiniStat(label: "Posts", value: "\(stats.posts)")
                    MiniStat(label: "Likes", value: "\(stats.likes)")
                    MiniStat(label: "Views", value: "\(stats.views)")
                    MiniStat(label: "Rate", value: String(format: "%.1f%%", stats.engagementRate))
                }
            } else {
                Text("Configure API keys to see analytics")
                    .font(.system(size: 12))
                    .foregroundColor(.sdTextMuted)
                    .italic()
            }
        }
        .padding(14)
        .background(Color.sdSurface)
        .cornerRadius(12)
    }
}

struct MiniStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.sdTextPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.sdTextMuted)
        }
    }
}
