import SwiftUI
import WebKit
import AVKit
import Supabase


/// Local request ownership is separate from retained form state and server authorization.
@MainActor
final class AdminRequestOwner: ObservableObject {
    @Published private(set) var revision = UUID()
    @Published private(set) var contentIdentity: UUID?
    @Published private(set) var working = false
    private var account: UUID?
    private var available = false
    private var requiresSession = true
    private weak var parent: AdminRequestOwner?
    private var hadParent = false
    private var origin: CommunityOperationScope?
    private var observedParentRevision: UUID?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var initialCompleted = false
    private var initialRequestID: UUID?
    var needsInitialLoad: Bool { !initialCompleted && initialRequestID == nil }

    func attach(parent: AdminRequestOwner?, origin: CommunityOperationScope?) {
        guard parent !== self else { return }
        self.parent = parent; self.origin = origin; hadParent = parent != nil; observedParentRevision = parent?.revision
    }
    @discardableResult
    func parentChanged(_ revision: UUID) -> Bool {
        guard observedParentRevision != revision else { return false }
        observedParentRevision = revision; cancel(); return true
    }
    func bindIdentity(requiresSession: Bool) {
        cancel()
        self.requiresSession = requiresSession
        account = AuthService.shared.currentUser?.id
        contentIdentity = AuthService.shared.communityIdentityRevision
        initialCompleted = false; initialRequestID = nil
    }
    func invalidateIdentity() { cancel(); available = false; contentIdentity = nil }
    func setAvailable(_ value: Bool) {
        if available != value { cancel(); available = value }
    }
    func cancel() {
        revision = UUID()
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); working = false
        // Completed initial reads retain their data/forms/pages; only unfinished work retries.
        if initialRequestID != nil { initialRequestID = nil; initialCompleted = false }
    }
    /// Dashboard-only read-only permission revalidation, deliberately not used by child panels.
    func resetInitialCompletionForAccessRevalidation() { initialRequestID = nil; initialCompleted = false }
    var canRun: Bool {
        let auth = AuthService.shared
        guard available, (origin?.isCurrent ?? true), (!hadParent || parent?.canRun == true), UIApplication.shared.applicationState == .active,
              contentIdentity == auth.communityIdentityRevision else { return false }
        if !requiresSession { return true } // Injected verified overview owns its authorization.
        return CommunityServices.isConfigured && auth.isAuthenticated && !auth.passwordRecoveryPending &&
            account != nil && auth.currentUser?.id == account &&
            CommunityServices.gateway.transport.sessionAccountID == account
    }
    func capture() -> CommunityOperationScope {
        let revision = self.revision, identity = contentIdentity, account = self.account
        let parent = CommunityOperationContext.scope
        let parentWindow = self.parent?.capture(), hadParent = self.hadParent
        return CommunityOperationScope(account: account) { [weak self] in
            (parent?.isCurrent ?? true) && (!hadParent || parentWindow?.isCurrent == true) && self?.canRun == true &&
            self?.revision == revision && self?.contentIdentity == identity
        }
    }
    /// Called synchronously by the UI after copying its operands; no authority is acquired in Task.
    @discardableResult
    func enqueue(origin: CommunityOperationScope? = nil, _ operation: @escaping @MainActor (CommunityOperationScope) async -> Void) -> Task<Void, Never>? {
        enqueueOwned(origin: origin, initial: false, operation)
    }
    @discardableResult
    func enqueueInitial(_ operation: @escaping @MainActor (CommunityOperationScope) async -> Void) -> Task<Void, Never>? {
        guard needsInitialLoad else { return nil }
        return enqueueOwned(origin: nil, initial: true, operation)
    }
    private func enqueueOwned(origin: CommunityOperationScope?, initial: Bool,
        _ operation: @escaping @MainActor (CommunityOperationScope) async -> Void) -> Task<Void, Never>? {
        guard !working else { return nil }
        let current = capture()
        let scope = CommunityOperationScope(account: current.account) { current.isCurrent && (origin?.isCurrent ?? true) }
        guard scope.isCurrent else { return nil }
        let id = UUID(); working = true
        // Set ownership only after every enqueue guard passed, before Task can start.
        if initial { initialRequestID = id }
        let task = Task { @MainActor in
            var completed = false
            defer {
                // An old cancelled completion cannot mark a newer initial request complete.
                if initial, self.initialRequestID == id {
                    self.initialRequestID = nil
                    self.initialCompleted = completed && scope.isCurrent
                }
                if self.tasks.removeValue(forKey: id) != nil { self.working = !self.tasks.isEmpty }
            }
            do {
                try await CommunityOperationContext.run(scope) { await operation(scope) }
                completed = true
            }
            catch { } // Revoked work cannot write an error into a replacement form.
        }
        tasks[id] = task
        return task
    }
}

private struct AdminOfferScopeKey: EnvironmentKey { static let defaultValue: CommunityOperationScope? = nil }
private struct AdminParentRequestsKey: EnvironmentKey {
    static let defaultValue: AdminRequestOwner? = nil
}
extension EnvironmentValues {
    var sdiAdminOfferScope: CommunityOperationScope? {
        get { self[AdminOfferScopeKey.self] }
        set { self[AdminOfferScopeKey.self] = newValue }
    }
    var sdiAdminParentRequests: AdminRequestOwner? {
        get { self[AdminParentRequestsKey.self] }
        set { self[AdminParentRequestsKey.self] = newValue }
    }
}
@MainActor
private struct AdminParentLifetimeObserver: View {
    @ObservedObject var parent: AdminRequestOwner
    let requests: AdminRequestOwner
    let pause: @MainActor () -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: parent.revision) { _, revision in if requests.parentChanged(revision) { pause() } }
    }
}
@MainActor
private struct AdminRequestLifetime: ViewModifier {
    @ObservedObject var requests: AdminRequestOwner
    let requiresSession: Bool
    let disableWhileWorking: Bool
    let reset: @MainActor () -> Void
    let initial: @MainActor () async -> Void
    let pause: @MainActor () -> Void
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.sdiSubjectWindowVisible) private var subjectVisible
    @Environment(\.sdiAdminParentRequests) private var parent
    @Environment(\.sdiAdminOfferScope) private var origin
    private var identity: String { "\(auth.communityIdentityRevision):\(phase == .active):\(subjectVisible):\(parent?.revision.uuidString ?? "root")" }
    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            if requests.contentIdentity == auth.communityIdentityRevision {
                content.disabled(disableWhileWorking && requests.working).environment(\.sdiAdminParentRequests, requests)
            }
            else { ProgressView().accessibilityLabel("Refreshing account context") }
        }
        .background {
            if let parent { AdminParentLifetimeObserver(parent: parent, requests: requests, pause: pause) }
        }
        .task(id: identity) {
            requests.attach(parent: parent, origin: origin)
            if requests.contentIdentity != auth.communityIdentityRevision {
                reset()
                requests.bindIdentity(requiresSession: requiresSession)
            }
            requests.setAvailable(subjectVisible && phase == .active)
            if requests.canRun && requests.needsInitialLoad {
                if let task = requests.enqueueInitial({ _ in await initial() }) { await task.value }
            }
        }
        .onChange(of: subjectVisible) { _, visible in
            requests.setAvailable(visible && phase == .active)
            if !visible { pause() }
        }
        .onChange(of: phase) { _, value in
            requests.setAvailable(subjectVisible && value == .active)
            if value != .active { pause() }
        }
        .onChange(of: auth.communityIdentityRevision) { _, revision in
            if requests.contentIdentity != revision { requests.invalidateIdentity(); pause() }
        }
        .onDisappear { requests.setAvailable(false); requests.cancel(); pause() }
    }
}
extension View {
    @MainActor
    func adminRequestLifetime(_ requests: AdminRequestOwner, requiresSession: Bool = true, disableWhileWorking: Bool = true,
        reset: @escaping @MainActor () -> Void, initial: @escaping @MainActor () async -> Void,
        pause: @escaping @MainActor () -> Void) -> some View {
        modifier(AdminRequestLifetime(requests: requests, requiresSession: requiresSession, disableWhileWorking: disableWhileWorking,
            reset: reset, initial: initial, pause: pause))
    }
}

/// Same RPC and server-error payload as the old direct SDK calls, through the existing scoped SDK.
@MainActor
private func adminRPC<P: Encodable & Sendable, R: CommunityResponse>(_ name: String, params: P) async throws -> R {
    guard CommunityOperationContext.scope != nil else { throw CommunityError.stale }
    return try await CommunityServices.admin.gateway.callKeepingServerError(name, params: params, as: R.self)
}

private struct AdminScopeOffer: Identifiable {
    let id = UUID()
    let scope: CommunityOperationScope
}
private struct AdminUserHistoryOffer: Identifiable {
    let id = UUID()
    let user: AdminDirectoryUser
    let scope: CommunityOperationScope
}
private struct AdminEmergencyStopIntent {
    let enabled: Bool
    let request: AdminAgentRequest
    let scope: CommunityOperationScope
}
private struct AdminAuthenticatorRequest: Identifiable {
    let id = UUID()
    let scope: CommunityOperationScope
}

// MARK: - Admin Dashboard (Superuser Only)
@MainActor
struct AdminDashboardView: View {
    @StateObject private var requests = AdminRequestOwner()
    @EnvironmentObject var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = "dashboard"
    @StateObject private var overview: AdminOverviewModel
    private let usesLiveOverview: Bool

    init(overview: AdminOverviewModel? = nil) {
        usesLiveOverview = overview == nil
        _overview = StateObject(wrappedValue: overview ?? AdminOverviewModel())
    }
    @State private var showSpatterAdmin = false
    @State private var authenticatorRequest: AdminAuthenticatorRequest?
    @State private var capabilities: Set<String> = []
    @State private var isOwner = false
    @State private var permissionRequest = UUID()
    @State private var permissionMessage: String? = "Verify MFA and refresh access."
    @State private var loadingPermissions = false
    @State private var stepUpCurrent: Bool?
    /// Tab visibility mirrors the server capability each panel's RPC requires.
    /// Seeing a tab grants nothing; every reply is server-authorized with MFA.
    private var visibleTabs: [(id: String, icon: String, label: String)] {
        guard usesLiveOverview else { return tabs }
        let needed = ["dashboard": "overview", "health": "overview", "operations": "overview", "agents": "overview",
                      "agentInbox": "overview", "analytics": "overview",
                      "users": "users", "support": "users", "approvals": "reviews", "decisions": "reviews", "spatter": "reviews",
                      "publishing": "publishing", "moderation": "moderation", "warReports": "moderation",
                      "warAppeals": "moderation", "content": "moderation", "challenges": "moderation",
                      "roomReports": "moderation", "removalAppeals": "moderation", "finance": "finance"]
        return tabs.filter { isOwner || needed[$0.id].map { capabilities.contains($0) } == true }
    }

    let tabs: [(id: String, icon: String, label: String)] = [
        ("dashboard", "chart.bar.fill", "Dashboard"),
        ("health", "waveform.path.ecg", "Service health"),
        ("operations", "externaldrive.badge.checkmark", "Backups & releases"),
        ("users", "person.2.fill", "Users"),
        ("support", "lifepreserver", "Support queue"),
        ("permissions", "key", "Permissions"),
        ("content", "doc.fill", "Content"),
        ("approvals", "checkmark.shield", "Video approvals"),
        ("decisions", "clock.arrow.circlepath", "Decision history"),
        ("publishing", "arrow.up.doc", "Publishing"),
        ("challenges", "trophy.fill", "Challenges"),
        ("agents", "cpu.fill", "Agents"),
        ("agentInbox", "tray.and.arrow.down", "Agent inbox & log"),
        ("moderation", "shield.fill", "Moderation"),
        ("warReports", "flag", "War Room reports"),
        ("warAppeals", "arrow.uturn.backward.circle", "War Room appeals"),
        ("roomReports", "person.3", "Room reports"),
        ("removalAppeals", "arrow.uturn.backward", "Removal appeals"),
        ("finance", "creditcard.fill", "Finance"),
        ("spatter", "brain.fill", "Spatter AI"),
        ("analytics", "chart.xyaxis.line", "Analytics"),
    ]
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "shield.fill")
                                .foregroundColor(.red)
                            Text("ADMIN PANEL")
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .foregroundColor(.red)
                        }
                        Text("StickDeath ∞ Command Center")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                    
                    Button("Verify MFA") { let scope = requests.capture(); guard scope.isCurrent else { return }; authenticatorRequest = AdminAuthenticatorRequest(scope: scope) }
                        .font(.caption)
                    Button("Refresh access") { requests.enqueue { _ in await refreshPermissions() } }
                        .font(.caption).disabled(loadingPermissions)
                    // Live indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.gray)
                            .frame(width: 6, height: 6)
                        Text("ADMIN")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                // Tab selector (horizontal scroll)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(visibleTabs, id: \.id) { tab in
                            Button(action: { selectedTab = tab.id }) {
                                HStack(spacing: 4) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 10))
                                    Text(tab.label)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(selectedTab == tab.id ? .white : .white.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedTab == tab.id ? Color.red : Color(hex: "1A1A24"))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
                
                Divider().background(Color.white.opacity(0.06))
                
                // Content
                ScrollView {
                    VStack(spacing: 12) {
                        if let permissionMessage, usesLiveOverview { Text(permissionMessage).font(.caption) }
                        if usesLiveOverview, stepUpCurrent == false {
                            Text("Privileged actions need a recent authenticator verification (15-minute window). Verify MFA before changing roles, agents, finance products or account states.")
                                .font(.caption).foregroundStyle(StudioCraftTheme.warning)
                                .accessibilityIdentifier("admin.step-up.notice")
                        }
                        if !usesLiveOverview || visibleTabs.contains(where: { $0.id == selectedTab }) {
                        switch selectedTab {
                        case "dashboard":
                            if usesLiveOverview { AdminLiveOverviewContent() }
                            else { AdminDashboardContent(state: overview.state) }
                        case "health":
                            AdminHealthContent()
                        case "operations":
                            AdminOperationsStatusContent()
                        case "users":
                            AdminUsersContent()
                        case "support":
                            AdminSupportQueueContent()
                        case "permissions":
                            AdminPermissionsContent()
                        case "approvals":
                            AdminVideoApprovalContent()
                        case "decisions":
                            AdminReviewHistoryContent()
                        case "publishing":
                            AdminPublishingContent()
                        case "content":
                            AdminContentContent()
                        case "challenges":
                            AdminChallengesContent()
                        case "agents":
                            AdminAgentsContent()
                        case "agentInbox":
                            AdminAgentInboxContent()
                        case "moderation":
                            AdminModerationContent()
                        case "warReports":
                            AdminWarReportsContent()
                        case "warAppeals":
                            AdminWarAppealsContent()
                        case "roomReports":
                            AdminRoomReportsContent()
                        case "removalAppeals":
                            AdminRemovalAppealsContent()
                        case "finance":
                            AdminFinanceContent()
                        case "spatter":
                            AdminSpatterContent()
                        case "analytics":
                            AdminAnalyticsContent()
                        default:
                            EmptyView()
                        }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .adminRequestLifetime(requests, requiresSession: usesLiveOverview, disableWhileWorking: false,
            reset: { clearPermissions(); permissionMessage = !CommunityServices.isConfigured ? CommunityServices.notConfiguredText : (AuthService.shared.isAuthenticated ? "Verify MFA and refresh access." : "Sign in and verify your administrator session."); selectedTab = "dashboard"; authenticatorRequest = nil; overview.invalidate() },
            initial: { if usesLiveOverview { await refreshPermissions() } else { await overview.refresh(accountID: authVM.isAuthenticated ? authVM.userId : nil) } },
            pause: { loadingPermissions = false; authenticatorRequest = nil; requests.resetInitialCompletionForAccessRevalidation(); if !usesLiveOverview { overview.invalidate() } })


        .sheet(item: $authenticatorRequest) { request in
            NavigationStack {
                AccountAuthenticatorView(onVerified: { if request.scope.isCurrent { CommunityServices.admin.recordVerification() } })
            }
            .onDisappear {
                guard request.scope.isCurrent else { return }
                requests.enqueue { _ in
                    do { try await CommunityOperationContext.run(request.scope) { await refreshPermissions() } }
                    catch { }
                }
            }
        }
    }
    private func clearPermissions() {
        permissionRequest = UUID(); capabilities = []; isOwner = false; loadingPermissions = false; stepUpCurrent = nil
    }
    private func refreshPermissions() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard usesLiveOverview else { return }
        permissionRequest = UUID(); loadingPermissions = false
        guard scenePhase == .active, authVM.isAuthenticated, let account = authVM.userId else {
            permissionMessage = "Sign in and verify your administrator session."; return
        }
        let id = UUID(); permissionRequest = id; loadingPermissions = true; permissionMessage = "Loading current permissions…"
        defer { if CommunityOperationContext.isCurrent { if permissionRequest == id { loadingPermissions = false } } }
        do {
            let access = try await CommunityServices.admin.access()
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, permissionRequest == id, account == authVM.userId, scenePhase == .active else { return }
            isOwner = access.owner; capabilities = access.capabilities; stepUpCurrent = access.stepUpCurrent; permissionMessage = nil
            if !visibleTabs.contains(where: { $0.id == selectedTab }) { selectedTab = visibleTabs.first?.id ?? "" }
            if visibleTabs.isEmpty { permissionMessage = "No administrative capabilities have been granted." }
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return };
            guard permissionRequest == id else { return }
            capabilities = []; isOwner = false; stepUpCurrent = nil
            if case .server(let message, _) = CommunityGateway.normalize(error) { permissionMessage = message }
            else { permissionMessage = "Access unavailable. Verify MFA and refresh; server permissions are required." }
        }
    }
}

