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

// MARK: - Render review evidence (#213, #214)

/// Reviewer-facing lines for what a render was submitted with: the script and
/// storyboard, the editable project's digest and the measured quality report
/// (`sdi_review_action` list). Empty arrays mean "not supplied"; the view says
/// so in those words and never fills the gap with a placeholder.
enum AdminReviewEvidence {
    static let maximumLines = 40
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func digestLine(_ digest: String?) -> String {
        guard let digest else { return "Editable project digest: not supplied for this render." }
        guard isDigest(digest) else { return "Editable project digest: unrecognized value (not shown)." }
        return "Editable project digest: \(digest)"
    }
    private static func number(_ value: CommunityJSONValue?) -> String? {
        guard case .number(let raw)? = value, raw.isFinite else { return nil }
        return raw == raw.rounded() && abs(raw) < 1e15 ? String(Int64(raw)) : String(format: "%.3f", raw)
    }
    private static func bounded(_ text: String, _ limit: Int = 500) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
    static func storyboardLines(_ value: CommunityJSONValue?) -> [String] {
        guard let value, value != .null else { return [] }
        guard let object = value.objectValue else { return ["Storyboard: unrecognized format (not shown)."] }
        var lines: [String] = []
        if object["schema"]?.stringValue == "spatter_storyboard" {
            if let brief = object["brief"]?.stringValue { lines.append("Script: " + bounded(brief)) }
            var timing: [String] = []
            if let fps = number(object["fps"]) { timing.append("\(fps) FPS") }
            if let ticks = number(object["totalTicks"]) { timing.append("\(ticks) ticks") }
            if let frames = number(object["frameCount"]) { timing.append("\(frames) frames") }
            if let hold = number(object["poseHoldTicks"]) { timing.append("pose hold \(hold)") }
            if let seed = number(object["seed"]) { timing.append("seed \(seed)") }
            if let version = number(object["version"]) { timing.append("storyboard v\(version)") }
            if !timing.isEmpty { lines.append("Storyboard: " + timing.joined(separator: " · ")) }
            if case .array(let actors)? = object["actors"] {
                for actor in actors.prefix(6) {
                    guard let fields = actor.objectValue else { continue }
                    let label = ["Actor", number(fields["index"]), fields["color"]?.stringValue].compactMap { $0 }.joined(separator: " ")
                    var clauses: [String] = []
                    if case .array(let items)? = fields["clauses"] {
                        for clause in items.prefix(12) {
                            guard let c = clause.objectValue, let action = c["action"]?.stringValue else { continue }
                            var text = action
                            if let direction = c["direction"]?.stringValue { text += " " + direction }
                            if let start = number(c["startTick"]), let ticks = number(c["ticks"]) { text += " @\(start)+\(ticks)t" }
                            clauses.append(text)
                        }
                    }
                    lines.append(bounded(label + ": " + (clauses.isEmpty ? "no clauses" : clauses.joined(separator: " → "))))
                }
            }
        } else {
            // A storyboard from another producer: show its scalar fields as given.
            for key in object.keys.sorted() {
                switch object[key] {
                case .string(let text)?: lines.append("\(key): " + bounded(text))
                case .number?: lines.append("\(key): " + (number(object[key]) ?? "?"))
                case .bool(let flag)?: lines.append("\(key): \(flag)")
                default: continue
                }
            }
            if lines.isEmpty { lines.append("Storyboard supplied without readable fields.") }
        }
        return Array(lines.prefix(maximumLines))
    }
    static func qualityLines(_ value: CommunityJSONValue?) -> [String] {
        guard let value, value != .null else { return [] }
        guard let object = value.objectValue, case .bool(let passes)? = object["passes"] else { return ["Quality report: unrecognized format (not shown)."] }
        var lines = [passes ? "Quality gates passed (measured findings; owner approval still required)." : "Quality gates FAILED."]
        if case .array(let failures)? = object["failures"] {
            lines.append(contentsOf: failures.prefix(20).compactMap { $0.stringValue.map { "• " + bounded($0, 300) } })
        }
        if let movie = object["movie"]?.objectValue, let decoded = number(movie["decodedFrameCount"]), let expected = number(movie["expectedFrameCount"]) {
            var text = "Decoded movie: \(decoded)/\(expected) frames"
            if let seconds = number(movie["decodedDurationSeconds"]), let planned = number(movie["expectedDurationSeconds"]) { text += ", \(seconds)/\(planned) s" }
            if let offset = number(movie["audioOffsetSeconds"]) { text += ", audio offset \(offset) s" }
            lines.append(text + ".")
        }
        if case .array(let unmeasured)? = object["unmeasured"], !unmeasured.isEmpty {
            lines.append("Not measured: " + unmeasured.compactMap(\.stringValue).prefix(10).joined(separator: ", ") + ".")
        }
        return Array(lines.prefix(maximumLines))
    }
}

