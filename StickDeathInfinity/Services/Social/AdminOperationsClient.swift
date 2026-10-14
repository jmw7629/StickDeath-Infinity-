// ═══════════════════════════════════════════════════════════════════
// AdminOperationsClient — admin command-center panels over the hardened
// RPC contracts: access/step-up (admin-hardening.sql), service health,
// agent controls (agent-controls.sql), finance reads and owner-only product
// configuration (billing.sql), room report queue (rooms-v2.sql), feed removal
// appeals (rooms-v2.sql), render decision history (admin-approval.sql),
// backup/release status (admin-hardening.sql), masked provider configuration
// (worker-configuration.sql) and the agent proposal inbox, searchable run
// history and audit log (agent-proposals.sql, agent-controls.sql).
// Opening a panel grants nothing: every reply is server-authorized with MFA,
// and sensitive actions are preceded by the recent re-authentication check.
// ═══════════════════════════════════════════════════════════════════

import Foundation

@MainActor
final class AdminOperationsClient {
    let gateway: CommunityGateway
    private(set) var stepUp = AdminStepUpPolicy()
    init(gateway: CommunityGateway) { self.gateway = gateway }

    struct Access: Equatable { let owner: Bool; let capabilities: Set<String>; let stepUpCurrent: Bool? }
    func access() async throws -> Access {
        let response = try await gateway.call("sdi_admin_permissions", params: ["action": "mine"], as: AdminAccessResponse.self)
        guard let owner = response.owner, let granted = response.capabilities else { throw CommunityError.invalidResponse("Administrator access unavailable.") }
        stepUp.stepUpCurrent = response.step_up_current
        return Access(owner: owner, capabilities: Set(granted), stepUpCurrent: response.step_up_current)
    }
    /// Recent re-authentication gate (#210). Returns the prompt text when the
    /// member must re-verify before the request may be sent.
    func stepUpPrompt(for action: String, now: Date = Date()) -> String? {
        if case .reverify(let message) = stepUp.decision(for: action, now: now) { return message }
        return nil
    }
    func recordVerification(at date: Date = Date()) { stepUp.recordVerification(at: date) }
    /// Map a server refusal: `step_up_required` clears the local window.
    func noteRefusal(_ error: Error) -> CommunityError {
        let normalized = CommunityGateway.normalize(error)
        if normalized.isStepUpRequired { stepUp.recordRefusal() }
        return normalized
    }

    // MARK: Health (#257)
    func health() async throws -> AdminHealthResponse {
        try await gateway.call("sdi_admin_health", params: [String: String](), as: AdminHealthResponse.self).validated()
    }

    // MARK: Agents (#248)
    func agents() async throws -> AdminAgentsResponse {
        let response = try await gateway.call("sdi_agent_admin", params: AdminAgentRequest(action: "list"), as: AdminAgentsResponse.self)
        guard response.agents != nil, response.emergency_stop != nil else { throw CommunityError.invalidResponse("Agent registry unavailable.") }
        return response
    }
    func agentRuns(_ agent: String?) async throws -> [AdminAgentRun] {
        let response = try await gateway.call("sdi_agent_admin", params: AdminAgentRequest(action: "runs", agent: agent), as: AdminAgentsResponse.self)
        guard let runs = response.runs else { throw CommunityError.invalidResponse("Run log unavailable.") }
        return runs
    }
    func agentInstructions(_ agent: String) async throws -> (active: Int?, versions: [AdminAgentInstruction]) {
        let response = try await gateway.call("sdi_agent_admin", params: AdminAgentRequest(action: "instructions", agent: agent), as: AdminAgentsResponse.self)
        guard let versions = response.instructions else { throw CommunityError.invalidResponse("Instruction history unavailable.") }
        return (response.active, versions)
    }
    /// Owner mutations: pause/resume/set_caps/set_permissions/publish/rollback/emergency_stop.
    func mutateAgent(_ request: AdminAgentRequest) async throws -> Int? {
        guard (1...2000).contains(request.reason.trimmingCharacters(in: .whitespacesAndNewlines).count) else { throw CommunityError.server(message: "A reason is required.", code: nil) }
        let response = try await gateway.call("sdi_agent_admin", params: request, as: AdminAgentsResponse.self)
        guard response.status == "confirmed" else { throw CommunityError.invalidResponse("Agent change was not confirmed.") }
        return response.revision
    }

