import SwiftUI
import WebKit
import AVKit
import Supabase

// MARK: - Admin Dashboard (Superuser Only)
@MainActor
struct AdminDashboardView: View {
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
    @State private var showAuthenticator = false
    @State private var capabilities: Set<String> = []
    @State private var isOwner = false
    @State private var permissionRequest = UUID()
    @State private var permissionMessage: String? = "Verify MFA and refresh access."
    @State private var loadingPermissions = false
    private var visibleTabs: [(id: String, icon: String, label: String)] {
        guard usesLiveOverview else { return tabs }
        let needed = ["dashboard": "overview", "users": "users", "approvals": "reviews", "decisions": "reviews",
                      "publishing": "publishing", "moderation": "moderation", "warReports": "moderation",
                      "warAppeals": "moderation", "content": "moderation", "billing": "finance"]
        return tabs.filter { isOwner || needed[$0.id].map { capabilities.contains($0) } == true }
    }
    
    let tabs: [(id: String, icon: String, label: String)] = [
        ("dashboard", "chart.bar.fill", "Dashboard"),
        ("users", "person.2.fill", "Users"),
        ("permissions", "key", "Permissions"),
        ("content", "doc.fill", "Content"),
        ("approvals", "checkmark.shield", "Video approvals"),
        ("decisions", "clock.arrow.circlepath", "Decision history"),
        ("publishing", "arrow.up.doc", "Publishing"),
        ("challenges", "trophy.fill", "Challenges"),
        ("spatter", "brain.fill", "Spatter AI"),
        ("bots", "cpu.fill", "AI Bots"),
        ("analytics", "chart.xyaxis.line", "Analytics"),
        ("moderation", "shield.fill", "Moderation"),
        ("warReports", "flag", "War Room reports"),
        ("warAppeals", "arrow.uturn.backward.circle", "War Room appeals"),
        ("settings", "gearshape.fill", "Settings"),
        ("billing", "creditcard.fill", "Billing"),
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
                    
                    Button("Verify MFA") { showAuthenticator = true }
                        .font(.caption)
                    Button("Refresh access") { Task { await refreshPermissions() } }
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
                        if !usesLiveOverview || visibleTabs.contains(where: { $0.id == selectedTab }) {
                        switch selectedTab {
                        case "dashboard":
                            if usesLiveOverview { AdminLiveOverviewContent() }
                            else { AdminDashboardContent(state: overview.state) }
                        case "users":
                            AdminUsersContent()
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
                        case "spatter":
                            AdminSpatterContent()
                        case "bots":
                            AdminBotsContent()
                        case "analytics":
                            AdminAnalyticsContent()
                        case "moderation":
                            AdminModerationContent()
                        case "warReports":
                            AdminWarReportsContent()
                        case "warAppeals":
                            AdminWarAppealsContent()
                        case "settings":
                            AdminSettingsContent()
                        case "billing":
                            AdminBillingContent()
                        default:
                            EmptyView()
                        }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task(id: "\(scenePhase == .active)-\(authVM.isAuthenticated)-\(authVM.userId ?? "none")-\(authVM.isSuperAdmin)") {
            if usesLiveOverview { await refreshPermissions(); return }
            guard scenePhase == .active else { overview.invalidate(); return }
            await overview.refresh(accountID: authVM.isAuthenticated ? authVM.userId : nil)
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { overview.invalidate(); clearPermissions() } }
        .onDisappear { overview.invalidate(); clearPermissions() }
        .sheet(isPresented: $showAuthenticator, onDismiss: { Task { await refreshPermissions() } }) { NavigationStack { AccountAuthenticatorView() } }
    }
    private func clearPermissions() {
        permissionRequest = UUID(); capabilities = []; isOwner = false; loadingPermissions = false
    }
    private func refreshPermissions() async {
        guard usesLiveOverview else { return }
        clearPermissions()
        guard scenePhase == .active, authVM.isAuthenticated, let account = authVM.userId else {
            permissionMessage = "Sign in and verify your administrator session."; return
        }
        let id = UUID(); permissionRequest = id; loadingPermissions = true; permissionMessage = "Loading current permissions…"
        defer { if permissionRequest == id { loadingPermissions = false } }
        do {
            let client = try SupabaseManager.shared.client
            let result: AdminAccessResponse = try await client.rpc("sdi_admin_permissions", params: ["action": "mine"]).execute().value
            guard !Task.isCancelled, permissionRequest == id, account == authVM.userId, scenePhase == .active else { return }
            guard result.error == nil, let owner = result.owner, let granted = result.capabilities else {
                permissionMessage = result.error ?? "Administrator access unavailable."; return
            }
            isOwner = owner; capabilities = Set(granted); permissionMessage = nil
            if !visibleTabs.contains(where: { $0.id == selectedTab }) { selectedTab = visibleTabs.first?.id ?? "" }
            if visibleTabs.isEmpty { permissionMessage = "No administrative capabilities have been granted." }
        } catch { if permissionRequest == id { permissionMessage = "Access unavailable. Verify MFA and refresh; server permissions are required." } }
    }
}
private struct AdminAccessResponse: Decodable { let error: String?; let owner: Bool?; let capabilities: [String]? }

// MARK: - Read-only verified overview
@MainActor
private struct AdminLiveOverviewContent: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var snapshot: AdminLiveSnapshot?
    @State private var requestID = UUID()
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Operations overview").font(.specialElite(22))
            Button("Refresh overview") { Task { await load() } }.disabled(busy)
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
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await load() }
        }
        .onDisappear { clear() }
    }
    private func metric(_ title: String, _ value: Int?, _ icon: String) -> some View {
        AdminStatCard(icon: icon, label: title, value: value.map(String.init) ?? "—", color: "EF4444")
    }
    private func clear() { requestID = UUID(); busy = false; snapshot = nil; error = nil }
    private func load() async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true; snapshot = nil
        defer { if requestID == id { busy = false } }
        do {
            let client = try SupabaseManager.shared.client
            let value: AdminLiveSnapshot = try await client.rpc("sdi_admin_overview").execute().value
            guard !Task.isCancelled, requestID == id else { return }
            let counts = [value.users,value.signed_in_today,value.pending_renders,value.publishing_jobs,
                          value.publishing_attention,value.feed_reports,value.war_reports,value.war_appeals]
            guard value.error == nil, value.measured_at != nil, counts.allSatisfy({ $0.map { $0 >= 0 } ?? false }) else {
                error = value.error ?? "Overview response incomplete."; return
            }
            snapshot = value; error = nil
        } catch { if requestID == id { self.error = "Overview unavailable. Check administrator authorization and MFA." } }
    }
}
private struct AdminLiveSnapshot: Decodable {
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
struct AdminUsersContent: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var showingAppeals = false
    @State private var historyUser: AdminDirectoryUser?
    @State private var pendingAction: AdminPendingAccountAction?
    @State private var users: [AdminDirectoryUser] = []
    @State private var search = ""
    @State private var appliedSearch = ""
    @State private var reason = ""
    @State private var page = 0
    @State private var more = true
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Review account appeals") { showingAppeals = true }
            TextField("Search username or account ID", text: $search).textFieldStyle(.roundedBorder)
            Button("Search") { Task { await load(reset: true) } }
                .disabled(busy || search.trimmingCharacters(in: .whitespacesAndNewlines).count > 100)
            if search.trimmingCharacters(in: .whitespacesAndNewlines) != appliedSearch {
                Text("Press Search to apply the edited query. Load more continues the current results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Reason for account action", text: $reason, axis: .vertical).lineLimit(2...4)
            if let error { Text(error).foregroundColor(.red) }
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
                    if let last = user.last_sign_in_at { Text("Last sign-in \(last.formatted())").font(.caption) }
                    Button("Account history") { historyUser = user }
                        .accessibilityIdentifier("admin.users.history")
                    Menu("Account actions") {
                        ForEach(["suspend","ban","restore","signout","note"], id: \.self) { action in
                            Button(action.capitalized) {
                                pendingAction = .init(action: action, user: user,
                                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                                    generation: generation)
                            }
                        }
                    }.disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 2000)
                }.padding().background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if more { Button("Load more") { Task { await load(reset: false) } }.disabled(busy) }
        }
        .task(id: "\(auth.userId ?? "none"):\(phase == .active):\(auth.isAuthenticated)") {
            generation = UUID(); users = []; page = 0; more = true; busy = false
            historyUser = nil; pendingAction = nil; reason = ""; error = nil; appliedSearch = ""
            if phase == .active && auth.isAuthenticated { await load(reset: true) }
        }
        .sheet(item: $historyUser) { user in AdminUserHistoryView(user: user) }
        .sheet(isPresented: $showingAppeals) { AccountAppealsView(administrator: true) }
        .confirmationDialog("Confirm account action", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible, presenting: pendingAction) { pending in
            Button("\(pending.action.capitalized) \(pending.user.username)",
                   role: ["suspend", "ban", "signout"].contains(pending.action) ? .destructive : nil) {
                Task { await apply(pending) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { pending in
            Text("Account: \(pending.user.id.uuidString)\nReason: \(pending.reason)\n\(pending.impact)")
        }
        .onDisappear { generation = UUID(); users = []; reason = ""; appliedSearch = ""; pendingAction = nil; historyUser = nil }
    }
    @MainActor private func load(reset: Bool, submittedQuery: String? = nil) async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        if reset {
            let query = (submittedQuery ?? search).trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count <= 100 else { error = "Use at most 100 characters for directory search."; return }
            generation = UUID(); pendingAction = nil; historyUser = nil
            appliedSearch = query; users = []; page = 0; more = true
        }
        guard page < 200, more else { return }
        let epoch = generation, account = auth.userId
        busy = true; defer { if epoch == generation { busy = false } }
        do {
            let response: AdminDirectoryResponse = try await client.rpc("sdi_users_action", params: AdminUserRequest(action: "list", query: appliedSearch, page: page)).execute().value
            guard !Task.isCancelled, epoch == generation, account == auth.userId, auth.isAuthenticated, phase == .active else { return }
            if let problem = response.error { users = []; more = false; error = problem; return }
            guard let items = response.users, items.count <= 50, let hasMore = response.has_more else { users = []; more = false; error = "Invalid directory response."; return }
            for item in items { if let index = users.firstIndex(where: {$0.id == item.id}) { users[index] = item } else { users.append(item) } }
            page += 1; more = hasMore && page < 200; error = nil
        } catch { if epoch == generation, account == auth.userId, phase == .active { users = []; more = false; self.error = "Directory unavailable. Check your admin session and MFA." } }
    }
    @MainActor private func apply(_ pending: AdminPendingAccountAction) async {
        guard !busy, auth.isAuthenticated, phase == .active, pending.generation == generation else { return }
        pendingAction = nil
        let epoch = generation, account = auth.userId; busy = true
        defer { if epoch == generation { busy = false } }
        do {
            let response: AdminDirectoryResponse = try await client.rpc("sdi_users_action", params: AdminUserRequest(action: pending.action, subject: pending.user.id, reason: pending.reason)).execute().value
            guard !Task.isCancelled, epoch == generation, account == auth.userId, auth.isAuthenticated, phase == .active else { return }
            if let problem = response.error { error = problem; busy = false; return }
            guard response.status == "confirmed" else { error = "Action was not confirmed."; busy = false; return }
            busy = false; reason = ""; await load(reset: true, submittedQuery: appliedSearch)
        } catch { if epoch == generation, account == auth.userId, phase == .active { self.error = "Action was not confirmed. Refresh before retrying." } }
    }
}
private struct AdminPendingAccountAction {
    let action: String; let user: AdminDirectoryUser; let reason: String; let generation: UUID
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
private struct AdminDirectoryResponse: Decodable {
    let status: String?; let error: String?; let users: [AdminDirectoryUser]?; let has_more: Bool?
}
private struct AdminDirectoryUser: Decodable, Identifiable {
    let id: UUID; let username: String; let masked_email: String?; let state: String
    let created_at: Date; let last_sign_in_at: Date?; let content_count: Int
    let sign_in_methods: [String]?; let feed_report_count: Int?
}

// MARK: - Content Tab
struct AdminContentContent: View {
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
    @State private var showingReports = false
    @State private var reason = ""
    @State private var curation: AdminCurationIntent?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search title, creator, post or account ID", text: $search).textFieldStyle(.roundedBorder)
            Button("Search content") { Task { await refresh() } }.disabled(busy || search.count > 100)
            Button("Open feed moderation queue") { showingReports = true }
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
                        curation = .init(post: post, reason: reason, generation: generation)
                    }.disabled(busy || post.feature_revision == nil || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 2000 || (!post.featured && (!post.visible || !post.approved)))
                    if let expiry = post.expires_at { Text("Media expiry: \(expiry.formatted())").font(.caption) }
                    Text("\(post.pending_report_count) pending / \(post.report_count) total reports").font(.caption)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if more && page < 200 { Button("Load more content") { Task { await load() } }.disabled(busy) }
            if more && page >= 200 { Text("Narrow the search to inspect more results.").font(.caption) }
        }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") { await refresh() }
        .onDisappear { generation = UUID(); posts = []; search = ""; appliedSearch = ""; reason = ""; curation = nil }
        .confirmationDialog("Change Featured placement?", isPresented: Binding(get: { curation != nil },
            set: { if !$0 { curation = nil } }), titleVisibility: .visible, presenting: curation) { pending in
            Button(pending.post.featured ? "Remove from Featured" : "Feature video") { Task { await curate(pending) } }
            Button("Cancel", role: .cancel) { curation = nil }
        } message: { pending in
            Text("\(pending.post.title)\nReason: \(pending.reason)\nThis changes Featured placement only; it does not approve, publish or restore removed content.")
        }
        .sheet(isPresented: $showingReports) {
            NavigationStack { ScrollView { AdminModerationContent().padding() }.navigationTitle("Feed moderation")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingReports = false } } } }
        }
    }
    @MainActor private func refresh() async {
        generation = UUID(); posts = []; page = 0; more = false; busy = false; error = nil; curation = nil; reason = ""
        appliedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        await load()
    }
    @MainActor private func curate(_ pending: AdminCurationIntent) async {
        guard !busy, phase == .active, auth.isAuthenticated, pending.generation == generation,
              let revision = pending.post.feature_revision else { return }
        let epoch = generation; busy = true
        defer { if epoch == generation { busy = false } }
        do {
            let response: AdminCurationResponse = try await SupabaseManager.shared.client.rpc("sdi_feature_content",
                params: AdminCurationRequest(post: pending.post.id, revision: revision,
                    featured: !pending.post.featured, reason: pending.reason)).execute().value
            guard !Task.isCancelled, epoch == generation, phase == .active else { return }
            guard response.error == nil, response.status == "confirmed" || response.status == "unchanged" else {
                error = response.error ?? "Curation was not confirmed. Refresh before retrying."; return
            }
            busy = false; await refresh()
        } catch { if epoch == generation { self.error = "Curation was not confirmed. Refresh before retrying." } }
    }
    @MainActor private func load() async {
        guard !busy, auth.isAuthenticated, phase == .active, page < 200, appliedSearch.count <= 100 else { return }
        let epoch = generation; let account = auth.userId
        busy = true; defer { if epoch == generation { busy = false } }
        do {
            let response: AdminContentResponse = try await SupabaseManager.shared.client.rpc("sdi_admin_content",
                params: AdminContentQuery(page: page, query: appliedSearch)).execute().value
            guard !Task.isCancelled, epoch == generation, account == auth.userId, phase == .active else { return }
            guard response.error == nil, let items = response.posts, items.count <= 50, let hasMore = response.has_more else {
                posts = []; more = false; error = response.error ?? "Invalid content response."; return
            }
            for item in items {
                if let index = posts.firstIndex(where: { $0.id == item.id }) { posts[index] = item }
                else { posts.append(item) }
            }
            page += 1; more = hasMore; error = nil
        } catch { if epoch == generation { posts = []; more = false; self.error = "Content inventory unavailable. Refresh your admin access and MFA." } }
    }
}
private struct AdminContentQuery: Encodable { let page: Int; let query: String }
private struct AdminContentResponse: Decodable { let error: String?; let posts: [AdminContentEntry]?; let has_more: Bool? }
private struct AdminContentEntry: Decodable, Identifiable {
    let id: UUID; let creator: UUID; let creator_name: String; let caption: String; let title: String
    let published_at: Date; let visible: Bool; let featured: Bool; let allow_export: Bool; let approved: Bool
    let expires_at: Date?; let report_count: Int; let pending_report_count: Int; let feature_revision: Int?
}

