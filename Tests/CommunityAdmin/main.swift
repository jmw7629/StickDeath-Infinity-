import Foundation

// Foundation-only verification of the admin panel client: recent
// re-authentication policy, health/agent/finance decoding, moderation queues
// and decision history. Scripted fake transports only.

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}

final class FakeTransport: CommunityTransport {
    struct Call { let name: String; let params: [String: Any] }
    var replies: [Result<String, Error>] = []
    var calls: [Call] = []
    var hasSession = true
    func rpc<P: Encodable & Sendable>(_ name: String, params: P) async throws -> CommunityReply {
        let data = try CommunityCoding.encoder().encode(params)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        calls.append(Call(name: name, params: object))
        return try next()
    }
    func rows(_ table: String, select: String, filters: [CommunityRowFilter], limit: Int) async throws -> CommunityReply {
        calls.append(Call(name: "rows:" + table, params: ["select": select]))
        return try next()
    }
    private func next() throws -> CommunityReply {
        guard !replies.isEmpty else { throw CommunityError.transport("No scripted reply.") }
        switch replies.removeFirst() {
        case .success(let json): return CommunityReply(data: Data(json.utf8), serverDate: nil, sentAt: Date(), receivedAt: Date())
        case .failure(let error): throw error
        }
    }
}

private let now = Date(timeIntervalSince1970: 1_791_837_191)
private let review = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let actor = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
private func decision(_ id: UUID, review target: UUID, at iso: String) -> String {
    #"{"id":"\#(id.uuidString)","review_id":"\#(target.uuidString)","actor":"\#(actor.uuidString)","owner_at_decision":true,"render_title":"T","source_revision":"r1","rights_summary":"ok","render_digest":"\#(String(repeating: "a", count: 64))","review_version":1,"consent_version":"v1","destinations":["feed"],"decision":"approved","note":"","created_at":"\#(iso)"}"#
}

@main @MainActor struct CommunityAdminTests {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        await test("recent re-authentication is required for privileged actions unless the window is current") {
            var policy = AdminStepUpPolicy()
            try require(policy.decision(for: "agent.runs", now: now) == .proceed, "read actions proceed")
            if case .reverify = policy.decision(for: "agent.emergency_stop", now: now) {} else { throw Failure(description: "unknown step-up state allowed a sensitive action") }
            policy.stepUpCurrent = true
            try require(policy.decision(for: "agent.emergency_stop", now: now) == .proceed, "server-reported current step-up proceeds")
            policy.recordVerification(at: now)
            try require(policy.decision(for: "finance.set_product", now: now.addingTimeInterval(14 * 60)) == .proceed, "within window")
            if case .reverify = policy.decision(for: "finance.set_product", now: now.addingTimeInterval(14 * 60 + 31)) {} else { throw Failure(description: "window did not expire with the safety margin") }
            policy.recordVerification(at: now)
            policy.recordRefusal()
            if case .reverify = policy.decision(for: "users.ban", now: now) {} else { throw Failure(description: "server refusal did not clear the window") }
            // The server gates reset_flags behind step-up (admin-users.sql), so the client must too.
            if case .reverify = AdminStepUpPolicy().decision(for: "users.reset_flags", now: now) {} else { throw Failure(description: "reset_flags is not step-up protected") }
        }