/// Shown before a privileged action when the recent re-authentication window
/// is not current (#210). Nothing is sent until the member verifies again.
@MainActor
struct AdminStepUpBanner: View {
    @StateObject private var requests = AdminRequestOwner()
    @State private var authenticatorRequest: AdminAuthenticatorRequest?
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.caption).foregroundStyle(StudioCraftTheme.warning)
            Button("Verify authenticator now") { let scope = requests.capture(); guard scope.isCurrent else { return }; authenticatorRequest = AdminAuthenticatorRequest(scope: scope) }
                .font(.caption).accessibilityIdentifier("admin.step-up.verify")
        }
        .sheet(item: $authenticatorRequest) { request in NavigationStack { AccountAuthenticatorView(onVerified: { if request.scope.isCurrent { CommunityServices.admin.recordVerification() } }) } }
        .accessibilityIdentifier("admin.step-up.banner")
        .adminRequestLifetime(requests, reset: { authenticatorRequest = nil }, initial: {}, pause: { authenticatorRequest = nil })
    }
}

// MARK: - Read-only verified overview
@MainActor
private struct AdminLiveOverviewContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var snapshot: AdminLiveSnapshot?
    @State private var requestID = UUID()
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Operations overview").font(.specialElite(22))
            Button("Refresh overview") { requests.enqueue { _ in await load() } }.disabled(busy)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let snapshot {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    metric("Registered users", snapshot.users, "person.2.fill")
                    metric("Signed in today (UTC)", snapshot.signed_in_today, "person.fill.checkmark")
                    metric("Renders awaiting review", snapshot.pending_renders, "film")
                    metric("Publishing queue", snapshot.publishing_jobs, "arrow.up.doc")
                    metric("Publishing needs attention", snapshot.publishing_attention, "exclamationmark.triangle")
                    metric("Feed reports", snapshot.feed_reports, "flag")
                    metric("War Room reports", snapshot.war_reports, "flag.fill")
                    metric("War Room appeals", snapshot.war_appeals, "arrow.uturn.backward")
                }
                if let date = snapshot.measured_at { Text("Snapshot: \(date.formatted())").font(.caption) }
            }
            Text("Sign-ins are not live active users. Device-only projects are not counted. Finance and AI usage require their connected ledgers.").font(.caption).foregroundStyle(.secondary)
        }
        .adminRequestLifetime(requests,
            reset: { clear() },
            initial: { await load() },
            pause: { busy = false })

    }
    private func metric(_ title: String, _ value: Int?, _ icon: String) -> some View {
        AdminStatCard(icon: icon, label: title, value: value.map(String.init) ?? "—", color: "EF4444")
    }
    private func clear() { requestID = UUID(); busy = false; snapshot = nil; error = nil }
    private func load() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true; snapshot = nil
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let value: AdminLiveSnapshot = try await adminRPC("sdi_admin_overview", params: [String: String]())
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            let counts = [value.users,value.signed_in_today,value.pending_renders,value.publishing_jobs,
                          value.publishing_attention,value.feed_reports,value.war_reports,value.war_appeals]
            guard value.error == nil, value.measured_at != nil, counts.allSatisfy({ $0.map { $0 >= 0 } ?? false }) else {
                error = value.error ?? "Overview response incomplete."; return
            }
            snapshot = value; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { self.error = "Overview unavailable. Check administrator authorization and MFA." } }
    }
}
private struct AdminLiveSnapshot: CommunityResponse {
    let error: String?; let users: Int?; let signed_in_today: Int?; let pending_renders: Int?
    let publishing_jobs: Int?; let publishing_attention: Int?; let feed_reports: Int?; let war_reports: Int?; let war_appeals: Int?
    let measured_at: Date?
}

struct AdminDashboardContent: View {
    let state: AdminOverviewModel.State
    private var snapshot: AdminOverviewSnapshot? {
        if case .data(let value) = state { return value }; return nil
    }
    private func count(_ key: KeyPath<AdminOverviewSnapshot, Int>) -> String {
        snapshot.map { String($0[keyPath: key]) } ?? "—"
    }
    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                AdminStatCard(icon: "person.2.fill", label: "Total Users", value: count(\.totalUsers), color: "3B82F6")
                AdminStatCard(icon: "person.fill.checkmark", label: "Active Today", value: count(\.activeToday), color: "10B981")
                AdminStatCard(icon: "film.fill", label: "Animations", value: count(\.totalAnimations), color: "8B5CF6")
                AdminStatCard(icon: "dollarsign.circle.fill", label: "Revenue (USD)", value: snapshot.map { String(format: "$%.2f", Double($0.revenueMinorUnits) / 100) } ?? "—", color: "F59E0B")
                AdminStatCard(icon: "exclamationmark.shield.fill", label: "Reports", value: count(\.pendingReports), color: "EF4444")
                AdminStatCard(icon: "brain", label: "AI Queries/Day", value: count(\.aiQueriesDay), color: "EC4899")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("DATA STATUS").font(.system(size: 10, weight: .bold, design: .monospaced))
                switch state {
                case .loading: ProgressView("Loading verified admin data…")
                case .unavailable(let message), .failed(let message): Text(message)
                case .data(let value):
                    Text("Snapshot: " + value.measuredAt.formatted(date: .abbreviated, time: .standard))
                }
                Text("Recent activity is not connected.")
                    .foregroundColor(.white.opacity(0.4))
            }
            .font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color(hex: "12121A")).cornerRadius(12)
            .accessibilityIdentifier("admin.overview.status")
        }
    }
}

struct AdminStatCard: View {
    let icon: String
    let label: String
    let value: String
    let color: String
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Color(hex: color))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(hex: "12121A"))
        .cornerRadius(12)
    }
}

// MARK: - Users Tab
@MainActor
struct AdminUsersContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var appealsOffer: AdminScopeOffer?
    @State private var historyUser: AdminUserHistoryOffer?
    @State private var pendingAction: AdminPendingAccountAction?
    @State private var users: [AdminDirectoryUser] = []
    @State private var search = ""
    @State private var appliedSearch = ""
    @State private var reason = ""
    @State private var page = 0
    @State private var more = true
    @State private var busy = false
    @State private var error: String?
    @State private var stepUp: String?
    @State private var generation = UUID()
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Review account appeals") { let scope = requests.capture(); guard scope.isCurrent else { return }; appealsOffer = AdminScopeOffer(scope: scope) }
            TextField("Search username or account ID", text: $search).textFieldStyle(.roundedBorder)
            Button("Search") { requests.enqueue { [query = search] _ in await load(reset: true, submittedQuery: query) } }
                .disabled(busy || search.trimmingCharacters(in: .whitespacesAndNewlines).count > 100)
            if search.trimmingCharacters(in: .whitespacesAndNewlines) != appliedSearch {
                Text("Press Search to apply the edited query. Load more continues the current results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Reason for account action", text: $reason, axis: .vertical).lineLimit(2...4)
            if let error { Text(error).foregroundColor(.red) }
            if let stepUp { AdminStepUpBanner(message: stepUp) }
            if busy { ProgressView() }
            ForEach(users) { user in
                VStack(alignment: .leading, spacing: 8) {
                    Text(user.username).font(.specialElite(18))
                    Text(user.id.uuidString).font(.caption).textSelection(.enabled)
                    Text(user.masked_email ?? "No email").font(.caption)
                    Text("\(user.state.capitalized) · \(user.content_count) videos")
                    Text("Joined \(user.created_at.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                    if let methods = user.sign_in_methods {
                        Text("Sign-in methods: \(methods.isEmpty ? "None linked" : methods.joined(separator: ", "))").font(.caption)
                    }
                    if let reports = user.feed_report_count {
                        Text("\(reports) feed reports received (all outcomes)").font(.caption)
                    }
                    // Present only for administrators holding the finance capability.
                    if let plan = user.plan { Text("Plan: \(plan.capitalized)").font(.caption) }
                    if let last = user.last_sign_in_at { Text("Last sign-in \(last.formatted())").font(.caption) }
                    Button("Account history") { let scope = requests.capture(); guard scope.isCurrent else { return }; historyUser = AdminUserHistoryOffer(user: user, scope: scope) }
                        .accessibilityIdentifier("admin.users.history")
                    Menu("Account actions") {
                        ForEach(["suspend","ban","restore","signout","note"], id: \.self) { action in
                            Button(action.capitalized) {
                                pendingAction = .init(action: action, user: user,
                                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                                    generation: generation, scope: requests.capture())
                            }
                        }
                    }.disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 2000)
                }.padding().background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if more { Button("Load more") { requests.enqueue { [page, query = appliedSearch] _ in await load(reset: false, submittedPage: page, pagingQuery: query) } }.disabled(busy) }
        }
        .adminRequestLifetime(requests,
            reset: { generation = UUID(); users = []; page = 0; more = true; busy = false; historyUser = nil; pendingAction = nil; reason = ""; search = ""; error = nil; appliedSearch = ""; stepUp = nil; appealsOffer = nil },
            initial: { await load(reset: true) },
            pause: { busy = false; pendingAction = nil; historyUser = nil; appealsOffer = nil })
        .sheet(item: $historyUser) { offer in AdminUserHistoryView(user: offer.user).environment(\.sdiAdminOfferScope, offer.scope) }
        .sheet(item: $appealsOffer) { offer in AccountAppealsView(administrator: true).environment(\.sdiAdminOfferScope, offer.scope) }
        .confirmationDialog("Confirm account action", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible, presenting: pendingAction) { pending in
            Button("\(pending.action.capitalized) \(pending.user.username)",
                   role: ["suspend", "ban", "signout"].contains(pending.action) ? .destructive : nil) {
                requests.enqueue(origin: pending.scope) { _ in await apply(pending) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { pending in
            Text("Account: \(pending.user.id.uuidString)\nReason: \(pending.reason)\n\(pending.impact)")
        }

    }
    @MainActor private func load(reset: Bool, submittedQuery: String? = nil, submittedPage: Int? = nil, pagingQuery: String? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        if reset {
            let query = (submittedQuery ?? search).trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count <= 100 else { error = "Use at most 100 characters for directory search."; return }
            generation = UUID(); pendingAction = nil; historyUser = nil
            appliedSearch = query; users = []; page = 0; more = true
        }
        guard page < 200, more else { return }
        let epoch = generation, account = auth.userId
        busy = true; defer { if CommunityOperationContext.isCurrent { if epoch == generation { busy = false } } }
        do {
            let response: AdminDirectoryResponse = try await adminRPC("sdi_users_action", params: AdminUserRequest(action: "list", query: pagingQuery ?? appliedSearch, page: submittedPage ?? page))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, epoch == generation, account == auth.userId, auth.isAuthenticated, phase == .active else { return }
            if let problem = response.error { users = []; more = false; error = problem; return }
            guard let items = response.users, items.count <= 50, let hasMore = response.has_more else { users = []; more = false; error = "Invalid directory response."; return }
            for item in items { if let index = users.firstIndex(where: {$0.id == item.id}) { users[index] = item } else { users.append(item) } }
            page += 1; more = hasMore && page < 200; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if epoch == generation, account == auth.userId, phase == .active { users = []; more = false; self.error = "Directory unavailable. Check your admin session and MFA." } }
    }
    @MainActor private func apply(_ pending: AdminPendingAccountAction) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active, pending.generation == generation else { return }
        pendingAction = nil
        if let prompt = CommunityServices.admin.stepUpPrompt(for: "users.\(pending.action)") { stepUp = prompt; return }
        stepUp = nil
        let epoch = generation, account = auth.userId; busy = true
        defer { if CommunityOperationContext.isCurrent { if epoch == generation { busy = false } } }
        do {
            let response: AdminDirectoryResponse = try await adminRPC("sdi_users_action", params: AdminUserRequest(action: pending.action, subject: pending.user.id, reason: pending.reason))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, epoch == generation, account == auth.userId, auth.isAuthenticated, phase == .active else { return }
            if let problem = response.error {
                // The server requires a recent second factor for state changes (admin_gate).
                let refusal = CommunityServices.admin.noteRefusal(CommunityError.server(message: problem, code: response.code))
                if refusal.isStepUpRequired { stepUp = problem } else { error = problem }
                busy = false; return
            }
            guard response.status == "confirmed" else { error = "Action was not confirmed."; busy = false; return }
            busy = false; reason = ""; await load(reset: true, submittedQuery: appliedSearch)
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if epoch == generation, account == auth.userId, phase == .active { self.error = "Action was not confirmed. Refresh before retrying." } }
    }
}
private struct AdminPendingAccountAction {
    let action: String; let user: AdminDirectoryUser; let reason: String; let generation: UUID; let scope: CommunityOperationScope
    var impact: String {
        switch action {
        case "suspend", "ban": return "Revokes existing sessions and blocks app-service access. Restore can allow a fresh sign-in."
        case "restore": return "Allows a fresh sign-in. Previously revoked sessions stay revoked."
        case "signout": return "Revokes existing sessions. The user can sign in again."
        default: return "Adds an internal audit note. No message is sent to this user."
        }
    }
}
private struct AdminUserRequest: Encodable {
    let action: String
    var subject: UUID? = nil; var query = ""; var page = 0; var reason = ""
}
private struct AdminDirectoryResponse: CommunityResponse {
    let status: String?; let error: String?; var code: String? = nil; let users: [AdminDirectoryUser]?; let has_more: Bool?
}
private struct AdminDirectoryUser: Decodable, Identifiable {
    let id: UUID; let username: String; let masked_email: String?; let state: String
    let created_at: Date; let last_sign_in_at: Date?; let content_count: Int
    let sign_in_methods: [String]?; let feed_report_count: Int?
    /// Billing tier (`free`, `creator`, `pro`, `unlimited`); null unless the server granted finance visibility.
    var plan: String? = nil
}

