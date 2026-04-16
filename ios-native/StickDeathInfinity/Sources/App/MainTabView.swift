// MainTabView.swift
// Layer 1 — ROOT NAVIGATION
// 4 destination tabs: Home · Challenges · Studio · Profile
// Custom tab bar matching web BottomNav design
// Each tab owns its NavigationStack + NavigationPath

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
                case .profile: ProfileTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Custom Bottom Nav (matches web) ──
            customTabBar

            // ── Spatter FAB (blood drop) ──
            spatterFAB
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: router.selectedTab) { _, newTab in
            switch newTab {
            case .home: router.spatterContext = .home
            case .challenges: router.spatterContext = .challenges
            case .studio: router.spatterContext = .studio(nil)
            case .profile: router.spatterContext = .profile
            }
        }
    }

    // MARK: - Custom Tab Bar
    var customTabBar: some View {
        HStack(spacing: 0) {
            tabButton(.home, icon: "flame.fill", label: "Home")
            tabButton(.challenges, icon: "trophy.fill", label: "Challenges")
            studioTabButton
            tabButton(.profile, icon: "person.fill", label: "Profile")
        }
        .frame(height: 56)
        .background(
            ThemeManager.card.opacity(0.95)
                .background(.ultraThinMaterial)
        )
        .overlay(
            Rectangle().fill(ThemeManager.border).frame(height: 1),
            alignment: .top
        )
    }

    func tabButton(_ tab: AppTab, icon: String, label: String) -> some View {
        let isActive = router.selectedTab == tab
        return Button {
            router.selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .white : ThemeManager.textDim)
                Text(label)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .white : ThemeManager.textDim)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // Studio tab — special red pill capsule when active
    var studioTabButton: some View {
        let isActive = router.selectedTab == .studio
        return Button {
            router.selectedTab = .studio
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? ThemeManager.brand : ThemeManager.surface)
                        .frame(width: 40, height: 28)
                        .overlay(
                            Group {
                                if !isActive {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(ThemeManager.border, lineWidth: 1)
                                }
                            }
                        )
                        .shadow(color: isActive ? ThemeManager.brand.opacity(0.3) : .clear, radius: 8)

                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isActive ? .white : ThemeManager.textDim)
                }
                .offset(y: -2)

                Text("Studio")
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .white : ThemeManager.textDim)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Spatter FAB (Blood Drop Button)
    var spatterFAB: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    router.openSpatter(context: router.spatterContext)
                } label: {
                    ZStack {
                        Circle()
                            .fill(ThemeManager.brand)
                            .frame(width: 52, height: 52)
                            .shadow(color: ThemeManager.brand.opacity(0.4), radius: 10)

                        // Blood drop icon
                        Image(systemName: "drop.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 72) // above tab bar
            }
        }
    }
}

// MARK: - Tab Views (NavigationStack wrappers)
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
