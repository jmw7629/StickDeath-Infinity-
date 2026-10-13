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
}

/// Shared call helper: decodes replies, surfaces server errors, bounds the
/// body size and feeds the clock estimator from every reply.
@MainActor
final class CommunityGateway {
    let transport: CommunityTransport
    private(set) var clock = ServerClockEstimator()
    init(transport: CommunityTransport) { self.transport = transport }

    func call<P: Encodable & Sendable, R: CommunityResponse>(_ name: String, params: P, as type: R.Type) async throws -> R {
        guard transport.hasSession else { throw CommunityError.signedOut }
        let reply = try await transport.rpc(name, params: params)
        clock.record(sentAt: reply.sentAt, receivedAt: reply.receivedAt, serverDate: reply.serverDate)
        try Task.checkCancellation()
        return try CommunityCoding.decode(R.self, from: reply.data)
    }
    /// Like `call`, but a server `error` field is returned inside the value so
    /// the caller can read companion fields (for example a command conflict's
    /// `head` and `missing`). Transport and decoding failures still throw.
    func callKeepingServerError<P: Encodable & Sendable, R: CommunityResponse>(_ name: String, params: P, as type: R.Type) async throws -> R {
        guard transport.hasSession else { throw CommunityError.signedOut }
        let reply = try await transport.rpc(name, params: params)
        clock.record(sentAt: reply.sentAt, receivedAt: reply.receivedAt, serverDate: reply.serverDate)
        try Task.checkCancellation()
        return try CommunityCoding.decodeKeepingServerError(R.self, from: reply.data)
    }
    func rows<R: Decodable>(_ table: String, select: String = "*", filters: [CommunityRowFilter] = [], limit: Int = 100, as type: R.Type) async throws -> [R] {
        guard transport.hasSession else { throw CommunityError.signedOut }
        let reply = try await transport.rows(table, select: select, filters: filters, limit: limit)
        clock.record(sentAt: reply.sentAt, receivedAt: reply.receivedAt, serverDate: reply.serverDate)
        try Task.checkCancellation()
        let values = try CommunityCoding.decodeRows(R.self, from: reply.data)
        guard values.count <= limit else { throw CommunityError.invalidResponse("The server returned more rows than requested.") }
        return values
    }
    /// Map any thrown error to a CommunityError without leaking response bodies.
    static func normalize(_ error: Error) -> CommunityError {
        if let known = error as? CommunityError { return known }
        if error is CancellationError { return .stale }
        return .transport("The service could not be reached. Check your connection and service configuration.")
    }
}