private struct AdminCurationIntent { let post: AdminContentEntry; let reason: String; let generation: UUID }
private struct AdminCurationRequest: Encodable { let post: UUID; let revision: Int; let featured: Bool; let reason: String }
private struct AdminCurationResponse: Decodable { let status: String?; let error: String? }

// MARK: - Challenges Tab
struct AdminChallengesContent: View {
    var body: some View {
        AdminInfoCard(title: "Challenge administration", value: "—", detail: "Service connection pending. No sample data or local-only controls.")
    }
}

// MARK: - Spatter AI Tab
struct AdminSpatterContent: View {
    var body: some View {
        AdminInfoCard(title: "Spatter operations", value: "—", detail: "Service connection pending. No sample data or local-only controls.")
    }
}

// MARK: - Bots Tab
struct AdminBotsContent: View {
    var body: some View {
        AdminInfoCard(title: "Agent operations", value: "—", detail: "Service connection pending. No sample data or local-only controls.")
    }
}

// MARK: - Analytics Tab
struct AdminAnalyticsContent: View {
    var body: some View {
        AdminInfoCard(title: "Analytics", value: "—", detail: "Service connection pending. No sample data or local-only controls.")
    }
}

// MARK: - Moderation Tab
struct AdminModerationContent: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var reports: [ModerationReport] = []
    @State private var selected: ModerationReport?
    @State private var player: AVPlayer?
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reported videos").font(.specialElite(22))
            Text("Removal hides the rendition from the app and queues external removal. It does not claim an external platform has removed it.").font(.caption)
            Button("Refresh reports") { Task { await load() } }.disabled(busy)
            if let error { Text(error).foregroundColor(.red) }
            if busy { ProgressView() }
            if let selected {
                Text(selected.title).font(.specialElite(18))
                if let player { VideoPlayer(player: player).frame(minHeight: 220) }
                Text("Report: \(selected.reason)")
                Text(selected.caption)
                Text(selected.render_digest).font(.caption.monospaced()).textSelection(.enabled)
                TextField("Required decision reason", text: $note, axis: .vertical).lineLimit(2...5)
                HStack {
                    Button("Dismiss report") { Task { await decide("dismiss") } }
                    Button("Remove rendition", role: .destructive) { Task { await decide("remove") } }
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
        .task(id: "\(auth.userId ?? "none"):\(phase == .active):\(auth.isAuthenticated)") {
            clear(); if phase == .active && auth.isAuthenticated { await load() }
        }
        .onDisappear { clear() }
    }
    private func clear() { generation = UUID(); reports = []; selected = nil; player?.pause(); player = nil; note = "" }
    private func select(_ report: ModerationReport) {
        player?.pause(); player = nil; selected = report; note = ""
        guard let parts = URLComponents(string: report.url), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, let url = parts.url else { error = "Preview unavailable."; return }
        player = AVPlayer(url: url)
    }
    @MainActor private func load() async {
        guard !busy, auth.isAuthenticated else { return }
        let epoch = generation; busy = true; defer { busy = false }
        do {
            let response: ModerationResponse = try await client.rpc("sdi_moderation_action", params: ModerationRequest(action: "list")).execute().value
            guard !Task.isCancelled, epoch == generation else { return }
            player?.pause(); player = nil; selected = nil
            if let problem = response.error { reports = []; error = problem; return }
            guard let items = response.reports else { reports = []; error = "Invalid moderation response."; return }
            reports = items; error = nil
        } catch { if epoch == generation { reports = []; self.error = "Moderation queue unavailable. Check your admin session and MFA." } }
    }
    @MainActor private func decide(_ action: String) async {
        guard !busy, let selected else { return }
        let epoch = generation; busy = true
        do {
            let response: ModerationResponse = try await client.rpc("sdi_moderation_action", params: ModerationRequest(action: action, report: selected.id, version: selected.version, note: note)).execute().value
            guard !Task.isCancelled, epoch == generation else { busy = false; return }
            if let problem = response.error { error = problem; busy = false; return }
            guard response.status == "confirmed" else { error = "Decision was not confirmed."; busy = false; return }
            busy = false; await load()
        } catch { busy = false; if epoch == generation { self.error = "Decision was not confirmed. Refresh before retrying." } }
    }
}
private struct ModerationRequest: Encodable { let action: String; var report: UUID? = nil; var version: Int? = nil; var note = "" }
private struct ModerationResponse: Decodable { let error: String?; let status: String?; let reports: [ModerationReport]? }
private struct ModerationReport: Decodable, Identifiable {
    let id: UUID; let reason: String; let version: Int; let created_at: Date
    let caption: String; let creator: UUID; let title: String; let url: String; let render_digest: String
}

