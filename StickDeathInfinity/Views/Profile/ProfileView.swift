import SwiftUI
import AVKit
import Supabase
import UniformTypeIdentifiers

/// A creator's desktop: device projects and account facts keep distinct sources.
struct ProfileView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @Environment(\.requestSignIn) private var requestSignIn
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var stripe = StripeService.shared
    let onOpenProjects: () -> Void
    @State private var destination: Destination?
    @State private var localProjectCount: Int?
    @State private var localProjectProblem: String?
    @State private var publishedCount: Int?
    @State private var stats: CreatorStatsResponse?
    @State private var statsProblem: String?
    @State private var statsLoading = false
    @State private var statsRequestID = UUID()

    private enum Destination: String, Identifiable {
        case account, analytics, subscription, publishing, records, admin
        var id: String { rawValue }
        var title: String {
            switch self {
            case .admin: return "Admin access"
            case .records: return "Records & badges"
            case .publishing: return "Publishing"
            case .account: return "Settings"
            case .analytics: return "Analytics"
            case .subscription: return "Subscription"
            }
        }
    }
    private var profile: UserProfile? {
        guard authVM.isAuthenticated, let user = authVM.user,
              let id = UUID(uuidString: user.id), let current = authVM.userId,
              id == UUID(uuidString: current) else { return nil }
        return user
    }
    /// Only render the service snapshot for the currently signed-in account.
    private var currentStatistics: CreatorStatsResponse? {
        guard authVM.isAuthenticated,
              let account = authVM.userId.flatMap(UUID.init(uuidString:)),
              let stats, stats.subject == account else { return nil }
        return stats
    }
    private var displayName: String {
        let name = profile?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (authVM.isAuthenticated ? "Your profile" : "Guest") : name
    }
    private var reportedPlan: String? {
        // Server values are constrained by users-profiles.sql: free, monthly_4_99, monthly_9_99.
        switch profile?.subscriptionTier?.lowercased() {
        case "free": return "Free"
        case "monthly_4_99": return "Creator"
        case "monthly_9_99": return "Pro"
        default: return nil
        }
    }
    private var avatarURL: URL? {
        guard let raw = profile?.avatarURL, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        return url
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    desktopHeading
                    identityWindow
                    if geometry.size.width >= 780 && !dynamicTypeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 20) {
                            workWindows.frame(maxWidth: .infinity)
                            accountWindows.frame(width: 290)
                        }
                    } else {
                        workWindows
                        accountWindows
                    }
                    Text("STICKDEATH ∞  /  YOUR CREATOR DESKTOP")
                        .font(.specialElite(11, relativeTo: .caption))
                        .foregroundStyle(ProfileDesktopPalette.paper)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: 1180)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(ProfileDesktopWallpaper().ignoresSafeArea())
        }
        .task(id: "\(authVM.userId ?? "none"):\(authVM.isAuthenticated):\(phase == .active)") {
            await loadStatistics()
        }
        .onChange(of: authVM.userId) { _ in destination = nil; publishedCount = nil }
        .sheet(item: $destination) { page in
            if page == .subscription {
                // SubscriptionView brings its own header and close control.
                NavigationStack { SubscriptionView() }
            } else {
                NavigationStack {
                    Group {
                        switch page {
                        case .admin: AdminDashboardView()
                        case .records: ProfileRecordsView()
                        case .publishing: PublishingJobsView()
                        case .account: ProfileSettingsView()
                        case .analytics:
                            analyticsPage
                        case .subscription: EmptyView()
                        }
                    }
                    .navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
                }
            }
        }
    }

    private var desktopHeading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                desktopTitle
                Spacer(minLength: 12)
                desktopLocation
            }
            VStack(alignment: .leading, spacing: 8) {
                desktopTitle
                desktopLocation
            }
        }
        .padding(12)
        .foregroundStyle(ProfileDesktopPalette.ink)
        .background(ProfileDesktopPalette.paper)
        .overlay(Rectangle().stroke(ProfileDesktopPalette.ink, lineWidth: 2))
    }
    private var desktopTitle: some View {
        Text("SD∞ / CREATOR DESKTOP")
            .font(.specialElite(16, relativeTo: .headline))
            .accessibilityAddTraits(.isHeader)
    }
    private var desktopLocation: some View {
        Label(authVM.isAuthenticated ? "Account + device" : "On this device", systemImage: authVM.isAuthenticated ? "person.crop.circle" : "internaldrive")
            .font(.specialElite(11, relativeTo: .caption))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var identityLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
    }
    private var identityWindow: some View {
        ProfileDesktopWindow(title: "Creator identity", icon: "person.crop.square") {
            VStack(alignment: .leading, spacing: 16) {
                identityLayout {
                    AsyncImage(url: avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProfileDesktopStickMark()
                            .stroke(ProfileDesktopPalette.paper, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .padding(12)
                            .background(ProfileDesktopPalette.ink)
                    }
                    .frame(width: 72, height: 80)
                    .clipped()
                    .overlay(Rectangle().stroke(ProfileDesktopPalette.ink, lineWidth: 2))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayName)
                            .font(.specialElite(27, relativeTo: .title))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(reportedPlan.map { "Reported plan: \($0)" } ?? (authVM.isAuthenticated ? "Plan unavailable" : "On-device guest"))
                            .font(.specialElite(12, relativeTo: .caption))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(ProfileDesktopPalette.grey.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let bio = profile?.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(bio).font(.body).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                }
                if !authVM.isAuthenticated {
                    Text("Your device projects stay here whether or not you sign in.")
                        .font(.callout).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                    Button { requestSignIn() } label: {
                        Label("Sign in or create an account", systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ProfileDesktopButtonStyle(prominent: true))
                    .accessibilityIdentifier("profile.sign-in")
                } else {
                    Button { destination = .account } label: {
                        Label("Account settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ProfileDesktopButtonStyle())
                    .accessibilityIdentifier("profile.settings.open")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.identity")
    }

    private var workWindows: some View {
        VStack(alignment: .leading, spacing: 20) {
            projectWindow
            statisticsWindow
            ProfileDesktopWindow(title: "Portfolio", icon: "play.rectangle") {
                if authVM.isAuthenticated {
                    ProfilePortfolioSection(onCount: { publishedCount = $0 })
                    if let publishedCount {
                        Text("\(publishedCount) approved rendition\(publishedCount == 1 ? "" : "s") returned by the service. This is separate from the projects stored on this device.")
                            .font(.caption).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                    }
                } else {
                    Label("Your approved work belongs here.", systemImage: "film")
                        .font(.specialElite(18, relativeTo: .headline))
                    Text("Sign in to load your account's approved renditions. Private projects stay in the device library.")
                        .font(.callout).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                }
            }
        }
    }
    private var projectWindow: some View {
        ProfileDesktopWindow(title: "Projects on this device", icon: "folder") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Text("DRAW IT.\nTIME IT.\nMAKE IT MOVE.")
                        .font(.specialElite(25, relativeTo: .title2))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ProfileDesktopStickMark()
                        .stroke(ProfileDesktopPalette.ink, style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .miter))
                        .frame(width: 52, height: 80)
                        .accessibilityHidden(true)
                }
                Text("Open a saved animation or start a new project in your library. Editable originals stay on this device.")
                    .font(.callout).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                Button(action: onOpenProjects) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus")
                        Text("Open projects / create")
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                    }
                }
                .buttonStyle(ProfileDesktopButtonStyle(prominent: true))
                .accessibilityLabel("Projects on this device")
                .accessibilityHint("Opens the project library, where you can open or create an animation.")
                .accessibilityIdentifier("profile.projects.open")
            }
        }
    }
    private var statisticsWindow: some View {
        ProfileDesktopWindow(title: "Creator totals", icon: "chart.bar.xaxis") {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 220 : 125), spacing: 2)], spacing: 2) {
                    statistic(localProjectCount.map(String.init) ?? "—", "Projects", source: "On this device")
                    statistic(currentStatistics?.published_videos.map(String.init) ?? "—", "Published", source: "From the service")
                    statistic(currentStatistics?.followers.map(String.init) ?? "—", "Followers", source: "From the service")
                    statistic(currentStatistics?.likes_received.map(String.init) ?? "—", "Likes", source: "From the service")
                }
                .accessibilityIdentifier("profile.statistics")
                Text("Projects counts saved animations on this device. Published and Likes come from eligible videos currently visible on the wall. Followers and Following are current account relationships. A dash means a total was not loaded.")
                    .font(.caption).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                if let localProjectProblem {
                    ProfileDesktopNotice(text: localProjectProblem, icon: "externaldrive.badge.exclamationmark")
                }
                if let statsProblem {
                    ProfileDesktopNotice(text: statsProblem, icon: "wifi.exclamationmark")
                        .accessibilityIdentifier("profile.statistics.problem")
                }
                if let following = currentStatistics?.following {
                    Text("Following \(following) creator\(following == 1 ? "" : "s").")
                        .font(.caption).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                }
                if statsLoading {
                    HStack(spacing: 8) { ProgressView().tint(ProfileDesktopPalette.ink); Text("Loading totals…").font(.callout) }
                        .accessibilityElement(children: .combine)
                } else if !authVM.isAuthenticated {
                    Text("Sign in to load account totals.").font(.callout).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                }
                Button {
                    guard !statsLoading else { return }
                    statsLoading = true
                    Task { await loadStatistics() }
                } label: {
                    Label(statsProblem == nil && localProjectProblem == nil ? "Refresh totals" : "Retry totals", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ProfileDesktopButtonStyle())
                .disabled(statsLoading)
                .accessibilityIdentifier("profile.statistics.retry")
            }
        }
    }
    private var accountWindows: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProfileDesktopWindow(title: "Creator tools", icon: "square.grid.2x2") {
                VStack(spacing: 0) {
                    row("Publishing", subtitle: "Review, permissions & destination jobs", icon: "square.and.arrow.up", destination: .publishing)
                    row("Records & badges", subtitle: "Choose what to display publicly", icon: "trophy", destination: .records)
                    row("Analytics", subtitle: "Published work, audience & device projects", icon: "chart.bar", destination: .analytics)
                }
            }
            ProfileDesktopWindow(title: "Account", icon: "gearshape") {
                VStack(spacing: 0) {
                    row("Settings", subtitle: "Identity, security, privacy & your data", icon: "gearshape", destination: .account)
                    if authVM.isAuthenticated {
                        row("Admin access", subtitle: "Server-authorized roles only", icon: "lock.shield", destination: .admin)
                    }
                    row("Subscription", subtitle: "Plans, restore & manage", icon: "creditcard", destination: .subscription)
                }
            }
            ProfileDesktopWindow(title: "Subscription", icon: "creditcard") {
                Button { destination = .subscription } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(BillingCopy.status(stripe.billing, catalog: stripe.catalog, locale: locale, timeZone: .current).title)
                            .font(.specialElite(18, relativeTo: .headline))
                        Text("Plans, prices and renewal come from the App Store. Open to see plans, restore purchases or manage your subscription.")
                            .font(.callout)
                        Label("Open subscription", systemImage: "arrow.up.right")
                            .font(.specialElite(13, relativeTo: .callout))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(12)
                    .background(ProfileDesktopPalette.grey.opacity(0.35))
                    .overlay(Rectangle().stroke(ProfileDesktopPalette.ink, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.subscription-status")
            }
        }
    }

    private func statistic(_ value: String, _ label: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.specialElite(27, relativeTo: .title2)).monospacedDigit()
            Text(label).font(.specialElite(13, relativeTo: .callout))
            Text(source).font(.caption2).foregroundStyle(ProfileDesktopPalette.grey)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(12)
        .foregroundStyle(ProfileDesktopPalette.paper)
        .background(ProfileDesktopPalette.ink)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value == "—" ? "unavailable" : value). \(source).")
    }
    private func row(_ title: String, subtitle: String, icon: String, destination page: Destination) -> some View {
        Button { destination = page } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).frame(width: 22).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.specialElite(15, relativeTo: .body))
                    Text(subtitle).font(.caption).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(ProfileDesktopPalette.grey).frame(height: 1) }
        }
        .buttonStyle(.plain)
    }
    private var analyticsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProfileDesktopWindow(title: "About this snapshot", icon: "chart.bar") {
                    Text("Your latest loaded totals")
                        .font(.specialElite(20, relativeTo: .title2))
                        .accessibilityAddTraits(.isHeader)
                    Text("Account totals come from the service. Projects counts saved animations on this device, independently of your account.")
                        .font(.callout).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                    if !authVM.isAuthenticated {
                        Text("Account analytics require sign-in. Close Analytics and choose Sign in on your profile to load them. Device project totals remain available to guests.")
                            .font(.callout).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                    }
                }
                // Reuse the same snapshot and explicit refresh/retry action; opening
                // Analytics does not start another request or maintain a second cache.
                statisticsWindow
                ProfileDesktopWindow(title: "How to read these totals", icon: "info.circle") {
                    Text("Published counts eligible videos currently visible on the wall; Likes counts the likes on those videos. These totals can change when work is removed, expires or changes visibility; they are not lifetime activity totals.")
                        .font(.callout).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                    Text("Followers and Following are current service counts. Views, watch time, historical trends and engagement rates are not supplied by this service and are not estimated here.")
                        .font(.callout).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                }
            }
            .frame(maxWidth: 780)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(ProfileDesktopWallpaper().ignoresSafeArea())
    }
    @MainActor private func loadStatistics() async {
        let id = UUID(); statsRequestID = id
        localProjectCount = nil; localProjectProblem = nil
        stats = nil; statsProblem = nil; statsLoading = true
        defer { if statsRequestID == id { statsLoading = false } }
        // Device-level inventory, never presented as a server/account portfolio.
        do {
            let listing = try DeviceStorageManager.shared.listAnimationsReportingFailures()
            if listing.failures.isEmpty { localProjectCount = listing.animations.count }
            else { localProjectProblem = "Some device projects could not be read. Open Projects to review your library." }
        } catch { localProjectProblem = "Device project count unavailable. Open Projects to review your library." }
        guard authVM.isAuthenticated, phase == .active, let account = authVM.userId else { return }
        do {
            let loaded = try await CommunityServices.profile.stats()
            guard !Task.isCancelled, statsRequestID == id, account == authVM.userId else { return }
            stats = loaded
        } catch {
            guard !Task.isCancelled, statsRequestID == id, account == authVM.userId else { return }
            statsProblem = "Totals unavailable: " + (CommunityGateway.normalize(error).errorDescription ?? "service unavailable.")
        }
    }
}

