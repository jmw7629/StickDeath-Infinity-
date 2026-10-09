import SwiftUI
import Supabase
import UniformTypeIdentifiers

/// Reference-shaped profile. Connected facts remain unavailable until verified.
struct ProfileView: View {
    @EnvironmentObject var authVM: AuthViewModel
    let onOpenProjects: () -> Void
    @State private var destination: Destination?
    @State private var localProjectCount: Int?

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
                    statistic("—", "Published")
                    statistic("—", "Followers")
                    statistic("—", "Likes")
                }
                .padding(.vertical, 14).background(Color(hex: "141414"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Projects counts saved animations on this device. Published, followers and likes are unavailable.")
                    .font(.specialElite(11)).foregroundStyle(.secondary)

                VStack(spacing: 8) {
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
            localProjectCount = nil
            if let listing = try? DeviceStorageManager.shared.listAnimationsReportingFailures(), listing.failures.isEmpty {
                localProjectCount = listing.animations.count
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
                    if let error = authVM.error { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .sheet(isPresented: $showingProfileEditor) { EditProfileView() }
        .sheet(isPresented: $showingMFA) { NavigationStack { AccountAuthenticatorView() } }
        .sheet(isPresented: $showingAppeals) { AccountAppealsView() }
        .onChange(of: authVM.userId) { _ in showingProfileEditor = false }
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
                    .font(.callout).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                if busy { ProgressView() }
                Button("Refresh") { Task { await load() } }.disabled(busy)
                NavigationLink("Upload an exported MP4 for review") { SDIRenderUploadView() }
                CreatorReviewsView()
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(job.destination.capitalized).font(.specialElite(18))
                        Text(job.state.replacingOccurrences(of: "_", with: " ").capitalized)
                        Text("Render \(job.render_digest.prefix(12)) · Attempt \(job.attempts)").font(.caption)
                        Text(job.updated_at, style: .relative).font(.caption)
                        if let issue = job.last_error { Text(issue).font(.caption).foregroundStyle(.red) }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Submitted renders").font(.specialElite(20))
            Text("Only submitted and approved renders appear here. Your local drafts are not uploaded automatically.").font(.caption)
            Button("Refresh submissions") { Task { await request("list") } }.disabled(busy)
            if busy { ProgressView() }
            if let message { Text(message).font(.caption) }
            ForEach(reviews) { review in
                VStack(alignment: .leading, spacing: 8) {
                    Text(review.title).font(.specialElite(17))
                    Text("\(review.state.capitalized) · Version \(review.version)").font(.caption)
                    Text("Render: \(review.render_digest.prefix(16))").font(.caption.monospaced())
                    Text("Permissions: \(review.destinations.isEmpty ? "None" : review.destinations.joined(separator: ", "))").font(.caption)
                    if review.can_publish {
                        Button("Publish approved video to SDI YouTube") { pending = review }.disabled(busy)
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
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await request("list") }
        }
        .onDisappear { clear() }
    }
    private func clear() { requestID = UUID(); busy = false; reviews = []; message = nil; pending = nil }
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
                reviews = []; message = result.status == "queued" ? "Queued. Refresh Publishing activity for status." : "Permissions withdrawn. Existing releases may remain visible until provider withdrawal is confirmed."
            } else { message = "Response incomplete. Refresh before retrying." }
        } catch { if requestID == id { message = "Submission service unavailable. Refresh before retrying."; if action == "list" { reviews = [] } } }
    }
}
private struct CreatorReviewRequest: Encodable { let action: String; var review: UUID?; var version: Int? }
private struct CreatorReviewResponse: Decodable { let error: String?; let status: String?; let reviews: [CreatorReview]? }
private struct CreatorReview: Decodable, Identifiable {
    let id: UUID; let title: String; let render_digest: String; let version: Int; let state: String
    let consent_version: String; let destinations: [String]; let can_publish: Bool
}

@MainActor
private struct ProfileRecordsView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var data: ProfileRecordsResponse?
    @State private var showRecords = false
    @State private var showBadges = false
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Records & badges").font(.specialElite(22))
                Text("Both public displays start off. Hiding your profile totals does not hide videos, match participation or individual match results.").font(.callout)
                if busy { ProgressView() }
                if let message { Text(message).font(.caption) }
                Button("Refresh") { Task { await load(save: false) } }.disabled(busy)
                if let data {
                    Text("Your private record").font(.specialElite(18))
                    Text("\(data.wins ?? 0) wins · \(data.losses ?? 0) losses · \(data.ties ?? 0) ties")
                    Toggle("Show my win/loss record publicly", isOn: $showRecords)
                    Toggle("Show my earned badges publicly", isOn: $showBadges)
                    Button("Save display preferences") { Task { await load(save: true) } }
                        .disabled(busy || (showRecords == data.show_records && showBadges == data.show_badges))
                    Text("Earned badges").font(.specialElite(18))
                    ForEach(data.badges ?? []) { badge in
                        VStack(alignment: .leading) {
                            Text(badge.title).font(.specialElite(16))
                            Text("\(badge.earned_at.formatted()) · Criteria \(badge.criterion_version)").font(.caption)
                        }
                    }
                    if data.badges?.isEmpty == true { Text("No verified badges awarded.").font(.caption) }
                }
            }.padding()
        }.background(Color.sdBackground).foregroundStyle(Color.sdTextPrimary)
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await load(save: false) }
        }
        .onDisappear { clear() }
    }
    private func clear() { requestID = UUID(); busy = false; data = nil; message = nil; showRecords = false; showBadges = false }
    private func load(save: Bool) async {
        guard !busy, auth.isAuthenticated, phase == .active, !save || data?.revision != nil else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let client = try SupabaseManager.shared.client
            let params = ProfileRecordsRequest(action: save ? "save" : "read", revision: save ? data?.revision : nil,
                records: save ? showRecords : nil, badges: save ? showBadges : nil)
            let result: ProfileRecordsResponse = try await client.rpc("sdi_profile_records", params: params).execute().value
            guard !Task.isCancelled, requestID == id else { return }
            guard result.error == nil, let records = result.show_records, let badges = result.show_badges,
                  result.revision != nil, result.wins != nil, result.losses != nil, result.ties != nil, result.badges != nil else {
                message = result.error ?? "Records response incomplete. Refresh before saving."; data = nil; return
            }
            data = result; showRecords = records; showBadges = badges; message = save ? "Display preferences saved." : nil
        } catch { if requestID == id { data = nil; message = "Records unavailable. Your display preferences were not confirmed." } }
    }
}
private struct ProfileRecordsRequest: Encodable { let action: String; let revision: Int?; let records: Bool?; let badges: Bool? }
private struct ProfileRecordsResponse: Decodable {
    let error: String?; let show_records: Bool?; let show_badges: Bool?; let revision: Int?
    let wins: Int?; let losses: Int?; let ties: Int?; let badges: [ProfileEarnedBadge]?
}
private struct ProfileEarnedBadge: Decodable, Identifiable { let id: UUID; let title: String; let criterion_version: String; let earned_at: Date }

