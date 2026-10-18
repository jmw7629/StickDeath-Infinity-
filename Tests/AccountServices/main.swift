import Foundation

// Foundation-only verification of the account service clients: support intake
// (#272), marketing permission and policy links (#273), notification
// preferences and inbox (#290) and the server entitlement check (#251).
// Scripted fake transports only; nothing opens a connection.

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

private let requestID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let key = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let delivery = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private let device = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

@main @MainActor struct AccountServicesTests {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        func fixture(_ replies: [String]) -> (FakeTransport, CommunityGateway) {
            let transport = FakeTransport()
            transport.replies = replies.map { .success($0) }
            return (transport, CommunityGateway(transport: transport))
        }

        // MARK: Support (#272)

        await test("support create sends trimmed bounded fields with the idempotency key and returns the server receipt") {
            let (transport, gateway) = fixture([#"{"status":"created","request_id":"\#(requestID.uuidString)","receipt":"SDI-ABCDEFGH12","request_status":"open"}"#])
            let receipt = try await SupportClient(gateway: gateway).create(category: .billing, subject: "  Restore failed ", body: "\nIt spins.\n",
                                                                           appVersion: String(repeating: "9", count: 80), idempotency: key)
            try require(receipt == SupportReceipt(requestID: requestID, receipt: "SDI-ABCDEFGH12", status: "open", duplicate: false), "receipt")
            let params = transport.calls[0].params
            try require(transport.calls[0].name == "sdi_support_action", "rpc name")
            try require(params["action"] as? String == "create" && params["category"] as? String == "billing" && params["platform"] as? String == "ios", "action fields")
            try require(params["subject"] as? String == "Restore failed" && params["body"] as? String == "It spins.", "trimmed text")
            try require((params["app_version"] as? String)?.count == 50, "app version bounded to 50")
            try require((params["idempotency"] as? String)?.lowercased() == key.uuidString.lowercased(), "idempotency key sent")
            try require(params["request"] == nil, "no request id on create")
        }
        await test("a retried draft reports the existing receipt as a duplicate") {
            let (_, gateway) = fixture([#"{"status":"duplicate","request_id":"\#(requestID.uuidString)","receipt":"SDI-ABCDEFGH12","request_status":"in_progress"}"#])
            let receipt = try await SupportClient(gateway: gateway).create(category: .bug, subject: "s", body: "b", appVersion: "1.0", idempotency: key)
            try require(receipt.duplicate && receipt.status == "in_progress", "duplicate surfaced")
        }
        await test("support create refuses empty or oversized drafts before sending") {
            let (transport, gateway) = fixture([])
            let client = SupportClient(gateway: gateway)
            for (subject, body) in [("   ", "body"), ("s", ""), (String(repeating: "x", count: 121), "b"), ("s", String(repeating: "y", count: 2001)),
                                   // 61 flags are 61 characters to Swift but 122 code points to PostgreSQL's length().
                                   (String(repeating: "\u{1F1FA}\u{1F1F8}", count: 61), "b")] {
                do { _ = try await client.create(category: .other, subject: subject, body: body, appVersion: "", idempotency: key); throw Failure(description: "accepted invalid draft") }
                catch let error as CommunityError { if case .server = error {} else { throw Failure(description: "wrong error \(error)") } }
            }
            try require(transport.calls.isEmpty, "nothing sent")
            try require(SupportLimits.length("\u{1F1FA}\u{1F1F8}") == 2 && SupportLimits.prefix("ab\u{1F1FA}\u{1F1F8}", 3) == "ab\u{1F1FA}", "code-point counting")
        }
        await test("support create surfaces the server's daily limit and refuses a reply without a valid receipt") {
            let (_, gateway) = fixture([#"{"error":"Daily support request limit reached. Existing requests remain open."}"#,
                                        #"{"status":"created","request_id":"\#(requestID.uuidString)","receipt":"not-a-receipt"}"#])
            let client = SupportClient(gateway: gateway)
            do { _ = try await client.create(category: .other, subject: "s", body: "b", appVersion: "", idempotency: key); throw Failure(description: "limit hidden") }
            catch CommunityError.server(let message, _) { try require(message.contains("Daily support request limit"), "server words kept") }
            do { _ = try await client.create(category: .other, subject: "s", body: "b", appVersion: "", idempotency: key); throw Failure(description: "bad receipt accepted") }
            catch CommunityError.invalidResponse {}
        }
        await test("support list decodes own requests and withdraw/delete need the server's confirmation") {
            let row = #"{"id":"\#(requestID.uuidString)","receipt":"SDI-ABCDEFGH12","category":"studio","platform":"ios","app_version":"1.0","subject":"S","body":"B","status":"waiting_on_member","revision":2,"created_at":"2026-10-17T10:00:00.123456+00:00","updated_at":"2026-10-17T11:00:00+00:00"}"#
            let (transport, gateway) = fixture([#"{"requests":[\#(row)]}"#, #"{"status":"confirmed"}"#, #"{"error":"This request is already closed."}"#, #"{"status":"something"}"#])
            let client = SupportClient(gateway: gateway)
            let list = try await client.listMine()
            try require(list.count == 1 && list[0].canWithdraw && list[0].statusTitle == "Waiting for your reply" && list[0].categoryTitle == "Studio and projects", "row decoded")
            try await client.withdraw(requestID)
            try require(transport.calls[1].params["action"] as? String == "withdraw" && (transport.calls[1].params["request"] as? String)?.lowercased() == requestID.uuidString.lowercased(), "withdraw params")
            do { try await client.withdraw(requestID); throw Failure(description: "closed withdraw accepted") } catch CommunityError.server {}
            do { try await client.delete(requestID); throw Failure(description: "unconfirmed delete accepted") } catch CommunityError.invalidResponse {}
        }
        await test("support calls are refused without a session and report not-configured honestly") {
            let (transport, gateway) = fixture([])
            transport.hasSession = false
            do { _ = try await SupportClient(gateway: gateway).listMine(); throw Failure(description: "signed-out call") } catch CommunityError.signedOut {}
            try require(transport.calls.isEmpty, "no call without session")
            try require(CommunityError.notConfigured.errorDescription?.contains("not configured") == true, "not-configured copy")
        }

        // MARK: Privacy choices (#273)

        await test("policy links use the canonical website base and the versioned policy pages") {
            try require(PolicyLinks.terms.absoluteString == "https://stickdeathinfinity.com/policies/terms-v1.html", "terms")
            try require(PolicyLinks.privacy.absoluteString == "https://stickdeathinfinity.com/policies/privacy-v1.html", "privacy")
            let constants = URL(fileURLWithPath: "scripts/website/site_constants.mjs")
            if let text = try? String(contentsOf: constants, encoding: .utf8) {
                try require(text.contains("export const CANONICAL_BASE = '\(PolicyLinks.canonicalBase)';"), "base matches site_constants.mjs")
                for path in [PolicyLinks.termsPath, PolicyLinks.privacyPath, PolicyLinks.publishingPath, PolicyLinks.attributionPath] {
                    try require(FileManager.default.fileExists(atPath: "website/" + path), "website/\(path) exists")
                }
            } else {
                print("NOTE site_constants.mjs not found from the working directory; cross-check skipped")
            }
        }
        await test("marketing state reads the current policy and the member's server record") {
            let (transport, gateway) = fixture([
                #"{"policies":[{"policy":"marketing","version":"m-2","summary":"Reuse in promotion","metadata":{},"effective_at":"2026-10-01T00:00:00+00:00"},{"policy":"terms","version":"t-1","summary":"Terms","metadata":{},"effective_at":"2026-09-01T00:00:00+00:00"}]}"#,
                #"{"consents":[{"policy":"marketing","version":"m-1","source":"web","accepted_at":"2026-09-02T00:00:00+00:00","withdrawn_at":null,"current":false},{"policy":"marketing","version":"m-2","source":"ios","accepted_at":"2026-10-02T00:00:00+00:00","withdrawn_at":null,"current":true}],"publishing_current":false,"marketing_current":true}"#])
            let state = try await PrivacyChoicesClient(gateway: gateway).marketingState()
            try require(state.currentPolicy?.version == "m-2" && state.granted && state.latest?.version == "m-2", "state")
            try require(transport.calls.map { $0.params["action"] as? String } == ["current", "mine"], "actions")
        }
        await test("marketing grant sends the shown version from ios and withdrawal needs the server's confirmation") {
            let (transport, gateway) = fixture([#"{"status":"accepted","policy":"marketing","version":"m-2"}"#,
                                                #"{"error":"Policy version changed. Review the current version before accepting.","current":"m-3"}"#,
                                                #"{"status":"withdrawn","policy":"marketing","records":1}"#,
                                                #"{"status":"withdrawn","policy":"publishing","records":1}"#])
            let client = PrivacyChoicesClient(gateway: gateway)
            try await client.grantMarketing(version: "m-2")
            let params = transport.calls[0].params
            try require(params["action"] as? String == "accept" && params["policy"] as? String == "marketing" && params["version"] as? String == "m-2" && params["source"] as? String == "ios", "accept params")
            do { try await client.grantMarketing(version: "m-2"); throw Failure(description: "stale version accepted") } catch CommunityError.server {}
            try await client.withdrawMarketing()
            try require(transport.calls[2].params["action"] as? String == "withdraw" && transport.calls[2].params["policy"] as? String == "marketing", "withdraw params")
            do { try await client.withdrawMarketing(); throw Failure(description: "wrong policy confirmation accepted") } catch CommunityError.invalidResponse {}
        }

        // MARK: Notifications (#290)

        let prefsJSON = #"{"push_product":false,"push_marketing":false,"email_product":true,"email_marketing":false,"daily_cap":2,"transactional":"always on for account and service notices","devices":[{"id":"\#(device.uuidString)","platform":"ios","environment":"sandbox","created_at":"2026-10-01T00:00:00+00:00","last_seen_at":"2026-10-02T00:00:00+00:00"}]}"#
        await test("notification preferences decode and saving sends only changed fields then reads back") {
            let saved = prefsJSON.replacingOccurrences(of: #""daily_cap":2"#, with: #""daily_cap":5"#).replacingOccurrences(of: #""push_product":false"#, with: #""push_product":true"#)
            let (transport, gateway) = fixture([prefsJSON, #"{"status":"confirmed"}"#, saved])
            let client = NotificationsClient(gateway: gateway)
            let old = try await client.preferences()
            try require(old.emailProduct && !old.pushProduct && old.dailyCap == 2 && old.devices.count == 1, "decoded")
            var edit = old; edit.pushProduct = true; edit.dailyCap = 5
            let stored = try await client.save(from: old, to: edit)
            try require(stored.pushProduct && stored.dailyCap == 5, "read back")
            let payload = transport.calls[1].params["payload"] as? [String: Any] ?? [:]
            try require(transport.calls[1].params["action"] as? String == "set_preferences", "action")
            try require(Set(payload.keys) == ["push_product", "daily_cap"] && payload["push_product"] as? Bool == true && payload["daily_cap"] as? Int == 5, "only changes sent: \(payload)")
            try require(transport.calls[0].params["payload"] as? [String: Any] != nil, "empty payload object sent")
        }
        await test("unchanged preferences send nothing and an out-of-range cap is refused locally") {
            let (transport, gateway) = fixture([prefsJSON])
            let client = NotificationsClient(gateway: gateway)
            let old = try await client.preferences()
            _ = try await client.save(from: old, to: old)
            var edit = old; edit.dailyCap = 11
            do { _ = try await client.save(from: old, to: edit); throw Failure(description: "cap 11 accepted") } catch CommunityError.server {}
            try require(transport.calls.count == 1, "no write sent")
        }
        await test("a preferences reply with a cap outside 0...10 or missing fields is refused") {
            let (_, gateway) = fixture([prefsJSON.replacingOccurrences(of: #""daily_cap":2"#, with: #""daily_cap":42"#), #"{"push_product":true}"#])
            let client = NotificationsClient(gateway: gateway)
            for _ in 0..<2 { do { _ = try await client.preferences(); throw Failure(description: "accepted") } catch CommunityError.invalidResponse {} }
        }
        await test("inbox decodes notices with the unread count and mark-read reports confirmed or unchanged") {
            let notice = #"{"delivery":"\#(delivery.uuidString)","title":"Maintenance","body":"Sunday 02:00 UTC","category":"transactional","state":"sent","delivered_at":"2026-10-17T09:00:00+00:00"}"#
            let (transport, gateway) = fixture([#"{"notices":[\#(notice)],"unread":1}"#, #"{"status":"confirmed"}"#, #"{"status":"unchanged"}"#, #"{"status":"other"}"#])
            let client = NotificationsClient(gateway: gateway)
            let inbox = try await client.inbox()
            try require(inbox.unread == 1 && inbox.notices.first?.isUnread == true && inbox.notices.first?.categoryTitle == "Account and service", "inbox")
            try require(try await client.markRead(delivery), "confirmed")
            let payload = transport.calls[1].params["payload"] as? [String: Any]
            try require((payload?["delivery"] as? String)?.lowercased() == delivery.uuidString.lowercased(), "delivery id sent")
            try require(try await client.markRead(delivery) == false, "unchanged")
            do { _ = try await client.markRead(delivery); throw Failure(description: "unknown status accepted") } catch CommunityError.invalidResponse {}
        }

        // MARK: Server entitlement (#251)

        await test("server entitlement decodes free and paid records and refuses incomplete paid ones") {
            let (transport, gateway) = fixture([#"{"tier":"free","status":"none","paid_through":null,"provider":null}"#,
                                                #"{"tier":"pro","status":"grace","paid_through":"2026-11-01T00:00:00+00:00","provider":"apple","cancel_at_period_end":true}"#,
                                                #"{"tier":"pro","status":"active","paid_through":null,"provider":"apple"}"#,
                                                #"{"tier":"studio","status":"active","paid_through":"2026-11-01T00:00:00+00:00","provider":"apple"}"#,
                                                #"{"error":"Sign in to view your plan."}"#])
            let client = ServerEntitlementClient(gateway: gateway)
            let free = try await client.current()
            try require(free.tier == .free && free.provider == nil, "free")
            let pro = try await client.current()
            try require(pro.tier == .pro && pro.status == "grace" && pro.cancelAtPeriodEnd && pro.provider == "apple", "pro")
            for _ in 0..<2 { do { _ = try await client.current(); throw Failure(description: "incomplete accepted") } catch CommunityError.invalidResponse {} }
            do { _ = try await client.current(); throw Failure(description: "server error hidden") } catch CommunityError.server {}
            try require(transport.calls.allSatisfy { $0.name == "sdi_my_entitlement" }, "rpc name")
        }
        await test("reconciliation verifies matches, defers when the server has no record and keeps the server's paid tier") {
            func server(_ tier: BillingPlanTier) -> ServerEntitlement {
                ServerEntitlement(tier: tier, status: tier == .free ? "none" : "active", paidThrough: nil, provider: tier == .free ? nil : "apple", cancelAtPeriodEnd: false)
            }
            try require(ServerEntitlementReconciliation.verification(storeTier: .creator, server: server(.creator)) == .verified, "match")
            try require(ServerEntitlementReconciliation.verification(storeTier: .pro, server: server(.free)) == .deferred(ServerEntitlementReconciliation.notRecordedYet), "not recorded")
            if case .deferred(let text) = ServerEntitlementReconciliation.verification(storeTier: .pro, server: server(.creator)) {
                try require(text.contains("Creator") && text.contains("Pro"), "mismatch named")
            } else { throw Failure(description: "mismatch not deferred") }
            try require(ServerEntitlementReconciliation.verification(storeTier: .free, server: server(.pro)) == .verified, "web plan accepted")
            try require(ServerEntitlementReconciliation.grantedTier(server(.pro)) == .pro && ServerEntitlementReconciliation.grantedTier(nil) == .free, "granted tier")
        }
        await test("reconciliation failures are worded honestly: not configured, signed out and offline") {
            if case .deferred(let text) = ServerEntitlementReconciliation.verification(for: CommunityError.notConfigured) { try require(text.contains("not configured"), "nc") } else { throw Failure(description: "nc") }
            if case .deferred(let text) = ServerEntitlementReconciliation.verification(for: CommunityError.signedOut) { try require(text.contains("sign in"), "so") } else { throw Failure(description: "so") }
            if case .failed(let text) = ServerEntitlementReconciliation.verification(for: URLError(.notConnectedToInternet)) { try require(text.contains("could not be reached"), "offline") } else { throw Failure(description: "offline") }
            try require(ServerEntitlementReconciliation.verification(for: CommunityError.server(message: "Sign in to view your plan.", code: nil)) == .failed("Sign in to view your plan."), "server text")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