/// Scoped to Profile: website OS palette, static dither, striped paper windows.
private enum ProfileDesktopPalette {
    static let paper = Color(hex: "EFEAE0")
    static let ink = Color(hex: "101011")
    static let grey = Color(hex: "BDB9B3")
    static let red = Color(hex: "FF454C")
    static let secondaryInk = Color(hex: "454341")
}
private struct ProfileDesktopWallpaper: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ProfileDesktopPalette.ink))
            var dots = Path()
            for y in stride(from: 0, to: size.height, by: 8) {
                for x in stride(from: 0, to: size.width, by: 8) {
                    let shift: CGFloat = Int(y / 8).isMultiple(of: 2) ? 0 : 4
                    dots.addRect(CGRect(x: x + shift, y: y, width: 1, height: 1))
                    dots.addRect(CGRect(x: x + shift + 2, y: y + 3, width: 1, height: 1))
                }
            }
            context.fill(dots, with: .color(ProfileDesktopPalette.paper.opacity(0.19)))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
private struct ProfileDesktopWindow<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title.uppercased()).accessibilityAddTraits(.isHeader)
            }
            .font(.specialElite(13, relativeTo: .headline))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(ProfileDesktopPalette.paper)
            .frame(maxWidth: .infinity, minHeight: 36)
            .padding(.vertical, 4)
            .background {
                Canvas { context, size in
                    var stripes = Path()
                    for y in stride(from: 2, to: size.height, by: 4) {
                        stripes.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                    }
                    context.fill(stripes, with: .color(ProfileDesktopPalette.ink))
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(ProfileDesktopPalette.ink).frame(height: 2) }
            VStack(alignment: .leading, spacing: 12) { content }.padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(ProfileDesktopPalette.ink)
        .background {
            // Shadow the opaque window, never its text and controls.
            Rectangle().fill(ProfileDesktopPalette.paper)
                .shadow(color: ProfileDesktopPalette.ink, radius: 0, x: 4, y: 4)
        }
        .overlay(Rectangle().stroke(ProfileDesktopPalette.ink, lineWidth: 2))
    }
}
private struct ProfileDesktopButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.specialElite(14, relativeTo: .body))
            .foregroundStyle(ProfileDesktopPalette.ink)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background {
                Rectangle()
                    .fill(configuration.isPressed ? ProfileDesktopPalette.grey : (prominent ? ProfileDesktopPalette.red : ProfileDesktopPalette.paper))
                    .shadow(color: ProfileDesktopPalette.ink.opacity(isEnabled ? 1 : 0.3), radius: 0, x: 2, y: 2)
            }
            .overlay(Rectangle().stroke(ProfileDesktopPalette.ink, lineWidth: 2))
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}
private struct ProfileDesktopNotice: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProfileDesktopPalette.grey.opacity(0.35))
            .overlay(alignment: .leading) { Rectangle().fill(ProfileDesktopPalette.red).frame(width: 3) }
            .accessibilityElement(children: .combine)
    }
}
/// A native line drawing, echoing the site's sequential stick-figure poster.
private struct ProfileDesktopStickMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.36, y: rect.minY + rect.height * 0.04, width: rect.width * 0.28, height: rect.height * 0.2))
        path.move(to: point(0.5, 0.24)); path.addLine(to: point(0.5, 0.59))
        path.move(to: point(0.08, 0.38)); path.addLine(to: point(0.5, 0.32)); path.addLine(to: point(0.89, 0.5))
        path.move(to: point(0.16, 0.94)); path.addLine(to: point(0.5, 0.59)); path.addLine(to: point(0.86, 0.94))
        return path
    }
}

