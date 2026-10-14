// ═══════════════════════════════════════════════════════════════════
// CommunityChrome — shared dark-chrome building blocks for the community
// screens (feed, Rooms, War Room, challenges, Calendar, profile, admin):
// StudioCraftTheme tokens, Special Elite headings, 44 pt targets, reduced
// motion respected, and one place that owns the production client instances.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

/// Production clients share one gateway over the Supabase transport.
@MainActor
enum CommunityServices {
    static let gateway = CommunityGateway(transport: SupabaseCommunityTransport.shared)
    static let feed = FeedClient(gateway: gateway)
    static let profile = ProfileClient(gateway: gateway)
    static let rooms = RoomsClient(gateway: gateway)
    static let warRoom = WarRoomClient(gateway: gateway)
    static let challenges = ChallengeLifecycleClient(gateway: gateway)
    static let calendar = CalendarClient(gateway: gateway)
    static let admin = AdminOperationsClient(gateway: gateway)
    /// Honest configuration state for screens that depend on the service.
    static var isConfigured: Bool { AppConfig.supabaseConfiguration != nil }
    static let notConfiguredText = "Community services are not configured in this build. Nothing is sent or shown as live data."
}

extension Notification.Name {
    /// Posted after a room's shared project was opened in the shared editor so
    /// the tab host can show the Studio tab without closing other work.
    static let sdiCommunityOpenStudio = Notification.Name("sdi.community.openStudio")
    /// Posted by the tab host or Studio to come back to the room whose shared
    /// project is open in Studio (RoomSessionCoordinator.returnRoom).
    static let sdiCommunityReturnToRoom = Notification.Name("sdi.community.returnToRoom")
}

struct CommunityCard<Content: View>: View {
    var selected = false
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: StudioCraftTheme.itemSpacing) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? StudioCraftTheme.hover : StudioCraftTheme.card)
            .overlay(RoundedRectangle(cornerRadius: StudioCraftTheme.radiusLarge)
                .stroke(selected ? StudioCraftTheme.accent.opacity(0.6) : StudioCraftTheme.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radiusLarge))
    }
}

struct CommunityPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.specialElite(15, relativeTo: .body))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isEnabled ? StudioCraftTheme.accent : StudioCraftTheme.pressed)
            .clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radius))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
struct CommunitySecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.specialElite(14, relativeTo: .callout))
            .foregroundStyle(destructive ? StudioCraftTheme.danger : StudioCraftTheme.accentText)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(StudioCraftTheme.field)
            .overlay(RoundedRectangle(cornerRadius: StudioCraftTheme.radius).stroke(StudioCraftTheme.fieldBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radius))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Status line kinds shared by every community screen.
struct CommunityMessage: View {
    enum Kind { case info, error, offline, success }
    let text: String
    var kind: Kind = .info
    var body: some View {
        Label {
            Text(text).font(.specialElite(13, relativeTo: .footnote))
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    private var icon: String {
        switch kind {
        case .info: return "info.circle"
        case .error: return "exclamationmark.triangle"
        case .offline: return "wifi.slash"
        case .success: return "checkmark.circle"
        }
    }
    private var color: Color {
        switch kind {
        case .info: return StudioCraftTheme.textDim
        case .error: return StudioCraftTheme.accentText
        case .offline: return StudioCraftTheme.warning
        case .success: return StudioCraftTheme.textDim
        }
    }
}

/// Guest prompt that reuses the app-wide sign-in flow (Studio work is kept).
struct CommunitySignInPrompt: View {
    let text: String
    let identifier: String
    @Environment(\.requestSignIn) private var requestSignIn
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text, systemImage: "lock").font(.specialElite(15, relativeTo: .body))
            Button("Sign In") { requestSignIn() }
                .buttonStyle(CommunityPrimaryButtonStyle())
                .accessibilityIdentifier(identifier)
            Text("Your Studio project is saved before sign-in and reopens when you return.")
                .font(.specialElite(12, relativeTo: .caption)).foregroundStyle(StudioCraftTheme.textDim)
        }
    }
}

extension View {
    func communityHeading() -> some View {
        font(.specialElite(22, relativeTo: .title2)).foregroundStyle(StudioCraftTheme.text)
    }
    func communitySubheading() -> some View {
        font(.specialElite(17, relativeTo: .headline)).foregroundStyle(StudioCraftTheme.text)
    }
    func communityCaption() -> some View {
        font(.specialElite(12, relativeTo: .caption)).foregroundStyle(StudioCraftTheme.textDim)
    }
    func communityScreen() -> some View {
        foregroundStyle(StudioCraftTheme.text).background(StudioCraftTheme.chrome.ignoresSafeArea())
    }
    func communityField() -> some View {
        font(.specialElite(14, relativeTo: .body))
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(StudioCraftTheme.field)
            .overlay(RoundedRectangle(cornerRadius: StudioCraftTheme.radius).stroke(StudioCraftTheme.fieldBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radius))
    }
}

/// Short account identifier for membership lists (never a name the server did not supply).
func communityShortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) + "…" }