// MARK: - Settings Tab
struct AdminSettingsContent: View {
    var body: some View {
        AdminInfoCard(title: "Service settings", value: "—", detail: "Service connection pending. No sample data or local-only controls.")
    }
}

// MARK: - Billing Tab
struct AdminBillingContent: View {
    var body: some View {
        AdminInfoCard(title: "Finance and billing", value: "—", detail: "Service connection pending. No sample data or local-only controls.")
    }
}

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
private struct AdminVideoApprovalContent: View {
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
    @State private var generation = UUID()
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }
    private var identity: String { "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Video approvals").font(.specialElite(22))
            if let error { Text(error).foregroundColor(.red) }
            Button("Refresh review queue") { Task { await load() } }.disabled(loading)
            if loading { ProgressView() }
            if let selected {
                Text(selected.title).font(.specialElite(18))
                if let player { VideoPlayer(player: player).frame(minHeight: 240) }
                Button("Renew private preview") { Task { await renewPreview() } }
                    .disabled(loading || AppConfig.uploadServiceURL == nil)
                    .accessibilityIdentifier("admin.review.renew-preview")
                if AppConfig.uploadServiceURL == nil {
                    Text("Private preview renewal is not configured in this build.").font(.caption)
                }
                Text("Source: \(selected.source_revision)").font(.caption)
                Text("Render: \(selected.render_digest)").font(.caption.monospaced()).textSelection(.enabled)
                Text("Consent: \(selected.consent_version)").font(.caption)
                Text(selected.rights_summary)
                Text("Destinations: \(selected.destinations.joined(separator: ", "))")
                if selected.spatter_generated { Text("Spatter video — owner approval required").foregroundColor(.red) }
                Toggle("I reviewed this exact video with audio, its rights and its destinations.", isOn: $acknowledged)
                TextField("Decision notes / rights evidence", text: $note, axis: .vertical).lineLimit(2...5)
                Text(selected.rights_cleared ? "Rights cleared — publication still needs a separate approval." : "Rights pending — record the evidence reviewed before approving.")
                    .font(.caption)
                Button(selected.rights_cleared ? "Revoke rights clearance" : "Record rights clearance") {
                    Task { await recordRights(cleared: !selected.rights_cleared) }
                }
                .disabled(loading || !acknowledged || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 2000 || (selected.spatter_generated && !owner))
                .accessibilityIdentifier("admin.review.rights")
                HStack {
                    Button("Approve") { Task { await decide("approved") } }
                        .disabled(!acknowledged || !selected.rights_cleared || (selected.spatter_generated && !owner) || selected.preview_expires_at <= Date() || loading)
                    Button("Request changes") { Task { await decide("changes") } }.disabled(loading)
                    Button("Reject", role: .destructive) { Task { await decide("rejected") } }.disabled(loading)
                }
            }
            ForEach(reviews) { review in
                Button(review.title) {
                    player?.pause(); selected = review; note = ""; acknowledged = false; player = nil
                    guard review.preview_expires_at > Date(), let parts = URLComponents(string: review.preview_url),
                          parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
                          let url = parts.url else { error = "Preview expired or unavailable. Refresh the queue."; return }
                    player = AVPlayer(url: url)
                }.font(.specialElite(16)).padding(10)
            }
            if reviews.isEmpty && !loading && error == nil { Text("No pending renders.") }
        }
        .task(id: identity) {
            generation = UUID(); loading = false; reviews = []; owner = false; selected = nil; player?.pause(); player = nil
            acknowledged = false; note = ""; error = nil
            if phase == .active && auth.isAuthenticated { await load() }
        }
        .onDisappear { generation = UUID(); loading = false; player?.pause(); player = nil; selected = nil; reviews = []; note = ""; acknowledged = false }
    }
    @MainActor private func load() async {
        guard !loading, auth.isAuthenticated else { return }
        let revision = generation; loading = true
        defer { if revision == generation { loading = false } }
        do {
            let response: ReviewResponse = try await client.rpc("sdi_review_action", params: ReviewRequest(action: "list")).execute().value
            guard !Task.isCancelled, revision == generation else { return }
            player?.pause(); player = nil; selected = nil; acknowledged = false
            if let problem = response.error { reviews = []; owner = false; error = problem; return }
            guard let items = response.reviews, let isOwner = response.owner else { error = "Invalid review response."; return }
            reviews = items; owner = isOwner; error = nil
        } catch { if revision == generation { reviews = []; owner = false; self.error = "Review queue unavailable. Check your administrator session and MFA." } }
    }
    @MainActor private func decide(_ decision: String) async {
        guard !loading, let selected, note.count <= 2000 else { return }
        let revision = generation; loading = true
        do {
            let payload = ReviewRequest(action: "decide", review: selected.id, digest: selected.render_digest, version: selected.version, decision: decision, note: note)
            let response: ReviewResponse = try await client.rpc("sdi_review_action", params: payload).execute().value
            guard !Task.isCancelled, revision == generation else { return }
            if let problem = response.error { error = problem; loading = false; return }
            guard response.status == "confirmed" else { error = "Decision was not confirmed."; loading = false; return }
            loading = false; await load()
        } catch { if revision == generation { loading = false; self.error = "Decision was not confirmed. Reload before retrying." } }
    }
    @MainActor private func renewPreview() async {
        guard !loading, let selected, auth.isAuthenticated, phase == .active else { return }
        let revision = generation; loading = true
        defer { if revision == generation { loading = false } }
        do {
            let client = try self.client
            guard let session = client.auth.currentSession, !session.isExpired,
                  session.user.id.uuidString.lowercased() == auth.userId?.lowercased() else { throw SDIIntakeClient.Failure.authorization }
            let response: ReviewPreviewRenewal = try await SDIIntakeClient.request(
                path: ["v1", "review-previews", selected.id.uuidString.lowercased(), "renew"],
                body: ReviewPreviewIdentity(digest: selected.render_digest, version: selected.version), token: session.accessToken)
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
                spatter_generated: selected.spatter_generated, version: selected.version)
        } catch {
            if revision == generation { self.error = error.localizedDescription }
        }
    }
    @MainActor private func recordRights(cleared: Bool) async {
        guard !loading, acknowledged, let selected, auth.isAuthenticated, phase == .active,
              !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.count <= 2000 else { return }
        let revision = generation; loading = true
        do {
            let payload = ReviewRightsRequest(review: selected.id, digest: selected.render_digest,
                version: selected.version, cleared: cleared, note: note)
            let response: ReviewResponse = try await client.rpc("sdi_review_rights", params: payload).execute().value
            guard !Task.isCancelled, revision == generation else { return }
            loading = false
            guard response.error == nil, response.status == "confirmed" else {
                error = response.error ?? "Rights decision was not confirmed. Refresh before retrying."; return
            }
            // Refetch the changed version; never apply approval to the stale capture.
            player?.pause(); player = nil; self.selected = nil; acknowledged = false; note = ""
            await load()
        } catch {
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
private struct ReviewResponse: Decodable {
    let error: String?; let status: String?; let reviews: [RenderReview]?; let owner: Bool?
}
private struct RenderReview: Decodable, Identifiable {
    let id: UUID; let title: String; let source_revision: String; let render_digest: String
    let preview_url: String; let preview_expires_at: Date; let consent_version: String; let rights_summary: String
    let rights_cleared: Bool; let destinations: [String]; let spatter_generated: Bool; let version: Int
}

@MainActor
private struct AdminPublishingContent: View {
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
                Button("Refresh") { Task { await load() } }
                Spacer()
                Button("Previous") { page -= 1; Task { await load() } }.disabled(page == 0)
                Text("\(page + 1)").font(.caption)
                Button("Next") { page += 1; Task { await load() } }.disabled(jobs.count < 50 || page >= 199)
            }.disabled(busy)
            if busy { ProgressView() }
            if let error { Text(error).foregroundColor(.red) }
            if let selected {
                Text(selected.title).font(.specialElite(18))
                Text("\(selected.destination) · \(selected.state) · \(selected.phase)")
                Text("Upload attempts: \(selected.attempts) · Withdrawal attempts: \(selected.removal_attempts)").font(.caption)
                Text(selected.render_digest).font(.caption.monospaced()).textSelection(.enabled)
                if let provider = selected.provider_id { Text("Provider video: \(provider)").font(.caption) }
                if let message = selected.last_error { Text(message).font(.caption) }
                if let url = publicLink(selected) { Link("Open confirmed publication", destination: url) }
                TextField("Required action reason", text: $reason, axis: .vertical).lineLimit(2...5)
                Button("Cancel / withdraw from channel", role: .destructive) {
                    Task { await act("withdraw") }
                }.disabled(!canAct || selected.state == "cancelled" || selected.destination != "youtube")
                if selected.state == "removal_pending" {
                    Button("Retry withdrawal") { Task { await act("retry_withdrawal") } }.disabled(!canAct)
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
                Button { Task { await select(job) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.title).font(.specialElite(16))
                        Text("\(job.destination) · \(job.state) · \(job.updated_at.formatted())").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.disabled(busy)
            }
            if jobs.isEmpty && !busy && error == nil { Text("No publishing jobs on this page.") }
        }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear()
            if phase == .active && auth.isAuthenticated { await load() }
        }
        .onDisappear { clear() }
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
    private func load() async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true; selected = nil; history = []
        defer { if requestID == id { busy = false } }
        do {
            let result: AdminPublishingResponse = try await client.rpc("sdi_publishing_admin", params: AdminPublishingRequest(action: "list", page: page)).execute().value
            guard !Task.isCancelled, requestID == id else { return }
            guard result.error == nil, let items = result.jobs else { jobs = []; error = result.error ?? "Invalid publishing response."; return }
            jobs = items; error = nil
        } catch { if requestID == id { jobs = []; self.error = "Publishing queue unavailable. Check admin authorization and MFA." } }
    }
    private func select(_ job: AdminPublishJob) async {
        guard !busy else { return }
        let id = UUID(); requestID = id; busy = true; selected = job; history = []; reason = ""; error = nil
        defer { if requestID == id { busy = false } }
        do {
            let result: AdminPublishingResponse = try await client.rpc("sdi_publishing_admin", params: AdminPublishingRequest(action: "history", job: job.id)).execute().value
            guard !Task.isCancelled, requestID == id else { return }
            guard result.error == nil, let events = result.history else { error = result.error ?? "History unavailable."; return }
            history = events
        } catch { if requestID == id { self.error = "History unavailable. Refresh before acting." } }
    }
    private func act(_ action: String) async {
        guard canAct, let selected else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let result: AdminPublishingResponse = try await client.rpc("sdi_publishing_admin", params: AdminPublishingRequest(action: action, job: selected.id, revision: selected.revision, reason: reason)).execute().value
            guard !Task.isCancelled, requestID == id else { return }
            guard result.error == nil, result.status == "confirmed" else { error = result.error ?? "Action was not confirmed."; return }
            busy = false; await load()
        } catch { if requestID == id { self.error = "Action outcome unavailable. Refresh status before retrying." } }
    }
}
@MainActor
private struct AdminReviewHistoryContent: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var decisions: [AdminRenderDecision] = []
    @State private var page = 0
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Video decision history").font(.specialElite(22))
            Text("These records describe the render and permissions at the time of each decision. Later edits require a new approval.").font(.caption)
            HStack {
                Button("Refresh") { Task { await load() } }
                Spacer()
                Button("Previous") { page -= 1; Task { await load() } }.disabled(page == 0)
                Text("\(page + 1)").font(.caption)
                Button("Next") { page += 1; Task { await load() } }.disabled(decisions.count < 50 || page >= 199)
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
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if phase == .active && auth.isAuthenticated { await load() }
        }
        .onDisappear { clear() }
    }
    private func clear() { requestID = UUID(); busy = false; decisions = []; page = 0; error = nil }
    private func load() async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let client = try SupabaseManager.shared.client
            let result: AdminReviewHistoryResponse = try await client.rpc("sdi_review_history", params: ["page": page]).execute().value
            guard !Task.isCancelled, requestID == id else { return }
            guard result.error == nil, let items = result.decisions else { decisions = []; error = result.error ?? "History response unavailable."; return }
            decisions = items; error = nil
        } catch { if requestID == id { decisions = []; self.error = "Decision history unavailable. Check admin authorization and MFA." } }
    }
}
private struct AdminReviewHistoryResponse: Decodable { let error: String?; let decisions: [AdminRenderDecision]? }
private struct AdminRenderDecision: Decodable, Identifiable {
    let id: UUID; let review_id: UUID; let actor: UUID; let owner_at_decision: Bool
    let render_title: String; let source_revision: String; let rights_summary: String
    let render_digest: String; let review_version: Int; let consent_version: String
    let destinations: [String]; let decision: String; let note: String; let created_at: Date
}

