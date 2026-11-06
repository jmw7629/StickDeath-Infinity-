// ═══════════════════════════════════════════════════════════════════
// CommunityTransport — the one seam between the community clients and the
// network. Production uses SupabaseCommunityTransport; the Foundation test
// suites use scripted fakes that never open a connection.
// ═══════════════════════════════════════════════════════════════════

import Foundation

/// Raw reply plus the timing needed for the server clock estimate.
struct CommunityReply {
    let data: Data
    let serverDate: Date?
    let sentAt: Date
    let receivedAt: Date
}

struct CommunityRowFilter: Equatable {
    enum Operator: String { case eq }
    let column: String
    let op: Operator
    let value: String
    static func eq(_ column: String, _ value: String) -> CommunityRowFilter { .init(column: column, op: .eq, value: value) }
}

protocol CommunityTransport: AnyObject {
    /// `POST /rest/v1/rpc/<name>` with a JSON parameter object.
    func rpc<P: Encodable & Sendable>(_ name: String, params: P) async throws -> CommunityReply
    /// `GET /rest/v1/<table>?select=…` under row-level security.
    func rows(_ table: String, select: String, filters: [CommunityRowFilter], limit: Int) async throws -> CommunityReply
    /// Whether a signed-in session exists; clients refuse to call without one.
    var hasSession: Bool { get }
    /// Production's actual SDK account, read without refreshing or issuing a request.
    var sessionAccountID: UUID? { get }
}
extension CommunityTransport { var sessionAccountID: UUID? { nil } }

/// Explicit owner of a queued community operation. Default nil keeps unrelated callers and
/// Foundation fixtures compatible; Rooms supplies account/window/scene/session guards.
@MainActor
final class CommunityOperationScope {
    let account: UUID?
    private let current: @MainActor () -> Bool
    init(account: UUID? = nil, current: @escaping @MainActor () -> Bool) { self.account = account; self.current = current }
    var isCurrent: Bool { !Task.isCancelled && current() }
    func check() throws { guard isCurrent else { throw CommunityError.stale } }
}
enum CommunityOperationContext {
    @TaskLocal static var scope: CommunityOperationScope?
    @MainActor static var isCurrent: Bool { !Task.isCancelled && (scope?.isCurrent ?? true) }
    @MainActor static func check() throws { guard isCurrent else { throw CommunityError.stale } }
    @MainActor static func run<Value>(_ scope: CommunityOperationScope, operation: @MainActor () async throws -> Value) async throws -> Value {
        try await Self.$scope.withValue(scope) {
            try scope.check()
            let value = try await operation()
            try scope.check()
            return value
        }
    }
}

/// Shared call helper: decodes replies, surfaces server errors, bounds the
/// body size and feeds the clock estimator from every reply.
@MainActor
final class CommunityGateway {
    let transport: CommunityTransport
    private(set) var clock = ServerClockEstimator()
    init(transport: CommunityTransport) { self.transport = transport }

    func call<P: Encodable & Sendable, R: CommunityResponse>(_ name: String, params: P, as type: R.Type) async throws -> R {
        try CommunityOperationContext.check()
        guard transport.hasSession else { throw CommunityError.signedOut }
        let account = try checkedAccount()
        let reply = try await transport.rpc(name, params: params)
        try checkReplyAccount(account)
        clock.record(sentAt: reply.sentAt, receivedAt: reply.receivedAt, serverDate: reply.serverDate)
        try Task.checkCancellation()
        return try CommunityCoding.decode(R.self, from: reply.data)
    }
    /// Like `call`, but a server `error` field is returned inside the value so
    /// the caller can read companion fields (for example a command conflict's
    /// `head` and `missing`). Transport and decoding failures still throw.
    func callKeepingServerError<P: Encodable & Sendable, R: CommunityResponse>(_ name: String, params: P, as type: R.Type) async throws -> R {
        try CommunityOperationContext.check()
        guard transport.hasSession else { throw CommunityError.signedOut }
        let account = try checkedAccount()
        let reply = try await transport.rpc(name, params: params)
        try checkReplyAccount(account)
        clock.record(sentAt: reply.sentAt, receivedAt: reply.receivedAt, serverDate: reply.serverDate)
        try Task.checkCancellation()
        return try CommunityCoding.decodeKeepingServerError(R.self, from: reply.data)
    }
    func rows<R: Decodable>(_ table: String, select: String = "*", filters: [CommunityRowFilter] = [], limit: Int = 100, as type: R.Type) async throws -> [R] {
        try CommunityOperationContext.check()
        guard transport.hasSession else { throw CommunityError.signedOut }
        let account = try checkedAccount()
        let reply = try await transport.rows(table, select: select, filters: filters, limit: limit)
        try checkReplyAccount(account)
        clock.record(sentAt: reply.sentAt, receivedAt: reply.receivedAt, serverDate: reply.serverDate)
        try Task.checkCancellation()
        let values = try CommunityCoding.decodeRows(R.self, from: reply.data)
        guard values.count <= limit else { throw CommunityError.invalidResponse("The server returned more rows than requested.") }
        return values
    }
    private func checkedAccount() throws -> UUID? {
        let account = transport.sessionAccountID
        if let expected = CommunityOperationContext.scope?.account, account != expected { throw CommunityError.stale }
        return account
    }
    private func checkReplyAccount(_ expected: UUID?) throws {
        try CommunityOperationContext.check()
        guard transport.hasSession, transport.sessionAccountID == expected else { throw CommunityError.stale }
    }
    /// Map any thrown error to a CommunityError without leaking response bodies.
    static func normalize(_ error: Error) -> CommunityError {
        if let known = error as? CommunityError { return known }
        if error is CancellationError { return .stale }
        return .transport("The service could not be reached. Check your connection and service configuration.")
    }
}
