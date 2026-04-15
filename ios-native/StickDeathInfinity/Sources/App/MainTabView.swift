// MainTabView.swift
// Layer 1 — ROOT NAVIGATION
// 4 destination tabs: Home · Challenges · Studio · Profile
// Each tab owns its NavigationStack + NavigationPath — back always retraces exact route.
// Messages moved to Profile context. Spatter AI lives as overlay at RootView level.

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var router: NavigationRouter

    var body: some View {
        TabView(selection: $router.selectedTab) {
            // ── Tab 0: HOME (Discover) ──
            HomeTab()
                .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.icon) }
                .tag(AppTab.home)

            // ── Tab 1: CHALLENGES ──
            ChallengesTab()
                .tabItem { Label(AppTab.challenges.title, systemImage: AppTab.challenges.icon) }
                .tag(AppTab.challenges)

            // ── Tab 2: STUDIO (Create) ──
            StudioTab()
                .tabItem { Label(AppTab.studio.title, systemImage: AppTab.studio.icon) }
                .tag(AppTab.studio)

            // ── Tab 3: PROFILE ──
            ProfileTab()
                .tabItem { Label(AppTab.profile.title, systemImage: AppTab.profile.icon) }
                .tag(AppTab.profile)
        }
        .tint(.red)
        .onChange(of: router.selectedTab) { _, newTab in
            // Update Spatter context when tab changes
            switch newTab {
            case .home: router.spatterContext = .home
            case .challenges: router.spatterContext = .challenges
            case .studio: router.spatterContext = .studio(nil)
            case .profile: router.spatterContext = .profile
            }
        }
    }
}

// MARK: - Home Tab (NavigationStack with typed path)
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

// MARK: - Challenges Tab
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
                    case .challengeEditor(let project, let challengeId):
                        StudioView(vm: EditorViewModel(project: project))
                    }
                }
        }
    }
}

// MARK: - Studio Tab
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

// MARK: - Profile Tab
struct ProfileTab: View {
    @EnvironmentObject var router: NavigationRouter

    var body: some View {
        NavigationStack(path: $router.profilePath) {
            ProfileView()
                .navigationDestination(for: ProfileDestination.self) { dest in
                    switch dest {
                    case .notifications:
                        NotificationsView()
                    case .messages:
                        MessagesListView()
                    case .chat(let id, let username):
                        ChatView(conversationId: id, otherUsername: username)
                    case .settings:
                        EditProfileSheet()
                    case .achievements:
                        AchievementsView()
                    case .connectedAccounts:
                        ConnectedAccountsView()
                    case .subscription:
                        SubscriptionView()
                    case .personalization:
                        PersonalizationSheet()
                    case .referral:
                        ReferralView()
                    case .help:
                        HelpCenterView()
                    case .creatorProfile(let userId):
                        CreatorProfileView(userId: userId)
                    }
                }
        }
    }
}