@MainActor
private struct AdminWarReportsContent: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var reports: [AdminWarReport] = []
    @State private var selected: AdminWarReport?
    @State private var player: AVPlayer?
    @State private var reason = ""
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("War Room reports").font(.specialElite(22))
            Button("Refresh reports") { Task { await request("list") } }.disabled(busy)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let selected {
                Text(selected.reason)
                Text("Match state: \(selected.status)").font(.caption)
                Button("Play: \(selected.left_title)") { play(selected.left_url) }
                if let title = selected.right_title, let url = selected.right_url { Button("Play: \(title)") { play(url) } }
                if let player { VideoPlayer(player: player).frame(minHeight: 220) }
                TextField("Required decision reason", text: $reason, axis: .vertical).lineLimit(2...5)
                Text("Removing a matchup hides it and excludes its result from profile totals. Media remains intact; video takedown is a separate decision.").font(.caption)
                HStack {
                    Button("Dismiss") { Task { await request("dismiss") } }
                    Button("Remove matchup", role: .destructive) { Task { await request("remove") } }
                }.disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 2000)
            }
            ForEach(reports) { report in
                Button {
                    player?.pause(); player = nil; selected = report; reason = ""; error = nil
                } label: {
                    VStack(alignment: .leading) {
                        Text(report.left_title).font(.specialElite(16))
                        Text("\(report.reason) · \(report.created_at.formatted())").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.disabled(busy)
            }
            if reports.isEmpty && !busy && error == nil { Text("No pending War Room reports.") }
        }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await request("list") }
        }
        .onDisappear { clear() }
    }
    private func clear() { requestID = UUID(); busy = false; reports = []; selected = nil; player?.pause(); player = nil; reason = ""; error = nil }
    private func play(_ raw: String) {
        guard let parts = URLComponents(string: raw), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, let url = parts.url else { error = "Preview unavailable."; return }
        player?.pause(); player = AVPlayer(url: url)
    }
    private func request(_ action: String) async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let client = try SupabaseManager.shared.client
            let result: AdminWarResponse = try await client.rpc("sdi_war_moderate", params: AdminWarRequest(action: action, report: selected?.id, revision: selected?.revision, reason: reason)).execute().value
            guard !Task.isCancelled, requestID == id else { return }
            if let issue = result.error { error = issue; return }
            if action == "list", let items = result.reports {
                reports = items; selected = nil; player?.pause(); player = nil; error = nil
            } else if result.status == "confirmed" { busy = false; await request("list") }
            else { error = "Response incomplete. Refresh before retrying." }
        } catch { if requestID == id { reports = []; selected = nil; player?.pause(); player = nil; self.error = "Moderation unavailable. Check admin session and MFA." } }
    }
}
private struct AdminWarRequest: Encodable { let action: String; let report: UUID?; let revision: Int?; let reason: String }
private struct AdminWarResponse: Decodable { let error: String?; let status: String?; let reports: [AdminWarReport]? }
private struct AdminWarReport: Decodable, Identifiable {
    let id: UUID; let match_id: UUID; let reason: String; let revision: Int; let created_at: Date; let status: String
    let left_title: String; let right_title: String?; let left_url: String; let right_url: String?
}

