import SwiftUI

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
            Button("Refresh") { Task { await load() } }.disabled(busy).accessibilityIdentifier("admin.operations.refresh")
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
        }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await load() }
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
    private func load() async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let value = try await CommunityServices.admin.operations()
            guard !Task.isCancelled, requestID == id else { return }
            status = value; error = nil
        } catch { if requestID == id { status = nil; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
        do {
            let value = try await CommunityServices.admin.configuration()
            guard !Task.isCancelled, requestID == id else { return }
            configuration = value; configurationError = nil
        } catch { if requestID == id { configuration = nil; configurationError = CommunityServices.admin.noteRefusal(error).errorDescription } }
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
    @State private var decision: (proposal: AdminAgentProposal, approve: Bool)?
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
            Button("Refresh") { Task { await loadAll() } }.disabled(busy).accessibilityIdentifier("admin.inbox.refresh")
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
                            Button("Approve") { decision = (proposal, true) }.accessibilityIdentifier("admin.inbox.approve")
                            Button("Reject", role: .destructive) { decision = (proposal, false) }.accessibilityIdentifier("admin.inbox.reject")
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
            Button("Search history") { Task { await loadHistory(page: 0) } }
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
                    if runs.page > 0 { Button("Previous page") { Task { await loadHistory(page: runs.page - 1) } } }
                    if runs.hasMore || audit.hasMore { Button("Next page") { Task { await loadHistory(page: runs.page + 1) } } }
                }.disabled(busy)
            }
            Text("Finished runs are kept 180 days and audit entries 400 days; audit entries cannot be edited.").font(.caption2).foregroundStyle(.secondary)
        }
        .confirmationDialog("Confirm proposal decision", isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } }),
                            titleVisibility: .visible, presenting: decision) { pending in
            Button(pending.approve ? "Approve for the worker" : "Reject proposal", role: pending.approve ? nil : .destructive) {
                decision = nil
                Task { await decide(pending.proposal, approve: pending.approve) }
            }
            Button("Cancel", role: .cancel) { decision = nil }
        } message: { pending in
            Text("\(pending.proposal.summary)\nReason: \(reason.trimmingCharacters(in: .whitespacesAndNewlines))\n" +
                 (pending.approve ? "The worker may execute it on its next permitted run, never under emergency stop or pause." : "Nothing will run."))
        }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await loadAll() }
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
    private func loadAll() async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let entries = try await CommunityServices.admin.agentConsole()
            let inbox = try await CommunityServices.admin.proposalInbox()
            guard !Task.isCancelled, requestID == id else { return }
            console = entries; proposals = inbox.proposals; pending = inbox.pending; error = nil
            if !agentFilter.isEmpty, !entries.contains(where: { $0.key == agentFilter }) { agentFilter = "" }
        } catch { if requestID == id { console = []; proposals = []; pending = 0; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
    private func loadHistory(page: Int) async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        let agent = agentKey, state = stateFilter.isEmpty ? nil : stateFilter, text = query
        do {
            let runPage = try await CommunityServices.admin.agentRunHistory(agent: agent, state: state, query: text, page: page)
            let auditPage = try await CommunityServices.admin.agentAudit(agent: agent, query: text, page: page)
            guard !Task.isCancelled, requestID == id else { return }
            runs = runPage; audit = auditPage; error = nil
        } catch { if requestID == id { runs = nil; audit = nil; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
    private func decide(_ proposal: AdminAgentProposal, approve: Bool) async {
        guard !busy, auth.isAuthenticated, phase == .active, reasonValid else { return }
        let id = UUID(); requestID = id; busy = true; error = nil; notice = nil
        defer { if requestID == id { busy = false } }
        do {
            let state = try await CommunityServices.admin.decideProposal(proposal, approve: approve, reason: reason)
            guard !Task.isCancelled, requestID == id else { return }
            notice = "Proposal \(state) and audited."; reason = ""; busy = false
            await loadAll()
        } catch { if requestID == id { self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
}
