// MainTabView.swift
// 5 tabs: Home · Challenges · Studio · Messages · Profile
// Custom tab bar with emoji icons matching reference exactly
// Studio hides the tab bar entirely

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var router: NavigationRouter

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Tab Content ──
            Group {
                switch router.selectedTab {
                case .home: HomeTab()
                case .challenges: ChallengesTab()
                case .studio: StudioTab()
                case .messages: MessagesTab()
                case .profile: ProfileTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Custom Bottom Nav (hidden in Studio editor) ──
            if !router.isInStudioEditor {
                customTabBar
            }

            // ── Spatter FAB (blood drop) — hidden in Studio ──
            if !router.isInStudioEditor {
                spatterFAB
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    // MARK: - Custom Tab Bar (matches reference exactly)
    var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .frame(height: 60)
        .background(
            ThemeManager.card.opacity(0.95)
                .background(.ultraThinMaterial)
        )
        .overlay(
            Rectangle().fill(ThemeManager.border).frame(height: 0.5),
            alignment: .top
        )
    }

    func tabButton(_ tab: AppTab) -> some View {
        let isActive = router.selectedTab == tab
        return Button {
            router.selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                // Studio tab: red highlight capsule when active
                if tab == .studio {
                    ZStack {
                        if isActive {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(ThemeManager.brand)
                                .frame(width: 44, height: 30)
                                .shadow(color: ThemeManager.brand.opacity(0.4), radius: 8)
                        }
                        Text(tab.emoji)
                            .font(.system(size: isActive ? 16 : 20))
                    }
                    .frame(height: 30)
                } else {
                    Text(tab.emoji)
                        .font(.system(size: 20))
                        .frame(height: 30)
                }

                Text(tab.title)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .white : ThemeManager.textDim)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Spatter FAB
    var spatterFAB: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    router.openSpatter(context: .home)
                } label: {
                    ZStack {
                        Circle()
                            .fill(ThemeManager.brand)
                            .frame(width: 52, height: 52)
                            .shadow(color: ThemeManager.brand.opacity(0.4), radius: 10)

                        Text("🩸")
                            .font(.system(size: 22))
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 76)
            }
        }
    }
}

// MARK: - Tab NavigationStack Wrappers

struct HomeTab: View {
    @EnvironmentObject var router: NavigationRouter

    var body: some View {
        NavigationStack(path: $router.homePath) {
            HomeView()
                .navigationDestination(for: HomeDestination.self) { dest in
                    switch dest {
                    case .postDetail(let item):
                        PostDetailView(item: item)
                    case .creatorProfile(let userId):
                        CreatorProfileView(userId: userId)
                    }
                }
        }
    }
}

struct ChallengesTab: View {
    @EnvironmentObject var router: NavigationRouter

    var body: some View {
        NavigationStack(path: $router.challengesPath) {
            ChallengesView()
                .navigationDestination(for: ChallengesDestination.self) { dest in
                    switch dest {
                    case .challengeDetail(let challenge):
                        ChallengeDetailView(challenge: challenge)
                    case .creatorProfile(let userId):
                        CreatorProfileView(userId: userId)
                    case .challengeEditor(let project, _):
                        StudioView(vm: EditorViewModel(project: project))
                    }
                }
        }
    }
}

struct StudioTab: View {
    @EnvironmentObject var router: NavigationRouter

    var body: some View {
        NavigationStack(path: $router.studioPath) {
            ProjectsGalleryView()
                .navigationDestination(for: StudioDestination.self) { dest in
                    switch dest {
                    case .editor(let project):
                        StudioView(vm: EditorViewModel(project: project))
                    case .templates:
                        TemplatesView()
                    }
                }
        }
    }
}

struct MessagesTab: View {
    @EnvironmentObject var router: NavigationRouter

    var body: some View {
        NavigationStack(path: $router.messagesPath) {
            MessagesListView()
                .navigationDestination(for: MessagesDestination.self) { dest in
                    switch dest {
                    case .chat(let id, let username):
                        ChatView(conversationId: id, otherUsername: username)
                    case .voiceCall(let channel):
                        VoiceCallView(channelName: channel)
                    case .watchTogether(let channel):
                        WatchTogetherView(channelName: channel)
                    case .creatorRoom(let channel):
                        CreatorRoomView(channelName: channel)
                    case .warRoom(let channel):
                        WarRoomView(channelName: channel)
                    }
                }
        }
    }
}

struct ProfileTab: View {
    @EnvironmentObject var router: NavigationRouter

    var body: some View {
        NavigationStack(path: $router.profilePath) {
            ProfileView()
                .navigationDestination(for: ProfileDestination.self) { dest in
                    switch dest {
                    case .notifications: NotificationsView()
                    case .messages: MessagesListView()
                    case .chat(let id, let username): ChatView(conversationId: id, otherUsername: username)
                    case .settings: EditProfileSheet()
                    case .achievements: AchievementsView()
                    case .connectedAccounts: ConnectedAccountsView()
                    case .subscription: SubscriptionView()
                    case .personalization: PersonalizationSheet()
                    case .referral: ReferralView()
                    case .help: HelpCenterView()
                    case .creatorProfile(let userId): CreatorProfileView(userId: userId)
                    }
                }
        }
    }
}