@MainActor
private struct AdminWarAppealsContent: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var appeals: [AdminWarAppeal] = []
    @State private var selected: AdminWarAppeal?
    @State private var player: AVPlayer?
    @State private var note = ""
    @State private var reviewed = false
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("War Room appeals").font(.specialElite(22))
            Button("Refresh appeals") { Task { await request("list") } }.disabled(busy)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let selected {
                Text("Original decision").font(.specialElite(18))
                Text(selected.decision_reason)
                Text("Prior match state: \(selected.previous_status)").font(.caption)
                Text("Participant appeal").font(.specialElite(18))
                Text(selected.explanation)
                Button("Play: \(selected.left_title)") { play(selected.left_url) }
                Text(selected.left_digest).font(.caption.monospaced()).textSelection(.enabled)
                if let url = selected.right_url {
                    Button("Play: \(selected.right_title ?? "Second video")") { play(url) }
                    Text(selected.right_digest ?? "Digest unavailable").font(.caption.monospaced()).textSelection(.enabled)
                }
                if let player { VideoPlayer(player: player).frame(minHeight: 220) }
                Toggle("I reviewed the decision, appeal and submitted videos.", isOn: $reviewed)
                TextField("Required appeal decision reason", text: $note, axis: .vertical).lineLimit(2...6)
                Text("Accepting restores the previous matchup state only if the server confirms that no newer restriction applies and the exact media remain approved. It does not change votes or create a reward.").font(.caption)
                HStack {
                    Button("Accept and restore") { Task { await request("accept") } }
                    Button("Reject appeal", role: .destructive) { Task { await request("reject") } }
                }.disabled(busy || !reviewed || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 2000)
            }
            ForEach(appeals) { appeal in
                Button {
                    player?.pause(); player = nil; selected = appeal; note = ""; reviewed = false; error = nil
                } label: {
                    VStack(alignment: .leading) {
                        Text(appeal.left_title).font(.specialElite(16))
                        Text(appeal.created_at.formatted()).font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.disabled(busy)
            }
            if appeals.isEmpty && !busy && error == nil { Text("No pending appeals.") }
        }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await request("list") }
        }
        .onDisappear { clear() }
    }
    private func clear() { requestID = UUID(); busy = false; appeals = []; selected = nil; player?.pause(); player = nil; note = ""; reviewed = false; error = nil }
    private func play(_ value: String) {
        guard let parts = URLComponents(string: value), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, let url = parts.url else { error = "Video unavailable."; return }
        player?.pause(); player = AVPlayer(url: url)
    }
    private func request(_ action: String) async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let client = try SupabaseManager.shared.client
            let response: AdminWarAppealResponse = try await client.rpc("sdi_war_appeal_admin", params: AdminWarAppealRequest(action: action, appeal: selected?.id, revision: selected?.revision, note: note)).execute().value
            guard !Task.isCancelled, requestID == id else { return }
            if let problem = response.error { error = problem; return }
            if action == "list", let items = response.appeals {
                appeals = items; selected = nil; player?.pause(); player = nil; error = nil; reviewed = false
            } else if response.status == "confirmed" { busy = false; await request("list") }
            else { error = "Decision not confirmed. Refresh before retrying." }
        } catch { if requestID == id { appeals = []; selected = nil; player?.pause(); player = nil; self.error = "Appeals unavailable. Check admin session and MFA." } }
    }
}
private struct AdminWarAppealRequest: Encodable { let action: String; let appeal: UUID?; let revision: Int?; let note: String }
private struct AdminWarAppealResponse: Decodable { let error: String?; let status: String?; let appeals: [AdminWarAppeal]? }
private struct AdminWarAppeal: Decodable, Identifiable {
    let id: UUID; let explanation: String; let revision: Int; let created_at: Date; let match_id: UUID
    let decision_reason: String; let previous_status: String; let left_digest: String; let right_digest: String?
    let left_title: String; let right_title: String?; let left_url: String; let right_url: String?
}