// MARK: - Typed agent controls (#284, agent-controls.sql `sdi_agent_admin`)

/// Every owner mutation `sdi_agent_admin` accepts for one agent, validated with
/// the server's own bounds so an out-of-range change is never sent. Each is a
/// sensitive action under the recent re-authentication policy (`stepUpAction`).
enum AdminAgentCommand: Equatable {
    case pause
    case resume
    /// `perRunCostMinor` nil clears the per-run cap on the server; callers that
    /// have not read the current value must not send caps (it would be erased).
    case setCaps(daily: Int, perRunItems: Int, monthlyCostMinor: Int64, perRunCostMinor: Int64?)
    case setPermissions(Set<String>)
    case publishInstructions(String)
    case rollbackInstructions(version: Int)

    static let permissions: Set<String> = ["read", "write", "propose"]
    static let maximumMinor: Int64 = 999_999_999_999

    var action: String {
        switch self {
        case .pause: return "pause"
        case .resume: return "resume"
        case .setCaps: return "set_caps"
        case .setPermissions: return "set_permissions"
        case .publishInstructions: return "publish_instructions"
        case .rollbackInstructions: return "rollback_instructions"
        }
    }
    var stepUpAction: String { "agent." + action }

    func request(agent: String, revision: Int, reason: String) throws -> AdminAgentRequest {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(why.count) else { throw CommunityError.server(message: "A reason is required.", code: nil) }
        guard AdminIdentifier.isBounded(agent), revision >= 1 else { throw CommunityError.invalidResponse("Select a current agent.") }
        let payload: CommunityJSONValue
        switch self {
        case .pause, .resume:
            payload = .object([:])
        case .setCaps(let daily, let items, let monthly, let perRun):
            guard (0...9999).contains(daily), (0...99999).contains(items), (0...Self.maximumMinor).contains(monthly) else {
                throw CommunityError.server(message: "Caps must be whole numbers: daily runs up to 9999, items per run up to 99999, cost caps in minor units.", code: nil)
            }
            var fields: [String: CommunityJSONValue] = ["daily_run_cap": .string(String(daily)), "per_run_item_cap": .string(String(items)),
                                                        "monthly_cost_cap_minor": .string(String(monthly)), "per_run_cost_cap_minor": .string("")]
            if let perRun {
                guard (0...Self.maximumMinor).contains(perRun) else { throw CommunityError.server(message: "The per-run cost cap must be a whole number of minor units.", code: nil) }
                fields["per_run_cost_cap_minor"] = .string(String(perRun))
            }
            payload = .object(fields)
        case .setPermissions(let granted):
            guard granted.isSubset(of: Self.permissions) else { throw CommunityError.server(message: "Permissions must be a subset of read, write, propose.", code: nil) }
            payload = .object(["permissions": .array(granted.sorted().map { .string($0) })])
        case .publishInstructions(let body):
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= 20_000 else {
                throw CommunityError.server(message: "Instruction text of at most 20000 characters is required.", code: nil)
            }
            payload = .object(["body": .string(body)])
        case .rollbackInstructions(let version):
            guard version >= 1 else { throw CommunityError.server(message: "Unknown instruction version.", code: nil) }
            payload = .object(["version": .string(String(version))])
        }
        return AdminAgentRequest(action: action, agent: agent, revision: revision, payload: payload, reason: why)
    }