/// Replace the old disconnected toggles, invented disk usage and inert Sign Out.
struct ProfileSettingsView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @AppStorage("sdi.desktop.bottomNavigation") private var showsBottomDock = false
    @State private var showingProfileEditor = false
    @State private var showingMFA = false
    @State private var showingAppeals = false
    @State private var showingRemovalAppeals = false
    @State private var showingDeletionConfirmation = false
    private var accountEmail: String {
        guard authVM.isAuthenticated, let user = authVM.user,
              let id = UUID(uuidString: user.id), let current = authVM.userId,
              id == UUID(uuidString: current) else { return "No signed-in account" }
        return user.email ?? "Email unavailable"
    }
    var body: some View {
        List {
            Section("Account") {
                Text(accountEmail)
                if authVM.isAuthenticated {
                    Button("Authenticator security") { showingMFA = true }
                    Button("Account status and appeals") { showingAppeals = true }
                    Button("Removed video appeals") { showingRemovalAppeals = true }
                        .accessibilityIdentifier("profile.removal-appeals.open")
                }
                if authVM.captureProfileEdit() != nil {
                    Button("Edit username and bio") { showingProfileEditor = true }
                        .accessibilityIdentifier("profile.edit.open")
                } else {
                    Text("Sign in with an available profile to edit username and bio.").foregroundStyle(.secondary)
                }
            }
            Section("Appearance") {
                Toggle("Show bottom dock", isOn: $showsBottomDock)
                    .accessibilityIdentifier("profile.settings.bottom-dock")
                Text("Shows the optional dock on the desktop. It stays hidden while you edit in Studio. This device remembers your choice.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Studio") {
                Text("Change grid, onion skin and project settings in the Studio menu. Those controls apply to the actual project.")
            }
            if authVM.isAuthenticated {
                Section("Your data") {
                    AccountDataExportRow()
                }
            }
            Section("Help and privacy") {
                NavigationLink("Contact support") { SupportRequestsView() }
                    .accessibilityIdentifier("profile.support.open")
                NavigationLink("Notifications and announcements") { NotificationCenterView() }
                    .accessibilityIdentifier("profile.notifications.open")
                NavigationLink("Privacy and marketing permission") { PrivacyChoicesView() }
                    .accessibilityIdentifier("profile.privacy.open")
            }
            Section("Policies") {
                PolicyLinksList()
            }
            Section("Diagnostics") {
                DiagnosticsSettingsView()
            }
            if authVM.isAuthenticated {
                Section {
                    Button("Sign Out", role: .destructive) { Task { await authVM.signOut() } }
                        .disabled(authVM.isLoading)
                    Text("Signing out closes the open project and returns to the library. Nothing on this device is deleted.")
                        .font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.secondary)
                    if let error = authVM.error { Text(error).foregroundStyle(.red) }
                }
                Section("Account deletion") {
                    if let status = authVM.accountDeletion, status.isOpen {
                        Text(AuthViewModel.deletionSummary(status))
                            .font(.specialElite(11, relativeTo: .caption))
                            .accessibilityIdentifier("profile.delete-account.status")
                        if status.state == .pending {
                            Button("Cancel deletion") { Task { await authVM.cancelAccountDeletion() } }
                                .disabled(authVM.isLoading)
                                .accessibilityIdentifier("profile.delete-account.cancel")
                        }
                    } else {
                        Button("Delete account", role: .destructive) { showingDeletionConfirmation = true }
                            .disabled(authVM.isLoading)
                            .accessibilityIdentifier("profile.delete-account")
                        // The request is filed server-side (sdi_account_lifecycle) and completed by
                        // the service worker after a cooling-off period; the app deletes nothing itself.
                        Text("Deletion is requested from the server and completed after a seven-day cooling-off period, during which you can cancel here. It removes server records and signs the account out everywhere; projects on this device stay. Subscriptions must be cancelled through the App Store or billing portal.")
                            .font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.secondary)
                    }
                    if let notice = authVM.notice {
                        Text(notice).font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("profile.delete-account.notice")
                    }
                }
            }
        }
        .sheet(isPresented: $showingProfileEditor) { EditProfileView() }
        .sheet(isPresented: $showingMFA) { NavigationStack { AccountAuthenticatorView() } }
        .sheet(isPresented: $showingAppeals) { AccountAppealsView() }
        .sheet(isPresented: $showingRemovalAppeals) { RemovalAppealsView() }
        .onChange(of: authVM.userId) { _ in showingProfileEditor = false; showingRemovalAppeals = false }
        .task(id: authVM.userId) { await authVM.refreshAccountDeletion() }
        .alert("Delete this account?", isPresented: $showingDeletionConfirmation) {
            Button("Request deletion", role: .destructive) { Task { await authVM.requestAccountDeletion() } }
                .accessibilityIdentifier("profile.delete-account.confirm")
            Button("Keep account", role: .cancel) {}
        } message: {
            Text("Server records are deleted after a seven-day cooling-off period; you can cancel until then. Projects on this device are not affected.")
        }
    }
}

