// ═══════════════════════════════════════════════════════════════════
// MainTabView — Bottom tab bar navigation
// Matches: MainApp.tsx NAV_ITEMS exactly
// Tabs: 🏠 Home / ⚔️ Challenges / 🎨 Studio / 💬 Messages / 👤 Profile
// Pricing ticker overlay + Spatter AI orb on all tabs except Studio
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct MainTabView: View {
    @State private var activeTab: AppTab = .home
    @State private var showTutorial = true
    @EnvironmentObject var spatterVM: SpatterAIViewModel

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Active screen
                Group {
                    switch activeTab {
                    case .home:
                        HomeFeedView()
                    case .challenges:
                        ChallengesView()
                    case .studio:
                        StudioView()
                    case .messages:
                        MessagesView()
                    case .profile:
                        ProfileView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom nav bar
                if activeTab != .studio || !StudioState.shared.isEditing {
                    bottomNavBar
                }
            }

            // Pricing ticker (hidden in Studio)
            if activeTab != .studio {
                PricingTickerView()
            }

            // Tutorial overlay
            if showTutorial {
                AppTutorialView(
                    onComplete: { showTutorial = false },
                    onSwitchTab: { tab in
                        if let t = AppTab(rawValue: tab) { activeTab = t }
                    }
                )
            }
        }
    }

    // MARK: - Bottom Nav Bar
    private var bottomNavBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        activeTab = tab
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(tab.icon)
                            .font(.system(size: 20))
                            .grayscale(activeTab == tab ? 0 : 1)
                            .opacity(activeTab == tab ? 1 : 0.5)

                        Text(tab.label)
                            .font(.specialElite(10))
                            .foregroundColor(activeTab == tab ? .sdRed : .sdTextMuted)
                            .fontWeight(activeTab == tab ? .bold : .regular)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.sdSurface)
        .overlay(
            Rectangle().fill(Color.sdBorder).frame(height: 1),
            alignment: .top
        )
    }
}

// MARK: - App Tab Enum
enum AppTab: String, CaseIterable {
    case home, challenges, studio, messages, profile

    var icon: String {
        switch self {
        case .home: return "🏠"
        case .challenges: return "⚔️"
        case .studio: return "🎨"
        case .messages: return "💬"
        case .profile: return "👤"
        }
    }

    var label: String {
        switch self {
        case .home: return "Home"
        case .challenges: return "Challenges"
        case .studio: return "Studio"
        case .messages: return "Messages"
        case .profile: return "Profile"
        }
    }
}

// Studio state tracker
class StudioState: ObservableObject {
    static let shared = StudioState()
    @Published var isEditing = false
}