// MARK: - Content Tab
@MainActor
struct AdminContentContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var search = ""
    @State private var appliedSearch = ""
    @State private var posts: [AdminContentEntry] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var reportsOffer: AdminScopeOffer?
    @State private var reason = ""
    @State private var curation: AdminCurationIntent?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search title, creator, post or account ID", text: $search).textFieldStyle(.roundedBorder)
            Button("Search content") { requests.enqueue { [query = search] _ in await refresh(submittedQuery: query) } }.disabled(busy || search.count > 100)
            Button("Open feed moderation queue") { let scope = requests.capture(); guard scope.isCurrent else { return }; reportsOffer = AdminScopeOffer(scope: scope) }
            TextField("Reason for Featured change", text: $reason, axis: .vertical).lineLimit(2...4)
            Text("Visibility and approval are separate requirements. Report counts are not findings of abuse.").font(.caption)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if !busy && error == nil && posts.isEmpty { Text("No matching feed content.") }
            ForEach(posts) { post in
                VStack(alignment: .leading, spacing: 8) {
                    Text(post.title).font(.specialElite(18))
                    Text(post.creator_name).font(.headline)
                    Text(post.caption)
                    Text("Post: \(post.id.uuidString)\nCreator: \(post.creator.uuidString)").font(.caption).textSelection(.enabled)
                    Text(post.published_at.formatted()).font(.caption)
                    Text("\(post.visible ? "Visible flag on" : "Hidden") · \(post.approved ? "Approved" : "Not approved")")
                    Text("Featured: \(post.featured ? "Yes" : "No") · Creator permits export: \(post.allow_export ? "Yes" : "No")").font(.caption)
                    Button(post.featured ? "Remove from Featured" : "Feature this video") {
                        curation = .init(post: post, reason: reason, generation: generation, scope: requests.capture())
                    }.disabled(busy || post.feature_revision == nil || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 2000 || (!post.featured && (!post.visible || !post.approved)))
                    if let expiry = post.expires_at { Text("Media expiry: \(expiry.formatted())").font(.caption) }
                    Text("\(post.pending_report_count) pending / \(post.report_count) total reports").font(.caption)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if more && page < 200 { Button("Load more content") { requests.enqueue { [page, query = appliedSearch] _ in await load(submittedPage: page, submittedQuery: query) } }.disabled(busy) }
            if more && page >= 200 { Text("Narrow the search to inspect more results.").font(.caption) }
        }
        .adminRequestLifetime(requests,
            reset: { generation = UUID(); posts = []; page = 0; more = false; search = ""; appliedSearch = ""; reason = ""; error = nil; curation = nil; busy = false; reportsOffer = nil },
            initial: { await refresh() },
            pause: { busy = false; curation = nil; reportsOffer = nil })

        .confirmationDialog("Change Featured placement?", isPresented: Binding(get: { curation != nil },
            set: { if !$0 { curation = nil } }), titleVisibility: .visible, presenting: curation) { pending in
            Button(pending.post.featured ? "Remove from Featured" : "Feature video") { requests.enqueue(origin: pending.scope) { _ in await curate(pending) } }
            Button("Cancel", role: .cancel) { curation = nil }
        } message: { pending in
            Text("\(pending.post.title)\nReason: \(pending.reason)\nThis changes Featured placement only; it does not approve, publish or restore removed content.")
        }
        .sheet(item: $reportsOffer) { offer in
            NavigationStack { ScrollView { AdminModerationContent().padding() }.navigationTitle("Feed moderation")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { reportsOffer = nil } } }
                .environment(\.sdiAdminOfferScope, offer.scope) }
        }
    }
    @MainActor private func refresh(submittedQuery: String? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        generation = UUID(); posts = []; page = 0; more = false; busy = false; error = nil; curation = nil; reason = ""
        appliedSearch = (submittedQuery ?? search).trimmingCharacters(in: .whitespacesAndNewlines)
        await load()
    }
    @MainActor private func curate(_ pending: AdminCurationIntent) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, phase == .active, auth.isAuthenticated, pending.generation == generation,
              let revision = pending.post.feature_revision else { return }
        let epoch = generation; busy = true
        defer { if CommunityOperationContext.isCurrent { if epoch == generation { busy = false } } }
        do {
            let response: AdminCurationResponse = try await adminRPC("sdi_feature_content",
                params: AdminCurationRequest(post: pending.post.id, revision: revision,
                    featured: !pending.post.featured, reason: pending.reason))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, epoch == generation, phase == .active else { return }
            guard response.error == nil, response.status == "confirmed" || response.status == "unchanged" else {
                error = response.error ?? "Curation was not confirmed. Refresh before retrying."; return
            }
            busy = false; await refresh()
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if epoch == generation { self.error = "Curation was not confirmed. Refresh before retrying." } }
    }
    @MainActor private func load(submittedPage: Int? = nil, submittedQuery: String? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active, page < 200, appliedSearch.count <= 100 else { return }
        let epoch = generation; let account = auth.userId
        busy = true; defer { if CommunityOperationContext.isCurrent { if epoch == generation { busy = false } } }
        do {
            let response: AdminContentResponse = try await adminRPC("sdi_admin_content",
                params: AdminContentQuery(page: submittedPage ?? page, query: submittedQuery ?? appliedSearch))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, epoch == generation, account == auth.userId, phase == .active else { return }
            guard response.error == nil, let items = response.posts, items.count <= 50, let hasMore = response.has_more else {
                posts = []; more = false; error = response.error ?? "Invalid content response."; return
            }
            for item in items {
                if let index = posts.firstIndex(where: { $0.id == item.id }) { posts[index] = item }
                else { posts.append(item) }
            }
            page += 1; more = hasMore; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if epoch == generation { posts = []; more = false; self.error = "Content inventory unavailable. Refresh your admin access and MFA." } }
    }
}
private struct AdminContentQuery: Encodable { let page: Int; let query: String }
private struct AdminContentResponse: CommunityResponse { let error: String?; let posts: [AdminContentEntry]?; let has_more: Bool? }
private struct AdminContentEntry: Decodable, Identifiable {
    let id: UUID; let creator: UUID; let creator_name: String; let caption: String; let title: String
    let published_at: Date; let visible: Bool; let featured: Bool; let allow_export: Bool; let approved: Bool
    let expires_at: Date?; let report_count: Int; let pending_report_count: Int; let feature_revision: Int?
}

private struct AdminCurationIntent { let post: AdminContentEntry; let reason: String; let generation: UUID; let scope: CommunityOperationScope }
private struct AdminCurationRequest: Encodable { let post: UUID; let revision: Int; let featured: Bool; let reason: String }
private struct AdminCurationResponse: CommunityResponse { let status: String?; let error: String? }

// MARK: - Spatter AI Tab
/// Spatter videos are approved render by render in Video approvals (owner
/// only). The generation service has no status contract exposed to this
/// client, so no counts, schedules or costs are shown here.
struct AdminSpatterContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spatter operations").font(.specialElite(22))
            Text("Every Spatter-generated video reaches the feed, channel or social only after the owner approves the exact render in Video approvals. Generation schedules, quotas and the emergency stop are managed in the Agents tab (agent key spatter_daily_video) once the agent controls are deployed.")
                .font(.caption)
            Text("No generation status, draft count or provider cost is connected to this build; nothing is estimated.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color(hex: "12121A")).cornerRadius(12)
            .accessibilityIdentifier("admin.spatter.status")
    }
}

// MARK: - Analytics Tab
/// Business analytics have no server contract; the overview and health tabs
/// show the counts that exist. Nothing is sampled or estimated here.
struct AdminAnalyticsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Analytics").font(.specialElite(22))
                Text("Engagement analytics are not connected. Registered-user, review, publishing and report counts are on the Dashboard; queue depth, worker liveness and denials are under Service health.")
                    .font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color(hex: "12121A")).cornerRadius(12)
                .accessibilityIdentifier("admin.analytics.status")
            AdminDiagnosticsContent()
        }
    }
}

// MARK: - Diagnostics (#291)
/// Opt-in, first-party stability counts from `sdi_diagnostics_admin`: day totals
/// per platform/build/counter, crash spikes and failed agent runs. Only members
/// who opted in send reports, so these are not population rates.
@MainActor
private struct AdminDiagnosticsContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var summary: AdminDiagnosticsSummary?
    @State private var days = 14
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stability diagnostics").font(.specialElite(18))
            Text("Counts from members who opted in to diagnostics. No account, device identifier, project content or free text is stored; day rows are kept 90 days.").font(.caption)
            HStack {
                Picker("Window", selection: $days) {
                    Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30); Text("90 days").tag(90)
                }.pickerStyle(.segmented).disabled(busy)
                Button("Refresh") { requests.enqueue { [days] _ in await load(submittedDays: days) } }.disabled(busy).accessibilityIdentifier("admin.diagnostics.refresh")
            }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("admin.diagnostics.error") }
            if let summary {
                Text("\(summary.reports ?? 0) report(s) since \(summary.since ?? "?") · latest complete day \(summary.latest_complete_day ?? "?")").font(.caption)
                if let failed = summary.agent_runs_failed_24h {
                    Text("Failed agent runs (24 h): \(failed)").font(.caption)
                        .foregroundStyle(failed > 0 ? StudioCraftTheme.accentText : .primary)
                }
                if let spikes = summary.crash_spikes, !spikes.isEmpty {
                    Text("Crash spikes").font(.specialElite(15)).foregroundStyle(StudioCraftTheme.accentText)
                    ForEach(Array(spikes.enumerated()), id: \.offset) { _, spike in
                        Text("\(spike.platform) build \(spike.build): \(spike.latest_total) crashes on the latest day vs \(String(format: "%.2f", spike.prior_daily_mean))/day before").font(.caption)
                    }
                } else if (summary.reports ?? 0) == 0 {
                    Text("No opt-in reports in this window, so no crash-spike alert can be computed.").font(.caption)
                } else {
                    Text("No crash spike on the latest complete day (rule: at least 5 and over five times the prior 7-day mean).").font(.caption)
                }
                ForEach(["ios", "android"], id: \.self) { platform in
                    let rows = summary.counterTotals(platform: platform)
                    Text(platform == "ios" ? "iOS" : "Android").font(.specialElite(15))
                    if rows.isEmpty { Text("No reports in this window.").font(.caption) }
                    ForEach(rows) { row in
                        Text("\(row.counter.replacingOccurrences(of: "_", with: " ")): \(row.total)").font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Color(hex: "12121A")).cornerRadius(12)
        .accessibilityIdentifier("admin.diagnostics.summary")
        .onChange(of: days) { _, value in requests.cancel(); busy = false; requests.enqueue { _ in await load(submittedDays: value) } }
        .adminRequestLifetime(requests,
            reset: { clear() },
            initial: { await load() },
            pause: { busy = false })

    }
    private func clear() { requestID = UUID(); busy = false; summary = nil; error = nil }
    private func load(submittedDays: Int? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let value = try await CommunityServices.admin.diagnostics(days: submittedDays ?? days)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            summary = value; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { summary = nil; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
}

// Queue rows are selections, never playback grants. Both providers use the
// same fresh server admission, local session fence and bounded renewal lease.
@MainActor
private struct AdminModerationPreviewButton: View {
    @StateObject private var requests = AdminRequestOwner()
    let target: AdminPreviewTarget?
    let title: String
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var admission = AdminPreviewAdmission()
    @State private var presentation: Presentation?
    @State private var opening: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var error: String?
    private struct Presentation: Identifiable {
        let id = UUID()
        let source: FeedPlaybackSource
        let target: AdminPreviewTarget
        let title: String
        let scope: CommunityOperationScope
    }
    private var context: AdminPreviewAdmission.Context {
        guard requests.canRun, auth.isAuthenticated, phase == .active, let account = auth.userId,
              let session = try? SupabaseManager.shared.client.auth.currentSession,
              !session.isExpired, session.user.id.uuidString == account else { return .unavailable }
        return .init(account: account, sessionMarker: session.accessToken, active: true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if target != nil {
                Button(opening == nil ? "Play: \(title)" : "Checking preview…") { startOpen() }
                    .disabled(opening != nil || !context.usable)
            } else {
                Text("Preview unavailable. Refresh the queue to check current access.").font(.caption)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .sheet(item: $presentation, onDismiss: { invalidate() }) { item in
            CommunityVideoPlayer(source: item.source, title: item.title, isAllowed: {
                item.scope.isCurrent && presentation?.id == item.id &&
                    admission.isValid(item.target, context: context, uptime: ProcessInfo.processInfo.systemUptime)
            })
            .task(id: item.id) { await renew(item) }
            // Independent of network renewal: a hung request cannot extend the grant.
            .task(id: item.id) { await watchLease(item) }
        }
        .onChange(of: context) { _, _ in invalidate() }
        .onChange(of: target) { _, _ in invalidate() }
        .adminRequestLifetime(requests, reset: { invalidate() }, initial: {}, pause: { invalidate() })
    }
    private func invalidate(_ message: String? = nil) {
        requestID = UUID(); opening?.cancel(); opening = nil; requests.cancel()
        admission.invalidate(); presentation = nil; error = message
    }
    /// All row/title/auth/window authority is captured before creating the owned Task.
    private func startOpen() {
        guard let target, requests.capture().isCurrent, !requests.working,
              let ticket = admission.begin(target, context: context, uptime: ProcessInfo.processInfo.systemUptime) else { return }
        let id = UUID(), submittedTitle = title
        requestID = id; error = nil
        opening = requests.enqueue { scope in
            defer { if scope.isCurrent, requestID == id { opening = nil } }
            do {
                let fresh = try await CommunityServices.admin.refreshPreview(target)
                guard scope.isCurrent, requestID == id, self.target == target,
                      admission.accept(fresh, ticket: ticket, context: context, serverNow: CommunityServices.admin.previewServerNow,
                                       uptime: ProcessInfo.processInfo.systemUptime), let source = admission.source else {
                    if scope.isCurrent, requestID == id { invalidate("Preview changed or is no longer authorized. Refresh the queue.") }
                    return
                }
                presentation = Presentation(source: source, target: target, title: submittedTitle, scope: scope)
            } catch {
                guard scope.isCurrent, requestID == id else { return }
                admission.refuse(ticket); invalidate(CommunityServices.admin.noteRefusal(error).errorDescription)
            }
        }
    }
    private func renew(_ item: Presentation) async {
        while item.scope.isCurrent, presentation?.id == item.id {
            do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation() }
            catch { return }
            guard item.scope.isCurrent, presentation?.id == item.id, target == item.target,
                  admission.isValid(item.target, context: context, uptime: ProcessInfo.processInfo.systemUptime),
                  let ticket = admission.begin(item.target, context: context, uptime: ProcessInfo.processInfo.systemUptime) else {
                if item.scope.isCurrent, presentation?.id == item.id { invalidate("Preview authorization expired. Refresh the queue.") }; return
            }
            do {
                let fresh = try await CommunityOperationContext.run(item.scope) {
                    try await CommunityServices.admin.refreshPreview(item.target)
                }
                guard item.scope.isCurrent, presentation?.id == item.id, target == item.target,
                      admission.accept(fresh, ticket: ticket, context: context, serverNow: CommunityServices.admin.previewServerNow,
                                       uptime: ProcessInfo.processInfo.systemUptime) else {
                    if item.scope.isCurrent, presentation?.id == item.id { invalidate("Preview changed or is no longer authorized. Refresh the queue.") }; return
                }
            } catch {
                guard item.scope.isCurrent, presentation?.id == item.id else { return }
                admission.refuse(ticket); invalidate(CommunityServices.admin.noteRefusal(error).errorDescription); return
            }
        }
    }
    private func watchLease(_ item: Presentation) async {
        while !Task.isCancelled, presentation?.id == item.id {
            guard item.scope.isCurrent else { invalidate(); return }
            let uptime = ProcessInfo.processInfo.systemUptime
            guard admission.isValid(item.target, context: context, uptime: uptime), let deadline = admission.deadline else {
                if item.scope.isCurrent { invalidate("Preview authorization expired. Refresh the queue.") }; return
            }
            do { try await Task.sleep(for: .seconds(min(1, max(0, deadline - uptime)))) }
            catch { return }
        }
    }
}

// MARK: - Moderation Tab
@MainActor
struct AdminModerationContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var reports: [ModerationReport] = []
    @State private var selected: ModerationReport?
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?
    @State private var stepUp: String?
    @State private var generation = UUID()
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reported videos").font(.specialElite(22))
            Text("Removal hides the rendition from the app and queues external removal. It does not claim an external platform has removed it.").font(.caption)
            Button("Refresh reports") { requests.enqueue { _ in await load() } }.disabled(busy)
            if let error { Text(error).foregroundColor(.red) }
            if let stepUp { AdminStepUpBanner(message: stepUp) }
            if busy { ProgressView() }
            if let selected {
                Text(selected.title).font(.specialElite(18))
                AdminModerationPreviewButton(target: selected.previewTarget, title: selected.title).id(selected.id)
                Text("Report: \(selected.reason)")
                Text(selected.caption)
                Text(selected.render_digest).font(.caption.monospaced()).textSelection(.enabled)
                TextField("Required decision reason", text: $note, axis: .vertical).lineLimit(2...5)
                HStack {
                    Button("Dismiss report") { requests.enqueue { [note] _ in await decide("dismiss", report: selected, submittedNote: note) } }
                    Button("Remove video", role: .destructive) { requests.enqueue { [note] _ in await decide("remove", report: selected, submittedNote: note) } }
                }.disabled(busy || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 2000)
            }
            ForEach(reports) { report in
                Button { select(report) } label: {
                    VStack(alignment: .leading) {
                        Text(report.title).font(.specialElite(17))
                        Text("\(report.reason) · \(report.created_at.formatted())").font(.caption)
                    }
                }.padding(10)
            }
            if reports.isEmpty && !busy && error == nil { Text("No pending reports.") }
        }
        .adminRequestLifetime(requests,
            reset: { clear(); busy = false; error = nil; stepUp = nil },
            initial: { await load() },
            pause: { busy = false })

    }
    private func clear() { generation = UUID(); reports = []; selected = nil; note = "" }
    private func select(_ report: ModerationReport) {
        selected = report; note = ""
        error = nil
    }
    @MainActor private func load() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated else { return }
        let epoch = generation; busy = true; selected = nil; defer { if CommunityOperationContext.isCurrent { busy = false } }
        do {
            let response: ModerationResponse = try await adminRPC("sdi_moderation_action", params: ModerationRequest(action: "list"))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, epoch == generation else { return }
            selected = nil
            if let problem = response.error { reports = []; error = problem; return }
            guard let items = response.reports, items.count <= 50 else { reports = []; error = "Invalid moderation response."; return }
            reports = items; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if epoch == generation { reports = []; self.error = "Moderation queue unavailable. Check your admin session and MFA." } }
    }
    @MainActor private func decide(_ action: String, report: ModerationReport?, submittedNote: String) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, let selected = report else { return }
        if action == "remove", let prompt = CommunityServices.admin.stepUpPrompt(for: "moderation.remove") { stepUp = prompt; return }
        stepUp = nil
        let epoch = generation; busy = true
        defer { if CommunityOperationContext.isCurrent, epoch == generation { busy = false } }
        do {
            let response: ModerationResponse = try await adminRPC("sdi_moderation_action", params: ModerationRequest(action: action, report: selected.id, version: selected.version, note: submittedNote))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, epoch == generation else { return }
            if let problem = response.error { error = problem; busy = false; return }
            guard response.status == "confirmed" else { error = "Decision was not confirmed."; busy = false; return }
            busy = false; await load()
        } catch {
            guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent, epoch == generation else { return }
            self.error = "Decision was not confirmed. Refresh before retrying."
        }
    }
}
private struct ModerationRequest: Encodable { let action: String; var report: UUID? = nil; var version: Int? = nil; var note = "" }
private struct ModerationResponse: CommunityResponse { let error: String?; let status: String?; let reports: [ModerationReport]? }

