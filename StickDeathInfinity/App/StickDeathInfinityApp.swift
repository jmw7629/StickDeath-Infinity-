// ═══════════════════════════════════════════════════════════════════
// StickDeathInfinityApp — Root @main entry point
// Handles:
//  - Deep links (URL scheme: stickdeath://) through DeepLinkRouter
//  - StoreKit transaction listener
//  - Environment objects for all ViewModels
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

/// Every incoming URL is classified before any navigation. OAuth callbacks are
/// owned by the in-flight browser session and are rejected here; password
/// recovery links are handed to the auth service, which only completes them
/// when this device holds the matching request verifier; anything else is
/// reported as unsupported. There are no messaging, call or invite deep links.
enum DeepLinkRouter: Equatable {
    case authCallback
    case passwordReset
    case unsupported

    static let scheme = "stickdeath"

    static func route(_ url: URL) -> DeepLinkRouter {
        guard url.scheme?.lowercased() == scheme, url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return .unsupported }
        let path = url.path.hasSuffix("/") && url.path.count > 1 ? String(url.path.dropLast()) : url.path
        switch (host, path) {
        case ("auth", "/callback"): return .authCallback
        case ("auth", "/reset"):
            // A recovery link carries exactly one PKCE code and no fragment tokens.
            guard url.fragment == nil,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.filter({ $0.name == "code" }).count == 1,
                  !(items.first { $0.name == "code" }?.value ?? "").isEmpty,
                  !items.contains(where: { $0.name == "error" }) else { return .unsupported }
            return .passwordReset
        default: return .unsupported
        }
    }
}

/// Keeps the process alive while a scene-phase save finishes (#168). Studio's
/// flush runs when the scene leaves the foreground; without a background task
/// assertion iOS may suspend the app mid-write. The storage layer already
/// publishes only complete revisions, so an expired assertion can lose at most
/// the unselected in-progress revision, never the last selected one.
@MainActor enum BackgroundTaskScope {
    private final class Assertion {
        #if canImport(UIKit) && !os(watchOS)
        var identifier: UIBackgroundTaskIdentifier = .invalid
        #endif
    }
    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        #if canImport(UIKit) && !os(watchOS)
        let assertion = Assertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Expiration: release the assertion; the write itself is not torn
            // down because an interrupted write never selects partial content.
            Task { @MainActor in
                guard assertion.identifier != .invalid else { return }
                UIApplication.shared.endBackgroundTask(assertion.identifier); assertion.identifier = .invalid
            }
        }
        Task { @MainActor in
            await work()
            guard assertion.identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(assertion.identifier); assertion.identifier = .invalid
        }
        #else
        Task { @MainActor in await work() }
        #endif
    }
}

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
                    Task { await authVM.handleDeepLink(url) }
                }
        }
    }
}
