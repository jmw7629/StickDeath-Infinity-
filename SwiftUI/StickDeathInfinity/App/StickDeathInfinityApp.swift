// ═══════════════════════════════════════════════════════════════════
// StickDeathInfinityApp — Root @main entry point
// Handles:
//  - OAuth callback for Google Sign In (URL scheme: stickdeath://)
//  - StoreKit transaction listener
//  - Environment objects for all ViewModels
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

@main
struct StickDeathInfinityApp: App {
    @StateObject private var authVM = AuthViewModel()
    @StateObject private var themeVM = ThemeViewModel()
    @StateObject private var spatterVM = SpatterAIViewModel()

    var body: some Scene {
        WindowGroup {
            AppFlowView()
                .environmentObject(authVM)
                .environmentObject(themeVM)
                .environmentObject(spatterVM)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Handle OAuth callback (Google Sign In redirect)
                    // URL scheme: stickdeath://auth/callback?...
                    if url.scheme == "stickdeath" && url.host == "auth" {
                        Task {
                            try? await AuthService.shared.handleOAuthCallback(url: url)
                        }
                    }
                }
        }
    }
}