/// Creator publishing status over `sdi_publish_status` (upload-retention.sql, #245/#188):
/// each submitted render with its review state, the server copy's retention and
/// every destination job's stage. Retry and cancel/removal appear only when the
/// server says they are allowed; links appear only from a provider-confirmed result_url.
private struct PublishingJobsView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var reviews: [PublishStatusReview] = []
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var hasMore = false
    @State private var page = 0
    @State private var generation = UUID()
    @State private var pendingCancel: PublishStatusJob?
    private static let pageSize = 25
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Publishing activity").font(.specialElite(22))
                Text("Only an approved render with destination consent can enter this queue. Cancelling an upload may require removal from the destination after transfer.")
                    .font(.specialElite(15, relativeTo: .callout)).foregroundStyle(.secondary)
                if !CommunityServices.isConfigured {
                    Text(CommunityError.notConfigured.errorDescription ?? "").font(.specialElite(13, relativeTo: .footnote)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("profile.publishing.not-configured")
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("profile.publishing.error") }
                if let notice { Text(notice).font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary) }
                if busy { ProgressView() }
                Button("Refresh") { Task { await load(reset: true) } }.disabled(busy || !auth.isAuthenticated)
                NavigationLink("Upload an exported MP4 for review") { SDIRenderUploadView() }
                CreatorReviewsView()
                ForEach(reviews) { review in reviewCard(review) }
                if hasMore {
                    Button("Load older submissions") { Task { await load(reset: false) } }.disabled(busy)
                }
                if reviews.isEmpty && !busy && error == nil && auth.isAuthenticated { Text("No publishing activity.") }
                if !auth.isAuthenticated { Text("Sign in with a full account to see publishing activity.").foregroundStyle(.secondary) }
            }.padding()
        }
        .confirmationDialog(pendingCancel?.state == "published" ? "Request removal from this destination?" : "Cancel this publishing job?",
                            isPresented: Binding(get: { pendingCancel != nil }, set: { if !$0 { pendingCancel = nil } })) {
            if let job = pendingCancel {
                Button(job.state == "published" ? "Request removal" : "Cancel job", role: .destructive) {
                    pendingCancel = nil; Task { await act("cancel", job.id) }
                }
            }
            Button("Keep", role: .cancel) { pendingCancel = nil }
        } message: { Text("The publishing service records the request. A video already transferred is removed from the destination by the service; the stage shows when that is done.") }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            generation = UUID(); busy = false; reviews = []; hasMore = false; page = 0; error = nil; notice = nil; pendingCancel = nil
            if auth.isAuthenticated && phase == .active { await load(reset: true) }
        }
        .onDisappear { generation = UUID(); reviews = [] }
    }

    @ViewBuilder private func reviewCard(_ review: PublishStatusReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(review.title).font(.specialElite(18))
            Text("Review: \(PublishStatusText.reviewState(review.review_state)) · Version \(review.version)")
                .font(.specialElite(13, relativeTo: .footnote))
                .accessibilityIdentifier("profile.publishing.review-state")
            if review.owner_approval_required == true {
                Text("Spatter-generated: the owner must approve this exact render before any release.")
                    .font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
            }
            Text("Render \(review.render_digest.prefix(12))").font(.specialElite(12, relativeTo: .caption).monospaced())
            Text(PublishStatusText.serverCopy(review.server_copy, expires: review.server_copy_expires_at))
                .font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
                .accessibilityIdentifier("profile.publishing.server-copy")
            if review.jobs.isEmpty {
                Text("No destination jobs yet.").font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
            }
            ForEach(review.jobs) { job in jobRow(job) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func jobRow(_ job: PublishStatusJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(PublishStatusText.destination(job.destination)): \(PublishStatusText.stage(job.stage))")
                .font(.specialElite(15, relativeTo: .body))
                .accessibilityIdentifier("profile.publishing.stage")
            HStack(spacing: 6) {
                Text("Attempt \(job.attempts)")
                Text("·")
                Text(job.updated_at, style: .relative)
            }.font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
            if job.current_render == false {
                Text("This job is for an earlier version of the render.").font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
            }
            if let issue = job.last_error, !issue.isEmpty {
                Text(issue).font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.red)
            }
            // Only the provider-confirmed link the server returns for a published job.
            if let url = PublishStatusText.resultLink(job.result_url) {
                Link("Open published video", destination: url)
            }
            if job.can_retry {
                Button("Retry") { Task { await act("retry", job.id) } }.disabled(busy)
                    .accessibilityIdentifier("profile.publishing.retry")
            }
            if job.can_cancel {
                Button(job.state == "published" ? "Request removal" : "Cancel", role: .destructive) { pendingCancel = job }
                    .disabled(busy)
                    .accessibilityIdentifier("profile.publishing.cancel")
            }
        }
        .padding(.top, 4)
    }

    @MainActor private func load(reset: Bool) async {
        guard !busy, auth.isAuthenticated else { return }
        let epoch = generation; busy = true
        defer { if epoch == generation { busy = false } }
        let target = reset ? 0 : page + 1
        do {
            let response = try await CommunityServices.gateway.call("sdi_publish_status", params: PublishStatusRequest(page: target), as: PublishStatusResponse.self)
            guard !Task.isCancelled, epoch == generation else { return }
            guard let rows = response.reviews else { error = "Incomplete publishing response."; return }
            reviews = reset ? rows : reviews + rows.filter { row in !reviews.contains { $0.id == row.id } }
            page = target; hasMore = rows.count == Self.pageSize; error = nil
        } catch {
            guard epoch == generation else { return }
            if reset { reviews = [] }
            self.error = CommunityGateway.normalize(error).errorDescription ?? "Publishing service unavailable."
        }
    }
    @MainActor private func act(_ action: String, _ job: UUID) async {
        guard !busy else { return }
        let epoch = generation; busy = true
        do {
            let response = try await CommunityServices.gateway.call("sdi_publish_action", params: PublishingRequest(action: action, job: job), as: PublishingResponse.self)
            guard !Task.isCancelled, epoch == generation else { busy = false; return }
            guard ["queued", "cancellation_recorded"].contains(response.status ?? "") else { error = "Request was not confirmed."; busy = false; return }
            notice = response.status == "queued" ? "Retry queued." : "Cancellation recorded. The stage shows when the service has finished."
            busy = false; await load(reset: true)
        } catch {
            busy = false
            if epoch == generation { self.error = CommunityGateway.normalize(error).errorDescription ?? "Request was not confirmed. Refresh before retrying." }
        }
    }
}
@MainActor
private struct CreatorReviewsView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var reviews: [CreatorReview] = []
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var message: String?
    @State private var pending: CreatorReview?
    @State private var pendingFeed: CreatorReview?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Submitted renders").font(.specialElite(20))
            Text("Only submitted and approved renders appear here. Your local drafts are not uploaded automatically.").font(.specialElite(12, relativeTo: .caption))
            Button("Refresh submissions") { Task { await request("list") } }.disabled(busy)
            if busy { ProgressView() }
            if let message { Text(message).font(.specialElite(12, relativeTo: .caption)) }
            ForEach(reviews) { review in
                VStack(alignment: .leading, spacing: 8) {
                    Text(review.title).font(.specialElite(17))
                    Text("\(review.state.capitalized) · Version \(review.version)").font(.specialElite(12, relativeTo: .caption))
                    Text("Render: \(review.render_digest.prefix(16))").font(.specialElite(12, relativeTo: .caption).monospaced())
                    Text("Permissions: \(review.destinations.isEmpty ? "None" : review.destinations.joined(separator: ", "))").font(.specialElite(12, relativeTo: .caption))
                    if review.can_publish {
                        Button("Publish approved video to SDI YouTube") { pending = review }.disabled(busy)
                    }
                    if review.can_publish_feed == true {
                        Button("Publish approved video to the SDI feed") { pendingFeed = review }.disabled(busy)
                            .accessibilityIdentifier("profile.reviews.publish-feed")
                    }
                    if let allowExport = review.allow_export {
                        Toggle("Allow viewers to save this video file", isOn: Binding(get: { allowExport }, set: { value in
                            Task { await setExport(review, value) }
                        })).disabled(busy)
                            .accessibilityIdentifier("profile.reviews.allow-export")
                        Text("Sharing links is always allowed for approved videos; this permits file export only. It is not part of approval evidence.")
                            .font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.secondary)
                    }
                    if !review.consent_version.isEmpty {
                        Button("Withdraw publication permissions", role: .destructive) {
                            Task { await request("withdraw_consent", review) }
                        }.disabled(busy)
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .confirmationDialog("Publish this approved render to the official SDI channel?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let review = pending {
                Button("Queue approved video") { pending = nil; Task { await request("publish_youtube", review) } }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text("This queues the exact reviewed video and its existing permissions. It does not publish any other draft.") }
        .confirmationDialog("Publish this approved render to the StickDeath Infinity feed?", isPresented: Binding(get: { pendingFeed != nil }, set: { if !$0 { pendingFeed = nil } })) {
            if let review = pendingFeed {
                Button("Queue for the feed") { pendingFeed = nil; Task { await request("publish_feed", review) } }
            }
            Button("Cancel", role: .cancel) { pendingFeed = nil }
        } message: { Text("The publishing service re-checks the owner's approval of this exact render, your consent and rights before any copy appears in the feed.") }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await request("list") }
        }
        .onDisappear { clear() }
    }
    private func clear() { requestID = UUID(); busy = false; reviews = []; message = nil; pending = nil; pendingFeed = nil }
    private func setExport(_ review: CreatorReview, _ allowed: Bool) async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let confirmed = try await CommunityServices.profile.setExportPermission(review: review.id, version: review.version, allowed: allowed)
            guard !Task.isCancelled, requestID == id else { return }
            message = confirmed ? (allowed ? "File export permitted for this render." : "File export withdrawn for this render.") : "Export permission was not confirmed."
            busy = false; await request("list")
        } catch { if requestID == id { message = CommunityGateway.normalize(error).errorDescription } }
    }
    private func request(_ action: String, _ review: CreatorReview? = nil) async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let client = try SupabaseManager.shared.client
            let result: CreatorReviewResponse = try await client.rpc("sdi_creator_review", params: CreatorReviewRequest(action: action, review: review?.id, version: review?.version)).execute().value
            guard !Task.isCancelled, requestID == id else { return }
            if let problem = result.error { message = problem; if action == "list" { reviews = [] }; return }
            if action == "list", let items = result.reviews { reviews = items; message = items.isEmpty ? "No submitted renders." : nil }
            else if result.status == "queued" || result.status == "consent_withdrawn" {
                reviews = []; message = result.status == "queued" ? "Queued. Refresh Publishing activity for status; nothing is public until the publishing service confirms." : "Permissions withdrawn. Existing releases may remain visible until provider withdrawal is confirmed."
            } else { message = "Response incomplete. Refresh before retrying." }
        } catch { if requestID == id { message = "Submission service unavailable. Refresh before retrying."; if action == "list" { reviews = [] } } }
    }
}
private struct CreatorReviewRequest: Encodable { let action: String; var review: UUID?; var version: Int? }
private struct CreatorReviewResponse: Decodable { let error: String?; let status: String?; let reviews: [CreatorReview]? }
private struct CreatorReview: Decodable, Identifiable {
    let id: UUID; let title: String; let render_digest: String; let version: Int; let state: String
    let consent_version: String; let destinations: [String]; let can_publish: Bool
    /// Present once feed-publication.sql is applied; absent on older services.
    var allow_export: Bool? = nil
    var can_publish_feed: Bool? = nil
}

