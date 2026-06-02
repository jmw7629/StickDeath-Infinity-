// ═══════════════════════════════════════════════════════════════════
// SpatterCommandCenterView — Main hub for owner-only bot management
// Matches: spatter-admin Viktor Space exactly (all 12 pages)
// Sidebar navigation → Dashboard | Content Queue | Analytics |
//   Settings | 8 platform bot configs
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

enum CCPage: Hashable {
    case dashboard
    case contentQueue
    case analytics
    case settings
    case botConfig(BotPlatform)
}

struct SpatterCommandCenterView: View {
    @StateObject private var botService = SpatterBotService.shared
    @State private var selectedPage: CCPage = .dashboard
    @State private var showSidebar = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Main content (always visible)
            VStack(spacing: 0) {
                CCTopBar(showSidebar: $showSidebar)

                ScrollView {
                    pageContent
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 100)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.sdBackground)

            // Dim overlay when sidebar is open
            if showSidebar {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { showSidebar = false }
                    }
            }

            // Sidebar (slides in from left)
            if showSidebar {
                CCSidebar(selectedPage: $selectedPage, showSidebar: $showSidebar)
                    .frame(width: 260)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showSidebar)
        .task {
            await botService.loadBotConfigs()
            await botService.loadContentQueue()
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .dashboard:
            SpatterDashboardView(selectedPage: $selectedPage)
        case .contentQueue:
            SpatterContentQueueView()
        case .analytics:
            SpatterAnalyticsView()
        case .settings:
            SpatterCCSettingsView()
        case .botConfig(let platform):
            SpatterBotConfigView(platform: platform)
        }
    }
}

// MARK: - Top Bar

struct CCTopBar: View {
    @Binding var showSidebar: Bool

    var body: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { showSidebar.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.sdTextPrimary)
            }

            Spacer()

            HStack(spacing: 6) {
                Text("💀")
                    .font(.system(size: 20))
                Text("Spatter Command Center")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.sdTextPrimary)
            }

            Spacer()

            // Placeholder for balance
            Color.clear.frame(width: 24, height: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.sdSurface)
        .overlay(
            Rectangle().fill(Color.sdBorder).frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Sidebar

struct CCSidebar: View {
    @Binding var selectedPage: CCPage
    @Binding var showSidebar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("💀")
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spatter")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.sdTextPrimary)
                    Text("Command Center")
                        .font(.system(size: 11))
                        .foregroundColor(.sdTextMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)

            Divider().background(Color.sdBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // Core pages
                    CCSidebarItem(title: "Dashboard", icon: "square.grid.2x2.fill",
                                  selected: selectedPage == .dashboard) {
                        selectedPage = .dashboard
                        closeSidebar()
                    }
                    CCSidebarItem(title: "Content Queue", icon: "tray.full.fill",
                                  selected: selectedPage == .contentQueue) {
                        selectedPage = .contentQueue
                        closeSidebar()
                    }
                    CCSidebarItem(title: "Analytics", icon: "chart.bar.fill",
                                  selected: selectedPage == .analytics) {
                        selectedPage = .analytics
                        closeSidebar()
                    }
                    CCSidebarItem(title: "Settings", icon: "gearshape.fill",
                                  selected: selectedPage == .settings) {
                        selectedPage = .settings
                        closeSidebar()
                    }

                    // Platform bots section
                    Text("PLATFORM BOTS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundColor(.sdTextMuted)
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .padding(.bottom, 8)

                    ForEach(BotPlatform.allCases) { platform in
                        let isSelected: Bool = {
                            if case .botConfig(let p) = selectedPage { return p == platform }
                            return false
                        }()

                        CCSidebarItem(
                            title: platform.displayName,
                            emoji: platform.icon,
                            selected: isSelected
                        ) {
                            selectedPage = .botConfig(platform)
                            closeSidebar()
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Spacer()
        }
        .background(Color.sdSurface)
        .overlay(
            Rectangle().fill(Color.sdBorder).frame(width: 1),
            alignment: .trailing
        )
    }

    private func closeSidebar() {
        withAnimation(.easeInOut(duration: 0.25)) { showSidebar = false }
    }
}

struct CCSidebarItem: View {
    let title: String
    var icon: String? = nil
    var emoji: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let emoji {
                    Text(emoji)
                        .font(.system(size: 16))
                        .frame(width: 24)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundColor(selected ? .sdRed : .sdTextSecondary)
                        .frame(width: 24)
                }

                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .sdTextPrimary : .sdTextSecondary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(selected ? Color.sdRed.opacity(0.1) : Color.clear)
            .cornerRadius(8)
            .padding(.horizontal, 8)
        }
    }
}
