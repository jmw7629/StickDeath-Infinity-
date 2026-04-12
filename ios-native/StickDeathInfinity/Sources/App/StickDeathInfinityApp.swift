// StickDeathInfinityApp.swift
// Main entry point

import SwiftUI

@main
struct StickDeathInfinityApp: App {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var themeManager = ThemeManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .environmentObject(themeManager)
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
        }
    }
}
