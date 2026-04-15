// NavigationRouter.swift
// Central navigation state — every tab owns its own NavigationPath
// so back always retraces the exact path the user took.
//
// Rules enforced:
//  1. Back never jumps tabs
//  2. Back never resets scroll position (NavigationStack preserves it)
//  3. Editor exit returns to Studio, challenge flows return to Challenges
//  4. Modal screens close, not navigate
//  5. Spatter overlay never changes navigation state

import SwiftUI

// MARK: - Tab Enum
enum AppTab: Int, CaseIterable, Identifiable {
    case home = 0
    case challenges = 1
    case studio = 2
    case profile = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .challenges: return "Challenges"
        case .studio: return "Studio"
        case .profile: return "Profile"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .challenges: return "trophy.fill"
        case .studio: return "paintbrush.pointed.fill"
        case .profile: return "person.crop.circle.fill"
        }
    }
}

// MARK: - Navigation Destinations (typed, Hashable)

/// Layer 2 destinations reachable from the Home tab
enum HomeDestination: Hashable {
    case postDetail(FeedItem)
    case creatorProfile(String)  // userId
}

/// Layer 2 destinations reachable from the Challenges tab
enum ChallengesDestination: Hashable {
    case challengeDetail(Challenge)
    case creatorProfile(String)
    case challengeEditor(StudioProject, Int)  // project + challengeId
}

/// Layer 2 destinations reachable from the Studio tab
enum StudioDestination: Hashable {
    case editor(StudioProject)
    case templates
}

/// Layer 2 destinations reachable from the Profile tab
enum ProfileDestination: Hashable {
    case notifications
    case messages
    case chat(Int, String)  // conversationId, username
    case settings
    case achievements
    case connectedAccounts
    case subscription
    case personalization
    case referral
    case help
    case creatorProfile(String)
}

// MARK: - Spatter Context
/// Tells Spatter AI what screen the user is on so it can give relevant suggestions
enum SpatterContext: Equatable {
    case home
    case challenges
    case studio(EditorViewModel?)
    case profile

    static func == (lhs: SpatterContext, rhs: SpatterContext) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home): return true
        case (.challenges, .challenges): return true
        case (.studio, .studio): return true
        case (.profile, .profile): return true
        default: return false
        }
    }
}

// MARK: - Router
@MainActor
class NavigationRouter: ObservableObject {
    @Published var selectedTab: AppTab = .home

    // Each tab owns its own path — back always retraces exact route
    @Published var homePath = NavigationPath()
    @Published var challengesPath = NavigationPath()
    @Published var studioPath = NavigationPath()
    @Published var profilePath = NavigationPath()

    // Spatter overlay state — Layer 4, never changes navigation
    @Published var showSpatter = false
    @Published var spatterContext: SpatterContext = .home

    // MARK: - Navigate within current tab
    func push<D: Hashable>(_ destination: D) {
        switch selectedTab {
        case .home: homePath.append(destination)
        case .challenges: challengesPath.append(destination)
        case .studio: studioPath.append(destination)
        case .profile: profilePath.append(destination)
        }
    }

    // MARK: - Deep link: switch tab then push
    func deepLink<D: Hashable>(tab: AppTab, destination: D) {
        selectedTab = tab
        // Small delay so TabView selection lands before push
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.push(destination)
        }
    }

    // MARK: - Pop to tab root
    func popToRoot(_ tab: AppTab? = nil) {
        let t = tab ?? selectedTab
        switch t {
        case .home: homePath = NavigationPath()
        case .challenges: challengesPath = NavigationPath()
        case .studio: studioPath = NavigationPath()
        case .profile: profilePath = NavigationPath()
        }
    }

    // MARK: - Spatter (overlay, never navigation)
    func openSpatter(context: SpatterContext) {
        spatterContext = context
        showSpatter = true
    }

    func closeSpatter() {
        showSpatter = false
    }
}