    /// Parses the owner's text fields; an empty per-run field clears that cap.
    static func caps(daily: String, perRunItems: String, monthlyCostMinor: String, perRunCostMinor: String) -> AdminAgentCommand? {
        func digits(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.count <= 12, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return value
        }
        guard let d = digits(daily).flatMap({ Int($0) }), let i = digits(perRunItems).flatMap({ Int($0) }),
              let m = digits(monthlyCostMinor).flatMap({ Int64($0) }) else { return nil }
        let perRunText = perRunCostMinor.trimmingCharacters(in: .whitespaces)
        var perRun: Int64? = nil
        if !perRunText.isEmpty {
            guard let value = digits(perRunText).flatMap({ Int64($0) }) else { return nil }
            perRun = value
        }
        return .setCaps(daily: d, perRunItems: i, monthlyCostMinor: m, perRunCostMinor: perRun)
    }
}

extension AdminOperationsClient {
    /// Sends one validated owner command and requires the server to confirm the
    /// next registry revision, so a stale screen cannot report a change it did not make.
    func runAgentCommand(_ command: AdminAgentCommand, agent: String, revision: Int, reason: String) async throws -> Int {
        let request = try command.request(agent: agent, revision: revision, reason: reason)
        guard let next = try await mutateAgent(request), next == revision + 1 else {
            throw CommunityError.invalidResponse("Agent change was not confirmed at the expected revision. Refresh before retrying.")
        }
        return next
    }
}

// MARK: - Publish stages (#245, upload-retention.sql `publish_stage`)

/// The creator-facing stage of one publishing job, computed exactly as
/// `sdi_private.publish_stage(state, phase, attempts, provider_id)` does, so the
/// admin list (which returns those four columns) reads the same words as the
/// creator's status screen.
enum AdminPublishStage: String, CaseIterable, Equatable {
    case queued, transferring, providerProcessing = "provider_processing", releasing, published, failed
    case needsReconciliation = "needs_reconciliation", cancelling, removalInProgress = "removal_in_progress", removed, cancelled

    init(state: String, phase: String, attempts: Int, providerID: String?) {
        switch state {
        case "published": self = .published
        case "failed": self = .failed
        case "reconcile": self = .needsReconciliation
        case "cancel_requested": self = .cancelling
        case "removal_pending": self = .removalInProgress
        case "cancelled": self = providerID != nil ? .removed : .cancelled
        default:
            if phase == "processing" { self = .providerProcessing }
            else if phase == "release" { self = .releasing }
            else if state == "queued" && attempts == 0 { self = .queued }
            else { self = .transferring }
        }
    }
    var title: String {
        switch self {
        case .queued: return "Queued"
        case .transferring: return "Transferring to provider"
        case .providerProcessing: return "Provider processing"
        case .releasing: return "Setting visibility"
        case .published: return "Published (provider confirmed)"
        case .failed: return "Failed"
        case .needsReconciliation: return "Needs reconciliation (provider outcome uncertain)"
        case .cancelling: return "Cancelling"
        case .removalInProgress: return "Removal in progress"
        case .removed: return "Removed from provider"
        case .cancelled: return "Cancelled before upload"
        }
    }
    /// The forward path a release follows. A job exists only after moderation and
    /// the exact-render approval, so those steps are complete for every job.
    static let releasePath: [(key: String, title: String)] = [
        ("moderation", "Moderation"), ("approval", "Exact-render approval"), ("transfer", "Transfer"),
        ("processing", "Provider processing"), ("release", "Visibility"), ("link", "Confirmed link"),
    ]
    /// How many `releasePath` steps are complete. Off-path stages (failed,
    /// cancelling, removal) report the steps reached before leaving the path.
    var completedSteps: Int {
        switch self {
        case .queued: return 2
        case .transferring: return 2
        case .providerProcessing: return 3
        case .releasing: return 4
        case .published: return 6
        case .failed, .needsReconciliation, .cancelling, .cancelled: return 2
        case .removalInProgress, .removed: return 3
        }
    }
    var isOffPath: Bool { [.failed, .needsReconciliation, .cancelling, .removalInProgress, .removed, .cancelled].contains(self) }
}