        await test("admin access parses step-up state and server step-up refusals flip the local policy") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"owner":false,"capabilities":["moderation","overview"],"step_up_current":true}"#)]
            let access = try await client.access()
            try require(!access.owner && access.capabilities == ["moderation", "overview"] && access.stepUpCurrent == true, "access decoded")
            try require(client.stepUpPrompt(for: "rooms.close", now: now) == nil, "current step-up allows the action")
            transport.replies = [.success(#"{"error":"Re-verify your second factor to continue.","code":"step_up_required"}"#)]
            do { _ = try await client.health(); throw Failure(description: "step-up refusal accepted") }
            catch { try require(client.noteRefusal(error).isStepUpRequired, "gate code surfaced") }
            try require(client.stepUpPrompt(for: "rooms.close", now: now) != nil, "refusal requires re-verification")
            transport.replies = [.success(#"{"owner":true,"capabilities":["users"]}"#)]
            try require(try await client.access().stepUpCurrent == nil, "pre-hardening reply leaves step-up unknown")
            transport.replies = [.success(#"{"error":"Current admin MFA session required."}"#)]
            do { _ = try await client.access(); throw Failure(description: "denied access decoded as granted") } catch CommunityError.server {}
        }

        await test("health replies fail closed without measurement or with host-like worker identifiers") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"queues":{"publish_queued":2,"support_open":null},"oldest_pending":{"publish_queued":"2026-10-12T10:00:00Z","feed_report":null},"workers":[{"worker":"feed-publisher","seen_at":"2026-10-12T20:00:00Z","note":"","stale":false}],"emergency_stop":false,"admin_denials_24h":1,"measured_at":"2026-10-12T20:33:11Z"}"#)]
            let health = try await client.health()
            try require(health.queues?["publish_queued"] == 2 && health.queues?["support_open"] == .some(nil) && health.workers?.first?.worker == "feed-publisher" && health.emergency_stop == false, "health decoded with nullable counts")
            transport.replies = [.success(#"{"queues":{},"measured_at":"2026-10-12T20:33:11Z"}"#)]
            do { _ = try await client.health(); throw Failure(description: "empty queues accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"queues":{"publish_queued":1},"workers":[{"worker":"db.internal:5432","seen_at":"2026-10-12T20:00:00Z","note":"","stale":false}],"measured_at":"2026-10-12T20:33:11Z"}"#)]
            do { _ = try await client.health(); throw Failure(description: "host-like worker accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"queues":{"publish_queued":-1},"measured_at":"2026-10-12T20:33:11Z"}"#)]
            do { _ = try await client.health(); throw Failure(description: "negative count accepted") } catch CommunityError.invalidResponse {}
            try require(AdminHealthResponse.queueTitles.count == 15, "every documented queue has a label")
        }

        await test("agent controls require a reason and encode caps and emergency stop as the contract expects") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"agents":[{"key":"spatter_daily_video","title":"Spatter","paused":true,"permissions":["read"],"daily_run_cap":1,"per_run_item_cap":1,"monthly_cost_cap_minor":0,"active_instruction_version":null,"revision":1,"running":0,"last_finished":null,"failures_7d":0,"cost_month_minor":0,"runs_today":0}],"emergency_stop":false,"emergency_reason":""}"#)]
            let agents = try await client.agents()
            guard let agent = agents.agents?.first else { throw Failure(description: "agent missing") }
            try require(agent.paused && agent.active_instruction_version == nil, "registry starts paused without instructions")
            do { _ = try await client.mutateAgent(AdminAgentRequest(action: "pause", agent: agent.key, revision: 1)); throw Failure(description: "mutation without reason sent") } catch CommunityError.server {}
            try require(transport.calls.count == 1, "no second request")
            guard let caps = AdminAgentRequest.caps(agent: agent, daily: 3, perRun: 20, monthlyMinor: 1500, reason: "budget") else { throw Failure(description: "caps builder refused valid values") }
            try require(AdminAgentRequest.caps(agent: agent, daily: 10_000, perRun: 1, monthlyMinor: 1, reason: "x") == nil, "cap bounds")
            transport.replies = [.success(#"{"status":"confirmed","revision":2}"#)]
            try require(try await client.mutateAgent(caps) == 2, "caps confirmed")
            let payload = transport.calls.last?.params["payload"] as? [String: Any]
            try require(payload?["daily_run_cap"] as? String == "3" && payload?["monthly_cost_cap_minor"] as? String == "1500" && transport.calls.last?.params["revision"] as? Int == 1, "caps payload uses the server's text fields and revision")
            transport.replies = [.success(#"{"status":"confirmed"}"#)]
            _ = try await client.mutateAgent(.emergencyStop(enabled: true, reason: "incident"))
            try require((transport.calls.last?.params["payload"] as? [String: Any])?["enabled"] as? String == "true" && transport.calls.last?.params["action"] as? String == "emergency_stop", "emergency stop payload")
            transport.replies = [.success(#"{"error":"Owner permission required for agent changes."}"#)]
            do { _ = try await client.mutateAgent(.emergencyStop(enabled: false, reason: "clear")); throw Failure(description: "owner refusal accepted") } catch CommunityError.server {}
            transport.replies = [.success(#"{"runs":[{"id":"\#(review.uuidString)","agent_key":"spatter_daily_video","instruction_version":1,"source_ref":"","started_at":"2026-10-12T20:00:00Z","heartbeat_at":null,"finished_at":null,"state":"running","items":0,"cost_minor":0,"error":null}]}"#)]
            try require(try await client.agentRuns("spatter_daily_video").first?.state == "running", "runs decoded")
        }

        await test("finance reads show provider-reported records only and mutations confirm or fail") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"products":[{"product_id":"sdi.creator.monthly","provider":"apple","tier":"creator","period":"monthly","approved":true,"owner_configured_at":"2026-10-01T00:00:00Z"}],"approved_offers":"Two monthly tiers (USD 4.99, USD 9.99). Annual periods require owner configuration."}"#)]
            let products = try await client.finance(AdminFinanceRequest(action: "products"))
            try require(products.products?.first?.approved == true && products.approved_offers?.contains("4.99") == true, "products decoded with the approved offers note")
            transport.replies = [.success(#"{"totals":[{"provider":"stripe","currency":"usd","kind":"charge","amount_minor":1998,"entries":2}],"label":"Sums of provider-reported entries; estimates and cash are not shown here.","entitled_accounts":2}"#)]
            let summary = try await client.finance(AdminFinanceRequest(action: "summary"))
            try require(summary.totals?.first?.amountText == "USD 19.98" && summary.entitled_accounts == 2, "totals formatted from minor units")
            transport.replies = [.success(#"{"ledger":[]}"#)]
            try require(try await client.finance(AdminFinanceRequest(action: "ledger")).ledger?.isEmpty == true, "empty ledger is a real empty state")
            transport.replies = [.success(#"{"subscriptions":null}"#)]
            do { _ = try await client.finance(AdminFinanceRequest(action: "subscriptions")); throw Failure(description: "missing subscriptions accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"status":"confirmed"}"#)]
            _ = try await client.finance(AdminFinanceRequest(action: "set_product", product: "sdi.pro.monthly", provider: "stripe", tier: "pro", period: "monthly", approved: true, reason: "owner decision"))
            try require(transport.calls.last?.params["approved"] as? Bool == true && transport.calls.last?.params["reason"] as? String == "owner decision", "set_product payload")
            transport.replies = [.success(#"{"error":"Annual offers need explicit owner configuration before approval."}"#)]
            do { _ = try await client.finance(AdminFinanceRequest(action: "set_product", product: "x", provider: "apple", tier: "pro", period: "annual", approved: true, reason: "r")); throw Failure(description: "annual approval accepted") } catch CommunityError.server {}
        }

        await test("room report and removal appeal decisions need a reason and a current revision") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"reports":[{"id":"\#(review.uuidString)","room_id":"\#(other.uuidString)","reason":"abuse","detail":"d","revision":1,"created_at":"2026-10-12T20:00:00Z","title":"Duel","owner_id":"\#(actor.uuidString)","closed":false,"members":2,"report_count":1}]}"#)]
            let reports = try await client.roomReports()
            try require(reports.count == 1 && reports[0].members == 2, "room reports decoded (no reporter identity field)")
            do { try await client.decideRoomReport(reports[0], close: true, reason: " "); throw Failure(description: "decision without reason sent") } catch CommunityError.server {}
            transport.replies = [.success(#"{"status":"confirmed"}"#)]
            try await client.decideRoomReport(reports[0], close: true, reason: "Repeated rights complaints")
            try require(transport.calls.last?.params["action"] as? String == "close" && transport.calls.last?.params["revision"] as? Int == 1, "close payload")
            transport.replies = [.success(#"{"appeals":[{"id":"\#(review.uuidString)","media_id":"\#(other.uuidString)","title":"V","explanation":"e","created_at":"2026-10-12T20:00:00Z","creator":"\#(actor.uuidString)","render_digest":"\#(String(repeating: "b", count: 64))","revision":1,"url":"https://cdn.example/v.mp4","removal_reason":"spam","removal_state":"pending"}]}"#)]
            let appeals = try await client.appealQueue()
            try require(appeals[0].removal_state == "pending", "appeal queue decoded")
            var stale = appeals[0]; stale.revision = nil
            do { try await client.decideAppeal(stale, accept: true, note: "ok"); throw Failure(description: "appeal without revision sent") } catch CommunityError.server {}
            transport.replies = [.success(#"{"status":"confirmed"}"#)]
            try await client.decideAppeal(appeals[0], accept: false, note: "Rights unresolved")
            try require(transport.calls.last?.params["action"] as? String == "reject" && transport.calls.last?.params["note"] as? String == "Rights unresolved", "reject payload")
            transport.replies = [.success(#"{"appeals":[]}"#)]
            try require(try await client.myAppeals().isEmpty, "member appeals empty state")
        }

        await test("decision history filters by render and reports how many pages were searched") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            do { _ = try await client.reviewHistory(page: 200); throw Failure(description: "page bound ignored") } catch CommunityError.invalidResponse {}
            let fullPage = (0..<50).map { index in decision(UUID(), review: index % 2 == 0 ? review : other, at: "2026-10-12T20:00:\(String(format: "%02d", index % 60))Z") }.joined(separator: ",")
            transport.replies = [.success("{\"decisions\":[\(fullPage)]}"), .success("{\"decisions\":[\(decision(UUID(), review: review, at: "2026-10-11T00:00:00Z"))]}")]
            let result = try await client.decisions(for: review, pages: 3)
            try require(result.records.count == 26 && result.searchedPages == 2, "filtered across pages until a short page")
            try require(result.records.first!.created_at >= result.records.last!.created_at, "newest first")
            try require(transport.calls.map { $0.params["page"] as? Int } == [0, 1], "page parameters")
        }

        await test("operations status fails closed on missing milestones, host-like labels and text metrics") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            let milestone = #"{"last_succeeded_at":"2026-10-12T03:00:00Z","last_failed_at":null,"stale":false}"#
            let never = #"{"last_succeeded_at":null,"last_failed_at":null,"stale":true}"#
            transport.replies = [.success(#"{"backup":\#(milestone),"restore_drill":\#(never),"retention_sweep":\#(milestone),"release":{"label":"1.4.0","at":"2026-10-10T00:00:00Z"},"rollback":null,"retention":{"render_artifacts_live":3,"render_artifacts_expired":0,"deletion_requests_blocked":null},"recent":[{"kind":"backup","outcome":"succeeded","label":"","metrics":{"bytes":123456},"created_at":"2026-10-12T03:00:00Z"},{"kind":"rollback","outcome":"succeeded","label":"3f2a9c1","metrics":{},"created_at":"2026-10-11T03:00:00Z"}],"note":"n","measured_at":"2026-10-12T20:33:11Z"}"#)]
            let status = try await client.operations()
            try require(status.backup?.stale == false && status.restore_drill?.stale == true && status.restore_drill?.last_succeeded_at == nil, "never-reported drill is stale, not healthy")
            try require(status.release?.label == "1.4.0" && status.retention?["deletion_requests_blocked"] == .some(nil) && status.recent?.first?.metrics["bytes"] == 123456, "release, nullable retention and metrics decoded")
            transport.replies = [.success(#"{"backup":\#(milestone),"restore_drill":\#(milestone),"recent":[],"measured_at":"2026-10-12T20:33:11Z"}"#)]
            do { _ = try await client.operations(); throw Failure(description: "missing retention milestone accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"backup":\#(milestone),"restore_drill":\#(milestone),"retention_sweep":\#(milestone),"release":{"label":"db.internal.example.com","at":"2026-10-10T00:00:00Z"},"recent":[],"measured_at":"2026-10-12T20:33:11Z"}"#)]
            do { _ = try await client.operations(); throw Failure(description: "host-like release label accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"backup":\#(milestone),"restore_drill":\#(milestone),"retention_sweep":\#(milestone),"recent":[{"kind":"terminal","outcome":"succeeded","label":"","metrics":{},"created_at":"2026-10-12T03:00:00Z"}],"measured_at":"2026-10-12T20:33:11Z"}"#)]
            do { _ = try await client.operations(); throw Failure(description: "unknown report kind accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"backup":\#(milestone),"restore_drill":\#(milestone),"retention_sweep":\#(milestone),"recent":[{"kind":"backup","outcome":"failed","label":"","metrics":{"bucket":"s3://x"},"created_at":"2026-10-12T03:00:00Z"}],"measured_at":"2026-10-12T20:33:11Z"}"#)]
            do { _ = try await client.operations(); throw Failure(description: "text metric accepted") } catch CommunityError.invalidResponse {}
            try require(AdminIdentifier.isReleaseLabel("v2.0.1-rc.1") && AdminIdentifier.isReleaseLabel("a1b2c3d") && !AdminIdentifier.isReleaseLabel("prod-db-1") && !AdminIdentifier.isReleaseLabel("1.2.3/../x"), "label rule mirrors the server")
        }

        await test("provider configuration shows presence only and rejects host-like or inconsistent entries") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"workers":[{"worker":"service-sweeps","reported_at":"2026-10-12T20:00:00Z","stale":false,"settings":{"stripe_webhook_secret":true,"youtube_client":false},"missing":["youtube_client"]}],"note":"Presence only."}"#)]
            let configuration = try await client.configuration()
            try require(configuration.workers?.first?.missing == ["youtube_client"] && configuration.workers?.first?.settings["stripe_webhook_secret"] == true, "presence decoded")
            transport.replies = [.success(#"{"workers":[{"worker":"db.internal:5432","reported_at":"2026-10-12T20:00:00Z","stale":false,"settings":{},"missing":[]}]}"#)]
            do { _ = try await client.configuration(); throw Failure(description: "host-like worker accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"workers":[{"worker":"w","reported_at":"2026-10-12T20:00:00Z","stale":false,"settings":{"key":true},"missing":["key"]}]}"#)]
            do { _ = try await client.configuration(); throw Failure(description: "inconsistent missing list accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"workers":[{"worker":"w","reported_at":"2026-10-12T20:00:00Z","stale":false,"settings":{"key":"sk_live_x"},"missing":[]}]}"#)]
            do { _ = try await client.configuration(); throw Failure(description: "a setting value was decoded") } catch CommunityError.invalidResponse {}
        }

        await test("proposal decisions need a reason and a pending proposal, and confirm the expected state") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            transport.replies = [.success(#"{"proposals":[{"id":"\#(review.uuidString)","agent_key":"marketing_proposals","kind":"email_blast","summary":"Send the blast","payload":{"draft":"d1"},"estimated_cost_minor":4800,"cap_reason":"monthly cost cap","state":"pending","proposed_at":"2026-10-12T20:00:00Z","expires_at":"2026-10-26T20:00:00Z","decided_by":null,"decided_at":null,"decision_note":"","outcome":"","revision":1}],"pending":1}"#)]
            let inbox = try await client.proposalInbox()
            try require(inbox.pending == 1 && inbox.proposals.first?.cap_reason == "monthly cost cap", "inbox decoded")
            let proposal = inbox.proposals[0]
            do { _ = try await client.decideProposal(proposal, approve: true, reason: " "); throw Failure(description: "decision without reason sent") } catch CommunityError.server {}
            try require(transport.calls.count == 1, "nothing sent without a reason")
            transport.replies = [.success(#"{"status":"confirmed","state":"approved","revision":2}"#)]
            try require(try await client.decideProposal(proposal, approve: true, reason: "Within plan") == "approved", "approval confirmed")
            try require(transport.calls.last?.params["action"] as? String == "approve" && transport.calls.last?.params["revision"] as? Int == 1 && transport.calls.last?.params["reason"] as? String == "Within plan", "decision payload")
            transport.replies = [.success(#"{"status":"confirmed","state":"rejected"}"#)]
            do { _ = try await client.decideProposal(proposal, approve: true, reason: "x"); throw Failure(description: "mismatched state accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"error":"Owner permission required for proposal decisions."}"#)]
            do { _ = try await client.decideProposal(proposal, approve: false, reason: "x"); throw Failure(description: "owner refusal accepted") } catch CommunityError.server {}
        }

        await test("run and audit history send bounded filters and decode pages") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            do { _ = try await client.agentRunHistory(agent: nil, state: "deleted"); throw Failure(description: "unknown state sent") } catch CommunityError.invalidResponse {}
            do { _ = try await client.agentAudit(agent: nil, page: 200); throw Failure(description: "page bound ignored") } catch CommunityError.invalidResponse {}
            do { _ = try await client.agentAudit(agent: nil, query: String(repeating: "q", count: 101)); throw Failure(description: "long query sent") } catch CommunityError.invalidResponse {}
            try require(transport.calls.isEmpty, "nothing sent for invalid filters")
            transport.replies = [.success(#"{"runs":[],"has_more":false,"page":2}"#)]
            let runs = try await client.agentRunHistory(agent: "support_triage", state: "failed", query: " batch ", page: 2)
            let payload = transport.calls.last?.params["payload"] as? [String: Any]
            try require(runs.items.isEmpty && !runs.hasMore && payload?["state"] as? String == "failed" && payload?["query"] as? String == "batch" && payload?["page"] as? String == "2" && transport.calls.last?.params["action"] as? String == "runs", "run filter payload")
            transport.replies = [.success(#"{"audit":[{"id":"\#(review.uuidString)","actor":"\#(actor.uuidString)","agent_key":null,"action":"emergency_stop true","reason":"incident","created_at":"2026-10-12T20:00:00Z"}],"has_more":true,"page":0}"#)]
            let audit = try await client.agentAudit(agent: nil, query: "incident")
            try require(audit.items.first?.agent_key == nil && audit.hasMore, "audit page decoded")
            transport.replies = [.success(#"{"agents":[{"key":"support_triage","title":"Support","paused":true,"permissions":["read"],"per_run_cost_cap_minor":100,"last_error":"Cost cap exceeded; agent paused for owner review.","last_started":"2026-10-12T20:00:00Z","pending_proposals":0}],"emergency_stop":false}"#)]
            let console = try await client.agentConsole()
            try require(console.first?.per_run_cost_cap_minor == 100 && console.first?.pending_proposals == 0 && console.first?.last_error?.contains("Cost cap") == true, "console extras decoded")
        }

        await test("typed agent commands mirror the server's actions, bounds and step-up names") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            let all: [AdminAgentCommand] = [.pause, .resume, .setCaps(daily: 3, perRunItems: 1, monthlyCostMinor: 100, perRunCostMinor: 25),
                .setPermissions(["write", "read"]), .publishInstructions("One private draft per day."), .rollbackInstructions(version: 2)]
            try require(all.map(\.action) == ["pause", "resume", "set_caps", "set_permissions", "publish_instructions", "rollback_instructions"], "action names")
            for command in all {
                if case .reverify = AdminStepUpPolicy().decision(for: command.stepUpAction, now: now) {} else { throw Failure(description: "\(command.action) is not step-up protected") }
            }
            // Invalid input is refused before anything is sent.
            for (command, reason) in [(AdminAgentCommand.pause, " "), (.setCaps(daily: 10_000, perRunItems: 1, monthlyCostMinor: 0, perRunCostMinor: nil), "r"),
                                      (.setCaps(daily: 1, perRunItems: 1, monthlyCostMinor: -1, perRunCostMinor: nil), "r"),
                                      (.setCaps(daily: 1, perRunItems: 1, monthlyCostMinor: 1, perRunCostMinor: 1_000_000_000_000), "r"),
                                      (.setPermissions(["admin"]), "r"), (.publishInstructions("  "), "r"),
                                      (.publishInstructions(String(repeating: "x", count: 20_001)), "r"), (.rollbackInstructions(version: 0), "r")] {
                do { _ = try await client.runAgentCommand(command, agent: "spatter_daily_video", revision: 4, reason: reason); throw Failure(description: "\(command) sent") }
                catch let error as CommunityError { if case .server = error {} else { throw Failure(description: "\(command) wrong refusal \(error)") } }
            }
            do { _ = try await client.runAgentCommand(.pause, agent: "Spatter Daily", revision: 4, reason: "r"); throw Failure(description: "bad agent key sent") } catch CommunityError.invalidResponse {}
            try require(transport.calls.isEmpty, "nothing sent for invalid commands")
            // Caps carry every server field, including the per-run cost cap, so saving never erases it.
            transport.replies = [.success(#"{"status":"confirmed","revision":5}"#)]
            try require(try await client.runAgentCommand(all[2], agent: "spatter_daily_video", revision: 4, reason: " Caps ") == 5, "caps confirmed")
            let caps = transport.calls.last?.params["payload"] as? [String: String]
            try require(caps == ["daily_run_cap": "3", "per_run_item_cap": "1", "monthly_cost_cap_minor": "100", "per_run_cost_cap_minor": "25"]
                && transport.calls.last?.params["action"] as? String == "set_caps" && transport.calls.last?.params["revision"] as? Int == 4
                && transport.calls.last?.params["reason"] as? String == "Caps", "caps payload: \(String(describing: caps))")
            transport.replies = [.success(#"{"status":"confirmed","revision":6}"#)]
            _ = try await client.runAgentCommand(all[3], agent: "spatter_daily_video", revision: 5, reason: "Perms")
            try require((transport.calls.last?.params["payload"] as? [String: Any])?["permissions"] as? [String] == ["read", "write"], "sorted permissions")
            transport.replies = [.success(#"{"status":"confirmed","revision":7}"#)]
            _ = try await client.runAgentCommand(all[5], agent: "spatter_daily_video", revision: 6, reason: "Back")
            try require((transport.calls.last?.params["payload"] as? [String: Any])?["version"] as? String == "2", "rollback version")
            // A confirmation at an unexpected revision is not reported as success.
            transport.replies = [.success(#"{"status":"confirmed","revision":9}"#)]
            do { _ = try await client.runAgentCommand(.resume, agent: "spatter_daily_video", revision: 7, reason: "Go"); throw Failure(description: "skipped revision accepted") } catch CommunityError.invalidResponse {}
            transport.replies = [.success(#"{"error":"Publish instructions before resuming this agent."}"#)]
            do { _ = try await client.runAgentCommand(.resume, agent: "spatter_daily_video", revision: 7, reason: "Go"); throw Failure(description: "server refusal accepted") } catch CommunityError.server {}
            // Text-field parsing: empty per-run clears it, anything non-numeric refuses.
            try require(AdminAgentCommand.caps(daily: "3", perRunItems: "1", monthlyCostMinor: "100", perRunCostMinor: "") == .setCaps(daily: 3, perRunItems: 1, monthlyCostMinor: 100, perRunCostMinor: nil), "empty per-run")
            try require(AdminAgentCommand.caps(daily: "3", perRunItems: "1", monthlyCostMinor: "1e3", perRunCostMinor: "") == nil
                && AdminAgentCommand.caps(daily: "-1", perRunItems: "1", monthlyCostMinor: "1", perRunCostMinor: "") == nil
                && AdminAgentCommand.caps(daily: "1", perRunItems: "1", monthlyCostMinor: "1", perRunCostMinor: "2.5") == nil, "non-numeric caps refused")
        }

        await test("publish stages match the server's publish_stage mapping") {
            let cases: [(String, String, Int, String?, AdminPublishStage)] = [
                ("published", "release", 1, "v1", .published), ("failed", "transfer", 5, nil, .failed), ("reconcile", "transfer", 1, nil, .needsReconciliation),
                ("cancel_requested", "transfer", 1, nil, .cancelling), ("removal_pending", "release", 1, "v1", .removalInProgress),
                ("cancelled", "release", 1, "v1", .removed), ("cancelled", "transfer", 0, nil, .cancelled), ("leased", "processing", 1, "v1", .providerProcessing),
                ("leased", "release", 1, "v1", .releasing), ("queued", "transfer", 0, nil, .queued), ("queued", "transfer", 2, nil, .transferring),
                ("leased", "transfer", 1, nil, .transferring)]
            for (state, phase, attempts, provider, expected) in cases {
                let stage = AdminPublishStage(state: state, phase: phase, attempts: attempts, providerID: provider)
                try require(stage == expected, "\(state)/\(phase)/\(attempts) → \(stage), expected \(expected)")
            }
            try require(AdminPublishStage.published.rawValue == "published" && AdminPublishStage.needsReconciliation.rawValue == "needs_reconciliation"
                && AdminPublishStage.providerProcessing.rawValue == "provider_processing" && AdminPublishStage.removalInProgress.rawValue == "removal_in_progress", "wire names")
            try require(AdminPublishStage.published.completedSteps == AdminPublishStage.releasePath.count && AdminPublishStage.queued.completedSteps == 2
                && !AdminPublishStage.releasing.isOffPath && AdminPublishStage.failed.isOffPath, "release path progress")
        }

        await test("provider health decodes closed vocabularies and fails closed on secrets or free text") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            let good = #"{"providers":[{"provider":"email","title":"Email sender","configured":"no","missing":["sdi_mail_credentials_file"],"configuration_reported_at":"2026-10-19T20:00:00Z","configuration_stale":false,"last_success_at":null,"last_failure_at":"2026-10-19T21:00:00Z","last_error_class":"authentication","consecutive_failures":2,"health":"unconfigured"},{"provider":"stripe","title":"Stripe billing","configured":"yes","missing":[],"configuration_reported_at":"2026-10-19T20:00:00Z","configuration_stale":false,"last_success_at":"2026-10-19T22:00:00Z","last_failure_at":null,"last_error_class":null,"consecutive_failures":0,"health":"healthy"},{"provider":"youtube","title":"YouTube channel","configured":"unreported","missing":["sdi_youtube_client_file","sdi_youtube_token_file"],"configuration_reported_at":null,"configuration_stale":false,"last_success_at":null,"last_failure_at":null,"last_error_class":null,"consecutive_failures":0,"health":"unreported"}],"measured_at":"2026-10-20T00:00:00Z","note":"Presence and outcome times only."}"#
            transport.replies = [.success(good)]
            let reply = try await client.providerHealth()
            try require(transport.calls.last?.name == "sdi_admin_provider_health", "request")
            let items = reply.providers ?? []
            try require(items.count == 3 && items[0].isAlert && items[0].last_error_class == "authentication" && items[0].consecutive_failures == 2
                && !items[1].isAlert && items[1].last_success_at != nil && items[2].configured == "unreported", "health decoded")
            for bad in [good.replacingOccurrences(of: #""last_error_class":"authentication""#, with: #""last_error_class":"535 bad password owner@example.test""#),
                        good.replacingOccurrences(of: #""missing":["sdi_mail_credentials_file"]"#, with: #""missing":["sk_live_1a2b"]"#),
                        good.replacingOccurrences(of: #""provider":"stripe""#, with: #""provider":"https://api.stripe.com""#),
                        good.replacingOccurrences(of: #""health":"healthy""#, with: #""health":"fine""#)] {
                transport.replies = [.success(bad)]
                do { _ = try await client.providerHealth(); throw Failure(description: "unexpected reply accepted") } catch CommunityError.invalidResponse {}
            }
            transport.replies = [.success(#"{"error":"Current administrator permission and MFA session required.","code":"forbidden"}"#)]
            do { _ = try await client.providerHealth(); throw Failure(description: "refusal accepted") } catch CommunityError.server {}
        }

        await test("diagnostics summary decodes the stored contract and fails closed on identifiers or free text") {
            let transport = FakeTransport()
            let client = AdminOperationsClient(gateway: CommunityGateway(transport: transport))
            let good = #"{"since":"2026-10-04","latest_complete_day":"2026-10-17","reports":3,"totals":[{"day":"2026-10-17","platform":"ios","app_version":"1.2.3","build":"45","counter":"crash","total":7,"reports":2},{"day":"2026-10-16","platform":"android","app_version":"unknown","build":"unknown","counter":"app_launch","total":40,"reports":1}],"crash_spikes":[{"platform":"ios","build":"45","latest_total":7,"prior_daily_mean":0.29}],"agent_runs_failed_24h":1,"retention_days":90}"#
            transport.replies = [.success(good)]
            let summary = try await client.diagnostics(days: 14)
            try require(transport.calls.last?.name == "sdi_diagnostics_admin" && transport.calls.last?.params["action"] as? String == "summary" && transport.calls.last?.params["days"] as? Int == 14, "request")
            try require(summary.crash_spikes?.first?.latest_total == 7 && summary.agent_runs_failed_24h == 1 && summary.counterTotals(platform: "ios").first?.total == 7
                && summary.counterTotals().count == 2, "summary decoded")
            do { _ = try await client.diagnostics(days: 91); throw Failure(description: "out-of-range window sent") } catch CommunityError.invalidResponse {}
            for bad in [good.replacingOccurrences(of: #""build":"45","counter""#, with: #""build":"device-a1","counter""#),
                        good.replacingOccurrences(of: #""counter":"crash""#, with: #""counter":"user_email""#),
                        good.replacingOccurrences(of: #""platform":"ios","app_version""#, with: #""platform":"web","app_version""#),
                        good.replacingOccurrences(of: #","agent_runs_failed_24h":1"#, with: "")] {
                transport.replies = [.success(bad)]
                do { _ = try await client.diagnostics(); throw Failure(description: "unexpected reply accepted") } catch CommunityError.invalidResponse {}
            }
            transport.replies = [.success(#"{"error":"Current administrator MFA session required.","code":"forbidden"}"#)]
            do { _ = try await client.diagnostics(); throw Failure(description: "refusal accepted") } catch CommunityError.server {}
        }

        await test("review evidence shows the real storyboard, digest and quality report, and says not supplied only for null") {
            try require(AdminReviewEvidence.storyboardLines(nil).isEmpty && AdminReviewEvidence.storyboardLines(.null).isEmpty && AdminReviewEvidence.qualityLines(nil).isEmpty, "null is not supplied")
            try require(AdminReviewEvidence.digestLine(nil).contains("not supplied") && AdminReviewEvidence.digestLine(String(repeating: "ab", count: 32)).hasSuffix(String(repeating: "ab", count: 32))
                && AdminReviewEvidence.digestLine("../../etc").contains("unrecognized"), "digest line")
            let story = try JSONDecoder().decode(CommunityJSONValue.self, from: Data(##"{"schema":"spatter_storyboard","version":1,"brief":"A red stick figure walks left to right, then falls; 3 seconds.","seed":11,"fps":24,"totalTicks":72,"poseHoldTicks":2,"frameCount":36,"generatedElementCount":360,"actors":[{"index":1,"color":"#FF0000","layerName":"Actor 1","startXPercent":10,"facing":1,"clauses":[{"action":"walk","direction":"left to right","startTick":0,"ticks":48,"travelPercent":40},{"action":"fall","startTick":48,"ticks":24,"travelPercent":0}]}]}"##.utf8))
            let lines = AdminReviewEvidence.storyboardLines(story)
            try require(lines.first == "Script: A red stick figure walks left to right, then falls; 3 seconds." && lines.contains { $0.contains("24 FPS") && $0.contains("72 ticks") && $0.contains("seed 11") }
                && lines.contains("Actor 1 #FF0000: walk left to right @0+48t → fall @48+24t"), "storyboard lines: \(lines)")
            let quality = try JSONDecoder().decode(CommunityJSONValue.self, from: Data(#"{"schema":"spatter_quality_report","version":1,"passes":false,"failures":["1 blank frame(s); limit 0."],"findings":[],"unmeasured":["audioOffsetSeconds"],"frameCount":36,"fps":24,"actualTicks":72,"requestedTicks":72,"movie":{"decodedFrameCount":36,"decodedDurationSeconds":3,"expectedFrameCount":36,"expectedDurationSeconds":3},"note":"n"}"#.utf8))
            let q = AdminReviewEvidence.qualityLines(quality)
            try require(q.first == "Quality gates FAILED." && q.contains("• 1 blank frame(s); limit 0.") && q.contains("Decoded movie: 36/36 frames, 3/3 s.") && q.contains("Not measured: audioOffsetSeconds."), "quality lines: \(q)")
            try require(AdminReviewEvidence.qualityLines(.string("ok")) == ["Quality report: unrecognized format (not shown)."], "malformed quality")
        }

        print("COMMUNITY_ADMIN_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed) passed \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