@MainActor
private struct AdminPermissionsContent: View {
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
    @State private var requestID = UUID()
    private let available = ["users", "reviews", "moderation", "publishing", "overview", "finance"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Administrator permissions").font(.specialElite(22))
            Text("Owner only. Role changes require a reason and sign the affected account out. Ownership and your own role cannot be changed here.").font(.caption)
            Button("Refresh roles") { Task { await request("list") } }.disabled(busy)
            if busy { ProgressView() }
            if let message { Text(message).font(.caption) }
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
                Button("Save permissions and revoke sessions") { Task { await request("save") } }
                    .disabled(busy || UUID(uuidString: subject) == nil || subject.lowercased() == auth.userId?.lowercased()
                              || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 2000)
            }
        }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await request("list") }
        }
        .onDisappear { clear() }
    }
    private func clear() { requestID = UUID(); busy = false; loaded = false; roles = []; subject = ""; capabilities = []; enabled = false; reason = ""; revision = 0; message = nil }
    private func request(_ action: String) async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let client = try SupabaseManager.shared.client
            let response: AdminPermissionsResponse = try await client.rpc("sdi_admin_permissions", params: AdminPermissionsRequest(action: action, subject: UUID(uuidString: subject), capabilities: capabilities.sorted(), enabled: enabled, reason: reason, revision: revision)).execute().value
            guard !Task.isCancelled, requestID == id else { return }
            if let error = response.error { message = error; if action == "list" { loaded = false; roles = [] }; return }
            if action == "list", let items = response.roles { roles = items; loaded = true; subject = ""; capabilities = []; enabled = false; revision = 0; reason = ""; message = nil }
            else if response.status == "confirmed" { busy = false; await request("list") }
            else { message = "Role response unavailable. Refresh before retrying." }
        } catch { if requestID == id { loaded = false; roles = []; message = "Role operation not confirmed. Owner MFA and service configuration are required." } }
    }
}
private struct AdminPermissionsRequest: Encodable { let action: String; let subject: UUID?; let capabilities: [String]; let enabled: Bool; let reason: String; let revision: Int }
private struct AdminPermissionsResponse: Decodable { let error: String?; let status: String?; let roles: [AdminRoleRecord]? }
private struct AdminRoleRecord: Decodable, Identifiable {
    let user_id: UUID; let owner: Bool; let enabled: Bool; let permissions: [String]; let revision: Int
    var id: UUID { user_id }
}