@MainActor
struct AccountAuthenticatorView: View {
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
                    Text(totp.secret).font(.body.monospaced()).textSelection(.enabled).privacySensitive()
                    Text("The setup key is cleared when you leave this screen or background the app. An unfinished factor can be removed below and set up again.").font(.caption)
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
                Text("Verified factors cannot be removed here. Account recovery requires the protected recovery process.").font(.caption)
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
    private let request: StudioMovieExportSession.ShareRequest
    private var copying = false
    private var closed = false
    init(request: StudioMovieExportSession.ShareRequest, account: String, title: String, revision: String) {
        self.request = request; self.account = account; self.title = title; self.revision = revision
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
                Text("Only selected destinations may be reviewed. Channel and social versions may include SDI branding. Private drafts and unselected files are not submitted.").font(.caption)
                if let consent = AppConfig.publishingConsent {
                    Link("Read publishing terms", destination: consent.termsURL)
                    Text("Terms version: \(consent.version)").font(.caption)
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
                Text("Copies remain on this device for resume until you remove them. Your original exported file and editable project are preserved.").font(.caption)
                Button("Refresh uploads") { Task { await reload() } }.disabled(busy)
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.metadata.title).font(.specialElite(17))
                        Text("\(job.offset) / \(job.metadata.size) bytes · \(job.state)").font(.caption)
                        if let review = job.reviewID {
                            Text("Submitted for review: \(review.uuidString)").font(.caption).textSelection(.enabled)
                            Text("Manage approval and destination permissions in Publishing. This receipt is not publication confirmation.").font(.caption)
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
        do { stage(try exportedMovie.beginCopy(), exportLease: exportedMovie) }
        catch { message = "This export is no longer available. Return to Studio and render it again." }
    }
    private func stage(_ url: URL, exportLease: SDIRenderUploadExport? = nil) {
        guard canStage, let account = auth.userId.flatMap(UUID.init(uuidString:)), let consent = AppConfig.publishingConsent else {
            exportLease?.endCopy(); return
        }
        let metadata = SDIRenderUploadMetadata(size: 0, sha256: "", title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            source_revision: sourceRevision, destinations: destinations, rights_summary: rights, consent_version: consent.version, made_for_kids: audience == "kids")
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