    /// Registry extras (#248, #284): per-run cost cap, last error, last start and
    /// pending proposal depth. Same reply as `agents()`, decoded for the console.
    func agentConsole() async throws -> [AdminAgentConsoleEntry] {
        let response = try await gateway.call("sdi_agent_admin", params: AdminAgentRequest(action: "list"), as: AdminAgentConsoleResponse.self)
        guard let agents = response.agents else { throw CommunityError.invalidResponse("Agent registry unavailable.") }
        return agents
    }
    /// Searchable, paged run log. `state` is one of the server's run states.
    func agentRunHistory(agent: String?, state: String? = nil, query: String = "", page: Int = 0) async throws -> AdminAgentHistoryPage<AdminAgentRun> {
        let request = try AdminAgentHistoryFilter(state: state, query: query, page: page).request(action: "runs", agent: agent)
        let response = try await gateway.call("sdi_agent_admin", params: request, as: AdminAgentHistoryResponse.self)
        guard let runs = response.runs, runs.count <= 50, let more = response.has_more else { throw CommunityError.invalidResponse("Run log unavailable.") }
        return AdminAgentHistoryPage(items: runs, hasMore: more, page: page)
    }
    /// Searchable, paged agent audit log (owner changes, emergency stops, proposal decisions).
    func agentAudit(agent: String?, query: String = "", page: Int = 0) async throws -> AdminAgentHistoryPage<AdminAgentAuditEntry> {
        let request = try AdminAgentHistoryFilter(state: nil, query: query, page: page).request(action: "audit", agent: agent)
        let response = try await gateway.call("sdi_agent_admin", params: request, as: AdminAgentHistoryResponse.self)
        guard let audit = response.audit, audit.count <= 50, let more = response.has_more else { throw CommunityError.invalidResponse("Audit log unavailable.") }
        return AdminAgentHistoryPage(items: audit, hasMore: more, page: page)
    }