@MainActor
private struct ProfileRecordsView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var data: ProfileRecordsResponse?
    @State private var showRecords = false
    @State private var showBadges = false
    @State private var groups: [AchievementGroup] = []
    @State private var achievementsProblem: String?
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Records & badges").communityHeading()
                Text("Both public displays start off. Hiding your profile totals does not hide videos, match participation or individual match results.")
                    .font(.specialElite(15, relativeTo: .callout)).foregroundStyle(StudioCraftTheme.textDim)
                if !CommunityServices.isConfigured { CommunityMessage(text: CommunityServices.notConfiguredText, kind: .info) }
                if busy { ProgressView().tint(StudioCraftTheme.accent) }
                if let message { CommunityMessage(text: message, kind: message.hasSuffix("saved.") ? .success : .error).accessibilityIdentifier("profile.records.message") }
                Button("Refresh") { Task { await load(save: false) } }
                    .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                    .accessibilityIdentifier("profile.records.refresh")
                if let data {
                    CommunityCard {
                        Text("Your private record").communitySubheading()
                        Text("\(data.wins ?? 0) wins · \(data.losses ?? 0) losses · \(data.ties ?? 0) ties").font(.specialElite(16, relativeTo: .body)).monospacedDigit()
                        Toggle("Show my win/loss record publicly", isOn: $showRecords).font(.specialElite(14, relativeTo: .body))
                            .accessibilityIdentifier("profile.records.show-records")
                        Toggle("Show my earned badges publicly", isOn: $showBadges).font(.specialElite(14, relativeTo: .body))
                            .accessibilityIdentifier("profile.records.show-badges")
                        Button("Save display preferences") { Task { await load(save: true) } }
                            .buttonStyle(CommunityPrimaryButtonStyle())
                            .disabled(busy || (showRecords == data.show_records && showBadges == data.show_badges))
                            .accessibilityIdentifier("profile.records.save")
                        Text("Preferences are enforced by the server in profiles, the leaderboard and API replies, not only in this screen.").communityCaption()
                    }
                }
                Text("Achievements").communitySubheading()
                Text("Badges are awarded by the server from finalised War Room and challenge results against versioned criteria. Nothing here is estimated.").communityCaption()
                if let achievementsProblem { CommunityMessage(text: achievementsProblem, kind: .info) }
                ForEach(groups) { group in
                    CommunityCard {
                        Text(group.category).communitySubheading()
                        if group.earned.isEmpty && group.locked.isEmpty { Text("No criteria configured.").communityCaption() }
                        ForEach(group.earned) { item in achievementRow(item) }
                        ForEach(group.locked) { item in achievementRow(item) }
                    }.accessibilityIdentifier("profile.achievements.group")
                }
                if groups.isEmpty && achievementsProblem == nil && !busy { Text("No achievement criteria were returned.").communityCaption() }
            }.padding()
        }
        .communityScreen()
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await load(save: false) }
        }
        .onDisappear { clear() }
    }
    private func achievementRow(_ item: AchievementItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.isEarned ? "seal.fill" : "lock")
                .foregroundStyle(item.isEarned ? StudioCraftTheme.accentText : StudioCraftTheme.textFaint)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.specialElite(15, relativeTo: .body))
                Text(item.description).communityCaption()
                Text(item.isEarned ? "Earned \(item.earned_at?.formatted(date: .abbreviated, time: .omitted) ?? "") · criteria \(item.criterion_version)" : "Locked · requires \(item.threshold) · criteria \(item.criterion_version)")
                    .communityCaption()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isEarned ? "Earned" : "Locked")
    }
    private func clear() { requestID = UUID(); busy = false; data = nil; message = nil; showRecords = false; showBadges = false; groups = []; achievementsProblem = nil }
    private func load(save: Bool) async {
        guard !busy, auth.isAuthenticated, phase == .active, !save || data?.revision != nil else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let result: ProfileRecordsResponse
            if save, let revision = data?.revision {
                result = try await CommunityServices.profile.saveRecords(revision: revision, showRecords: showRecords, showBadges: showBadges)
            } else {
                result = try await CommunityServices.profile.readRecords()
            }
            guard !Task.isCancelled, requestID == id else { return }
            data = result; showRecords = result.show_records ?? false; showBadges = result.show_badges ?? false
            message = save ? "Display preferences saved." : nil
        } catch { if requestID == id { data = nil; message = CommunityGateway.normalize(error).errorDescription } }
        guard requestID == id, !save else { return }
        do {
            let catalogue = try await CommunityServices.profile.achievements()
            guard !Task.isCancelled, requestID == id else { return }
            groups = catalogue; achievementsProblem = nil
        } catch { if requestID == id { groups = []; achievementsProblem = CommunityGateway.normalize(error).errorDescription } }
    }
}