// MARK: - Diagnostics read model (#291, diagnostics.sql `sdi_diagnostics_admin`)

struct AdminDiagnosticsTotal: Decodable, Equatable {
    let day: String
    let platform: String
    let app_version: String
    let build: String
    let counter: String
    let total: Int
    let reports: Int
}
struct AdminDiagnosticsSpike: Decodable, Equatable {
    let platform: String
    let build: String
    let latest_total: Int
    let prior_daily_mean: Double
}
/// Opt-in, first-party diagnostics day counts (no identifiers, no free text).
/// Fail closed on anything outside the stored contract.
struct AdminDiagnosticsSummary: CommunityCodedResponse {
    let error: String?
    let code: String?
    let since: String?
    let latest_complete_day: String?
    let reports: Int?
    let totals: [AdminDiagnosticsTotal]?
    let crash_spikes: [AdminDiagnosticsSpike]?
    let agent_runs_failed_24h: Int?
    let retention_days: Int?

    static let platforms: Set<String> = ["ios", "android"]
    static let counters: Set<String> = ["app_launch", "crash", "hang", "cpu_exception", "disk_write_exception", "memory_limit_exit", "watchdog_exit", "uncaught_exception"]
    static func isDay(_ value: String) -> Bool { value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil }
    static func isVersion(_ value: String) -> Bool { value == "unknown" || value.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,2}$"#, options: .regularExpression) != nil }
    static func isBuild(_ value: String) -> Bool { value == "unknown" || value.range(of: #"^[0-9]{1,9}$"#, options: .regularExpression) != nil }

    func validated() throws -> AdminDiagnosticsSummary {
        guard let since, Self.isDay(since), let latest = latest_complete_day, Self.isDay(latest), let reports, reports >= 0,
              let totals, totals.count <= 20_000, let crash_spikes, crash_spikes.count <= 500,
              let failed = agent_runs_failed_24h, failed >= 0, retention_days != nil else {
            throw CommunityError.invalidResponse("Diagnostics reply incomplete.")
        }
        for row in totals {
            guard Self.isDay(row.day), Self.platforms.contains(row.platform), Self.isVersion(row.app_version), Self.isBuild(row.build),
                  Self.counters.contains(row.counter), row.total >= 0, row.reports >= 0 else {
                throw CommunityError.invalidResponse("Diagnostics reply contained an unexpected record.")
            }
        }
        for spike in crash_spikes {
            guard Self.platforms.contains(spike.platform), Self.isBuild(spike.build), spike.latest_total >= 0,
                  spike.prior_daily_mean.isFinite, spike.prior_daily_mean >= 0 else {
                throw CommunityError.invalidResponse("Diagnostics reply contained an unexpected spike.")
            }
        }
        return self
    }
    /// Per-counter sums over the window, by platform, for the overview tiles.
    func counterTotals(platform: String? = nil) -> [AdminDiagnosticsCounter] {
        var sums: [String: Int] = [:]
        for row in totals ?? [] where platform == nil || row.platform == platform { sums[row.counter, default: 0] += row.total }
        return sums.sorted { $0.key < $1.key }.map { AdminDiagnosticsCounter(counter: $0.key, total: $0.value) }
    }
}

extension AdminOperationsClient {
    /// Overview-capability read of opt-in diagnostics for the last `days` days (1...90).
    func diagnostics(days: Int = 14) async throws -> AdminDiagnosticsSummary {
        guard (1...90).contains(days) else { throw CommunityError.invalidResponse("Choose between 1 and 90 days.") }
        return try await gateway.call("sdi_diagnostics_admin", params: AdminDiagnosticsRequest(action: "summary", days: days),
                                      as: AdminDiagnosticsSummary.self).validated()
    }
}
struct AdminDiagnosticsRequest: Encodable, Equatable { let action: String; let days: Int }
struct AdminDiagnosticsCounter: Identifiable, Equatable { var id: String { counter }; let counter: String; let total: Int }