// MARK: - Reusable Info Card
struct AdminInfoCard: View {
    let title: String
    let value: String
    let detail: String
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            Spacer()
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
                .multilineTextAlignment(.trailing)
        }
        .padding(12)
        .background(Color(hex: "12121A"))
        .cornerRadius(12)
    }
}

/// Decisions are authorized by the server with MFA and bound to exact render
/// digest/version. Opening this tab or seeing an admin label grants no authority.
@MainActor
private struct AdminVideoApprovalContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var reviews: [RenderReview] = []
    @State private var owner = false
    @State private var loading = false
    @State private var error: String?
    @State private var note = ""
    @State private var selected: RenderReview?
    @State private var player: AVPlayer?
    @State private var acknowledged = false
    @State private var history: [AdminRenderDecisionRecord] = []
    @State private var historyNote: String?
    @State private var generation = UUID()
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }
    private var identity: String { "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Video approvals").font(.specialElite(22))
            if let error { Text(error).foregroundColor(.red) }
            Button("Refresh review queue") { requests.enqueue { _ in await load() } }.disabled(loading || requests.working)
            if loading { ProgressView() }
            if let selected {
                Text(selected.title).font(.specialElite(18))
                if let player { VideoPlayer(player: player).frame(minHeight: 240) }
                Button("Renew private preview") { requests.enqueue { _ in await renewPreview(review: selected) } }
                    .disabled(loading || requests.working || AppConfig.uploadServiceURL == nil)
                    .accessibilityIdentifier("admin.review.renew-preview")
                if AppConfig.uploadServiceURL == nil {
                    Text("Private preview renewal is not configured in this build.").font(.caption)
                }
                Text("Source: \(selected.source_revision)").font(.caption)
                Text("Render: \(selected.render_digest)").font(.caption.monospaced()).textSelection(.enabled)
                Text("Consent: \(selected.consent_version)").font(.caption)
                Text(selected.rights_summary)
                Text("Destinations: \(selected.destinations.joined(separator: ", "))")
                // Real submission evidence (#213/#214); "not supplied" only when the field is null.
                VStack(alignment: .leading, spacing: 3) {
                    let story = AdminReviewEvidence.storyboardLines(selected.storyboard)
                    if story.isEmpty {
                        Text("Script and storyboard: not supplied for this render. The decision binds to the exact rendered video, its source revision, consent and destinations above.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(story.enumerated()), id: \.offset) { Text($0.element).textSelection(.enabled) }
                    }
                }
                .font(.caption)
                .accessibilityIdentifier("admin.review.storyboard")
                Text(AdminReviewEvidence.digestLine(selected.source_project_digest))
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("admin.review.project-digest")
                VStack(alignment: .leading, spacing: 3) {
                    let quality = AdminReviewEvidence.qualityLines(selected.quality_report)
                    if quality.isEmpty {
                        Text("Quality report: not supplied for this render.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(quality.enumerated()), id: \.offset) { Text($0.element) }
                    }
                }
                .font(.caption)
                .accessibilityIdentifier("admin.review.quality")
                Text("Any change to the render, storyboard or project digest returns this review to pending under a new version; an earlier approval does not carry over.")
                    .font(.caption2).foregroundStyle(.secondary)
                if selected.spatter_generated { Text("Spatter video — owner approval required").foregroundColor(.red) }
                DisclosureGroup("Decision history for this render (\(history.count))") {
                    if let historyNote { Text(historyNote).font(.caption) }
                    ForEach(history) { decision in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(decision.decision) · version \(decision.review_version) · \(decision.created_at.formatted())").font(.caption)
                            Text(decision.owner_at_decision ? "Owner at decision time" : "Administrator at decision time").font(.caption)
                            Text("Render: \(decision.render_digest.prefix(16))…").font(.caption.monospaced())
                            if !decision.note.isEmpty { Text(decision.note).font(.caption) }
                        }.padding(.vertical, 3)
                    }
                }.font(.caption).accessibilityIdentifier("admin.review.history")
                Toggle("I reviewed this exact video with audio, its rights and its destinations.", isOn: $acknowledged).disabled(requests.working)
                TextField("Decision notes / rights evidence", text: $note, axis: .vertical).lineLimit(2...5).disabled(requests.working)
                Text(selected.rights_cleared ? "Rights cleared — publication still needs a separate approval." : "Rights pending — record the evidence reviewed before approving.")
                    .font(.caption)
                Button(selected.rights_cleared ? "Revoke rights clearance" : "Record rights clearance") {
                    requests.enqueue { [note, acknowledged] _ in await recordRights(cleared: !selected.rights_cleared, review: selected, submittedNote: note, reviewed: acknowledged) }
                }
                .disabled(loading || requests.working || !acknowledged || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 2000 || (selected.spatter_generated && !owner))
                .accessibilityIdentifier("admin.review.rights")
                HStack {
                    Button("Approve") { requests.enqueue { [note, acknowledged, owner] _ in await decide("approved", review: selected, submittedNote: note, reviewed: acknowledged, ownerAtTap: owner) } }
                        .disabled(!acknowledged || !selected.rights_cleared || (selected.spatter_generated && !owner) || selected.preview_expires_at <= Date() || loading || requests.working)
                    Button("Request changes") { requests.enqueue { [note, acknowledged, owner] _ in await decide("changes", review: selected, submittedNote: note, reviewed: acknowledged, ownerAtTap: owner) } }.disabled(loading || requests.working)
                    Button("Reject", role: .destructive) { requests.enqueue { [note, acknowledged, owner] _ in await decide("rejected", review: selected, submittedNote: note, reviewed: acknowledged, ownerAtTap: owner) } }.disabled(loading || requests.working)
                }
            }
            ForEach(reviews) { review in
                Button(review.title) {
                    guard requests.capture().isCurrent, !requests.working else { return }
                    player?.pause(); selected = review; note = ""; acknowledged = false; player = nil
                    history = []; historyNote = nil
                    requests.enqueue { _ in await loadHistory(review.id) }
                    guard review.preview_expires_at > Date(), let parts = URLComponents(string: review.preview_url),
                          parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
                          let url = parts.url else { error = "Preview expired or unavailable. Refresh the queue."; return }
                    player = AVPlayer(url: url)
                }.font(.specialElite(16)).padding(10).accessibilityIdentifier("admin.review.select")
            }
            if reviews.isEmpty && !loading && error == nil { Text("No pending renders.") }
        }
        .adminRequestLifetime(requests, disableWhileWorking: false,
            reset: { generation = UUID(); loading = false; reviews = []; owner = false; selected = nil; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; acknowledged = false; note = ""; error = nil; history = []; historyNote = nil },
            initial: { await load() },
            pause: { loading = false; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; acknowledged = false })

    }
    @MainActor private func load() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !loading, auth.isAuthenticated else { return }
        let revision = generation; loading = true
        defer { if CommunityOperationContext.isCurrent { if revision == generation { loading = false } } }
        do {
            let response: ReviewResponse = try await adminRPC("sdi_review_action", params: ReviewRequest(action: "list"))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, revision == generation else { return }
            player?.pause(); player = nil; selected = nil; acknowledged = false
            if let problem = response.error { reviews = []; owner = false; error = problem; return }
            guard let items = response.reviews, let isOwner = response.owner else { error = "Invalid review response."; return }
            reviews = items; owner = isOwner; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if revision == generation { reviews = []; owner = false; self.error = "Review queue unavailable. Check your administrator session and MFA." } }
    }
    /// Earlier decisions on the same render from the audited history (latest
    /// pages only; the note says how far the search went).
    @MainActor private func loadHistory(_ review: UUID) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        let revision = generation
        do {
            let result = try await CommunityServices.admin.decisions(for: review, pages: 3)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, revision == generation, selected?.id == review else { return }
            history = result.records
            historyNote = result.records.isEmpty ? "No earlier decisions in the latest \(result.searchedPages * 50) history records." : "Searched the latest \(result.searchedPages * 50) history records."
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if revision == generation, selected?.id == review { historyNote = "Decision history unavailable: \(CommunityGateway.normalize(error).errorDescription ?? "")" } }
    }
    @MainActor private func decide(_ decision: String, review: RenderReview?, submittedNote: String, reviewed: Bool, ownerAtTap: Bool) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !loading, let selected = review, submittedNote.count <= 2000 else { return }
        guard decision != "approved" || (reviewed && selected.rights_cleared && (!selected.spatter_generated || ownerAtTap) && selected.preview_expires_at > Date()) else { return }
        let revision = generation; loading = true
        do {
            let payload = ReviewRequest(action: "decide", review: selected.id, digest: selected.render_digest, version: selected.version, decision: decision, note: submittedNote)
            let response: ReviewResponse = try await adminRPC("sdi_review_action", params: payload)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, revision == generation else { return }
            if let problem = response.error { error = problem; loading = false; return }
            guard response.status == "confirmed" else { error = "Decision was not confirmed."; loading = false; return }
            loading = false; await load()
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if revision == generation { loading = false; self.error = "Decision was not confirmed. Reload before retrying." } }
    }
    @MainActor private func renewPreview(review: RenderReview?) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard let scope = CommunityOperationContext.scope else { return }
        guard !loading, let selected = review, auth.isAuthenticated, phase == .active else { return }
        let revision = generation; loading = true
        defer { if CommunityOperationContext.isCurrent { if revision == generation { loading = false } } }
        do {
            let client = try self.client
            guard let session = client.auth.currentSession, !session.isExpired,
                  session.user.id.uuidString.lowercased() == auth.userId?.lowercased() else { throw SDIIntakeClient.Failure.authorization }
            let response: ReviewPreviewRenewal = try await SDIIntakeClient.request(
                path: ["v1", "review-previews", selected.id.uuidString.lowercased(), "renew"],
                body: ReviewPreviewIdentity(digest: selected.render_digest, version: selected.version), token: session.accessToken,
                checkCurrent: { try scope.check() })
            try Task.checkCancellation()
            guard revision == generation, phase == .active, self.selected?.id == selected.id,
                  client.auth.currentSession?.accessToken == session.accessToken else { return }
            guard let origin = AppConfig.renderPreviewOrigin, let url = URL(string: response.preview_url),
                  url.scheme == "https", url.host == origin.host, (url.port ?? 443) == (origin.port ?? 443),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/v1/render-previews/") else { throw SDIIntakeClient.Failure.response }
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expires = fractional.date(from: response.preview_expires_at) ?? ISO8601DateFormatter().date(from: response.preview_expires_at)
            guard let expires, expires > Date(), expires.timeIntervalSinceNow <= 16 * 60 else { throw SDIIntakeClient.Failure.response }
            player?.pause(); player = AVPlayer(url: url); acknowledged = false; error = nil
            self.selected = RenderReview(id: selected.id, title: selected.title, source_revision: selected.source_revision,
                render_digest: selected.render_digest, preview_url: response.preview_url, preview_expires_at: expires,
                consent_version: selected.consent_version, rights_summary: selected.rights_summary,
                rights_cleared: selected.rights_cleared, destinations: selected.destinations,
                spatter_generated: selected.spatter_generated, version: selected.version,
                storyboard: selected.storyboard, source_project_digest: selected.source_project_digest,
                quality_report: selected.quality_report)
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return };
            if revision == generation { self.error = error.localizedDescription }
        }
    }
    @MainActor private func recordRights(cleared: Bool, review: RenderReview?, submittedNote: String, reviewed: Bool) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !loading, reviewed, let selected = review, auth.isAuthenticated, phase == .active,
              !submittedNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, submittedNote.count <= 2000 else { return }
        let revision = generation; loading = true
        do {
            let payload = ReviewRightsRequest(review: selected.id, digest: selected.render_digest,
                version: selected.version, cleared: cleared, note: submittedNote)
            let response: ReviewResponse = try await adminRPC("sdi_review_rights", params: payload)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, revision == generation else { return }
            loading = false
            guard response.error == nil, response.status == "confirmed" else {
                error = response.error ?? "Rights decision was not confirmed. Refresh before retrying."; return
            }
            // Refetch the changed version; never apply approval to the stale capture.
            player?.pause(); player = nil; self.selected = nil; acknowledged = false; note = ""
            await load()
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return };
            if revision == generation { loading = false; self.error = "Rights decision was not confirmed. Refresh before retrying." }
        }
    }

}
private struct ReviewPreviewIdentity: Encodable { let digest: String; let version: Int }
private struct ReviewPreviewRenewal: Decodable { let preview_url: String; let preview_expires_at: String }
private struct ReviewRightsRequest: Encodable {
    let review: UUID; let digest: String; let version: Int; let cleared: Bool; let note: String
}
private struct ReviewRequest: Encodable {
    let action: String
    var review: UUID? = nil; var digest: String? = nil; var version: Int? = nil; var decision: String? = nil; var note = ""
}
private struct ReviewResponse: CommunityResponse {
    let error: String?; let status: String?; let reviews: [RenderReview]?; let owner: Bool?
}
private struct RenderReview: Decodable, Identifiable {
    let id: UUID; let title: String; let source_revision: String; let render_digest: String
    let preview_url: String; let preview_expires_at: Date; let consent_version: String; let rights_summary: String
    let rights_cleared: Bool; let destinations: [String]; let spatter_generated: Bool; let version: Int
    /// Null when the render was submitted without them (#214).
    var storyboard: CommunityJSONValue? = nil
    var source_project_digest: String? = nil
    var quality_report: CommunityJSONValue? = nil
}