    // MARK: Agent proposal inbox (#284)
    func proposalInbox(agent: String? = nil) async throws -> (proposals: [AdminAgentProposal], pending: Int) {
        let response = try await gateway.call("sdi_agent_proposal_admin", params: AdminProposalRequest(action: "inbox", agent: agent), as: AdminProposalResponse.self)
        guard let proposals = response.proposals, proposals.count <= 100, let pending = response.pending, pending >= 0 else {
            throw CommunityError.invalidResponse("Proposal inbox unavailable.")
        }
        return (proposals, pending)
    }
    /// Owner decision on a pending proposal. Approval only hands it to the worker;
    /// nothing executes from this client.
    func decideProposal(_ proposal: AdminAgentProposal, approve: Bool, reason: String) async throws -> String {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count) else { throw CommunityError.server(message: "A reason is required.", code: nil) }
        guard proposal.state == "pending" else { throw CommunityError.server(message: "Only a pending proposal can be decided.", code: nil) }
        let response = try await gateway.call("sdi_agent_proposal_admin",
            params: AdminProposalRequest(action: approve ? "approve" : "reject", proposal: proposal.id, revision: proposal.revision, reason: text),
            as: AdminProposalResponse.self)
        let expected = approve ? "approved" : "rejected"
        guard response.status == "confirmed", response.state == expected else { throw CommunityError.invalidResponse("Decision was not confirmed.") }
        return expected
    }

    // MARK: Provider configuration presence (#248)
    func configuration() async throws -> AdminConfigurationResponse {
        try await gateway.call("sdi_admin_configuration", params: [String: String](), as: AdminConfigurationResponse.self).validated()
    }

    // MARK: Backups, releases and retention (#257)
    func operations() async throws -> AdminOperationsStatus {
        try await gateway.call("sdi_admin_operations", params: [String: String](), as: AdminOperationsStatus.self).validated()
    }

    // MARK: Finance (#255)
    func finance(_ request: AdminFinanceRequest) async throws -> AdminFinanceResponse {
        let response = try await gateway.call("sdi_finance_admin", params: request, as: AdminFinanceResponse.self)
        switch request.action {
        case "products": guard response.products != nil else { throw CommunityError.invalidResponse("Product list unavailable.") }
        case "subscriptions": guard response.subscriptions != nil else { throw CommunityError.invalidResponse("Subscriptions unavailable.") }
        case "ledger": guard response.ledger != nil else { throw CommunityError.invalidResponse("Ledger unavailable.") }
        case "events": guard response.events != nil else { throw CommunityError.invalidResponse("Provider events unavailable.") }
        case "summary": guard response.totals != nil else { throw CommunityError.invalidResponse("Summary unavailable.") }
        default: guard response.status == "confirmed" else { throw CommunityError.invalidResponse("Finance change was not confirmed.") }
        }
        return response
    }

    // MARK: Room reports (#235/#247)
    func roomReports() async throws -> [AdminRoomReport] {
        let response = try await gateway.call("sdi_room_moderate", params: AdminRoomModerateRequest(action: "list"), as: AdminRoomModerateResponse.self)
        guard let reports = response.reports, reports.count <= 50 else { throw CommunityError.invalidResponse("Room report queue unavailable.") }
        return reports
    }
    func decideRoomReport(_ report: AdminRoomReport, close: Bool, reason: String) async throws {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count) else { throw CommunityError.server(message: "A decision reason is required.", code: nil) }
        let response = try await gateway.call("sdi_room_moderate", params: AdminRoomModerateRequest(action: close ? "close" : "dismiss", report: report.id, revision: report.revision, reason: text), as: AdminRoomModerateResponse.self)
        guard response.status == "confirmed" else { throw CommunityError.invalidResponse("Decision was not confirmed.") }
    }

    // MARK: Feed removal appeals (#247)
    func appealQueue() async throws -> [ModerationAppeal] {
        let response = try await gateway.call("sdi_moderation_appeal", params: ModerationAppealRequest(action: "queue"), as: ModerationAppealResponse.self)
        guard let appeals = response.appeals, appeals.count <= 50 else { throw CommunityError.invalidResponse("Appeal queue unavailable.") }
        return appeals
    }
    func decideAppeal(_ appeal: ModerationAppeal, accept: Bool, note: String) async throws {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count), let revision = appeal.revision else { throw CommunityError.server(message: "A current appeal and a member-visible decision reason are required.", code: nil) }
        let response = try await gateway.call("sdi_moderation_appeal", params: ModerationAppealRequest(action: accept ? "accept" : "reject", appeal: appeal.id, revision: revision, note: text), as: ModerationAppealResponse.self)
        guard response.status == "confirmed" else { throw CommunityError.invalidResponse("Decision was not confirmed.") }
    }
    /// Member side: own appeals and submission for a removed rendition.
    func myAppeals() async throws -> [ModerationAppeal] {
        let response = try await gateway.call("sdi_moderation_appeal", params: ModerationAppealRequest(action: "mine"), as: ModerationAppealResponse.self)
        guard let appeals = response.appeals else { throw CommunityError.invalidResponse("Appeals unavailable.") }
        return appeals
    }
    func submitAppeal(media: UUID, explanation: String) async throws -> [ModerationAppeal] {
        let text = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count) else { throw CommunityError.server(message: "Explain the appeal in up to 2000 characters.", code: nil) }
        let response = try await gateway.call("sdi_moderation_appeal", params: ModerationAppealRequest(action: "submit", media: media, explanation: text), as: ModerationAppealResponse.self)
        guard let appeals = response.appeals else { throw CommunityError.invalidResponse("Appeal was not confirmed.") }
        return appeals
    }

    // MARK: Render decision history (#211/#214)
    func reviewHistory(page: Int) async throws -> [AdminRenderDecisionRecord] {
        guard (0...199).contains(page) else { throw CommunityError.invalidResponse("History page out of range.") }
        let response = try await gateway.call("sdi_review_history", params: AdminReviewHistoryRequest(page: page), as: AdminReviewHistoryResponse.self)
        guard let decisions = response.decisions, decisions.count <= 50 else { throw CommunityError.invalidResponse("History unavailable.") }
        return decisions
    }
    /// Decisions for one render, across the latest `pages` history pages. The
    /// result says how many pages were searched so the UI never implies completeness.
    func decisions(for review: UUID, pages: Int = 3) async throws -> (records: [AdminRenderDecisionRecord], searchedPages: Int) {
        var found: [AdminRenderDecisionRecord] = []
        var searched = 0
        for page in 0..<max(1, min(pages, 200)) {
            let batch = try await reviewHistory(page: page)
            searched += 1
            found.append(contentsOf: batch.filter { $0.review_id == review })
            if batch.count < 50 { break }
        }
        return (found.sorted { $0.created_at > $1.created_at }, searched)
    }
}