private struct AdminPublishingRequest: Encodable {
    let action: String
    var job: UUID? = nil; var revision: Int? = nil; var reason = ""; var page = 0
}
private struct AdminPublishingResponse: Decodable {
    let error: String?; let status: String?; let jobs: [AdminPublishJob]?; let history: [AdminPublishEvent]?
}
private struct AdminPublishJob: Decodable, Identifiable {
    let id: UUID; let title: String; let destination: String; let state: String; let phase: String
    let revision: Int; let attempts: Int; let removal_attempts: Int; let render_digest: String
    let provider_id: String?; let result_url: String?; let last_error: String?; let updated_at: Date
}
private struct AdminPublishEvent: Decodable, Identifiable {
    let id: UUID; let actor: UUID; let action: String; let previous_state: String
    let job_revision: Int; let reason: String; let created_at: Date
}


private struct AdminUserAuditEvent: Decodable, Identifiable {
    let id: UUID; let actor: UUID; let subject: UUID
    let action: String; let reason: String; let previous_state: String?; let created_at: Date
}
private struct AdminUserHistoryResponse: Decodable {
    let events: [AdminUserAuditEvent]?; let has_more: Bool?; let error: String?
}
private struct AdminUserHistoryView: View {
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
                if more && page < 20 { Button("Load older actions") { Task { await load() } }.disabled(busy) }
                if more && page >= 20 { Text("Showing the latest 1,000 actions. Refresh to see new actions.") }
            }
            .navigationTitle("Account history")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh") { Task { await reset() } }.disabled(busy) }
            }
            .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") { await reset() }
            .onDisappear { generation = UUID(); events = []; error = nil; busy = false }
        }.preferredColorScheme(.dark)
    }
    @MainActor private func reset() async {
        generation = UUID(); events = []; page = 0; more = false; error = nil; busy = false
        if phase == .active && auth.isAuthenticated { await load() }
    }
    @MainActor private func load() async {
        guard !busy, auth.isAuthenticated, phase == .active, page < 20 else { return }
        let request = generation; let account = auth.userId
        busy = true; defer { if generation == request { busy = false } }
        do {
            let result: AdminUserHistoryResponse = try await SupabaseManager.shared.client.rpc("sdi_users_action",
                params: AdminUserRequest(action: "history", subject: user.id, page: page)).execute().value
            guard !Task.isCancelled, generation == request, account == auth.userId, phase == .active else { return }
            guard result.error == nil, let items = result.events, let hasMore = result.has_more,
                  items.count <= 50, items.allSatisfy({ $0.subject == user.id && $0.reason.count <= 2000 }) else {
                events = []; error = result.error ?? "Invalid account history response."; more = false; return
            }
            let known = Set(events.map(\.id))
            events.append(contentsOf: items.filter { !known.contains($0.id) })
            page += 1; more = hasMore; error = nil
        } catch {
            if generation == request { events = []; more = false; self.error = "Account history unavailable. Check administrator authorization and MFA." }
        }
    }
}