@MainActor
private struct AdminPublishingContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var jobs: [AdminPublishJob] = []
    @State private var selected: AdminPublishJob?
    @State private var history: [AdminPublishEvent] = []
    @State private var reason = ""
    @State private var page = 0
    @State private var requestID = UUID()
    @State private var busy = false
    @State private var error: String?
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Publishing operations").font(.specialElite(22))
            Text("Withdrawal makes the channel copy private after provider confirmation. It preserves the creator’s original.").font(.caption)
            HStack {
                Button("Refresh") { requests.enqueue { [page] _ in await load(submittedPage: page) } }
                Spacer()
                Button("Previous") { requests.enqueue { [target = page - 1] _ in page = target; await load(submittedPage: target) } }.disabled(page == 0)
                Text("\(page + 1)").font(.caption)
                Button("Next") { requests.enqueue { [target = page + 1] _ in page = target; await load(submittedPage: target) } }.disabled(jobs.count < 50 || page >= 199)
            }.disabled(busy)
            if busy { ProgressView() }
            if let error { Text(error).foregroundColor(.red) }
            if let selected {
                Text(selected.title).font(.specialElite(18))
                Text("\(selected.destination) · \(selected.state) · \(selected.phase)")
                AdminPublishStageView(stage: selected.stage)
                Text("Upload attempts: \(selected.attempts) · Withdrawal attempts: \(selected.removal_attempts)").font(.caption)
                Text(selected.render_digest).font(.caption.monospaced()).textSelection(.enabled)
                if let provider = selected.provider_id { Text("Provider video: \(provider)").font(.caption) }
                if let message = selected.last_error { Text(message).font(.caption) }
                if let url = publicLink(selected) { Link("Open confirmed publication", destination: url) }
                TextField("Required action reason", text: $reason, axis: .vertical).lineLimit(2...5)
                Button("Cancel / withdraw from channel", role: .destructive) {
                    requests.enqueue { [reason] _ in await act("withdraw", job: selected, submittedReason: reason) }
                }.disabled(!canAct || selected.state == "cancelled" || selected.destination != "youtube")
                if selected.state == "removal_pending" {
                    Button("Retry withdrawal") { requests.enqueue { [reason] _ in await act("retry_withdrawal", job: selected, submittedReason: reason) } }.disabled(!canAct)
                }
                if selected.state == "reconcile" {
                    Text("Provider outcome is uncertain. Server reconciliation is required before any release retry.").font(.caption)
                }
                Text("Administrator action history").font(.specialElite(16))
                ForEach(history) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(event.action) · \(event.created_at.formatted())").font(.caption)
                        Text(event.reason)
                        Text("Previous state: \(event.previous_state) · revision \(event.job_revision)").font(.caption)
                    }.padding(.vertical, 4)
                }
            }
            ForEach(jobs) { job in
                Button { requests.enqueue { _ in await select(job) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.title).font(.specialElite(16))
                        Text("\(job.destination) · \(job.stage.title) · \(job.updated_at.formatted())").font(.caption)
                            .accessibilityIdentifier("admin.publishing.stage")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.disabled(busy)
            }
            if jobs.isEmpty && !busy && error == nil { Text("No publishing jobs on this page.") }
        }
        .adminRequestLifetime(requests,
            reset: { clear() },
            initial: { await load() },
            pause: { busy = false })

    }
    private var canAct: Bool {
        !busy && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reason.count <= 2000
    }
    private func publicLink(_ job: AdminPublishJob) -> URL? {
        guard job.state == "published", let value = job.result_url,
              let parts = URLComponents(string: value), parts.scheme == "https",
              parts.host == "www.youtube.com", parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
    private func clear() {
        requestID = UUID(); busy = false; jobs = []; selected = nil; history = []; reason = ""; error = nil; page = 0
    }
    private func load(submittedPage: Int? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true; selected = nil; history = []
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let result: AdminPublishingResponse = try await adminRPC("sdi_publishing_admin", params: AdminPublishingRequest(action: "list", page: submittedPage ?? page))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            guard result.error == nil, let items = result.jobs else { jobs = []; error = result.error ?? "Invalid publishing response."; return }
            jobs = items; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { jobs = []; self.error = "Publishing queue unavailable. Check admin authorization and MFA." } }
    }
    private func select(_ job: AdminPublishJob) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy else { return }
        let id = UUID(); requestID = id; busy = true; selected = job; history = []; reason = ""; error = nil
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let result: AdminPublishingResponse = try await adminRPC("sdi_publishing_admin", params: AdminPublishingRequest(action: "history", job: job.id))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            guard result.error == nil, let events = result.history else { error = result.error ?? "History unavailable."; return }
            history = events
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { self.error = "History unavailable. Refresh before acting." } }
    }
    private func act(_ action: String, job: AdminPublishJob?, submittedReason: String) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, !submittedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, submittedReason.count <= 2000, let selected = job else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let result: AdminPublishingResponse = try await adminRPC("sdi_publishing_admin", params: AdminPublishingRequest(action: action, job: selected.id, revision: selected.revision, reason: submittedReason))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            guard result.error == nil, result.status == "confirmed" else { error = result.error ?? "Action was not confirmed."; return }
            busy = false; await load()
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { self.error = "Action outcome unavailable. Refresh status before retrying." } }
    }
}
@MainActor
private struct AdminReviewHistoryContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var decisions: [AdminRenderDecisionRecord] = []
    @State private var page = 0
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Video decision history").font(.specialElite(22))
            Text("These records describe the render and permissions at the time of each decision. Later edits require a new approval.").font(.caption)
            HStack {
                Button("Refresh") { requests.enqueue { [page] _ in await load(submittedPage: page) } }
                Spacer()
                Button("Previous") { requests.enqueue { [target = page - 1] _ in page = target; await load(submittedPage: target) } }.disabled(page == 0)
                Text("\(page + 1)").font(.caption)
                Button("Next") { requests.enqueue { [target = page + 1] _ in page = target; await load(submittedPage: target) } }.disabled(decisions.count < 50 || page >= 199)
            }.disabled(busy)
            if busy { ProgressView() }
            if let error { Text(error).foregroundColor(.red) }
            ForEach(decisions) { decision in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Source: \(decision.source_revision)")
                        Text("Render: \(decision.render_digest)").font(.caption.monospaced()).textSelection(.enabled)
                        Text("Review version: \(decision.review_version)")
                        Text("Consent: \(decision.consent_version)")
                        Text("Destinations: \(decision.destinations.joined(separator: ", "))")
                        Text(decision.rights_summary)
                        Text("Decision by: \(decision.actor.uuidString)").font(.caption)
                        Text(decision.owner_at_decision ? "Owner at decision time" : "Administrator at decision time").font(.caption)
                        if !decision.note.isEmpty { Text(decision.note) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                } label: {
                    VStack(alignment: .leading) {
                        Text(decision.render_title).font(.specialElite(17))
                        Text("\(decision.decision) · \(decision.created_at.formatted())").font(.caption)
                    }
                }.padding(10)
            }
            if decisions.isEmpty && !busy && error == nil { Text("No decisions on this page.") }
        }
        .adminRequestLifetime(requests,
            reset: { clear() },
            initial: { await load() },
            pause: { busy = false })

    }
    private func clear() { requestID = UUID(); busy = false; decisions = []; page = 0; error = nil }
    private func load(submittedPage: Int? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let items = try await CommunityServices.admin.reviewHistory(page: submittedPage ?? page)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            decisions = items; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { decisions = []; self.error = CommunityGateway.normalize(error).errorDescription } }
    }
}

@MainActor
private struct AdminWarReportsContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var reports: [AdminWarReport] = []
    @State private var selected: AdminWarReport?
    @State private var reason = ""
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var error: String?
    @State private var stepUp: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("War Room reports").font(.specialElite(22))
            Button("Refresh reports") { requests.enqueue { [payload = AdminWarRequest(action: "list", report: nil, revision: nil, reason: reason)] _ in await request("list", submitted: payload) } }.disabled(busy)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let stepUp { AdminStepUpBanner(message: stepUp) }
            if let selected {
                Text(selected.reason)
                Text("Match state: \(selected.status)").font(.caption)
                AdminModerationPreviewButton(target: selected.previewTarget(right: false), title: selected.left_title).id("left-" + selected.id.uuidString)
                if let title = selected.right_title { AdminModerationPreviewButton(target: selected.previewTarget(right: true), title: title).id("right-" + selected.id.uuidString) }
                TextField("Required decision reason", text: $reason, axis: .vertical).lineLimit(2...5)
                Text("Removing a matchup hides it and excludes its result from profile totals. Media remains intact; video takedown is a separate decision.").font(.caption)
                HStack {
                    Button("Dismiss") { requests.enqueue { [payload = AdminWarRequest(action: "dismiss", report: selected.id, revision: selected.revision, reason: reason)] _ in await request("dismiss", submitted: payload) } }
                    Button("Remove matchup", role: .destructive) { requests.enqueue { [payload = AdminWarRequest(action: "remove", report: selected.id, revision: selected.revision, reason: reason)] _ in await request("remove", submitted: payload) } }
                }.disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 2000)
            }
            ForEach(reports) { report in
                Button {
                    selected = report; reason = ""; error = nil
                } label: {
                    VStack(alignment: .leading) {
                        Text(report.left_title).font(.specialElite(16))
                        Text("\(report.reason) · \(report.created_at.formatted())").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.disabled(busy)
            }
            if reports.isEmpty && !busy && error == nil { Text("No pending War Room reports.") }
        }
        .adminRequestLifetime(requests,
            reset: { clear(); stepUp = nil },
            initial: { await request("list") },
            pause: { busy = false })

    }
    private func clear() { requestID = UUID(); busy = false; reports = []; selected = nil; reason = ""; error = nil }
    private func request(_ action: String, submitted: AdminWarRequest? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        if action == "remove", let prompt = CommunityServices.admin.stepUpPrompt(for: "war.remove") { stepUp = prompt; return }
        stepUp = nil
        if action == "list" { selected = nil }
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let result: AdminWarResponse = try await adminRPC("sdi_war_moderate", params: submitted ?? AdminWarRequest(action: action, report: selected?.id, revision: selected?.revision, reason: reason))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            if let issue = result.error { error = issue; return }
            if action == "list", let items = result.reports {
                reports = items; selected = nil; error = nil
            } else if result.status == "confirmed" { busy = false; await request("list") }
            else { error = "Response incomplete. Refresh before retrying." }
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { reports = []; selected = nil; self.error = "Moderation unavailable. Check admin session and MFA." } }
    }
}
private struct AdminWarRequest: Encodable { let action: String; let report: UUID?; let revision: Int?; let reason: String }
private struct AdminWarResponse: CommunityResponse { let error: String?; let status: String?; let reports: [AdminWarReport]? }

@MainActor
private struct AdminWarAppealsContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var appeals: [AdminWarAppeal] = []
    @State private var selected: AdminWarAppeal?
    @State private var note = ""
    @State private var reviewed = false
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var error: String?
    @State private var stepUp: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("War Room appeals").font(.specialElite(22))
            Button("Refresh appeals") { requests.enqueue { [payload = AdminWarAppealRequest(action: "list", appeal: nil, revision: nil, note: note), reviewed] _ in await request("list", submitted: payload, reviewedAtTap: reviewed) } }.disabled(busy)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let stepUp { AdminStepUpBanner(message: stepUp) }
            if let selected {
                Text("Original decision").font(.specialElite(18))
                Text(selected.decision_reason)
                Text("Prior match state: \(selected.previous_status)").font(.caption)
                Text("Participant appeal").font(.specialElite(18))
                Text(selected.explanation)
                AdminModerationPreviewButton(target: selected.previewTarget(right: false), title: selected.left_title).id("left-" + selected.id.uuidString)
                Text(selected.left_digest).font(.caption.monospaced()).textSelection(.enabled)
                if let title = selected.right_title {
                    AdminModerationPreviewButton(target: selected.previewTarget(right: true), title: title).id("right-" + selected.id.uuidString)
                    Text(selected.right_digest ?? "Digest unavailable").font(.caption.monospaced()).textSelection(.enabled)
                }
                Toggle("I reviewed the decision, appeal and submitted videos.", isOn: $reviewed)
                TextField("Required appeal decision reason", text: $note, axis: .vertical).lineLimit(2...6)
                Text("Accepting restores the previous matchup state only if the server confirms that no newer restriction applies and the exact media remain approved. It does not change votes or create a reward.").font(.caption)
                HStack {
                    Button("Accept and restore") { requests.enqueue { [payload = AdminWarAppealRequest(action: "accept", appeal: selected.id, revision: selected.revision, note: note), reviewed] _ in await request("accept", submitted: payload, reviewedAtTap: reviewed) } }
                    Button("Reject appeal", role: .destructive) { requests.enqueue { [payload = AdminWarAppealRequest(action: "reject", appeal: selected.id, revision: selected.revision, note: note), reviewed] _ in await request("reject", submitted: payload, reviewedAtTap: reviewed) } }
                }.disabled(busy || !reviewed || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 2000)
            }
            ForEach(appeals) { appeal in
                Button {
                    selected = appeal; note = ""; reviewed = false; error = nil
                } label: {
                    VStack(alignment: .leading) {
                        Text(appeal.left_title).font(.specialElite(16))
                        Text(appeal.created_at.formatted()).font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.disabled(busy)
            }
            if appeals.isEmpty && !busy && error == nil { Text("No pending appeals.") }
        }
        .adminRequestLifetime(requests,
            reset: { clear() },
            initial: { await request("list") },
            pause: { busy = false })

    }
    private func clear() { requestID = UUID(); busy = false; appeals = []; selected = nil; note = ""; reviewed = false; error = nil; stepUp = nil }
    private func request(_ action: String, submitted: AdminWarAppealRequest? = nil, reviewedAtTap: Bool = true) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        guard action == "list" || reviewedAtTap else { return }
        if action == "accept" || action == "reject", let prompt = CommunityServices.admin.stepUpPrompt(for: "appeal." + action) { stepUp = prompt; return }
        stepUp = nil
        if action == "list" { selected = nil }
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let response: AdminWarAppealResponse = try await adminRPC("sdi_war_appeal_admin", params: submitted ?? AdminWarAppealRequest(action: action, appeal: selected?.id, revision: selected?.revision, note: note))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            if let problem = response.error {
                let refusal = CommunityServices.admin.noteRefusal(CommunityError.server(message: problem, code: response.code))
                if refusal.isStepUpRequired { stepUp = refusal.errorDescription } else { error = refusal.errorDescription }; return
            }
            if action == "list", let items = response.appeals {
                appeals = items; selected = nil; error = nil; reviewed = false
            } else if response.status == "confirmed" { busy = false; await request("list") }
            else { error = "Decision not confirmed. Refresh before retrying." }
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { appeals = []; selected = nil; self.error = "Appeals unavailable. Check admin session and MFA." } }
    }
}
private struct AdminWarAppealRequest: Encodable { let action: String; let appeal: UUID?; let revision: Int?; let note: String }
private struct AdminWarAppealResponse: CommunityResponse { let error: String?; let code: String?; let status: String?; let appeals: [AdminWarAppeal]? }

