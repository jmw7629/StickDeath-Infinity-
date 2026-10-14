import SwiftUI
import AVKit
import Supabase
import UniformTypeIdentifiers

/// Reference-shaped profile. Connected facts remain unavailable until verified.
struct ProfileView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @Environment(\.requestSignIn) private var requestSignIn
    let onOpenProjects: () -> Void
    @State private var destination: Destination?
    @State private var localProjectCount: Int?
    @State private var publishedCount: Int?
    @State private var stats: CreatorStatsResponse?
    @State private var statsProblem: String?

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
    private var displayName: String {
        let name = profile?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (authVM.isAuthenticated ? "Your profile" : "Guest") : name
    }
    private var reportedPlan: String? {
        guard let tier = profile?.subscriptionTier?.lowercased(),
              ["free", "pro", "creator", "studio"].contains(tier) else { return nil }
        return tier.capitalized
    }
    private var avatarURL: URL? {
        guard let raw = profile?.avatarURL, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        return url
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    AsyncImage(url: avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Text(String(displayName.prefix(2)).uppercased())
                            .font(.specialElite(24)).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(hex: "1E1E1E"))
                    }
                    .frame(width: 64, height: 64).clipShape(Circle())
                    .overlay(Circle().stroke(Color.sdRed, lineWidth: 3))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayName).font(.specialElite(20)).foregroundStyle(.white)
                        Text(reportedPlan.map { "Reported plan: \($0)" } ?? (authVM.isAuthenticated ? "Plan unavailable" : "On-device guest"))
                            .font(.specialElite(11)).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.sdRed.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.top, 24)
                .accessibilityIdentifier("profile.identity")

                if let bio = profile?.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(bio).font(.specialElite(13)).foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    statistic(localProjectCount.map(String.init) ?? "—", "Projects")
                    statistic(stats?.published_videos.map(String.init) ?? "—", "Published")
                    statistic(stats?.followers.map(String.init) ?? "—", "Followers")
                    statistic(stats?.likes_received.map(String.init) ?? "—", "Likes")
                }
                .padding(.vertical, 14).background(Color(hex: "141414"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("profile.statistics")
                Text("Projects counts saved animations on this device. Published, Followers and Likes are counted by the service from videos currently visible on the wall; a dash means the total was not loaded, never an estimate.")
                    .font(.specialElite(11)).foregroundStyle(.secondary)
                if let statsProblem { Text(statsProblem).font(.specialElite(11)).foregroundStyle(.secondary).accessibilityIdentifier("profile.statistics.problem") }
                if let following = stats?.following { Text("Following \(following) creator\(following == 1 ? "" : "s").").font(.specialElite(11)).foregroundStyle(.secondary) }
                if authVM.isAuthenticated {
                    ProfilePortfolioSection(onCount: { publishedCount = $0 })
                }

                VStack(spacing: 8) {
                    if !authVM.isAuthenticated {
                        Button { requestSignIn() } label: {
                            rowLabel("Sign in or create an account", icon: "person.crop.circle.badge.plus")
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("profile.sign-in")
                        Text("Your device projects stay here whether or not you sign in.")
                            .font(.specialElite(11)).foregroundStyle(.secondary)
                    }
                    Button(action: onOpenProjects) {
                        rowLabel("Projects on this device", icon: "folder")
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("profile.projects.open")
                    row("Publishing", icon: "square.and.arrow.up", destination: .publishing)
                    row("Records & badges", icon: "trophy", destination: .records)
                    row("Analytics", icon: "chart.bar", destination: .analytics)
                    row("Settings", icon: "gearshape", destination: .account)
                    if authVM.isAuthenticated {
                        row("Admin access", icon: "lock.shield", destination: .admin)
                    }
                    row("Subscription", icon: "creditcard", destination: .subscription)
                }

                Text("Subscription").font(.specialElite(16)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(reportedPlan ?? "Plan unavailable").font(.specialElite(16))
                    Text("Pricing, renewal and purchase information are not connected. No payment or subscription change is available here.")
                        .font(.specialElite(12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(Color(hex: "141414")).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("profile.subscription-status")
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Color(hex: "0A0A0A").ignoresSafeArea())
        .foregroundStyle(.white)
        .task(id: authVM.userId) {
            // Device-level inventory, never presented as a server/account portfolio.
            localProjectCount = nil; publishedCount = nil; stats = nil; statsProblem = nil
            if let listing = try? DeviceStorageManager.shared.listAnimationsReportingFailures(), listing.failures.isEmpty {
                localProjectCount = listing.animations.count
            }
            guard authVM.isAuthenticated, let account = authVM.userId else { return }
            do {
                let loaded = try await CommunityServices.profile.stats()
                guard !Task.isCancelled, account == authVM.userId else { return }
                stats = loaded
            } catch {
                guard !Task.isCancelled, account == authVM.userId else { return }
                statsProblem = "Totals unavailable: " + (CommunityGateway.normalize(error).errorDescription ?? "service unavailable.")
            }
        }
        .onChange(of: authVM.userId) { _ in destination = nil }
        .sheet(item: $destination) { page in
            NavigationStack {
                Group {
                    switch page {
                    case .admin: AdminDashboardView()
                    case .records: ProfileRecordsView()
                    case .publishing: PublishingJobsView()
                    case .account: ProfileSettingsView()
                    case .analytics:
                        detail("Analytics unavailable", "Views, likes and engagement have not been loaded. No activity totals are estimated.")
                    case .subscription:
                        detail(reportedPlan.map { "Reported plan: \($0)" } ?? "Plan unavailable",
                               "Verified pricing and billing management are not connected. No purchase or renewal is claimed.")
                    }
                }
                .navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
            }
        }
    }

    private func statistic(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.specialElite(18))
            Text(label).font(.specialElite(11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
    private func row(_ title: String, icon: String, destination page: Destination) -> some View {
        Button { destination = page } label: {
            rowLabel(title, icon: icon)
        }.buttonStyle(.plain)
    }
    private func rowLabel(_ title: String, icon: String) -> some View {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 22)
                Text(title).font(.specialElite(15))
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(15).background(Color(hex: "141414"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.specialElite(20))
            Text(text).font(.specialElite(14)).foregroundStyle(.secondary)
            Spacer()
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Replace the old disconnected toggles, invented disk usage and inert Sign Out.
struct ProfileSettingsView: View {
    @EnvironmentObject var authVM: AuthViewModel
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
            Section("Studio") {
                Text("Change grid, onion skin and project settings in the Studio menu. Those controls apply to the actual project.")
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

private struct PublishingJobsView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var jobs: [PublishingJob] = []
    @State private var error: String?
    @State private var busy = false
    @State private var generation = UUID()
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Publishing activity").font(.specialElite(22))
                Text("Only an approved render with destination consent can enter this queue. Cancelling an upload may require removal from the destination after transfer.")
                    .font(.specialElite(15, relativeTo: .callout)).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                if busy { ProgressView() }
                Button("Refresh") { Task { await load() } }.disabled(busy)
                NavigationLink("Upload an exported MP4 for review") { SDIRenderUploadView() }
                CreatorReviewsView()
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(job.destination.capitalized).font(.specialElite(18))
                        Text(job.state.replacingOccurrences(of: "_", with: " ").capitalized)
                        Text("Render \(job.render_digest.prefix(12)) · Attempt \(job.attempts)").font(.specialElite(12, relativeTo: .caption))
                        Text(job.updated_at, style: .relative).font(.specialElite(12, relativeTo: .caption))
                        if let issue = job.last_error { Text(issue).font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.red) }
                        if job.state == "published", let raw = job.result_url, let parts = URLComponents(string: raw),
                           parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil, let url = parts.url {
                            Link("Open published video", destination: url)
                        }
                        if job.state == "failed" && job.attempts < 5 {
                            Button("Retry") { Task { await act("retry", job.id) } }.disabled(busy)
                        }
                        if ["queued","leased","failed","published"].contains(job.state) {
                            Button(job.state == "published" ? "Request removal" : "Cancel", role: .destructive) {
                                Task { await act("cancel", job.id) }
                            }.disabled(busy)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if jobs.isEmpty && !busy && error == nil { Text("No publishing jobs.") }
            }.padding()
        }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            generation = UUID(); jobs = []
            if auth.isAuthenticated && phase == .active { await load() }
        }
        .onDisappear { generation = UUID(); jobs = [] }
    }
    @MainActor private func load() async {
        guard !busy, auth.isAuthenticated else { return }
        let epoch = generation; busy = true; defer { busy = false }
        do {
            let response: PublishingResponse = try await client.rpc("sdi_publish_action", params: PublishingRequest(action: "list")).execute().value
            guard !Task.isCancelled, epoch == generation else { return }
            if let problem = response.error { jobs = []; error = problem; return }
            guard let rows = response.jobs else { error = "Incomplete publishing response."; return }
            jobs = rows; error = nil
        } catch { if epoch == generation { jobs = []; self.error = "Publishing service unavailable. Check your account and connection." } }
    }
    @MainActor private func act(_ action: String, _ job: UUID) async {
        guard !busy else { return }
        let epoch = generation; busy = true
        do {
            let response: PublishingResponse = try await client.rpc("sdi_publish_action", params: PublishingRequest(action: action, job: job)).execute().value
            guard !Task.isCancelled, epoch == generation else { busy = false; return }
            if let problem = response.error { error = problem; busy = false; return }
            guard ["queued","cancellation_recorded"].contains(response.status ?? "") else { error = "Request was not confirmed."; busy = false; return }
            busy = false; await load()
        } catch { busy = false; if epoch == generation { self.error = "Request was not confirmed. Refresh before retrying." } }
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
    @State private var problem: String?
    @State private var playback: ProfilePlayback?
    @State private var requestID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loaded && problem == nil ? "Portfolio · \(items.count) approved" : "Portfolio").font(.specialElite(16)).foregroundStyle(.secondary)
            if let problem { CommunityMessage(text: problem, kind: .info) }
            if loaded && items.isEmpty && problem == nil {
                Text("No approved renditions yet. Submit an exported MP4 for review from Publishing.").font(.specialElite(12)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile.portfolio.empty")
            }
            ForEach(items) { item in
                Button {
                    guard let url = CommunityMediaURL.checked(item.url) else { return }
                    playback = ProfilePlayback(url: url, title: item.title)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(Color.sdRed)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.specialElite(15))
                            Text(item.duration.map { "\(Int($0.rounded())) s" } ?? "Duration unavailable").font(.specialElite(11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let expiry = item.expires_at { Text("Until \(expiry.formatted(date: .abbreviated, time: .omitted))").font(.specialElite(11)).foregroundStyle(.secondary) }
                    }.padding(12).background(Color(hex: "141414")).clipShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("Play \(item.title)").accessibilityIdentifier("profile.portfolio.play")
            }
        }
        .accessibilityIdentifier("profile.portfolio")
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            requestID = UUID(); items = []; loaded = false; problem = nil; onCount(nil)
            guard auth.isAuthenticated, phase == .active, let account = auth.userId.flatMap(UUID.init(uuidString:)) else { return }
            let id = requestID
            do {
                let rows = try await CommunityServices.profile.portfolio(account: account)
                guard !Task.isCancelled, requestID == id else { return }
                items = rows; loaded = true; onCount(rows.count)
            } catch { if requestID == id { loaded = true; problem = CommunityGateway.normalize(error).errorDescription } }
        }
        .sheet(item: $playback) { item in CommunityVideoPlayer(url: item.url, title: item.title) }
        .onDisappear { playback = nil }
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

private struct PublishingRequest: Encodable { let action: String; var job: UUID? = nil }
private struct PublishingResponse: Decodable { let error: String?; let status: String?; let jobs: [PublishingJob]? }
private struct PublishingJob: Decodable, Identifiable {
    let id: UUID; let review_id: UUID; let render_digest: String; let destination: String
    let state: String; let attempts: Int; let result_url: String?; let last_error: String?; let updated_at: Date
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