/// Structured restriction review only; this is not user-to-user messaging.
struct AccountAppealsView: View {
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
                            Button("Submit appeal") { Task { await perform("submit", explanation: text) } }
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
                            Button("Accept and restore access") { decision = .init(action: "accept", item: item, reply: text, generation: generation) }
                                .disabled(busy || !validText)
                            Button("Reject appeal", role: .destructive) { decision = .init(action: "reject", item: item, reply: text, generation: generation) }
                                .disabled(busy || !validText)
                        }
                    }
                }
            }
            .navigationTitle(administrator ? "Account appeals" : "Account status")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh") { Task { await refresh() } }.disabled(busy) }
            }
            .confirmationDialog("Confirm appeal decision", isPresented: Binding(get: { decision != nil },
                set: { if !$0 { decision = nil } }), titleVisibility: .visible, presenting: decision) { pending in
                Button(pending.action == "accept" ? "Restore access" : "Reject appeal") {
                    Task {
                        guard pending.generation == generation else { return }
                        await perform(pending.action, appeal: pending.item.id, reply: pending.reply)
                    }
                }
                Button("Cancel", role: .cancel) { decision = nil }
            } message: { pending in
                Text("Account: \(pending.item.subject?.uuidString ?? "Unavailable")\nMember-visible reason: \(pending.reply)")
            }
            .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") { await refresh() }
            .onDisappear { generation = UUID(); items = []; text = ""; decision = nil; accountState = nil }
        }.preferredColorScheme(.dark)
    }
    private var validText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 2000 }
    @MainActor private func refresh() async {
        generation = UUID(); items = []; text = ""; decision = nil; error = nil; accountState = nil; restriction = nil; canAppeal = false; busy = false
        await perform(administrator ? "queue" : "mine")
    }
    @MainActor private func perform(_ action: String, appeal: UUID? = nil, explanation: String = "", reply: String = "") async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let epoch = generation; let account = auth.userId
        busy = true; defer { if generation == epoch { busy = false } }
        do {
            let response: AccountAppealResponse = try await SupabaseManager.shared.client.rpc("sdi_account_appeal_action",
                params: AccountAppealRequest(action: action, appeal: appeal, explanation: explanation, reply: reply, restriction: restriction)).execute().value
            guard !Task.isCancelled, generation == epoch, account == auth.userId, phase == .active else { return }
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
        } catch {
            if generation == epoch { items = []; canAppeal = false; self.error = "Appeal service unavailable. Sign in again and refresh before retrying." }
        }
    }
}
private struct AccountAppealEntry: Decodable, Identifiable {
    let id: UUID; let subject: UUID?; let explanation: String; let state: String
    let reply: String?; let created_at: Date; let decided_at: Date?
}
private struct AccountAppealDecision {
    let action: String; let item: AccountAppealEntry; let reply: String; let generation: UUID
}
private struct AccountAppealRequest: Encodable {
    let action: String; let appeal: UUID?; let explanation: String; let reply: String; let restriction: String?
}
private struct AccountAppealResponse: Decodable {
    let error: String?; let status: String?; let appeals: [AccountAppealEntry]?
    let account_state: String?; let can_appeal: Bool?; let restriction: String?
}
