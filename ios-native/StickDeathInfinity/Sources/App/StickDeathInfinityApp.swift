// StickDeathInfinityApp.swift
// Main entry point — supports iPhone, iPad, Mac Catalyst
// v2: + onOpenURL for deep links + Sign In with Apple entitlement

import SwiftUI

@main
struct StickDeathInfinityApp: App {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var offlineManager = OfflineManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .environmentObject(themeManager)
                .environmentObject(offlineManager)
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
                .onAppear {
                    offlineManager.startMonitoring()
                    PushNotificationManager.shared.requestPermission()
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
        #if os(macOS) || targetEnvironment(macCatalyst)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Animation") {
                    NotificationCenter.default.post(name: .newProject, object: nil)
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        #endif
    }

    /// Start Realtime on login
                .onChange(of: auth.isAuthenticated) { _, isAuth in
                    Task {
                        if isAuth {
                            await realtime.subscribeAll()
                        } else {
                            await realtime.unsubscribeAll()
                        }
                    }
                }
                // Handle deep links: stickdeath://post/{id}, stickdeath://challenge/{id}, etc.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "stickdeath" else { return }
        let host = url.host ?? ""
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        switch host {
        case "post":
            if let id = pathComponents.first {
                NotificationCenter.default.post(name: .deepLinkPost, object: id)
            }
        case "challenge":
            if let id = pathComponents.first {
                NotificationCenter.default.post(name: .deepLinkChallenge, object: id)
            }
        case "studio":
            NotificationCenter.default.post(name: .switchToTab, object: "studio")
        case "profile":
            if let id = pathComponents.first {
                NotificationCenter.default.post(name: .deepLinkProfile, object: id)
            }
        default:
            break
        }
    }
}

extension Notification.Name {
    static let newProject = Notification.Name("newProject")
    static let toggleSidebar = Notification.Name("toggleSidebar")
    static let switchToTab = Notification.Name("switchToTab")
    static let deepLinkPost = Notification.Name("deepLinkPost")
    static let deepLinkChallenge = Notification.Name("deepLinkChallenge")
    static let deepLinkProfile = Notification.Name("deepLinkProfile")
}
