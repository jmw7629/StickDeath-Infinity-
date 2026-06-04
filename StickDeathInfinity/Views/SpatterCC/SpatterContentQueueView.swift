// ═══════════════════════════════════════════════════════════════════
// SpatterContentQueueView — Content queue management
// Matches: spatter-admin /content-queue exactly
// - Filter by platform / status
// - Pre-generated content items with platform icon, preview, status
// - Scheduled date display
// - Approve/reject/delete actions
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SpatterContentQueueView: View {
    @ObservedObject private var botService = SpatterBotService.shared
    @State private var filterPlatform: BotPlatform? = nil
    @State private var filterStatus: ContentStatus? = nil

    private var filteredItems: [ContentQueueItem] {
        botService.contentQueue.filter { item in
            let platformMatch = filterPlatform == nil || item.platform == filterPlatform?.rawValue
            let statusMatch = filterStatus == nil || item.status == filterStatus
            return platformMatch && statusMatch
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Content Queue")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.sdTextPrimary)
                Text("\(botService.contentQueue.count) items across all platforms")
                    .font(.system(size: 14))
                    .foregroundColor(.sdTextSecondary)
            }

            // Filters
            VStack(spacing: 12) {
                // Platform filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CCFilterChip(label: "All", selected: filterPlatform == nil) {
                            filterPlatform = nil
                        }
                        ForEach(BotPlatform.allCases) { platform in
                            CCFilterChip(
                                label: "\(platform.icon) \(platform.displayName)",
                                selected: filterPlatform == platform
                            ) {
                                filterPlatform = (filterPlatform == platform) ? nil : platform
                            }
                        }
                    }
                }

                // Status filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CCFilterChip(label: "All Status", selected: filterStatus == nil) {
                            filterStatus = nil
                        }
                        ForEach(ContentStatus.allCases, id: \.rawValue) { status in
                            CCFilterChip(
                                label: status.rawValue.capitalized,
                                selected: filterStatus == status,
                                color: statusColor(status)
                            ) {
                                filterStatus = (filterStatus == status) ? nil : status
                            }
                        }
                    }
                }
            }

            // Queue items
            if filteredItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.sdTextMuted)
                    Text("No items match your filters")
                        .font(.system(size: 15))
                        .foregroundColor(.sdTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else {
                ForEach(filteredItems) { item in
                    ContentQueueItemRow(item: item)
                }
            }
        }
    }

    private func statusColor(_ status: ContentStatus) -> Color {
        switch status {
        case .draft:  return Color(hex: "FFD600")
        case .queued: return Color(hex: "1DA1F2")
        case .posted: return .sdSuccess
        case .failed: return .sdDestructive
        }
    }
}

// MARK: - Content Queue Item Row

struct ContentQueueItemRow: View {
    let item: ContentQueueItem
    @ObservedObject private var botService = SpatterBotService.shared
    @State private var showActions = false

    private var platform: BotPlatform? {
        BotPlatform(rawValue: item.platform)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top: platform + status
            HStack {
                HStack(spacing: 8) {
                    Text(platform?.icon ?? "📄")
                        .font(.system(size: 18))
                    Text(platform?.displayName ?? item.platform)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.sdTextPrimary)
                }

                Spacer()

                CCStatusBadge(
                    text: item.status.rawValue,
                    color: statusColor(item.status)
                )
            }

            // Content preview
            Text(item.content)
                .font(.system(size: 14))
                .foregroundColor(.sdTextSecondary)
                .lineLimit(3)

            // Footer: scheduled date + actions
            HStack {
                if let scheduled = item.scheduledAt {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        Text(formatDate(scheduled))
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.sdTextMuted)
                }

                Spacer()

                HStack(spacing: 8) {
                    if item.status == .draft {
                        Button {
                            botService.updateContentStatus(id: item.id, status: .queued)
                        } label: {
                            Label("Queue", systemImage: "tray.and.arrow.down.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "1DA1F2"))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(hex: "1DA1F2").opacity(0.12))
                                .cornerRadius(6)
                        }
                    }

                    if item.status == .queued {
                        Button {
                            botService.updateContentStatus(id: item.id, status: .draft)
                        } label: {
                            Label("Hold", systemImage: "pause.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "FFD600"))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(hex: "FFD600").opacity(0.12))
                                .cornerRadius(6)
                        }
                    }

                    Button {
                        botService.deleteContentItem(id: item.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.sdDestructive)
                            .padding(6)
                            .background(Color.sdDestructive.opacity(0.12))
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.sdSurface)
        .cornerRadius(12)
    }

    private func statusColor(_ status: ContentStatus) -> Color {
        switch status {
        case .draft:  return Color(hex: "FFD600")
        case .queued: return Color(hex: "1DA1F2")
        case .posted: return .sdSuccess
        case .failed: return .sdDestructive
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

// MARK: - Filter Chip

struct CCFilterChip: View {
    let label: String
    let selected: Bool
    var color: Color = .sdRed
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : .sdTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? color.opacity(0.8) : Color.sdSurface2)
                .cornerRadius(20)
        }
    }
}
