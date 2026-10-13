// ═══════════════════════════════════════════════════════════════════
// AdminOperationsClient — admin command-center panels over the hardened
// RPC contracts: access/step-up (admin-hardening.sql), service health,
// agent controls (agent-controls.sql), finance reads and owner-only product
// configuration (billing.sql), room report queue (rooms-v2.sql), feed removal
// appeals (rooms-v2.sql) and render decision history (admin-approval.sql).
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