@MainActor
private struct AdminPermissionsContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var roles: [AdminRoleRecord] = []
    @State private var subject = ""
    @State private var capabilities: Set<String> = []
    @State private var enabled = false
    @State private var revision = 0
    @State private var reason = ""
    @State private var loaded = false
    @State private var busy = false
    @State private var message: String?
    @State private var stepUp: String?
    @State private var requestID = UUID()
    private let available = ["users", "reviews", "moderation", "publishing", "overview", "finance"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Administrator permissions").font(.specialElite(22))
            Text("Owner only. Role changes require a reason, a recent authenticator verification, and sign the affected account out. Ownership and your own role cannot be changed here.").font(.caption)
            Button("Refresh roles") { requests.enqueue { [payload = AdminPermissionsRequest(action: "list", subject: UUID(uuidString: subject), capabilities: capabilities.sorted(), enabled: enabled, reason: reason, revision: revision)] _ in await request("list", submitted: payload) } }.disabled(busy)
            if busy { ProgressView() }
            if let message { Text(message).font(.caption) }
            if let stepUp { AdminStepUpBanner(message: stepUp) }
            if loaded {
                ForEach(roles) { role in
                    Button {
                        subject = role.user_id.uuidString; capabilities = Set(role.permissions); enabled = role.enabled
                        revision = role.revision; reason = ""
                    } label: {
                        VStack(alignment: .leading) {
                            Text(role.user_id.uuidString).font(.caption.monospaced())
                            Text(role.owner ? "Owner — protected" : "\(role.enabled ? "Enabled" : "Disabled") · \(role.permissions.joined(separator: ", "))").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.disabled(busy || role.owner || role.user_id.uuidString.lowercased() == auth.userId?.lowercased())
                }
                Button("Add administrator") { subject = ""; capabilities = []; enabled = false; revision = 0; reason = "" }.disabled(busy)
                TextField("Existing account ID", text: $subject).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(busy || revision > 0)
                Toggle("Administrator enabled", isOn: $enabled).disabled(busy)
                ForEach(available, id: \.self) { capability in
                    Toggle(capability.capitalized, isOn: Binding(get: { capabilities.contains(capability) }, set: {
                        if $0 { capabilities.insert(capability) } else { capabilities.remove(capability) }
                    })).disabled(busy)
                }
                TextField("Required reason", text: $reason, axis: .vertical).lineLimit(2...5)
                Button("Save permissions and revoke sessions") { requests.enqueue { [payload = AdminPermissionsRequest(action: "save", subject: UUID(uuidString: subject), capabilities: capabilities.sorted(), enabled: enabled, reason: reason, revision: revision)] _ in await request("save", submitted: payload) } }
                    .disabled(busy || UUID(uuidString: subject) == nil || subject.lowercased() == auth.userId?.lowercased()
                              || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 2000)
            }
        }
        .adminRequestLifetime(requests,
            reset: { clear() },
            initial: { await request("list") },
            pause: { busy = false })

    }
    private func clear() { requestID = UUID(); busy = false; loaded = false; roles = []; subject = ""; capabilities = []; enabled = false; reason = ""; revision = 0; message = nil }
    private func request(_ action: String, submitted: AdminPermissionsRequest? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        if action == "save", let prompt = CommunityServices.admin.stepUpPrompt(for: "admin_permissions.save") { stepUp = prompt; return }
        stepUp = nil
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let response: AdminPermissionsResponse = try await adminRPC("sdi_admin_permissions", params: submitted ?? AdminPermissionsRequest(action: action, subject: UUID(uuidString: subject), capabilities: capabilities.sorted(), enabled: enabled, reason: reason, revision: revision))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            if let error = response.error {
                if response.code == "step_up_required" { stepUp = error; _ = CommunityServices.admin.noteRefusal(CommunityError.server(message: error, code: response.code)) }
                message = error; if action == "list" { loaded = false; roles = [] }; return
            }
            if action == "list", let items = response.roles { roles = items; loaded = true; subject = ""; capabilities = []; enabled = false; revision = 0; reason = ""; message = nil }
            else if response.status == "confirmed" { busy = false; await request("list") }
            else { message = "Role response unavailable. Refresh before retrying." }
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { loaded = false; roles = []; message = "Role operation not confirmed. Owner MFA and service configuration are required." } }
    }
}
private struct AdminPermissionsRequest: Encodable { let action: String; let subject: UUID?; let capabilities: [String]; let enabled: Bool; let reason: String; let revision: Int }
private struct AdminPermissionsResponse: CommunityResponse { let error: String?; let code: String?; let status: String?; let roles: [AdminRoleRecord]? }
private struct AdminRoleRecord: Decodable, Identifiable {
    let user_id: UUID; let owner: Bool; let enabled: Bool; let permissions: [String]; let revision: Int
    var id: UUID { user_id }
}

private struct AdminPublishingRequest: Encodable {
    let action: String
    var job: UUID? = nil; var revision: Int? = nil; var reason = ""; var page = 0
}
private struct AdminPublishingResponse: CommunityResponse {
    let error: String?; let status: String?; let jobs: [AdminPublishJob]?; let history: [AdminPublishEvent]?
}
private struct AdminPublishJob: Decodable, Identifiable {
    let id: UUID; let title: String; let destination: String; let state: String; let phase: String
    let revision: Int; let attempts: Int; let removal_attempts: Int; let render_digest: String
    let provider_id: String?; let result_url: String?; let last_error: String?; let updated_at: Date
    /// Same words as the creator's status screen (`publish_stage`, #245).
    var stage: AdminPublishStage { AdminPublishStage(state: state, phase: phase, attempts: attempts, providerID: provider_id) }
}

/// Moderation → exact-render approval → transfer → provider processing →
/// visibility → confirmed link. A publishing job exists only after the first
/// two, so they read as complete; off-path outcomes are named, not hidden.
private struct AdminPublishStageView: View {
    let stage: AdminPublishStage
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Stage: \(stage.title)").font(.specialElite(15))
                .foregroundStyle(stage.isOffPath ? StudioCraftTheme.accentText : .primary)
            ForEach(Array(AdminPublishStage.releasePath.enumerated()), id: \.offset) { index, step in
                let done = index < stage.completedSteps
                let current = !stage.isOffPath && index == stage.completedSteps && stage != .published
                Label(step.title, systemImage: done ? "checkmark.circle.fill" : (current ? "arrow.right.circle" : "circle"))
                    .font(.caption).foregroundStyle(done || current ? .primary : .secondary)
            }
            if stage.isOffPath { Text("Left the release path after \(AdminPublishStage.releasePath[max(0, stage.completedSteps - 1)].title.lowercased()).").font(.caption) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("admin.publishing.stages")
    }
}
private struct AdminPublishEvent: Decodable, Identifiable {
    let id: UUID; let actor: UUID; let action: String; let previous_state: String
    let job_revision: Int; let reason: String; let created_at: Date
}


private struct AdminUserAuditEvent: Decodable, Identifiable {
    let id: UUID; let actor: UUID; let subject: UUID
    let action: String; let reason: String; let previous_state: String?; let created_at: Date
}
private struct AdminUserHistoryResponse: CommunityResponse {
    let events: [AdminUserAuditEvent]?; let has_more: Bool?; let error: String?
}
@MainActor
private struct AdminUserHistoryView: View {
    @StateObject private var requests = AdminRequestOwner()
    let user: AdminDirectoryUser
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var events: [AdminUserAuditEvent] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        NavigationStack {
            List {
                Section(user.username) {
                    Text(user.id.uuidString).font(.caption).textSelection(.enabled)
                    Text("Account action history. Reasons may contain private moderation information.")
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
                if !busy && error == nil && events.isEmpty { Text("No recorded account actions.") }
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.action.capitalized).font(.headline)
                        Text(event.created_at.formatted()).font(.caption)
                        Text("Administrator: \(event.actor.uuidString)").font(.caption)
                        if let previous = event.previous_state { Text("Previous account state: \(previous)") }
                        Text(event.reason).textSelection(.enabled)
                    }
                }
                if more && page < 20 { Button("Load older actions") { requests.enqueue { [page] _ in await load(submittedPage: page) } }.disabled(busy) }
                if more && page >= 20 { Text("Showing the latest 1,000 actions. Refresh to see new actions.") }
            }
            .navigationTitle("Account history")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh") { requests.enqueue { _ in await reset() } }.disabled(busy) }
            }
            .adminRequestLifetime(requests,
            reset: { generation = UUID(); events = []; error = nil; busy = false; page = 0; more = false },
            initial: { await reset() },
            pause: { busy = false })

        }.preferredColorScheme(.dark)
    }
    @MainActor private func reset() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        generation = UUID(); events = []; page = 0; more = false; error = nil; busy = false
        if phase == .active && auth.isAuthenticated { await load() }
    }
    @MainActor private func load(submittedPage: Int? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active, page < 20 else { return }
        let request = generation; let account = auth.userId
        busy = true; defer { if CommunityOperationContext.isCurrent { if generation == request { busy = false } } }
        do {
            let result: AdminUserHistoryResponse = try await adminRPC("sdi_users_action",
                params: AdminUserRequest(action: "history", subject: user.id, page: submittedPage ?? page))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, generation == request, account == auth.userId, phase == .active else { return }
            guard result.error == nil, let items = result.events, let hasMore = result.has_more,
                  items.count <= 50, items.allSatisfy({ $0.subject == user.id && $0.reason.count <= 2000 }) else {
                events = []; error = result.error ?? "Invalid account history response."; more = false; return
            }
            let known = Set(events.map(\.id))
            events.append(contentsOf: items.filter { !known.contains($0.id) })
            page += 1; more = hasMore; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return };
            if generation == request { events = []; more = false; self.error = "Account history unavailable. Check administrator authorization and MFA." }
        }
    }
}


/// Structured restriction review only; this is not user-to-user messaging.
@MainActor
struct AccountAppealsView: View {
    @StateObject private var requests = AdminRequestOwner()
    var administrator = false
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AccountAppealEntry] = []
    @State private var accountState: String?
    @State private var restriction: String?
    @State private var canAppeal = false
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false
    @State private var generation = UUID()
    @State private var decision: AccountAppealDecision?
    var body: some View {
        NavigationStack {
            List {
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
                if let accountState { Text("Account: \(accountState.capitalized)") }
                if administrator || canAppeal {
                    Section(administrator ? "Member-visible decision reason" : "Request a review") {
                        TextField(administrator ? "Explain your decision" : "Explain why this restriction should be reviewed",
                                  text: $text, axis: .vertical).lineLimit(3...8)
                        Text("\(text.count)/2000 characters").font(.caption)
                        if !administrator {
                            Button("Submit appeal") { requests.enqueue { [payload = AccountAppealRequest(action: "submit", appeal: nil, explanation: text, reply: "", restriction: restriction)] _ in await perform("submit", submitted: payload) } }
                                .disabled(busy || !validText)
                            Text("One request per restriction. Your request and the decision appear here.").font(.caption)
                        }
                    }
                }
                if !busy && error == nil && items.isEmpty { Text("No account appeals to show.") }
                ForEach(items) { item in
                    Section {
                        if let subject = item.subject { Text("Account: \(subject.uuidString)").font(.caption).textSelection(.enabled) }
                        Text(item.state.capitalized).font(.headline)
                        Text(item.created_at.formatted()).font(.caption)
                        Text(item.explanation).textSelection(.enabled)
                        if let reply = item.reply { Text("Decision: \(reply)").textSelection(.enabled) }
                        if let date = item.decided_at { Text(date.formatted()).font(.caption) }
                        if administrator {
                            Button("Accept and restore access") { decision = .init(action: "accept", item: item, reply: text, generation: generation, scope: requests.capture()) }
                                .disabled(busy || !validText)
                            Button("Reject appeal", role: .destructive) { decision = .init(action: "reject", item: item, reply: text, generation: generation, scope: requests.capture()) }
                                .disabled(busy || !validText)
                        }
                    }
                }
            }
            .navigationTitle(administrator ? "Account appeals" : "Account status")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh") { requests.enqueue { _ in await refresh() } }.disabled(busy) }
            }
            .confirmationDialog("Confirm appeal decision", isPresented: Binding(get: { decision != nil },
                set: { if !$0 { decision = nil } }), titleVisibility: .visible, presenting: decision) { pending in
                Button(pending.action == "accept" ? "Restore access" : "Reject appeal") {
                    requests.enqueue(origin: pending.scope) { [restriction] _ in
                        guard pending.generation == generation else { return }
                        await perform(pending.action, submitted: AccountAppealRequest(action: pending.action, appeal: pending.item.id, explanation: "", reply: pending.reply, restriction: restriction))
                    }
                }
                Button("Cancel", role: .cancel) { decision = nil }
            } message: { pending in
                Text("Account: \(pending.item.subject?.uuidString ?? "Unavailable")\nMember-visible reason: \(pending.reply)")
            }
            .adminRequestLifetime(requests,
            reset: { generation = UUID(); items = []; text = ""; decision = nil; accountState = nil; restriction = nil; canAppeal = false; error = nil; busy = false },
            initial: { await refresh() },
            pause: { busy = false; decision = nil })

        }.preferredColorScheme(.dark)
    }
    private var validText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 2000 }
    @MainActor private func refresh() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        generation = UUID(); items = []; text = ""; decision = nil; error = nil; accountState = nil; restriction = nil; canAppeal = false; busy = false
        await perform(administrator ? "queue" : "mine")
    }
    @MainActor private func perform(_ action: String, appeal: UUID? = nil, explanation: String = "", reply: String = "", submitted: AccountAppealRequest? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let epoch = generation; let account = auth.userId
        busy = true; defer { if CommunityOperationContext.isCurrent { if generation == epoch { busy = false } } }
        do {
            let response: AccountAppealResponse = try await adminRPC("sdi_account_appeal_action",
                params: submitted ?? AccountAppealRequest(action: action, appeal: appeal, explanation: explanation, reply: reply, restriction: restriction))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, generation == epoch, account == auth.userId, phase == .active else { return }
            if let problem = response.error { error = problem; return }
            if action == "accept" || action == "reject" {
                guard response.status == "confirmed" || response.status == "superseded" else { error = "Decision not confirmed. Refresh before retrying."; return }
                busy = false; await refresh(); return
            }
            guard let records = response.appeals, records.count <= (administrator ? 50 : 20) else {
                error = "Invalid appeal response."; return
            }
            items = records; accountState = response.account_state; restriction = response.restriction
            canAppeal = response.can_appeal == true && restriction != nil
            text = ""; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return };
            if generation == epoch { items = []; canAppeal = false; self.error = "Appeal service unavailable. Sign in again and refresh before retrying." }
        }
    }
}
private struct AccountAppealEntry: Decodable, Identifiable {
    let id: UUID; let subject: UUID?; let explanation: String; let state: String
    let reply: String?; let created_at: Date; let decided_at: Date?
}
private struct AccountAppealDecision {
    let action: String; let item: AccountAppealEntry; let reply: String; let generation: UUID; let scope: CommunityOperationScope
}
private struct AccountAppealRequest: Encodable {
    let action: String; let appeal: UUID?; let explanation: String; let reply: String; let restriction: String?
}
private struct AccountAppealResponse: CommunityResponse {
    let error: String?; let status: String?; let appeals: [AccountAppealEntry]?
    let account_state: String?; let can_appeal: Bool?; let restriction: String?
}


