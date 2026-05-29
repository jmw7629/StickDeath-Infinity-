// ═══════════════════════════════════════════════════════════════════
// SpatterDashboardView — Command Center dashboard
// Matches: spatter-admin /dashboard exactly
// - Spatter profile header with tagline
// - Bot status bar (active / configured count)
// - 4 stat cards (Active Bots, Posts Today, Total Followers, Content Queued)
// - Platform bot grid with status + configure links
// - Content queue preview (latest 5 items)
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SpatterDashboardView: View {
    @ObservedObject private var botService = SpatterBotService.shared
    @Binding var selectedPage: CCPage

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            headerSection

            // Stats row
            statsRow

            // Platform Bots grid
            platformBotsSection

            // Content Queue preview
            contentQueuePreview
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 16) {
            // Spatter profile
            HStack(spacing: 16) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(Color.sdSurface2)
                        .frame(width: 64, height: 64)
                    Text("💀")
                        .font(.system(size: 32))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Spatter")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.sdTextPrimary)
                    Text("\"Making TikTok kids question their life choices since 2026 🎵\"")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.sdTextSecondary)
                        .italic()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Status bar
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(botService.activeBotCount > 0 ? Color.sdSuccess : Color.sdTextMuted)
                        .frame(width: 8, height: 8)
                    Text("\(botService.activeBotCount) / 8 Active")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.sdTextSecondary)
                }

                Text("•")
                    .foregroundColor(.sdTextMuted)

                Text("\(botService.configuredBotCount) Configured")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.sdTextSecondary)
            }
        }
        .padding(20)
        .background(Color.sdSurface)
        .cornerRadius(16)
    }

    // MARK: - Stats Row
    private var statsRow: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ], spacing: 12) {
            CCStatCard(value: "\(botService.activeBotCount)", label: "Active Bots",
                       icon: "bolt.fill", color: .sdRed)
            CCStatCard(value: "\(botService.postsToday)", label: "Posts Today",
                       icon: "paperplane.fill", color: Color(hex: "1DA1F2"))
            CCStatCard(value: "\(botService.totalFollowers)", label: "Total Followers",
                       icon: "person.2.fill", color: Color(hex: "00C853"))
            CCStatCard(value: "\(botService.contentQueuedCount)", label: "Content Queued",
                       icon: "tray.full.fill", color: Color(hex: "FFD600"))
        }
    }

    // MARK: - Platform Bots
    private var platformBotsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Platform Bots")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.sdTextPrimary)

            ForEach(BotPlatform.allCases) { platform in
                let config = botService.botConfigs[platform.rawValue]
                let isConfigured = config != nil && !(config?.credentials.isEmpty ?? true)
                let isActive = config?.isActive ?? false

                Button {
                    selectedPage = .botConfig(platform)
                } label: {
                    HStack(spacing: 12) {
                        Text(platform.icon)
                            .font(.system(size: 24))
                            .frame(width: 40, height: 40)
                            .background(platform.color.opacity(0.15))
                            .cornerRadius(10)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(platform.displayName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.sdTextPrimary)
                            Text(platform.shortDescription)
                                .font(.system(size: 12))
                                .foregroundColor(.sdTextSecondary)
                        }

                        Spacer()

                        if isActive {
                            CCStatusBadge(text: "Active", color: .sdSuccess)
                        } else if isConfigured {
                            CCStatusBadge(text: "Ready", color: Color(hex: "FFD600"))
                        } else {
                            CCStatusBadge(text: "Needs API keys", color: .sdTextMuted)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.sdTextMuted)
                    }
                    .padding(14)
                    .background(Color.sdSurface)
                    .cornerRadius(12)
                }
            }
        }
    }

    // MARK: - Content Queue Preview
    private var contentQueuePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Content Queue")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.sdTextPrimary)
                Spacer()
                Button {
                    selectedPage = .contentQueue
                } label: {
                    Text("View all")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.sdRed)
                }
            }

            ForEach(Array(botService.contentQueue.prefix(5))) { item in
                let platform = BotPlatform(rawValue: item.platform)
                HStack(spacing: 10) {
                    Text(platform?.icon ?? "📄")
                        .font(.system(size: 16))

                    Text(item.content)
                        .font(.system(size: 13))
                        .foregroundColor(.sdTextSecondary)
                        .lineLimit(2)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        CCStatusBadge(
                            text: item.status.rawValue,
                            color: item.status == .queued ? Color(hex: "1DA1F2") :
                                   item.status == .draft ? Color(hex: "FFD600") :
                                   item.status == .posted ? .sdSuccess : .sdDestructive
                        )
                        if let scheduled = item.scheduledAt {
                            Text(formatDate(scheduled))
                                .font(.system(size: 10))
                                .foregroundColor(.sdTextMuted)
                        }
                    }
                }
                .padding(12)
                .background(Color.sdSurface)
                .cornerRadius(10)
            }
        }
    }

    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateFormat = "M/d/yyyy h:mm a"
        return display.string(from: date)
    }
}

// MARK: - Stat Card

struct CCStatCard: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.sdTextPrimary)

            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.sdTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color.sdSurface)
        .cornerRadius(14)
    }
}

// MARK: - Status Badge

struct CCStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .cornerRadius(6)
    }
}
