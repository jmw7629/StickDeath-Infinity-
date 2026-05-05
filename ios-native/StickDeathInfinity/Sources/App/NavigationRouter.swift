// NavigationRouter.swift
// Central navigation state — 5 tabs: Home · Challenges · Studio · Messages · Profile
// Studio hides the tab bar. Each tab owns its own NavigationPath.

import SwiftUI

// MARK: - Tab Enum (matches reference bottom nav)
enum AppTab: Int, CaseIterable, Identifiable {
    case home = 0
    case challenges = 1
    case studio = 2
    case messages = 3
    case profile = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .challenges: return "Challenges"
        case .studio: return "Studio"
        case .messages: return "Messages"
        case .profile: return "Profile"
        }
    }

    var emoji: String {
        switch self {
        case .home: return "🔥"
        case .challenges: return "🏆"
        case .studio: return "✏️"
        case .messages: return "💬"
        case .profile: return "👤"
        }
    }
}

// MARK: - Navigation Destinations

enum HomeDestination: Hashable {
    case postDetail(FeedItem)
    case creatorProfile(String)
}

enum ChallengesDestination: Hashable {
    case challengeDetail(Challenge)
    case creatorProfile(String)
    case challengeEditor(StudioProject, Int)
}

enum StudioDestination: Hashable {
    case editor(StudioProject)
    case templates
}

enum MessagesDestination: Hashable {
    case chat(Int, String)        // conversationId, username
    case voiceCall(String)        // channelName
    case watchTogether(String)    // channelName
    case creatorRoom(String)      // channelName
    case warRoom(String)          // channelName
}

enum ProfileDestination: Hashable {
    case notifications
    case messages
    case chat(Int, String)
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
enum SpatterContext: Equatable {
    case home
    case challenges
    case studio(EditorViewModel?)
    case messages
    case profile

    static func == (lhs: SpatterContext, rhs: SpatterContext) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home), (.challenges, .challenges),
             (.studio, .studio), (.messages, .messages),
             (.profile, .profile): return true
        default: return false
        }
    }
}

// MARK: - Router
@MainActor
class NavigationRouter: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var isInStudioEditor = false  // hides tab bar

    // Each tab owns its own path
    @Published var homePath = NavigationPath()
    @Published var challengesPath = NavigationPath()
    @Published var studioPath = NavigationPath()
    @Published var messagesPath = NavigationPath()
    @Published var profilePath = NavigationPath()

    // Spatter overlay
    @Published var showSpatter = false
    @Published var spatterContext: SpatterContext = .home

    func push<D: Hashable>(_ destination: D) {
        switch selectedTab {
        case .home: homePath.append(destination)
        case .challenges: challengesPath.append(destination)
        case .studio: studioPath.append(destination)
        case .messages: messagesPath.append(destination)
        case .profile: profilePath.append(destination)
        }
    }

    func deepLink<D: Hashable>(tab: AppTab, destination: D) {
        selectedTab = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.push(destination)
        }
    }

    func popToRoot(_ tab: AppTab? = nil) {
        let t = tab ?? selectedTab
        switch t {
        case .home: homePath = NavigationPath()
        case .challenges: challengesPath = NavigationPath()
        case .studio: studioPath = NavigationPath()
        case .messages: messagesPath = NavigationPath()
        case .profile: profilePath = NavigationPath()
        }
    }

    func openSpatter(context: SpatterContext) {
        spatterContext = context
        showSpatter = true
    }

    func closeSpatter() {
        showSpatter = false
    }
}