// MARK: - Service health (#257)
/// Authenticated queue depth, oldest pending items, worker liveness, the agent
/// emergency stop and 24-hour denials from `sdi_admin_health`. Hostnames,
/// credentials and backups are deliberately absent from the contract.
@MainActor
private struct AdminHealthContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var health: AdminHealthResponse?
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Service health").font(.specialElite(22))
            Text("Queue counts and worker heartbeats as recorded by the database. Backup, rollback and release operations are not exposed to this client; nothing here opens a terminal or control endpoint.").font(.caption)
            Button("Refresh health") { requests.enqueue { _ in await load() } }.disabled(busy).accessibilityIdentifier("admin.health.refresh")
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("admin.health.error") }
            if let health {
                if health.emergency_stop == true {
                    Text("AGENT EMERGENCY STOP IS ACTIVE").font(.specialElite(14)).foregroundStyle(StudioCraftTheme.accentText)
                        .accessibilityIdentifier("admin.health.emergency-stop")
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(AdminHealthResponse.queueTitles, id: \.key) { entry in
                        AdminStatCard(icon: "tray.full", label: entry.title,
                                      value: (health.queues?[entry.key] ?? nil).map(String.init) ?? "not installed", color: "EF4444")
                    }
                }
                if let oldest = health.oldest_pending, oldest.contains(where: { $0.value != nil }) {
                    Text("Oldest pending").font(.specialElite(16))
                    ForEach(oldest.keys.sorted(), id: \.self) { key in
                        if let date = oldest[key] ?? nil {
                            Text("\(key.replacingOccurrences(of: "_", with: " ")): \(date.formatted())").font(.caption)
                        }
                    }
                }
                Text("Workers").font(.specialElite(16))
                if health.workers?.isEmpty ?? true { Text("No worker heartbeats recorded.").font(.caption) }
                ForEach(health.workers ?? []) { worker in
                    HStack {
                        Circle().fill(worker.stale ? StudioCraftTheme.warning : Color.green).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text("\(worker.worker) · seen \(worker.seen_at.formatted())\(worker.stale ? " · stale" : "")").font(.caption)
                    }.accessibilityElement(children: .combine)
                }
                if let denials = health.admin_denials_24h { Text("Administrative denials in the last 24 hours: \(denials)").font(.caption) }
                if let measured = health.measured_at { Text("Measured \(measured.formatted())").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .adminRequestLifetime(requests,
            reset: { clear() },
            initial: { await load() },
            pause: { busy = false })

    }
    private func clear() { requestID = UUID(); busy = false; health = nil; error = nil }
    private func load() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let value = try await CommunityServices.admin.health()
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            health = value; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { health = nil; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
}

// MARK: - Agents (#248)
/// Owner console over `sdi_agent_admin`: registry (paused by default), caps,
/// permissions, versioned instructions, run log and the global emergency stop.
/// Provider credentials never reach this client; caps are configuration only.
@MainActor
private struct AdminAgentsContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var registry: AdminAgentsResponse?
    @State private var selected: AdminAgent?
    @State private var runs: [AdminAgentRun] = []
    @State private var instructions: [AdminAgentInstruction] = []
    @State private var activeVersion: Int?
    @State private var reason = ""
    @State private var daily = ""
    @State private var perRun = ""
    @State private var monthlyMinor = ""
    @State private var perRunCost = ""
    /// The current per-run cost cap was read for the selected agent; caps are not
    /// saved before that, because an omitted value clears it on the server.
    @State private var perRunCostLoaded = false
    @State private var console: AdminAgentConsoleEntry?
    @State private var permissions: Set<String> = []
    @State private var instructionBody = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var stepUp: String?
    @State private var confirmStop: AdminEmergencyStopIntent?
    @State private var requestID = UUID()
    private var reasonValid: Bool { (1...2000).contains(reason.trimmingCharacters(in: .whitespacesAndNewlines).count) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent controls").font(.specialElite(22))
            Text("Agents start paused and run only with published instructions, under daily run, per-run item and monthly cost caps. Changes are owner-only, reason-required and audited. Nothing here spends or publishes.").font(.caption)
            Button("Refresh registry") { requests.enqueue { _ in await load() } }.disabled(busy).accessibilityIdentifier("admin.agents.refresh")
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("admin.agents.error") }
            if let notice { Text(notice).font(.caption) }
            if let stepUp { AdminStepUpBanner(message: stepUp) }
            if let registry {
                HStack {
                    Text(registry.emergency_stop == true ? "Emergency stop ACTIVE" : "Emergency stop clear").font(.specialElite(15))
                        .foregroundStyle(registry.emergency_stop == true ? StudioCraftTheme.accentText : .primary)
                    Spacer()
                    Button(registry.emergency_stop == true ? "Clear emergency stop" : "Emergency stop all agents") {
                        let scope = requests.capture(); guard scope.isCurrent else { return }
                        let enabled = !(registry.emergency_stop == true)
                        confirmStop = AdminEmergencyStopIntent(enabled: enabled,
                            request: .emergencyStop(enabled: enabled, reason: reason), scope: scope)
                    }
                        .disabled(busy || !reasonValid)
                        .accessibilityIdentifier("admin.agents.emergency-stop")
                }
                if let why = registry.emergency_reason, !why.isEmpty { Text("Reason: \(why)").font(.caption) }
                TextField("Required reason for any change", text: $reason, axis: .vertical).lineLimit(2...4)
                    .accessibilityIdentifier("admin.agents.reason")
                ForEach(registry.agents ?? []) { agent in
                    Button {
                        select(agent)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.title).font(.specialElite(16))
                            Text("\(agent.paused ? "Paused" : "Enabled") · instructions v\(agent.active_instruction_version.map(String.init) ?? "none") · \(agent.running) running · \(agent.runs_today)/\(agent.daily_run_cap) runs today · \(agent.failures_7d) failures (7d)").font(.caption)
                            Text("Month cost \(agent.cost_month_minor) of cap \(agent.monthly_cost_cap_minor) (minor units) · permissions \(agent.permissions.isEmpty ? "none" : agent.permissions.joined(separator: ", "))").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.disabled(busy).accessibilityIdentifier("admin.agents.select")
                }
                if registry.agents?.isEmpty ?? true { Text("No agents registered.").font(.caption) }
            }
            if let selected {
                Divider()
                Text(selected.title).font(.specialElite(18))
                HStack {
                    Button(selected.paused ? "Resume" : "Pause") {
                        requests.enqueue { [reason] _ in await run(selected.paused ? .resume : .pause, on: selected, submittedReason: reason) }
                    }.disabled(busy || !reasonValid).accessibilityIdentifier(selected.paused ? "admin.agents.resume" : "admin.agents.pause")
                }
                if let console {
                    Text("Last started \(console.last_started?.formatted() ?? "never") · proposals awaiting decision \(console.pending_proposals.map(String.init) ?? "unavailable")").font(.caption)
                    if let failure = console.last_error, !failure.isEmpty { Text("Last error: \(failure)").font(.caption).foregroundStyle(.red) }
                }
                if selected.paused && selected.active_instruction_version == nil { Text("Publish instructions before this agent can resume.").font(.caption) }
                Text("Caps").font(.specialElite(15))
                HStack {
                    TextField("Daily runs", text: $daily).keyboardType(.numberPad).accessibilityIdentifier("admin.agents.cap-daily")
                    TextField("Items per run", text: $perRun).keyboardType(.numberPad).accessibilityIdentifier("admin.agents.cap-items")
                    TextField("Monthly cost cap (minor units)", text: $monthlyMinor).keyboardType(.numberPad).accessibilityIdentifier("admin.agents.cap-cost")
                }.textFieldStyle(.roundedBorder)
                TextField("Per-run cost cap (minor units, empty for none)", text: $perRunCost).keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder).disabled(!perRunCostLoaded)
                    .accessibilityIdentifier("admin.agents.cap-run-cost")
                if !perRunCostLoaded { Text("The current per-run cost cap has not been read yet; caps cannot be saved until it is, so it is never cleared by accident.").font(.caption) }
                Button("Save caps") {
                    guard let command = AdminAgentCommand.caps(daily: daily, perRunItems: perRun, monthlyCostMinor: monthlyMinor, perRunCostMinor: perRunCost) else {
                        error = "Caps must be whole numbers: daily runs up to 9999, items per run up to 99999, cost caps in minor units."; return
                    }
                    requests.enqueue { [reason] _ in await run(command, on: selected, submittedReason: reason) }
                }.disabled(busy || !reasonValid || !perRunCostLoaded).accessibilityIdentifier("admin.agents.save-caps")
                Text("Permissions").font(.specialElite(15))
                ForEach(["read", "write", "propose"], id: \.self) { permission in
                    Toggle(permission.capitalized, isOn: Binding(get: { permissions.contains(permission) }, set: { on in
                        if on { permissions.insert(permission) } else { permissions.remove(permission) }
                    })).disabled(busy)
                }
                Button("Save permissions") {
                    requests.enqueue { [command = AdminAgentCommand.setPermissions(permissions), reason] _ in await run(command, on: selected, submittedReason: reason) }
                }.disabled(busy || !reasonValid).accessibilityIdentifier("admin.agents.save-permissions")
                Text("Instructions (active v\(activeVersion.map(String.init) ?? "none"))").font(.specialElite(15))
                TextField("New instruction text (publishing creates the next version and activates it)", text: $instructionBody, axis: .vertical).lineLimit(3...10)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("admin.agents.instructions")
                Button("Publish instructions") {
                    requests.enqueue { [command = AdminAgentCommand.publishInstructions(instructionBody), reason] _ in await run(command, on: selected, submittedReason: reason) }
                }.disabled(busy || !reasonValid || instructionBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instructionBody.count > 20_000)
                    .accessibilityIdentifier("admin.agents.publish-instructions")
                ForEach(instructions) { version in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("v\(version.version) · \(version.created_at.formatted())").font(.caption)
                            Text(version.body).font(.caption).lineLimit(3)
                        }
                        Spacer()
                        if version.version != activeVersion {
                            Button("Roll back") {
                                requests.enqueue { [reason] _ in await run(.rollbackInstructions(version: version.version), on: selected, submittedReason: reason) }
                            }.disabled(busy || !reasonValid).accessibilityIdentifier("admin.agents.rollback")
                        }
                    }
                }
                Text("Recent runs").font(.specialElite(15))
                if runs.isEmpty { Text("No runs recorded.").font(.caption) }
                ForEach(runs.prefix(20)) { run in
                    Text("\(run.state) · started \(run.started_at.formatted()) · \(run.items) items · cost \(run.cost_minor)\(run.error.map { " · \($0)" } ?? "")").font(.caption)
                }
            }
        }
        .confirmationDialog("Confirm emergency stop change", isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } }), titleVisibility: .visible, presenting: confirmStop) { intent in
            Button(intent.enabled ? "Stop all agents now" : "Clear emergency stop", role: intent.enabled ? .destructive : nil) {
                confirmStop = nil
                requests.enqueue(origin: intent.scope) { _ in await mutate(intent.request, action: "agent.emergency_stop") }
            }
            Button("Cancel", role: .cancel) { confirmStop = nil }
        } message: { intent in
            Text(intent.enabled ? "Running agent work is marked stopped and no agent may begin until the stop is cleared. Drafts are not deleted." : "Agents remain paused individually until resumed.")
        }
        .adminRequestLifetime(requests,
            reset: { clear() },
            initial: { await load() },
            pause: { busy = false; confirmStop = nil })

    }
    private func clear() {
        requestID = UUID(); busy = false; registry = nil; selected = nil; runs = []; instructions = []; activeVersion = nil
        reason = ""; daily = ""; perRun = ""; monthlyMinor = ""; perRunCost = ""; perRunCostLoaded = false; console = nil
        permissions = []; instructionBody = ""; error = nil; notice = nil; stepUp = nil; confirmStop = nil
    }
    private func select(_ agent: AdminAgent) {
        guard requests.capture().isCurrent, !requests.working else { return }
        selected = agent; daily = String(agent.daily_run_cap); perRun = String(agent.per_run_item_cap)
        monthlyMinor = String(agent.monthly_cost_cap_minor); permissions = Set(agent.permissions); instructionBody = ""
        perRunCost = ""; perRunCostLoaded = false; console = nil
        requests.enqueue { _ in await loadDetail(agent) }
    }
    private func load() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let value = try await CommunityServices.admin.agents()
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            registry = value; error = nil
            if let current = selected, let refreshed = value.agents?.first(where: { $0.key == current.key }) { selected = refreshed } else { selected = nil }
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { registry = nil; selected = nil; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
    private func loadDetail(_ agent: AdminAgent) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        let id = requestID
        do {
            let log = try await CommunityServices.admin.agentRuns(agent.key)
            let history = try await CommunityServices.admin.agentInstructions(agent.key)
            let entry = try await CommunityServices.admin.agentConsole().first { $0.key == agent.key }
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id, selected?.key == agent.key else { return }
            runs = log; instructions = history.versions; activeVersion = history.active
            console = entry
            if let entry { perRunCost = entry.per_run_cost_cap_minor.map(String.init) ?? ""; perRunCostLoaded = true }
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { runs = []; instructions = []; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
    /// One typed owner command (#284): validated client-side, step-up gated,
    /// and confirmed only at the next server revision.
    private func run(_ command: AdminAgentCommand, on agent: AdminAgent, submittedReason: String) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy else { return }
        if let prompt = CommunityServices.admin.stepUpPrompt(for: command.stepUpAction) { stepUp = prompt; return }
        stepUp = nil
        let id = UUID(); requestID = id; busy = true; error = nil; notice = nil
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            _ = try await CommunityServices.admin.runAgentCommand(command, agent: agent.key, revision: agent.revision, reason: submittedReason)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            notice = "Change confirmed and audited."; busy = false; await load()
            if let refreshed = selected, refreshed.key == agent.key {
                selected = refreshed; daily = String(refreshed.daily_run_cap); perRun = String(refreshed.per_run_item_cap)
                monthlyMinor = String(refreshed.monthly_cost_cap_minor); permissions = Set(refreshed.permissions); instructionBody = ""
                perRunCost = ""; perRunCostLoaded = false; console = nil
                await loadDetail(refreshed)
            }
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return };
            guard requestID == id else { return }
            let problem = CommunityServices.admin.noteRefusal(error)
            if problem.isStepUpRequired { stepUp = problem.errorDescription } else { self.error = problem.errorDescription }
        }
    }
    private func mutate(_ request: AdminAgentRequest, action: String) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy else { return }
        if let prompt = CommunityServices.admin.stepUpPrompt(for: action) { stepUp = prompt; return }
        stepUp = nil
        let id = UUID(); requestID = id; busy = true; error = nil; notice = nil
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            _ = try await CommunityServices.admin.mutateAgent(request)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            notice = "Change confirmed and audited."; busy = false; await load()
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return };
            guard requestID == id else { return }
            let problem = CommunityServices.admin.noteRefusal(error)
            if problem.isStepUpRequired { stepUp = problem.errorDescription } else { self.error = problem.errorDescription }
        }
    }
}

// MARK: - Finance (#255)
/// Finance-capability reads of provider-reported records and owner-only
/// product configuration through `sdi_finance_admin`. No balances, estimates
/// or charges; the approved offers are the three monthly tiers.
@MainActor
private struct AdminFinanceContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var section = "summary"
    @State private var page = 0
    @State private var response: AdminFinanceResponse?
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var stepUp: String?
    @State private var productID = ""
    @State private var provider = "apple"
    @State private var tier = "creator"
    @State private var period = "monthly"
    @State private var approved = false
    @State private var reason = ""
    @State private var requestID = UUID()
    private let sections = [("summary", "Summary"), ("products", "Products"), ("subscriptions", "Subscriptions"), ("ledger", "Ledger"), ("events", "Provider events")]
    private var reasonValid: Bool { (1...2000).contains(reason.trimmingCharacters(in: .whitespacesAndNewlines).count) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finance").font(.specialElite(22))
            Text("Provider-reported records in minor units. Sums are not balances; no charge, refund or payout can be made from this client. Approved offers: three monthly tiers at USD 4.99, USD 9.99 and USD 19.99, each with a 3-day free trial configured in App Store Connect; annual periods need explicit owner configuration.").font(.caption)
            Picker("Section", selection: $section) { ForEach(sections, id: \.0) { Text($0.1).tag($0.0) } }
                .pickerStyle(.segmented).accessibilityIdentifier("admin.finance.section")
            HStack {
                Button("Refresh") { requests.enqueue { [section, page] _ in await load(submittedSection: section, submittedPage: page) } }
                Spacer()
                if section != "summary" && section != "products" {
                    Button("Previous") { requests.enqueue { [section, target = page - 1] _ in page = target; await load(submittedSection: section, submittedPage: target) } }.disabled(page == 0)
                    Text("\(page + 1)").font(.caption)
                    Button("Next") { requests.enqueue { [section, target = page + 1] _ in page = target; await load(submittedSection: section, submittedPage: target) } }.disabled(page >= 199 || currentCount < 50)
                }
            }.disabled(busy).accessibilityIdentifier("admin.finance.refresh")
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("admin.finance.error") }
            if let notice { Text(notice).font(.caption) }
            if let stepUp { AdminStepUpBanner(message: stepUp) }
            if let response {
                switch section {
                case "summary":
                    if let label = response.label { Text(label).font(.caption) }
                    if let accounts = response.entitled_accounts { Text("Entitled accounts: \(accounts)").font(.specialElite(15)) }
                    ForEach(response.totals ?? []) { total in Text("\(total.provider) · \(total.kind): \(total.amountText) over \(total.entries) entries").font(.caption) }
                    if response.totals?.isEmpty ?? true { Text("No provider-reported entries.").font(.caption) }
                case "products":
                    if let offers = response.approved_offers { Text(offers).font(.caption) }
                    ForEach(response.products ?? []) { product in
                        Text("\(product.product_id) · \(product.provider) · \(product.tier) \(product.period) · \(product.approved ? "approved" : "not approved")\(product.owner_configured_at == nil && product.period == "annual" ? " · awaiting owner configuration" : "")").font(.caption)
                    }
                    if response.products?.isEmpty ?? true { Text("No product identifiers recorded.").font(.caption) }
                    Divider()
                    Text("Owner: record a product identifier").font(.specialElite(15))
                    TextField("Provider product id", text: $productID).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("admin.finance.product-id")
                    Picker("Provider", selection: $provider) { Text("Apple").tag("apple"); Text("Stripe").tag("stripe") }.pickerStyle(.segmented)
                    Picker("Tier", selection: $tier) { Text("Creator (USD 4.99)").tag("creator"); Text("Pro (USD 9.99)").tag("pro"); Text("Unlimited (USD 19.99)").tag("unlimited") }.pickerStyle(.segmented)
                    Picker("Period", selection: $period) { Text("Monthly").tag("monthly"); Text("Annual (owner configuration required)").tag("annual") }.pickerStyle(.segmented)
                    Toggle("Approved for sale", isOn: $approved)
                    TextField("Required reason", text: $reason, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("admin.finance.reason")
                    Button("Save product") { requests.enqueue { [payload = AdminFinanceRequest(action: "set_product", product: productID, provider: provider, tier: tier, period: period, approved: approved, reason: reason)] _ in await mutate(payload, action: "finance.set_product") } }
                        .disabled(busy || !reasonValid || productID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("admin.finance.save-product")
                    if period == "annual" {
                        Button("Record owner configuration for this annual product") { requests.enqueue { [payload = AdminFinanceRequest(action: "configure_annual", product: productID, reason: reason)] _ in await mutate(payload, action: "finance.configure_annual") } }
                            .disabled(busy || !reasonValid || productID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("admin.finance.configure-annual")
                        Text("Annual amounts live in the provider dashboards; this records only the owner's explicit decision.").font(.caption)
                    }
                case "subscriptions":
                    ForEach(response.subscriptions ?? []) { sub in
                        Text("\(sub.provider) · \(sub.product_id) · \(sub.status)\(sub.paid_through.map { " · paid through \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")\(sub.cancel_at_period_end ? " · cancels at period end" : "") · account \(communityShortID(sub.user_id))").font(.caption)
                    }
                    if response.subscriptions?.isEmpty ?? true { Text("No subscriptions on this page.").font(.caption) }
                case "ledger":
                    if let label = response.label { Text(label).font(.caption) }
                    ForEach(response.ledger ?? []) { entry in
                        Text("\(entry.occurred_at.formatted()) · \(entry.provider) · \(entry.kind) · \(entry.currency.uppercased()) \(String(format: "%.2f", Double(entry.amount_minor) / 100))\(entry.note.map { " · \($0)" } ?? "")").font(.caption)
                    }
                    if response.ledger?.isEmpty ?? true { Text("No ledger entries on this page.").font(.caption) }
                default:
                    ForEach(response.events ?? []) { event in
                        Text("\(event.received_at.formatted()) · \(event.provider) · \(event.event_type) · \(event.processed_at == nil ? "unprocessed" : (event.outcome ?? "processed"))").font(.caption)
                    }
                    if response.events?.isEmpty ?? true { Text("No provider events on this page.").font(.caption) }
                }
            }
        }
        .onChange(of: section) { _, section in requests.cancel(); busy = false; page = 0; requests.enqueue { _ in await load(submittedSection: section, submittedPage: 0) } }
        .adminRequestLifetime(requests,
            reset: { clear(); provider = "apple"; tier = "creator"; period = "monthly"; approved = false },
            initial: { await load() },
            pause: { busy = false })

    }
    private var currentCount: Int {
        switch section {
        case "subscriptions": return response?.subscriptions?.count ?? 0
        case "ledger": return response?.ledger?.count ?? 0
        case "events": return response?.events?.count ?? 0
        default: return 0
        }
    }
    private func clear() { requestID = UUID(); busy = false; response = nil; error = nil; notice = nil; stepUp = nil; page = 0; reason = ""; productID = "" }
    private func load(submittedSection: String? = nil, submittedPage: Int? = nil) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let value = try await CommunityServices.admin.finance(AdminFinanceRequest(action: submittedSection ?? section, page: submittedPage ?? page))
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            response = value; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { response = nil; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
    private func mutate(_ request: AdminFinanceRequest, action: String) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy else { return }
        if let prompt = CommunityServices.admin.stepUpPrompt(for: action) { stepUp = prompt; return }
        stepUp = nil
        let id = UUID(); requestID = id; busy = true; error = nil; notice = nil
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            _ = try await CommunityServices.admin.finance(request)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            notice = "Recorded and audited."; busy = false; await load()
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return };
            guard requestID == id else { return }
            let problem = CommunityServices.admin.noteRefusal(error)
            if problem.isStepUpRequired { stepUp = problem.errorDescription } else { self.error = problem.errorDescription }
        }
    }
}