// MARK: - Command-center contracts (#248, #257, #284)

struct AdminAgentConsoleEntry: Decodable, Identifiable, Equatable {
    var id: String { key }
    let key: String
    let title: String
    let paused: Bool
    let per_run_cost_cap_minor: Int?
    let last_error: String?
    let last_started: Date?
    /// Null when the proposal inbox candidate is not installed.
    let pending_proposals: Int?
}
struct AdminAgentConsoleResponse: CommunityCodedResponse {
    let error: String?
    let code: String?
    let agents: [AdminAgentConsoleEntry]?
}

struct AdminAgentAuditEntry: Decodable, Identifiable, Equatable {
    let id: UUID; let actor: UUID; let agent_key: String?; let action: String; let reason: String; let created_at: Date
}
struct AdminAgentHistoryPage<Item: Equatable>: Equatable {
    let items: [Item]; let hasMore: Bool; let page: Int
}
struct AdminAgentHistoryResponse: CommunityCodedResponse {
    let error: String?
    let code: String?
    let runs: [AdminAgentRun]?
    let audit: [AdminAgentAuditEntry]?
    let has_more: Bool?
}
/// Client bounds mirror the server's (`Invalid history filter.`), so an
/// out-of-range filter is never sent.
struct AdminAgentHistoryFilter: Equatable {
    static let states = ["running", "succeeded", "failed", "stopped"]
    var state: String?
    var query: String
    var page: Int
    func request(action: String, agent: String?) throws -> AdminAgentRequest {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (0...199).contains(page), text.count <= 100 else { throw CommunityError.invalidResponse("History filter out of range.") }
        if let state, !Self.states.contains(state) { throw CommunityError.invalidResponse("Unknown run state.") }
        var fields: [String: CommunityJSONValue] = ["query": .string(text), "page": .string(String(page))]
        if let state { fields["state"] = .string(state) }
        return AdminAgentRequest(action: action, agent: agent, payload: .object(fields))
    }
}

struct AdminAgentProposal: Decodable, Identifiable, Equatable {
    let id: UUID
    let agent_key: String
    let kind: String
    let summary: String
    let estimated_cost_minor: Int
    let cap_reason: String
    let state: String
    let proposed_at: Date
    let expires_at: Date
    let decided_by: UUID?
    let decided_at: Date?
    let decision_note: String?
    let outcome: String?
    let revision: Int
}
struct AdminProposalRequest: Encodable, Equatable {
    let action: String
    var proposal: UUID? = nil
    var revision: Int? = nil
    var reason = ""
    var agent: String? = nil
}
struct AdminProposalResponse: CommunityCodedResponse {
    let error: String?
    let code: String?
    let status: String?
    let state: String?
    let proposals: [AdminAgentProposal]?
    let pending: Int?
}

enum AdminIdentifier {
    /// Lowercase letters, digits and underscore (plus `extra` bytes), 1...40 bytes.
    static func isBounded(_ value: String, extra: Set<UInt8> = []) -> Bool {
        (1...40).contains(value.utf8.count)
            && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || extra.contains($0) }
    }
    /// The server's label rule: empty, a version number (1.4.0, v2.0.1-rc.1) or a commit hash.
    static let releaseLabelPattern = #"^(v?[0-9]{1,6}(\.[0-9]{1,6}){0,3}([-+][0-9A-Za-z]{1,20}(\.[0-9A-Za-z]{1,20}){0,3})?|[0-9a-f]{7,40})$"#
    static func isReleaseLabel(_ value: String) -> Bool {
        value.isEmpty || (value.utf8.count <= 120 && value.range(of: releaseLabelPattern, options: .regularExpression) != nil)
    }
}

