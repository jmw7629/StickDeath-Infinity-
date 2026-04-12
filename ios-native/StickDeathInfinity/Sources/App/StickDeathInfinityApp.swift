// StickDeathInfinityApp.swift
// Main entry point — supports iPhone, iPad, Mac Catalyst

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
                .onAppear { offlineManager.startMonitoring() }
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
}

extension Notification.Name {
    static let newProject = Notification.Name("newProject")
    static let toggleSidebar = Notification.Name("toggleSidebar")
}