/// Approved renditions owned by the account, played from their HTTPS address.
@MainActor
private struct ProfilePortfolioSection: View {
    let onCount: (Int?) -> Void
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var items: [ApprovedMedia] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var problem: String?
    @State private var playback: ProfilePlayback?
    @State private var requestID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loaded && problem == nil ? "\(items.count) approved rendition\(items.count == 1 ? "" : "s")" : "Approved renditions")
                .font(.specialElite(18, relativeTo: .headline))
                .accessibilityAddTraits(.isHeader)
            if busy {
                HStack(spacing: 8) { ProgressView().tint(ProfileDesktopPalette.ink); Text("Loading portfolio…").font(.callout) }
                    .accessibilityElement(children: .combine)
            }
            if let problem { ProfileDesktopNotice(text: problem, icon: "wifi.exclamationmark") }
            if loaded && items.isEmpty && problem == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "film.stack").font(.title2).accessibilityHidden(true)
                    Text("No approved renditions yet.").font(.specialElite(17, relativeTo: .headline))
                    Text("Submit an exported MP4 for review from Publishing. Opening a device project never uploads it automatically.")
                        .font(.callout).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().stroke(ProfileDesktopPalette.grey, lineWidth: 1))
                .accessibilityIdentifier("profile.portfolio.empty")
            }
            ForEach(items) { item in portfolioItem(item) }
            Button { Task { await load() } } label: {
                Label(problem == nil ? "Refresh portfolio" : "Retry portfolio", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ProfileDesktopButtonStyle())
            .disabled(busy || !auth.isAuthenticated)
            .accessibilityIdentifier("profile.portfolio.retry")
        }
        .accessibilityIdentifier("profile.portfolio")
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            requestID = UUID(); busy = false; items = []; loaded = false; problem = nil; playback = nil; onCount(nil)
            if auth.isAuthenticated && phase == .active { await load() }
        }
        .sheet(item: $playback) { item in CommunityVideoPlayer(url: item.url, title: item.title) }
        .onDisappear { requestID = UUID(); busy = false; playback = nil }
    }
    private func portfolioItem(_ item: ApprovedMedia) -> some View {
        let url = CommunityMediaURL.checked(item.url)
        return Button {
            guard let url else { return }
            playback = ProfilePlayback(url: url, title: item.title)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: url == nil ? "film" : "play.fill")
                    .font(.body)
                    .frame(width: 36, height: 44)
                    .foregroundStyle(ProfileDesktopPalette.paper)
                    .background(ProfileDesktopPalette.ink)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.specialElite(17, relativeTo: .headline))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(durationText(item.duration)).font(.caption).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                    if let expiry = item.expires_at {
                        Text("Available until \(expiry.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                    }
                    if url == nil {
                        Text("Playback link unavailable. Refresh to try again.").font(.caption).foregroundStyle(ProfileDesktopPalette.secondaryInk)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .padding(12)
            .background(ProfileDesktopPalette.grey.opacity(0.25))
            .overlay(Rectangle().stroke(ProfileDesktopPalette.ink, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .accessibilityLabel(url == nil ? "\(item.title), playback unavailable" : "Play \(item.title)")
        .accessibilityIdentifier("profile.portfolio.play")
    }
    private func durationText(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "Duration unavailable" }
        let seconds = duration.rounded()
        guard seconds < Double(Int.max) else { return "Duration unavailable" }
        return "\(Int(seconds)) s"
    }
    private func load() async {
        guard !busy, auth.isAuthenticated, phase == .active, let account = auth.userId.flatMap(UUID.init(uuidString:)) else { return }
        let id = UUID(); requestID = id; busy = true; problem = nil; loaded = false; items = []; onCount(nil)
        defer { if requestID == id { busy = false } }
        do {
            let rows = try await CommunityServices.profile.portfolio(account: account)
            guard !Task.isCancelled, requestID == id, auth.userId.flatMap(UUID.init(uuidString:)) == account else { return }
            items = rows; loaded = true; onCount(rows.count)
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            loaded = true
            problem = CommunityGateway.normalize(error).errorDescription ?? "Portfolio unavailable. Check your connection and retry."
        }
    }
}
private struct ProfilePlayback: Identifiable { let id = UUID(); let url: URL; let title: String }

/// Member side of feed removal appeals: own appeals and a bounded submission.
/// Structured review only; this is not a message to anyone.
@MainActor
private struct RemovalAppealsView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var appeals: [ModerationAppeal] = []
    @State private var mediaID = ""
    @State private var explanation = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var requestID = UUID()
    var body: some View {
        NavigationStack {
            List {
                Section("Appeal a removed video") {
                    Text("Enter the video identifier from your removal notice and explain why the removal should be reviewed. An uninvolved administrator decides within the 30-day window; the decision appears here.")
                    TextField("Video identifier", text: $mediaID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("profile.removal-appeals.media")
                    TextField("Explanation (up to 2000 characters)", text: $explanation, axis: .vertical).lineLimit(3...8)
                        .accessibilityIdentifier("profile.removal-appeals.explanation")
                    Button("Submit appeal") { Task { await submit() } }
                        .disabled(busy || UUID(uuidString: mediaID) == nil || explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || explanation.count > 2000)
                        .accessibilityIdentifier("profile.removal-appeals.submit")
                    if let problem { Text(problem).foregroundStyle(StudioCraftTheme.accentText) }
                }
                Section("Your appeals") {
                    if busy { ProgressView() }
                    if appeals.isEmpty && !busy && problem == nil { Text("No removal appeals.") }
                    ForEach(appeals) { appeal in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appeal.title).font(.headline)
                            Text("\(appeal.state?.capitalized ?? "Pending") · \(appeal.created_at.formatted())").font(.caption)
                            Text(appeal.explanation)
                            if let reply = appeal.reply { Text("Decision: \(reply)") }
                        }
                    }
                }
            }
            .navigationTitle("Removed video appeals")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh") { Task { await load() } }.disabled(busy) }
            }
            .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") { await load() }
            .onDisappear { requestID = UUID(); appeals = [] }
        }.preferredColorScheme(.dark)
    }
    private func load() async {
        requestID = UUID(); appeals = []; problem = nil; busy = false
        guard auth.isAuthenticated, phase == .active else { return }
        let id = requestID; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let items = try await CommunityServices.admin.myAppeals()
            guard !Task.isCancelled, requestID == id else { return }
            appeals = items
        } catch { if requestID == id { problem = CommunityGateway.normalize(error).errorDescription } }
    }
    private func submit() async {
        guard !busy, let media = UUID(uuidString: mediaID) else { return }
        let id = requestID; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let items = try await CommunityServices.admin.submitAppeal(media: media, explanation: explanation)
            guard requestID == id else { return }
            appeals = items; explanation = ""; mediaID = ""; problem = nil
        } catch { if requestID == id { problem = CommunityGateway.normalize(error).errorDescription } }
    }
}

@MainActor
struct AccountAuthenticatorView: View {
    /// Called after the server confirms a code, so privileged screens can
    /// record the recent re-authentication window (#210).
    var onVerified: (() -> Void)? = nil
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var factors: [Factor] = []
    @State private var enrollment: AuthMFAEnrollResponse?
    @State private var selected = ""
    @State private var code = ""
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Text("Use an authenticator app for six-digit security codes. Administrator actions also require a server-granted role; verification alone grants no admin permission.")
                Button("Refresh factors") { Task { await perform("list") } }.disabled(busy)
                if busy { ProgressView() }
                if let message { Text(message) }
            }
            if let totp = enrollment?.totp {
                Section("Set up your authenticator") {
                    Text("Enter this setup key in your authenticator app, then enter its current code below. Keep the key private.")
                    Text(totp.secret).font(.specialElite(16, relativeTo: .body).monospaced()).textSelection(.enabled).privacySensitive()
                    Text("The setup key is cleared when you leave this screen or background the app. An unfinished factor can be removed below and set up again.").font(.specialElite(12, relativeTo: .caption))
                }
            }
            Section("Verify this session") {
                Picker("Authenticator", selection: $selected) {
                    Text("Select authenticator").tag("")
                    ForEach(factors.filter { $0.status == .verified }) { factor in
                        Text(factor.friendlyName ?? "Authenticator").tag(factor.id)
                    }
                    if let enrollment { Text("New authenticator").tag(enrollment.id) }
                }.disabled(busy)
                SecureField("Six-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).privacySensitive()
                Button("Verify") { Task { await perform("verify") } }
                    .disabled(busy || selected.isEmpty || code.count != 6 || !code.utf8.allSatisfy { (48...57).contains($0) })
            }
            Section("Set up") {
                Button("Add authenticator") { Task { await perform("enroll") } }.disabled(busy || enrollment != nil)
                ForEach(factors.filter { $0.status == .unverified && $0.id != enrollment?.id }) { factor in
                    Button("Remove unfinished setup", role: .destructive) { Task { await perform("remove", factor: factor.id) } }.disabled(busy)
                }
                Text("Verified factors cannot be removed here. Account recovery requires the protected recovery process.").font(.specialElite(12, relativeTo: .caption))
            }
        }.navigationTitle("Authenticator security")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await perform("list") }
        }
        .onDisappear { clear() }
    }
    private func clear() { requestID = UUID(); enrollment = nil; factors = []; code = ""; selected = ""; busy = false; message = nil }
    private func perform(_ action: String, factor: String? = nil) async {
        guard !busy, auth.isAuthenticated, phase == .active, let account = auth.userId else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false; code = "" } }
        do {
            let operation: AuthService.AuthenticatorAction
            switch action {
            case "enroll": operation = .enroll
            case "verify": operation = .verify(factorID: selected, code: code)
            case "remove":
                guard let factor else { return }
                operation = .removeUnfinished(factorID: factor)
            default: operation = .list
            }
            let response = try await auth.authenticatorOperation(accountID: account, action: operation)
            guard !Task.isCancelled, requestID == id, account == auth.userId else { return }
            factors = response.factors
            if action == "enroll" {
                guard let value = response.enrollment else { return }
                enrollment = value; selected = value.id; message = "Verify a code to finish enrollment."
            } else if action == "verify" {
                enrollment = nil; message = "Authenticator verified. Return to the admin screen and refresh its data."
                onVerified?()
            } else if action == "remove" {
                message = "Unfinished setup removed."
            }
        } catch { if requestID == id { message = "Security operation not confirmed. Check your code, session and connection, then refresh before retrying." } }
    }
}

