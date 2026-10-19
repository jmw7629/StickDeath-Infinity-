// ═══════════════════════════════════════════════════════════════════
// SupabaseCommunityTransport — production CommunityTransport over the
// existing Supabase client. No endpoint is invented: without validated
// configuration every call fails with CommunityError.notConfigured, and
// without a session with CommunityError.signedOut. Media playback never
// goes through here; AVPlayer loads HTTPS renditions without account tokens.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class SupabaseCommunityTransport: CommunityTransport {
    static let shared = SupabaseCommunityTransport(provider: { try SupabaseManager.shared.client })
    /// Production passes the app's configured client. The hosted native journey
    /// tests (Tests/AuthState/ServiceJourneyTests.swift) pass an SDK client
    /// whose URLSession is a local fixture, so the same request, session and
    /// decoding path runs without contacting any host.
    private let provider: @MainActor () throws -> SupabaseClient
    init(provider: @escaping @MainActor () throws -> SupabaseClient) { self.provider = provider }

    private var client: SupabaseClient {
        get throws {
            do { return try provider() }
            catch { throw CommunityError.notConfigured }
        }
    }
    nonisolated var hasSession: Bool {
        MainActor.assumeIsolated { (try? provider().auth.currentSession) != nil }
    }

    func rpc<P: Encodable & Sendable>(_ name: String, params: P) async throws -> CommunityReply {
        let client = try client
        guard client.auth.currentSession != nil else { throw CommunityError.signedOut }
        let sentAt = Date()
        let response: PostgrestResponse<Void>
        do { response = try await client.rpc(name, params: params).execute() }
        catch { throw Self.map(error) }
        return Self.reply(data: response.data, http: response.response, sentAt: sentAt)
    }

    func rows(_ table: String, select: String, filters: [CommunityRowFilter], limit: Int) async throws -> CommunityReply {
        let client = try client
        guard client.auth.currentSession != nil else { throw CommunityError.signedOut }
        let sentAt = Date()
        var query = client.from(table).select(select)
        for filter in filters {
            switch filter.op {
            case .eq: query = query.eq(filter.column, value: filter.value)
            }
        }
        let response: PostgrestResponse<Void>
        do { response = try await query.limit(limit).execute() }
        catch { throw Self.map(error) }
        return Self.reply(data: response.data, http: response.response, sentAt: sentAt)
    }

    private static func reply(data: Data, http: HTTPURLResponse, sentAt: Date) -> CommunityReply {
        let header = http.value(forHTTPHeaderField: "Date")
        return CommunityReply(data: data, serverDate: header.flatMap(CommunityDates.parseHTTPDate), sentAt: sentAt, receivedAt: Date())
    }
    private static func map(_ error: Error) -> CommunityError {
        if let known = error as? CommunityError { return known }
        if error is CancellationError { return .stale }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .transport("You appear to be offline. Check your connection and try again.")
            default: break
            }
        }
        // PostgREST failures carry server text; it is not shown verbatim.
        return .transport("The service refused or could not complete the request. Refresh before retrying.")
    }
}
