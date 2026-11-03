import SwiftUI

// MARK: - Private support triage
@MainActor
struct AdminSupportQueueContent: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var queue: AdminSupportPage?
    @State private var loadedAccount: String?
    @State private var displayAccount: String?
    @State private var statusFilter = ""
    @State private var selectedID: UUID?
    @State private var nextStatus = AdminSupportStatus.inProgress
    @State private var note = ""
    @State private var pending: Decision?
    @State private var generation = UUID()
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    private struct Decision {
        let item: AdminSupportItem
        let status: AdminSupportStatus
        let note: String
        let context: AdminSupportContext
    }
    private var active: Bool { auth.isAuthenticated && auth.userId != nil && phase == .active }
    private var visibleQueue: AdminSupportPage? { active && loadedAccount == auth.userId ? queue : nil }
    private var selected: AdminSupportItem? { visibleQueue?.items.first { $0.id == selectedID } }
    private func current(_ context: AdminSupportContext) -> Bool {
        !Task.isCancelled && context.admits(accountID: auth.userId, authenticated: auth.isAuthenticated,
            active: phase == .active, generation: generation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Support queue").font(.specialElite(22))
            Text("Private customer-service requests. Status changes and notes are audited. Notes stay private to authorized administrators; this does not send a reply or email.").font(.caption)
            Text("The server requires the Users capability and an active MFA session.").font(.caption2).foregroundStyle(.secondary)
            Picker("Request status", selection: $statusFilter) {
                Text("All requests").tag("")
                ForEach(AdminSupportStatus.allCases) { Text($0.title).tag($0.rawValue) }
            }.disabled(busy || !active).accessibilityIdentifier("admin.support.filter")
            Button("Refresh queue") { queueLoad(page: 0) }
                .disabled(busy || !active).accessibilityIdentifier("admin.support.refresh")
            if busy { ProgressView().accessibilityLabel("Loading support queue") }
            if !active { Text("Sign in and verify MFA to work the support queue.").font(.caption) }
            if active, displayAccount == auth.userId, let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("admin.support.error") }
            if active, displayAccount == auth.userId, let notice { Text(notice).font(.caption).accessibilityIdentifier("admin.support.notice") }
            if let queue = visibleQueue {
                Text("Page \(queue.page + 1) · \(queue.items.count) requests").font(.specialElite(16))
                if queue.items.isEmpty { Text("No requests match this status on this page.").font(.caption) }
                ForEach(queue.items) { item in
                    Button { select(item) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.subject).font(.specialElite(15)).multilineTextAlignment(.leading)
                            Text("\(item.receipt) · \(item.status.title)").font(.caption)
                            Text("\(item.category) · \(item.platform) · \(item.created_at.formatted())").font(.caption2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(selectedID == item.id ? Color.red.opacity(0.15) : Color.sdSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).disabled(busy)
                        .accessibilityIdentifier("admin.support.request.\(item.id.uuidString)")
                        .accessibilityAddTraits(selectedID == item.id ? [.isSelected] : [])
                }
                HStack {
                    if queue.page > 0 { Button("Previous page") { queueLoad(page: queue.page - 1) } }
                    if queue.hasMore, queue.page < 199 { Button("Next page") { queueLoad(page: queue.page + 1) } }
                }.disabled(busy).accessibilityIdentifier("admin.support.pagination")
                if queue.hasMore, queue.page == 199 {
                    Text("The queue page limit is reached. Narrow the status filter or refresh for current requests.").font(.caption)
                }
                if let item = selected { detail(item) }
            }
        }
        .confirmationDialog("Confirm private support status change", isPresented: Binding(
            get: { pending.map { current($0.context) && selected == $0.item } ?? false }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { decision in
                Button("Confirm status change") {
                    pending = nil
                    Task { await update(decision) }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { decision in
                Text("\(decision.item.receipt) · revision \(decision.item.revision)\n\(decision.item.status.title) → \(decision.status.title)\nPrivate note: \(decision.note)\nNo reply or email is sent.")
            }
        .onChange(of: statusFilter) { _, _ in clear(); queueLoad(page: 0) }
        .onChange(of: auth.userId) { _, _ in clear() }
        .onChange(of: auth.isAuthenticated) { _, _ in clear() }
        .onChange(of: phase) { _, newPhase in if newPhase != .active { clear() } }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            guard !Task.isCancelled else { return }
            clear(); if active { await load(page: 0, expectedGeneration: generation) }
        }
        .onDisappear { clear() }
    }

    @ViewBuilder private func detail(_ item: AdminSupportItem) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text(item.subject).font(.specialElite(18))
            Text("Receipt: \(item.receipt) · revision \(item.revision)").font(.caption)
            Text("Account: \(item.user_id.uuidString)").font(.caption2)
            Text("\(item.category) · \(item.platform)\(item.app_version.isEmpty ? "" : " · version " + item.app_version)").font(.caption)
            Text("Received \(item.created_at.formatted()) · updated \(item.updated_at.formatted())").font(.caption2)
            Text(item.body).font(.body).textSelection(.enabled).accessibilityIdentifier("admin.support.body")
            Text("Status: \(item.status.title)").font(.caption)
            if !item.admin_note.isEmpty {
                Text("Current private note").font(.specialElite(14))
                Text(item.admin_note).font(.caption).textSelection(.enabled)
            }
            if item.canUpdate {
                Picker("New status", selection: $nextStatus) {
                    ForEach(AdminSupportStatus.editable) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("admin.support.status")
                TextField("Required private note (up to 2000 characters)", text: $note, axis: .vertical)
                    .lineLimit(3...8).textFieldStyle(.roundedBorder).accessibilityIdentifier("admin.support.note")
                Button("Review status change") { prepare(item) }
                    .disabled(busy || !AdminOperationsClient.supportNoteIsValid(note))
                    .accessibilityIdentifier("admin.support.review")
            } else {
                Text("This request was withdrawn by its member and is read-only.").font(.caption)
                    .accessibilityIdentifier("admin.support.withdrawn")
            }
        }.disabled(busy)
    }

    private func clearSelection() { selectedID = nil; note = ""; pending = nil; nextStatus = .inProgress }
    private func clear() {
        generation = UUID(); busy = false; queue = nil; loadedAccount = nil; displayAccount = nil
        clearSelection(); error = nil; notice = nil
    }
    private func select(_ item: AdminSupportItem) {
        guard !busy, visibleQueue?.items.contains(item) == true else { return }
        generation = UUID(); clearSelection(); selectedID = item.id
        nextStatus = item.canUpdate ? item.status : .inProgress
    }
    private func prepare(_ item: AdminSupportItem) {
        guard !busy, active, let account = auth.userId, selected == item, item.canUpdate,
              AdminSupportStatus.editable.contains(nextStatus), AdminOperationsClient.supportNoteIsValid(note) else { return }
        pending = Decision(item: item, status: nextStatus, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            context: AdminSupportContext(accountID: account, generation: generation))
    }
    /// Capture ownership at the UI event, before its unstructured task is queued.
    /// Disappearance/account/filter/selection changes revoke even a task which
    /// has not started yet; load must never acquire the replacement generation.
    private func queueLoad(page: Int) {
        let expected = generation
        Task { await load(page: page, expectedGeneration: expected) }
    }
    private func load(page: Int, expectedGeneration: UUID, keepingNotice: Bool = false) async {
        guard !Task.isCancelled, generation == expectedGeneration,
              !busy, active, let account = auth.userId else { return }
        generation = UUID(); clearSelection(); queue = nil; loadedAccount = nil; displayAccount = account; error = nil
        if !keepingNotice { notice = nil }
        let context = AdminSupportContext(accountID: account, generation: generation)
        let filter = statusFilter.isEmpty ? nil : AdminSupportStatus(rawValue: statusFilter)
        busy = true
        defer { if current(context) { busy = false } }
        do {
            let value = try await CommunityServices.admin.supportQueue(status: filter, page: page)
            guard current(context) else { return }
            queue = value; loadedAccount = account
        } catch {
            guard current(context) else { return }
            self.error = CommunityServices.admin.noteRefusal(error).errorDescription
        }
    }
    private func update(_ decision: Decision) async {
        guard !busy, current(decision.context), selected == decision.item else { return }
        busy = true; error = nil; notice = nil
        defer { if current(decision.context) { busy = false } }
        do {
            let revision = try await CommunityServices.admin.updateSupport(decision.item, to: decision.status, note: decision.note)
            guard current(decision.context), selected == decision.item else { return }
            notice = "\(decision.item.receipt): \(decision.status.title), revision \(revision), confirmed by the server."
            busy = false
            await load(page: 0, expectedGeneration: decision.context.generation, keepingNotice: true)
        } catch {
            guard current(decision.context) else { return }
            queue = nil; loadedAccount = nil; clearSelection()
            self.error = CommunityServices.admin.noteRefusal(error).errorDescription
        }
    }
}

// MARK: - Backups, releases and provider configuration (#257, #248)
/// Read-only operations status from `sdi_admin_operations` (backups, restore
/// drills, releases, rollbacks, retention) and presence-only provider
/// configuration from `sdi_admin_configuration`. Both are reported by host jobs
/// as outcomes, counts and booleans; no host, path, key or credential reaches
/// this client, and nothing here starts a backup, restore or deployment.
@MainActor
struct AdminOperationsStatusContent: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var status: AdminOperationsStatus?
    @State private var configuration: AdminConfigurationResponse?
    @State private var busy = false
    @State private var error: String?
    @State private var configurationError: String?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backups & releases").font(.specialElite(22))
            Text("Outcomes reported by the host's backup, restore-drill, release and retention jobs. Controls stay on the host; this screen only reads.").font(.caption)
            Button("Refresh") { queueLoad() }.disabled(busy).accessibilityIdentifier("admin.operations.refresh")
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("admin.operations.error") }
            if let status {
                milestone("Daily backup", status.backup, id: "backup")
                milestone("Restore drill", status.restore_drill, id: "restore-drill")
                milestone("Retention sweep", status.retention_sweep, id: "retention-sweep")
                Text("Current release: \(Self.releaseText(status.release))")
                    .font(.caption).accessibilityIdentifier("admin.operations.release")
                if let rollback = status.rollback {
                    Text("Last rollback: \(rollback.label.isEmpty ? "unlabelled" : rollback.label) · \(rollback.outcome ?? "unknown") · \(rollback.at.formatted())").font(.caption)
                }
                Text("Retention").font(.specialElite(16))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(AdminOperationsStatus.retentionTitles, id: \.key) { entry in
                        AdminStatCard(icon: "clock.badge.checkmark", label: entry.title,
                                      value: (status.retention?[entry.key] ?? nil).map(String.init) ?? "not installed", color: "EF4444")
                    }
                }
                Text("Recent reports").font(.specialElite(16))
                if status.recent?.isEmpty ?? true { Text("No operations reported yet.").font(.caption) }
                ForEach(Array((status.recent ?? []).enumerated()), id: \.offset) { _, report in
                    Text(Self.reportText(report)).font(.caption)
                }
                if let note = status.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                if let measured = status.measured_at { Text("Measured \(measured.formatted())").font(.caption2).foregroundStyle(.secondary) }
            }
            Divider()
            Text("Provider configuration").font(.specialElite(18))
            Text("Each service worker reports which named settings are present, as yes/no only. Values are never stored or shown.").font(.caption)
            if let configurationError { Text(configurationError).foregroundStyle(.red).accessibilityIdentifier("admin.configuration.error") }
            if let configuration {
                if configuration.workers?.isEmpty ?? true { Text("No worker has reported its configuration.").font(.caption) }
                ForEach(configuration.workers ?? []) { worker in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(worker.worker) · reported \(worker.reported_at.formatted())\(worker.stale ? " · stale" : "")").font(.specialElite(14))
                        Text(worker.missing.isEmpty ? "All \(worker.settings.count) named settings present."
                             : "Missing: \(worker.missing.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(worker.missing.isEmpty ? Color.primary : StudioCraftTheme.warning)
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("admin.configuration.worker")
                }
            }
            Divider()
            AdminProviderHealthSection()
        }
        .onChange(of: auth.userId) { _, _ in clear() }
        .onChange(of: auth.isAuthenticated) { _, _ in clear() }
        .onChange(of: phase) { _, value in if value != .active { clear() } }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            guard !Task.isCancelled else { return }
            clear()
            if auth.isAuthenticated, phase == .active, let account = auth.userId {
                await load(expectedID: requestID, account: account)
            }
        }
        .onDisappear { clear() }
    }

    @ViewBuilder private func milestone(_ title: String, _ value: AdminOperationsMilestone?, id: String) -> some View {
        if let value {
            HStack(alignment: .top) {
                Circle().fill(value.stale ? StudioCraftTheme.warning : Color.green).frame(width: 8, height: 8).padding(.top, 4).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(title)\(value.stale ? " · overdue" : "")").font(.specialElite(14))
                    Text("Last success: \(value.last_succeeded_at?.formatted() ?? "never reported")").font(.caption)
                    if let failed = value.last_failed_at { Text("Last failure: \(failed.formatted())").font(.caption).foregroundStyle(StudioCraftTheme.warning) }
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("admin.operations.\(id)")
        }
    }
    private static func releaseText(_ release: AdminOperationsRelease?) -> String {
        guard let release else { return "never reported" }
        return "\(release.label.isEmpty ? "unlabelled" : release.label) since \(release.at.formatted())"
    }
    private static func reportText(_ report: AdminOperationsReport) -> String {
        var parts = [report.kind.replacingOccurrences(of: "_", with: " "), report.outcome]
        if !report.label.isEmpty { parts.append(report.label) }
        parts.append(report.created_at.formatted())
        let metrics: [String] = report.metrics.keys.sorted().map { key in
            let name = key.replacingOccurrences(of: "_", with: " ")
            return "\(name) \(report.metrics[key] ?? 0)"
        }
        if !metrics.isEmpty { parts.append(metrics.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
    private func clear() { requestID = UUID(); busy = false; status = nil; configuration = nil; error = nil; configurationError = nil }
    private func current(_ id: UUID, account: String) -> Bool {
        !Task.isCancelled && requestID == id && auth.isAuthenticated &&
        auth.userId == account && phase == .active
    }
    private func queueLoad() {
        guard auth.isAuthenticated, phase == .active, let account = auth.userId else { return }
        let expected = requestID
        Task { await load(expectedID: expected, account: account) }
    }
    private func load(expectedID: UUID, account: String) async {
        guard !busy, current(expectedID, account: account) else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let value = try await CommunityServices.admin.operations()
            guard current(id, account: account) else { return }
            status = value; error = nil
        } catch {
            guard current(id, account: account) else { return }
            status = nil; self.error = CommunityServices.admin.noteRefusal(error).errorDescription
        }
        // A current first-section failure may still load the independent
        // configuration section; stale/cancelled work never starts its RPC.
        guard current(id, account: account) else { return }
        do {
            let value = try await CommunityServices.admin.configuration()
            guard current(id, account: account) else { return }
            configuration = value; configurationError = nil
        } catch {
            guard current(id, account: account) else { return }
            configuration = nil; configurationError = CommunityServices.admin.noteRefusal(error).errorDescription
        }
    }
}

// MARK: - Agent inbox, run history and audit log (#284)
/// Proposals an agent filed instead of acting above its caps, with owner-only
/// approve/reject (reason required, audited server-side); a searchable run log
/// and audit log with bounded retention. Approving hands a proposal to the
/// worker; nothing executes from this screen.
@MainActor
struct AdminAgentInboxContent: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var console: [AdminAgentConsoleEntry] = []
    @State private var proposals: [AdminAgentProposal] = []
    @State private var pending = 0
    private struct Decision {
        let proposal: AdminAgentProposal
        let approve: Bool
        let reason: String
        let account: String
        let generation: UUID
    }
    private struct HistoryRequest {
        let page: Int
        let agent: String?
        let state: String?
        let query: String
    }
    @State private var decision: Decision?
    @State private var reason = ""
    @State private var agentFilter = ""
    @State private var stateFilter = ""
    @State private var query = ""
    @State private var runs: AdminAgentHistoryPage<AdminAgentRun>?
    @State private var audit: AdminAgentHistoryPage<AdminAgentAuditEntry>?
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var requestID = UUID()
    private var reasonValid: Bool { (1...2000).contains(reason.trimmingCharacters(in: .whitespacesAndNewlines).count) }
    private var agentKey: String? { agentFilter.isEmpty ? nil : agentFilter }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent inbox & log").font(.specialElite(22))
            Text("Agents with the propose permission file a proposal instead of acting above their caps. Only the owner approves or rejects, with a reason; pending proposals expire after 14 days.").font(.caption)
            Button("Refresh") { queueLoadAll() }.disabled(busy).accessibilityIdentifier("admin.inbox.refresh")
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("admin.inbox.error") }
            if let notice { Text(notice).font(.caption) }

            ForEach(console) { agent in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(agent.title) · \(agent.paused ? "paused" : "enabled")").font(.specialElite(14))
                    Text(Self.agentText(agent)).font(.caption)
                    if let failure = agent.last_error { Text("Last error: \(failure)").font(.caption).foregroundStyle(StudioCraftTheme.warning).lineLimit(3) }
                }.accessibilityElement(children: .combine)
            }

            Text("Proposals (\(pending) pending)").font(.specialElite(18))
            TextField("Required reason for a decision", text: $reason, axis: .vertical).lineLimit(2...4)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("admin.inbox.reason")
            if proposals.isEmpty { Text("No proposals.").font(.caption) }
            ForEach(proposals) { proposal in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(proposal.agent_key) · \(proposal.kind) · \(proposal.state)").font(.specialElite(14))
                    Text(proposal.summary).font(.caption)
                    Text("Exceeds: \(proposal.cap_reason) · estimate \(proposal.estimated_cost_minor) minor units · proposed \(proposal.proposed_at.formatted()) · expires \(proposal.expires_at.formatted())").font(.caption2)
                    if let note = proposal.decision_note, !note.isEmpty { Text("Decision: \(note)").font(.caption2) }
                    if let outcome = proposal.outcome, !outcome.isEmpty { Text("Outcome: \(outcome)").font(.caption2) }
                    if proposal.state == "pending" {
                        HStack {
                            Button("Approve") { prepareDecision(proposal, approve: true) }.accessibilityIdentifier("admin.inbox.approve")
                            Button("Reject", role: .destructive) { prepareDecision(proposal, approve: false) }.accessibilityIdentifier("admin.inbox.reject")
                        }.disabled(busy || !reasonValid)
                    }
                }.padding(8).background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Divider()
            Text("Run history and audit").font(.specialElite(18))
            Picker("Agent", selection: $agentFilter) {
                Text("All agents").tag("")
                ForEach(console) { Text($0.title).tag($0.key) }
            }.accessibilityIdentifier("admin.inbox.agent")
            Picker("Run state", selection: $stateFilter) {
                Text("Any state").tag("")
                ForEach(AdminAgentHistoryFilter.states, id: \.self) { Text($0.capitalized).tag($0) }
            }.accessibilityIdentifier("admin.inbox.state")
            TextField("Search references, errors or audit reasons", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("admin.inbox.query")
            Button("Search history") { queueHistory(page: 0) }
                .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).count > 100)
                .accessibilityIdentifier("admin.inbox.search")
            if let runs {
                Text("Runs · page \(runs.page + 1)").font(.specialElite(15))
                if runs.items.isEmpty { Text("No matching runs.").font(.caption) }
                ForEach(runs.items) { run in
                    Text(Self.runText(run)).font(.caption)
                }
            }
            if let audit {
                Text("Audit · page \(audit.page + 1)").font(.specialElite(15))
                if audit.items.isEmpty { Text("No matching audit entries.").font(.caption) }
                ForEach(audit.items) { entry in
                    Text("\(entry.created_at.formatted()) · \(entry.agent_key ?? "all agents") · \(entry.action) · \(entry.reason)").font(.caption)
                }
            }
            if let runs, let audit {
                HStack {
                    if runs.page > 0 { Button("Previous page") { queueHistory(page: runs.page - 1) } }
                    if runs.hasMore || audit.hasMore { Button("Next page") { queueHistory(page: runs.page + 1) } }
                }.disabled(busy)
            }
            Text("Finished runs are kept 180 days and audit entries 400 days; audit entries cannot be edited.").font(.caption2).foregroundStyle(.secondary)
        }
        .confirmationDialog("Confirm proposal decision", isPresented: Binding(get: {
            decision.map { current($0.generation, account: $0.account) && proposals.contains($0.proposal) } ?? false
        }, set: { if !$0 { decision = nil } }),
                            titleVisibility: .visible, presenting: decision) { pending in
            Button(pending.approve ? "Approve for the worker" : "Reject proposal", role: pending.approve ? nil : .destructive) {
                decision = nil
                Task { await decide(pending) }
            }
            Button("Cancel", role: .cancel) { decision = nil }
        } message: { pending in
            Text("\(pending.proposal.summary)\nReason: \(pending.reason)\n" +
                 (pending.approve ? "The worker may execute it on its next permitted run, never under emergency stop or pause." : "Nothing will run."))
        }
        .onChange(of: auth.userId) { _, _ in clear() }
        .onChange(of: auth.isAuthenticated) { _, _ in clear() }
        .onChange(of: phase) { _, value in if value != .active { clear() } }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            guard !Task.isCancelled else { return }
            clear()
            if auth.isAuthenticated, phase == .active, let account = auth.userId {
                await loadAll(expectedID: requestID, account: account)
            }
        }
        .onDisappear { clear() }
    }

    private static func runText(_ run: AdminAgentRun) -> String {
        var parts = [run.agent_key, run.state, run.started_at.formatted(), "\(run.items) items", "cost \(run.cost_minor)"]
        if let reference = run.source_ref, !reference.isEmpty { parts.append(reference) }
        if let failure = run.error, !failure.isEmpty { parts.append(failure) }
        return parts.joined(separator: " · ")
    }
    private static func agentText(_ agent: AdminAgentConsoleEntry) -> String {
        let pending = agent.pending_proposals.map(String.init) ?? "inbox not installed"
        let cap = agent.per_run_cost_cap_minor.map { "\($0) minor units" } ?? "monthly cap only"
        let started = agent.last_started?.formatted() ?? "never"
        return "Pending proposals: \(pending) · per-run cost cap: \(cap) · last start: \(started)"
    }
    private func clear() {
        requestID = UUID(); busy = false; console = []; proposals = []; pending = 0; decision = nil; reason = ""
        agentFilter = ""; stateFilter = ""; query = ""; runs = nil; audit = nil; error = nil; notice = nil
    }
    private func current(_ id: UUID, account: String) -> Bool {
        !Task.isCancelled && requestID == id && auth.isAuthenticated &&
        auth.userId == account && phase == .active
    }
    private func queueLoadAll() {
        guard auth.isAuthenticated, phase == .active, let account = auth.userId else { return }
        let expected = requestID
        Task { await loadAll(expectedID: expected, account: account) }
    }
    private func queueHistory(page: Int) {
        guard auth.isAuthenticated, phase == .active, let account = auth.userId else { return }
        let expected = requestID
        let input = HistoryRequest(page: page, agent: agentKey,
            state: stateFilter.isEmpty ? nil : stateFilter, query: query)
        Task { await loadHistory(input, expectedID: expected, account: account) }
    }
    private func prepareDecision(_ proposal: AdminAgentProposal, approve: Bool) {
        guard !busy, auth.isAuthenticated, phase == .active, let account = auth.userId,
              reasonValid, proposal.state == "pending", proposals.contains(proposal) else { return }
        decision = Decision(proposal: proposal, approve: approve,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), account: account, generation: requestID)
    }
    private func loadAll(expectedID: UUID, account: String) async {
        guard !busy, current(expectedID, account: account) else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let entries = try await CommunityServices.admin.agentConsole()
            guard current(id, account: account) else { return }
            let inbox = try await CommunityServices.admin.proposalInbox()
            guard current(id, account: account) else { return }
            console = entries; proposals = inbox.proposals; pending = inbox.pending; error = nil
            if !agentFilter.isEmpty, !entries.contains(where: { $0.key == agentFilter }) { agentFilter = "" }
        } catch {
            guard current(id, account: account) else { return }
            console = []; proposals = []; pending = 0; self.error = CommunityServices.admin.noteRefusal(error).errorDescription
        }
    }
    private func loadHistory(_ input: HistoryRequest, expectedID: UUID, account: String) async {
        guard !busy, current(expectedID, account: account) else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let runPage = try await CommunityServices.admin.agentRunHistory(agent: input.agent,
                state: input.state, query: input.query, page: input.page)
            guard current(id, account: account) else { return }
            let auditPage = try await CommunityServices.admin.agentAudit(agent: input.agent, query: input.query, page: input.page)
            guard current(id, account: account) else { return }
            runs = runPage; audit = auditPage; error = nil
        } catch {
            guard current(id, account: account) else { return }
            runs = nil; audit = nil; self.error = CommunityServices.admin.noteRefusal(error).errorDescription
        }
    }
    private func decide(_ pending: Decision) async {
        guard !busy, current(pending.generation, account: pending.account),
              pending.proposal.state == "pending", proposals.contains(pending.proposal),
              (1...2000).contains(pending.reason.count) else { return }
        let id = UUID(); requestID = id; busy = true; error = nil; notice = nil
        defer { if requestID == id { busy = false } }
        do {
            let state = try await CommunityServices.admin.decideProposal(pending.proposal,
                approve: pending.approve, reason: pending.reason)
            guard current(id, account: pending.account) else { return }
            notice = "Proposal \(state) and audited."
            // Do not erase a newer draft typed while this exact decision ran.
            if reason.trimmingCharacters(in: .whitespacesAndNewlines) == pending.reason { reason = "" }
            busy = false
            await loadAll(expectedID: id, account: pending.account)
        } catch {
            guard current(id, account: pending.account) else { return }
            self.error = CommunityServices.admin.noteRefusal(error).errorDescription
        }
    }
}