private struct PublishingRequest: Encodable, Sendable { let action: String; var job: UUID? = nil }
private struct PublishingResponse: CommunityResponse { let error: String?; let status: String? }
private struct PublishStatusRequest: Encodable, Sendable { let page: Int }
private struct PublishStatusResponse: CommunityResponse { let error: String?; let reviews: [PublishStatusReview]? }
/// One submitted render as `sdi_publish_status` reports it.
private struct PublishStatusReview: Decodable, Identifiable {
    let review_id: UUID; let title: String; let render_digest: String; let version: Int
    let review_state: String; let owner_approval_required: Bool?; let destinations: [String]?
    let server_copy: String; let server_copy_expires_at: Date?; let jobs: [PublishStatusJob]
    var id: UUID { review_id }
}
private struct PublishStatusJob: Decodable, Identifiable {
    let id: UUID; let destination: String; let state: String; let phase: String?; let stage: String
    let attempts: Int; let current_render: Bool?; let can_retry: Bool; let can_cancel: Bool
    let result_url: String?; let last_error: String?; let updated_at: Date
}
/// Creator-facing words for the server's stage, review and retention values.
private enum PublishStatusText {
    static func stage(_ stage: String) -> String {
        switch stage {
        case "queued": return "Queued"
        case "transferring": return "Transferring to the destination"
        case "provider_processing": return "Destination is processing"
        case "releasing": return "Releasing"
        case "published": return "Published"
        case "failed": return "Failed"
        case "needs_reconciliation": return "Checking with the destination"
        case "cancelling": return "Cancelling"
        case "removal_in_progress": return "Removal in progress"
        case "removed": return "Removed from the destination"
        case "cancelled": return "Cancelled"
        default: return stage.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    static func reviewState(_ state: String) -> String {
        switch state {
        case "awaiting_review": return "Awaiting moderation"
        case "changes_requested": return "Changes requested"
        case "approved": return "Approved"
        case "rejected": return "Rejected"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    static func destination(_ destination: String) -> String {
        switch destination {
        case "youtube": return "SDI YouTube"
        case "feed": return "SDI feed"
        default: return destination.capitalized
        }
    }
    static func serverCopy(_ copy: String, expires: Date?) -> String {
        switch copy {
        case "retained":
            if let expires { return "Server copy kept until \(expires.formatted(date: .abbreviated, time: .shortened)). Your original stays on this device." }
            return "Server copy kept for publication. Your original stays on this device."
        case "expired": return "Server copy expired and is deleted. Your original stays on this device."
        case "deleted": return "Server copy deleted after verified publication. Your original stays on this device."
        default: return "Server copy: \(copy)."
        }
    }
    /// HTTPS only, no embedded credentials.
    static func resultLink(_ raw: String?) -> URL? {
        guard let raw, let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
}


/// Keeps the export's real consumer lease until a staging read has finished,
/// including cancellation or dismissal while its file copy is in flight.
@MainActor
final class SDIRenderUploadExport: Identifiable {
    let id = UUID()
    let account: String
    let title: String
    let revision: String
    /// Library assets the export manifest credits (images by original digest,
    /// sounds by catalogue digest), declared to intake so licensing is checked
    /// server-side. Empty means the render credits no library asset.
    let assetCredits: [SDIRenderAssetCredit]
    private let request: StudioMovieExportSession.ShareRequest
    private var copying = false
    private var closed = false
    init(request: StudioMovieExportSession.ShareRequest, account: String, title: String, revision: String,
         manifest: StudioMovieExportService.Manifest? = nil) {
        self.request = request; self.account = account; self.title = title; self.revision = revision
        var credits: [SDIRenderAssetCredit] = []
        for image in manifest?.imageCredits ?? [] { credits.append(.init(kind: "image", sha256: image.originalSHA256)) }
        for sound in manifest?.soundCredits ?? [] { credits.append(.init(kind: "sound", sha256: sound.originalSHA256)) }
        var seen = Set<String>()
        assetCredits = credits.filter { seen.insert($0.kind + ":" + $0.sha256).inserted }
    }
    func beginCopy() throws -> URL {
        guard !closed, !copying,
              let url = try request.checkedURLs().first(where: { $0.pathExtension.lowercased() == "mp4" }) else {
            throw SDIIntakeClient.Failure.unavailable
        }
        copying = true
        return url
    }
    func endCopy() {
        copying = false
        if closed { request.finish(completed: false, error: nil) }
    }
    func close() {
        closed = true
        if !copying { request.finish(completed: false, error: nil) }
    }
}

@MainActor
struct SDIRenderUploadView: View {
    var exportedMovie: SDIRenderUploadExport? = nil
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var title = ""
    @State private var sourceRevision = "Imported MP4; project revision not provided"
    @State private var rights = ""
    @State private var feed = false
    @State private var youtube = false
    @State private var social = false
    @State private var accepted = false
    @State private var audience = ""
    @State private var picking = false
    @State private var jobs: [SDIRenderUploadJournal] = []
    @State private var removal: SDIRenderUploadJournal?
    @State private var work: Task<Void, Never>?
    @State private var busy = false
    @State private var progress: Double?
    @State private var message: String?
    @State private var epoch = UUID()
    private var destinations: [String] { [(feed, "feed"), (youtube, "youtube"), (social, "social")].filter { $0.0 }.map { $0.1 } }
    private var configured: Bool { AppConfig.uploadServiceURL != nil && AppConfig.publishingConsent != nil }
    private var canStage: Bool {
        configured && auth.isAuthenticated && (exportedMovie == nil || exportedMovie?.account == auth.userId) && !busy && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 100 &&
        !sourceRevision.isEmpty && sourceRevision.count <= 200 && !rights.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        rights.count <= 2000 && !destinations.isEmpty && accepted && !audience.isEmpty
    }
    var body: some View {
        Form {
            Section("Submit a rendered video") {
                Text(exportedMovie == nil
                    ? "Export your animation as MP4 and save it to Files, then choose that file here. Uploading submits a private copy for review; it does not publish the video."
                    : "Use the finished Studio MP4 below. Keeping a copy does not upload it; sending it later submits private review, not publication.")
                if !configured { Text("Uploading is unavailable until the private service and current publishing terms are configured.").foregroundStyle(.secondary) }
                if !auth.isAuthenticated { Text("Sign in to submit or resume a video.") }
                TextField("Video title", text: $title)
                TextField("Project/export revision", text: $sourceRevision)
                    .disabled(exportedMovie != nil)
                TextField("Asset licenses and contributor permissions", text: $rights, axis: .vertical).lineLimit(3...6)
                Picker("Audience classification", selection: $audience) {
                    Text("Choose an audience").tag("")
                    Text("Made for kids").tag("kids")
                    Text("Not made for kids").tag("general")
                }
            }.disabled(busy)
            Section("Allowed destinations") {
                Toggle("StickDeath Infinity home feed", isOn: $feed)
                Toggle("Official SDI YouTube channel", isOn: $youtube)
                Toggle("SDI social marketing reuse", isOn: $social)
                Text("Only selected destinations may be reviewed. Channel and social versions may include SDI branding. Private drafts and unselected files are not submitted.").font(.specialElite(12, relativeTo: .caption))
                if let consent = AppConfig.publishingConsent {
                    Link("Read publishing terms", destination: consent.termsURL)
                    Text("Terms version: \(consent.version)").font(.specialElite(12, relativeTo: .caption))
                }
                Toggle("I have the necessary rights and contributor permissions and agree to the current terms for these destinations.", isOn: $accepted)
                if let exportedMovie {
                    Button("Keep this export as upload copy") { stageExport(exportedMovie) }.disabled(!canStage)
                } else {
                    Button("Choose MP4 and keep upload copy") { picking = true }.disabled(!canStage)
                }
            }.disabled(busy)
            if let message { Section { Text(message) } }
            if busy {
                Section {
                    if let progress { ProgressView(value: progress) } else { ProgressView("Preparing…") }
                    Button("Pause") { work?.cancel() }
                }
            }
            Section("Private upload copies") {
                Text("Copies remain on this device for resume until you remove them. Your original exported file and editable project are preserved.").font(.specialElite(12, relativeTo: .caption))
                Button("Refresh uploads") { Task { await reload() } }.disabled(busy)
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.metadata.title).font(.specialElite(17))
                        Text("\(job.offset) / \(job.metadata.size) bytes · \(job.state)").font(.specialElite(12, relativeTo: .caption))
                        if let review = job.reviewID {
                            Text("Submitted for review: \(review.uuidString)").font(.specialElite(12, relativeTo: .caption)).textSelection(.enabled)
                            Text("Manage approval and destination permissions in Publishing. This receipt is not publication confirmation.").font(.specialElite(12, relativeTo: .caption))
                        } else {
                            Button("Resume upload") { transfer(job) }.disabled(busy || !configured || !auth.isAuthenticated)
                        }
                        Button(job.reviewID == nil ? "Cancel upload and remove copy" : "Remove local upload copy", role: .destructive) { removal = job }.disabled(busy)
                    }.padding(.vertical, 6)
                }
                if jobs.isEmpty && !busy { Text("No staged uploads for this account.") }
            }
        }
        .navigationTitle("Submit for review").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.mpeg4Movie]) { result in
            switch result {
            case .success(let url): stage(url)
            case .failure: message = "No video was staged. You can choose the file again."
            }
        }
        .confirmationDialog("Remove this app-owned upload copy?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let job = removal {
                Button("Remove upload copy", role: .destructive) { removal = nil; discard(job) }
            }
            Button("Keep copy", role: .cancel) { removal = nil }
        } message: {
            Text("Receiving uploads are cancelled before removing their staged copy. Registered reviews keep their separate permission-withdrawal workflow. Your original file and Studio project are not deleted.")
        }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            reset()
            if phase == .active && auth.isAuthenticated { await reload() }
        }
        .onDisappear { reset(); exportedMovie?.close() }
    }
    private func reset() {
        epoch = UUID(); work?.cancel(); work = nil; busy = false; jobs = []; progress = nil; message = nil; removal = nil; picking = false
        sourceRevision = exportedMovie?.revision ?? "Imported MP4; project revision not provided"
        title = exportedMovie?.title ?? ""; rights = ""; accepted = false; feed = false; youtube = false; social = false; audience = ""
    }
    private func reload() async {
        guard auth.isAuthenticated, let account = auth.userId.flatMap(UUID.init(uuidString:)) else { return }
        let captured = epoch
        do {
            let loaded = try await SDIRenderUploads.shared.list(account: account)
            guard !Task.isCancelled, epoch == captured else { return }
            jobs = loaded
        } catch { if epoch == captured { message = "Private upload records could not be read. Existing files have been preserved." } }
    }
    private static func token(for account: UUID) async throws -> String {
        try Task.checkCancellation()
        return try await MainActor.run {
            let auth = AuthService.shared
            guard auth.isAuthenticated, auth.userId.flatMap(UUID.init(uuidString:)) == account,
                  let session = try SupabaseManager.shared.client.auth.currentSession,
                  !session.isExpired, session.user.id == account else { throw SDIIntakeClient.Failure.authorization }
            return session.accessToken
        }
    }
    private func stageExport(_ exportedMovie: SDIRenderUploadExport) {
        guard canStage else { return }
        do { stage(try exportedMovie.beginCopy(), assetCredits: exportedMovie.assetCredits, exportLease: exportedMovie) }
        catch { message = "This export is no longer available. Return to Studio and render it again." }
    }
    private func stage(_ url: URL, assetCredits: [SDIRenderAssetCredit] = [], exportLease: SDIRenderUploadExport? = nil) {
        guard canStage, let account = auth.userId.flatMap(UUID.init(uuidString:)), let consent = AppConfig.publishingConsent else {
            exportLease?.endCopy(); return
        }
        // A file picked from Files carries no manifest, so it declares nothing;
        // the rights summary and owner review remain the authority for it.
        let metadata = SDIRenderUploadMetadata(size: 0, sha256: "", title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            source_revision: sourceRevision, destinations: destinations, rights_summary: rights, consent_version: consent.version, made_for_kids: audience == "kids",
            asset_credits: assetCredits.isEmpty ? nil : assetCredits)
        let captured = epoch; busy = true; message = nil
        work = Task {
            defer { exportLease?.endCopy() }
            defer { if epoch == captured { busy = false; work = nil; progress = nil } }
            do {
                _ = try await SDIRenderUploads.shared.stage(source: url, account: account, metadata: metadata)
                guard !Task.isCancelled, epoch == captured else { return }
                message = "Private copy ready. Choose Resume upload when you are ready to send it for review."
            } catch is CancellationError { if epoch == captured { message = "Preparation paused. Your original export is unchanged." } }
            catch { if epoch == captured { message = error.localizedDescription } }
            if epoch == captured { busy = false; work = nil; await reload() }
        }
    }
    private func transfer(_ job: SDIRenderUploadJournal) {
        guard !busy, auth.userId.flatMap(UUID.init(uuidString:)) == job.account else { return }
        let captured = epoch; busy = true; progress = 0; message = nil
        work = Task {
            defer { if epoch == captured { busy = false; work = nil; progress = nil } }
            do {
                let result = try await SDIRenderUploads.shared.resume(job, token: { try await Self.token(for: job.account) }, progress: { completed, total in
                    await MainActor.run { if epoch == captured { progress = Double(completed) / Double(max(1, total)) } }
                })
                guard !Task.isCancelled, epoch == captured else { return }
                message = result.reviewID == nil ? "Upload remains unconfirmed. Resume to check its status." : "Submitted for private review. Nothing has been published."
            } catch is CancellationError { if epoch == captured { message = "Paused. Resume uses the server's confirmed offset." } }
            catch { if epoch == captured { message = error.localizedDescription } }
            if epoch == captured { busy = false; work = nil; progress = nil; await reload() }
        }
    }
    private func discard(_ job: SDIRenderUploadJournal) {
        guard !busy, auth.userId.flatMap(UUID.init(uuidString:)) == job.account else { return }
        let captured = epoch; busy = true; message = nil
        work = Task {
            defer { if epoch == captured { busy = false; work = nil; progress = nil } }
            do {
                try await SDIRenderUploads.shared.discard(job, token: { try await Self.token(for: job.account) })
                if epoch == captured { message = "App-owned upload copy removed. Your original export is preserved." }
            } catch { if epoch == captured { message = "Removal was not confirmed. \(error.localizedDescription)" } }
            if epoch == captured { busy = false; work = nil; await reload() }
        }
    }
}
