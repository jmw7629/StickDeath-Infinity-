import Foundation

private struct Failure: Error {}
private func require(_ value: @autoclosure () -> Bool) throws { if !value() { throw Failure() } }
@MainActor private final class Gate {
    var reply: CheckedContinuation<Data, Error>?
    var start: CheckedContinuation<Void, Never>?
    var entered = false
    func fetch() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            reply = continuation; entered = true; start?.resume(); start = nil
        }
    }
    func wait() async { if !entered { await withCheckedContinuation { start = $0 } } }
}
@main @MainActor struct AdminOverviewTests {
    static func main() async {
        do {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var session: AdminOverviewModel.AuthorizedSession? = nil
            var calls = 0
            let fixture = Data(#"{"totalUsers":7,"activeToday":2,"totalAnimations":11,"revenueMinorUnits":1299,"currency":"USD","pendingReports":1,"aiQueriesDay":4,"measuredAt":"2027-01-15T08:00:00Z"}"#.utf8)
            let model = AdminOverviewModel(currentSession: { session }, transport: { _ in calls += 1; return fixture }, now: { now })
            await model.refresh(accountID: nil); try require(calls == 0)
            await model.refresh(accountID: "a"); try require(calls == 0)
            session = .init(accountID: "a", sessionID: UUID(), expiresAt: now.addingTimeInterval(300))
            await model.refresh(accountID: "b"); try require(calls == 0)
            let absent = AdminOverviewModel(currentSession: { session }, now: { now })
            await absent.refresh(accountID: "a")
            if case .unavailable = absent.state {} else { throw Failure() }
            print("PASS missing account authorization and configuration perform zero transport requests")
            await model.refresh(accountID: "a")
            guard case .data(let data) = model.state else { throw Failure() }
            try require(calls == 1 && data.totalUsers == 7 && data.revenueMinorUnits == 1299 && data.currency == "USD")
            print("PASS actual JSON snapshot decoding publishes supplied counts and money units")
            let error = AdminOverviewModel(currentSession: { session }, transport: { _ in throw Failure() }, now: { now })
            await error.refresh(accountID: "a")
            if case .failed = error.state {} else { throw Failure() }
            let malformed = AdminOverviewModel(currentSession: { session }, transport: { _ in Data("{}".utf8) }, now: { now })
            await malformed.refresh(accountID: "a")
            if case .failed = malformed.state {} else { throw Failure() }
            print("PASS transport and invalid payload errors never invent statistics")
            for switchAccount in [false, true] {
                session = .init(accountID: "a", sessionID: UUID(), expiresAt: now.addingTimeInterval(300))
                let gate = Gate()
                let pending = AdminOverviewModel(currentSession: { session }, transport: { _ in try await gate.fetch() }, now: { now })
                let task = Task { await pending.refresh(accountID: "a") }
                await gate.wait()
                if case .loading = pending.state {} else { throw Failure() }
                if switchAccount { session = .init(accountID: "b", sessionID: UUID(), expiresAt: now.addingTimeInterval(300)) }
                else { pending.invalidate() }
                gate.reply?.resume(returning: fixture); await task.value
                if case .unavailable = pending.state {} else { throw Failure() }
            }
            print("PASS late completion cannot republish invalidated or other-account data")
            session = .init(accountID: "a", sessionID: UUID(), expiresAt: now)
            await model.refresh(accountID: "a"); try require(calls == 1)
            do { _ = try AdminOverviewSnapshot.decode(Data(repeating: 32, count: 65_537)); throw Failure() }
            catch AdminOverviewSnapshot.Failure.invalid {}
            print("PASS expired authorization and oversized data fail closed")
            var clock = now, tick: TimeInterval = 100
            let bound = AdminOverviewModel(currentSession: { session }, transport: { _ in fixture }, now: { clock }, uptime: { tick })
            for invalidation in 0..<3 {
                session = .init(accountID: "a", sessionID: UUID(), expiresAt: clock.addingTimeInterval(60))
                await bound.refresh(accountID: "a")
                guard case .data = bound.state else { throw Failure() }
                if invalidation == 0 { clock = clock.addingTimeInterval(61) }
                else if invalidation == 1 { session = nil }
                else { session = .init(accountID: "a", sessionID: UUID(), expiresAt: clock.addingTimeInterval(60)) }
                try require(!bound.revalidateAuthorization())
                if case .unavailable = bound.state {} else { throw Failure() }
            }
            print("PASS delivered data disappears on expiry revocation and same-account session rotation")
            session = .init(accountID: "a", sessionID: UUID(), expiresAt: clock.addingTimeInterval(300))
            let lease = Gate(); var leasedCalls = 0
            let leased = AdminOverviewModel(currentSession: { session }, transport: { _ in
                leasedCalls += 1; return try await lease.fetch()
            }, now: { clock }, uptime: { tick })
            let first = Task { await leased.refresh(accountID: "a") }
            await lease.wait()
            tick += 16
            try require(!leased.revalidateAuthorization())
            if case .failed = leased.state {} else { throw Failure() }
            await leased.refresh(accountID: "a")
            try require(leasedCalls == 1)
            if case .unavailable = leased.state {} else { throw Failure() }
            leased.invalidate() // same path used for background/disappear
            await leased.refresh(accountID: "a"); try require(leasedCalls == 1)
            lease.reply?.resume(returning: fixture); await first.value
            if case .unavailable = leased.state {} else { throw Failure() }
            lease.entered = false
            let next = Task { await leased.refresh(accountID: "a") }
            await lease.wait(); try require(leasedCalls == 2)
            leased.invalidate(); lease.reply?.resume(returning: fixture); await next.value
            print("PASS timeout/background revoke results but retain worker lease until completion then admit a new request")
            model.invalidate(); bound.invalidate(); leased.invalidate()
            print("ADMIN_OVERVIEW_TESTS=PASS 7 production groups")
        } catch { print("ADMIN_OVERVIEW_TESTS=FAIL \(error)"); exit(1) }
    }
}