// MARK: - Room reports (#235, #247)
@MainActor
private struct AdminRoomReportsContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var reports: [AdminRoomReport] = []
    @State private var selected: AdminRoomReport?
    @State private var reason = ""
    @State private var busy = false
    @State private var error: String?
    @State private var stepUp: String?
    @State private var requestID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Room reports").font(.specialElite(22))
            Text("Closing a room ends access for everyone; it never deletes anyone's device project. Reporter identity is not returned. An uninvolved administrator must decide.").font(.caption)
            Button("Refresh reports") { requests.enqueue { _ in await load() } }.disabled(busy).accessibilityIdentifier("admin.rooms.reports.refresh")
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let stepUp { AdminStepUpBanner(message: stepUp) }
            if let selected {
                Text(selected.title).font(.specialElite(18))
                Text("Reason: \(selected.reason)\(selected.detail.isEmpty ? "" : " · \(selected.detail)")")
                Text("Owner \(communityShortID(selected.owner_id)) · \(selected.members) approved members · \(selected.report_count) reports · \(selected.closed ? "closed" : "open")").font(.caption)
                TextField("Required decision reason", text: $reason, axis: .vertical).lineLimit(2...5)
                    .accessibilityIdentifier("admin.rooms.reports.reason")
                HStack {
                    Button("Dismiss") { requests.enqueue { [reason] _ in await decide(close: false, report: selected, submittedReason: reason) } }.accessibilityIdentifier("admin.rooms.reports.dismiss")
                    Button("Close room", role: .destructive) { requests.enqueue { [reason] _ in await decide(close: true, report: selected, submittedReason: reason) } }.accessibilityIdentifier("admin.rooms.reports.close")
                }.disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 2000)
            }
            ForEach(reports) { report in
                Button { selected = report; reason = ""; error = nil } label: {
                    VStack(alignment: .leading) {
                        Text(report.title).font(.specialElite(16))
                        Text("\(report.reason) · \(report.created_at.formatted())").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.disabled(busy).accessibilityIdentifier("admin.rooms.reports.select")
            }
            if reports.isEmpty && !busy && error == nil { Text("No pending room reports.").font(.caption) }
        }
        .adminRequestLifetime(requests,
            reset: { clear() },
            initial: { await load() },
            pause: { busy = false })

    }
    private func clear() { requestID = UUID(); busy = false; reports = []; selected = nil; reason = ""; error = nil; stepUp = nil }
    private func load() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let items = try await CommunityServices.admin.roomReports()
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            reports = items; selected = nil; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { reports = []; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
    private func decide(close: Bool, report: AdminRoomReport?, submittedReason: String) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, let selected = report else { return }
        if close, let prompt = CommunityServices.admin.stepUpPrompt(for: "rooms.close") { stepUp = prompt; return }
        stepUp = nil
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            try await CommunityServices.admin.decideRoomReport(selected, close: close, reason: submittedReason)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            busy = false; await load()
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return };
            guard requestID == id else { return }
            let problem = CommunityServices.admin.noteRefusal(error)
            if problem.isStepUpRequired { stepUp = problem.errorDescription } else { self.error = problem.errorDescription }
        }
    }
}

// MARK: - Feed removal appeals (#247)
@MainActor
private struct AdminRemovalAppealsContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var appeals: [ModerationAppeal] = []
    @State private var selected: ModerationAppeal?
    @State private var note = ""
    @State private var reviewed = false
    @State private var busy = false
    @State private var error: String?
    @State private var stepUp: String?
    @State private var requestID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Feed removal appeals").font(.specialElite(22))
            Text("Acceptance restores the exact removed video only while its hosted copy or verified channel publication remains eligible and no newer restriction applies. Rights or consent withdrawal requires a new approved publication. The decision reason is shown to the member.").font(.caption)
            Button("Refresh appeals") { requests.enqueue { _ in await load() } }.disabled(busy).accessibilityIdentifier("admin.appeals.refresh")
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let stepUp { AdminStepUpBanner(message: stepUp) }
            if let selected {
                Text(selected.title).font(.specialElite(18))
                Text("Removal reason: \(selected.removal_reason ?? "unavailable")").font(.caption)
                if let state = selected.removal_state { Text("Hosted copy: \(state)").font(.caption) }
                Text("Creator's appeal: \(selected.explanation)")
                if let digest = selected.render_digest { Text(digest).font(.caption.monospaced()).textSelection(.enabled) }
                AdminModerationPreviewButton(target: selected.previewTarget, title: selected.title)
                    .id(selected.id).accessibilityIdentifier("admin.appeals.play")
                Toggle("I reviewed the removal, the appeal and the exact video.", isOn: $reviewed)
                TextField("Member-visible decision reason", text: $note, axis: .vertical).lineLimit(2...6)
                    .accessibilityIdentifier("admin.appeals.note")
                HStack {
                    Button("Accept and restore") { requests.enqueue { [note, reviewed] _ in await decide(accept: true, appeal: selected, submittedNote: note, reviewedAtTap: reviewed) } }.accessibilityIdentifier("admin.appeals.accept")
                    Button("Reject appeal", role: .destructive) { requests.enqueue { [note, reviewed] _ in await decide(accept: false, appeal: selected, submittedNote: note, reviewedAtTap: reviewed) } }.accessibilityIdentifier("admin.appeals.reject")
                }.disabled(busy || !reviewed || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 2000)
            }
            ForEach(appeals) { appeal in
                Button { selected = appeal; note = ""; reviewed = false; error = nil } label: {
                    VStack(alignment: .leading) {
                        Text(appeal.title).font(.specialElite(16))
                        Text(appeal.created_at.formatted()).font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.disabled(busy).accessibilityIdentifier("admin.appeals.select")
            }
            if appeals.isEmpty && !busy && error == nil { Text("No pending removal appeals.").font(.caption) }
        }
        .adminRequestLifetime(requests,
            reset: { clear() },
            initial: { await load() },
            pause: { busy = false })

    }
    private func clear() { requestID = UUID(); busy = false; appeals = []; selected = nil; note = ""; reviewed = false; error = nil; stepUp = nil }
    private func load() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true; selected = nil
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let items = try await CommunityServices.admin.appealQueue()
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            appeals = items; selected = nil; error = nil
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { appeals = []; selected = nil; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
    private func decide(accept: Bool, appeal: ModerationAppeal?, submittedNote: String, reviewedAtTap: Bool) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, reviewedAtTap, let selected = appeal else { return }
        if let prompt = CommunityServices.admin.stepUpPrompt(for: accept ? "appeal.accept" : "appeal.reject") { stepUp = prompt; return }
        stepUp = nil
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            try await CommunityServices.admin.decideAppeal(selected, accept: accept, note: submittedNote)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            busy = false; await load()
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return };
            guard requestID == id else { return }
            let problem = CommunityServices.admin.noteRefusal(error)
            if problem.isStepUpRequired { stepUp = problem.errorDescription } else { self.error = problem.errorDescription }
        }
    }
}

// MARK: - Challenges (#223 moderator lifecycle)
/// Create, schedule and cancel challenges through `sdi_challenge_action`
/// (moderation capability with MFA). Reward text is descriptive only.
@MainActor
struct AdminChallengesContent: View {
    @StateObject private var requests = AdminRequestOwner()
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var challenges: [ChallengeSummary] = []
    @State private var clock: ChallengeClock?
    @State private var title = ""
    @State private var brief = ""
    @State private var reward = ""
    @State private var created: (id: UUID, revision: Int)?
    @State private var selected: ChallengeSummary?
    @State private var startsAt = Date().addingTimeInterval(3600)
    @State private var closesAt = Date().addingTimeInterval(3600 * 25)
    @State private var endsAt = Date().addingTimeInterval(3600 * 49)
    @State private var reason = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var requestID = UUID()
    private var draft: ChallengeScheduleDraft { ChallengeScheduleDraft(startsAt: startsAt, closesAt: closesAt, endsAt: endsAt) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Challenge administration").font(.specialElite(22))
            Text("Challenges reuse the War Room rules: approved renditions only, one entry per creator, one favourite vote per non-participant, server-timed phases, ties record no winner. reward_text describes a real configured reward or stays empty; no coins or money exist.").font(.caption)
            Button("Refresh challenges") { requests.enqueue { _ in await load() } }.disabled(busy).accessibilityIdentifier("admin.challenges.refresh")
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("admin.challenges.error") }
            if let notice { Text(notice).font(.caption) }
            Text("Create").font(.specialElite(16))
            TextField("Title (1–100)", text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("admin.challenges.title")
            TextField("Brief (up to 2000)", text: $brief, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("admin.challenges.brief")
            TextField("Reward text (configured real reward or empty)", text: $reward).textFieldStyle(.roundedBorder).accessibilityIdentifier("admin.challenges.reward")
            Button("Create draft challenge") { requests.enqueue { [title, brief, reward] _ in await create(submittedTitle: title, submittedBrief: brief, submittedReward: reward) } }
                .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("admin.challenges.create")
            if let created { Text("Draft created: \(communityShortID(created.id)) (revision \(created.revision)). Schedule it below.").font(.caption) }
            Text("Schedule").font(.specialElite(16))
            DatePicker("Opens", selection: $startsAt).accessibilityIdentifier("admin.challenges.starts")
            DatePicker("Submissions close", selection: $closesAt).accessibilityIdentifier("admin.challenges.closes")
            DatePicker("Voting ends", selection: $endsAt).accessibilityIdentifier("admin.challenges.ends")
            if let problem = draft.validation(now: Date()) { Text(problem).font(.caption).foregroundStyle(StudioCraftTheme.warning) }
            Button("Schedule \(selected.map { "“\($0.title)”" } ?? created.map { _ in "new draft" } ?? "(select a challenge)")") { requests.enqueue { [target = selected.map { ($0.id, $0.revision) } ?? created.map { ($0.id, $0.revision) }, draft] _ in await schedule(submittedTarget: target, submittedDraft: draft) } }
                .disabled(busy || (selected == nil && created == nil) || draft.validation(now: Date()) != nil)
                .accessibilityIdentifier("admin.challenges.schedule")
            Text("Scheduled challenges").font(.specialElite(16))
            ForEach(challenges) { challenge in
                Button { selected = challenge; created = nil } label: {
                    VStack(alignment: .leading) {
                        Text(challenge.title).font(.specialElite(15))
                        Text("\(challenge.phase(at: clock?.now(deviceNow: Date()) ?? Date()).title) · \(challenge.entry_count) entries · revision \(challenge.revision)").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }.disabled(busy).accessibilityIdentifier("admin.challenges.select")
            }
            if challenges.isEmpty && !busy && error == nil { Text("No scheduled challenges.").font(.caption) }
            if let selected {
                TextField("Cancellation reason", text: $reason, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("admin.challenges.cancel-reason")
                Button("Cancel “\(selected.title)”", role: .destructive) { requests.enqueue { [reason] _ in await cancel(selected, submittedReason: reason) } }
                    .disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("admin.challenges.cancel")
            }
        }
        .adminRequestLifetime(requests,
            reset: { clear(); title = ""; brief = ""; reward = ""; startsAt = Date().addingTimeInterval(3600); closesAt = Date().addingTimeInterval(3600 * 25); endsAt = Date().addingTimeInterval(3600 * 49) },
            initial: { await load() },
            pause: { busy = false })

    }
    private func clear() { requestID = UUID(); busy = false; challenges = []; clock = nil; selected = nil; created = nil; error = nil; notice = nil; reason = "" }
    private func load() async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let listing = try await CommunityServices.challenges.list()
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            challenges = listing.challenges; clock = listing.clock; error = nil
            if let current = selected { selected = listing.challenges.first { $0.id == current.id } }
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { challenges = []; self.error = CommunityGateway.normalize(error).errorDescription } }
    }
    private func create(submittedTitle: String, submittedBrief: String, submittedReward: String) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy else { return }
        let id = UUID(); requestID = id; busy = true; error = nil; notice = nil
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let result = try await CommunityServices.challenges.create(title: submittedTitle, brief: submittedBrief, reward: submittedReward)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            created = result; selected = nil; title = ""; brief = ""; reward = ""; notice = "Draft recorded. It is listed to members only after scheduling."
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { self.error = CommunityGateway.normalize(error).errorDescription } }
    }
    private func schedule(submittedTarget: (UUID, Int)?, submittedDraft: ChallengeScheduleDraft) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy else { return }
        guard let target = submittedTarget else { return }
        let id = UUID(); requestID = id; busy = true; error = nil; notice = nil
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            let revision = try await CommunityServices.challenges.schedule(challenge: target.0, revision: target.1, draft: submittedDraft)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            notice = "Scheduled (revision \(revision))."; created = nil; busy = false; await load()
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { self.error = CommunityGateway.normalize(error).errorDescription } }
    }
    private func cancel(_ challenge: ChallengeSummary, submittedReason: String) async {
        guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }
        guard !busy else { return }
        let id = UUID(); requestID = id; busy = true; error = nil; notice = nil
        defer { if CommunityOperationContext.isCurrent { if requestID == id { busy = false } } }
        do {
            _ = try await CommunityServices.challenges.cancel(challenge: challenge.id, revision: challenge.revision, reason: submittedReason)
            guard CommunityOperationContext.isCurrent, !Task.isCancelled, requestID == id else { return }
            notice = "Challenge cancelled and audited."; reason = ""; selected = nil; busy = false; await load()
        } catch { guard CommunityOperationContext.scope != nil, CommunityOperationContext.isCurrent else { return }; if requestID == id { self.error = CommunityGateway.normalize(error).errorDescription } }
    }
}