/// Presence-only provider configuration: setting names with booleans, never values.
struct AdminWorkerConfiguration: Decodable, Identifiable, Equatable {
    var id: String { worker }
    let worker: String
    let reported_at: Date
    let stale: Bool
    let settings: [String: Bool]
    let missing: [String]
}
struct AdminConfigurationResponse: CommunityCodedResponse {
    let error: String?
    let code: String?
    let workers: [AdminWorkerConfiguration]?
    let note: String?
    /// Fail closed on anything that is not a bounded identifier, so a value that
    /// looks like a host, URL or key is never displayed.
    func validated() throws -> AdminConfigurationResponse {
        guard let workers, workers.count <= 100 else { throw CommunityError.invalidResponse("Configuration reply incomplete.") }
        for worker in workers {
            guard AdminIdentifier.isBounded(worker.worker, extra: [45]), worker.settings.count <= 40,
                  worker.settings.keys.allSatisfy({ AdminIdentifier.isBounded($0) }),
                  worker.missing.allSatisfy({ worker.settings[$0] == false }) else {
                throw CommunityError.invalidResponse("Configuration reply contained an unexpected identifier.")
            }
        }
        return self
    }
}

struct AdminOperationsMilestone: Decodable, Equatable {
    let last_succeeded_at: Date?
    let last_failed_at: Date?
    let stale: Bool
}
struct AdminOperationsRelease: Decodable, Equatable {
    let label: String
    let at: Date
    let outcome: String?
}
struct AdminOperationsReport: Decodable, Equatable {
    let kind: String
    let outcome: String
    let label: String
    let metrics: [String: Int]
    let created_at: Date
}
/// Backups, restore drills, releases, rollbacks and retention as reported by
/// host jobs (`sdi_admin_operations`). Read-only: no control endpoint exists.
struct AdminOperationsStatus: CommunityCodedResponse {
    let error: String?
    let code: String?
    let backup: AdminOperationsMilestone?
    let restore_drill: AdminOperationsMilestone?
    let retention_sweep: AdminOperationsMilestone?
    let release: AdminOperationsRelease?
    let rollback: AdminOperationsRelease?
    let retention: [String: Int?]?
    let recent: [AdminOperationsReport]?
    let note: String?
    let measured_at: Date?

    static let kinds: Set<String> = ["backup", "restore_drill", "release", "rollback", "retention_sweep"]
    static let retentionTitles: [(key: String, title: String)] = [
        ("render_artifacts_live", "Private renders within retention"),
        ("render_artifacts_expired", "Private renders past expiry"),
        ("deletion_requests_blocked", "Account deletions blocked"),
    ]
    /// Fail closed: a reply carries its measurement time and every milestone;
    /// labels are version-shaped and metrics are named non-negative counts.
    func validated() throws -> AdminOperationsStatus {
        guard measured_at != nil, backup != nil, restore_drill != nil, retention_sweep != nil, let recent, recent.count <= 20 else {
            throw CommunityError.invalidResponse("Operations reply incomplete.")
        }
        for report in recent {
            guard Self.kinds.contains(report.kind), ["succeeded", "failed"].contains(report.outcome), AdminIdentifier.isReleaseLabel(report.label),
                  report.metrics.count <= 20, report.metrics.allSatisfy({ AdminIdentifier.isBounded($0.key) && $0.value >= 0 }) else {
                throw CommunityError.invalidResponse("Operations reply contained an unexpected record.")
            }
        }
        for label in [release?.label, rollback?.label].compactMap({ $0 }) where !AdminIdentifier.isReleaseLabel(label) {
            throw CommunityError.invalidResponse("Operations reply contained an unexpected label.")
        }
        for (_, value) in retention ?? [:] { if let value, value < 0 { throw CommunityError.invalidResponse("Negative retention count.") } }
        return self
    }
}
