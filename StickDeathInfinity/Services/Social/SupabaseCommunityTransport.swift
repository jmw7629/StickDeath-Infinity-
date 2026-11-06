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
    static let shared = SupabaseCommunityTransport(provider: { try SupabaseManager.shared.client }, session: SupabaseManager.shared.requestSession)
    /// Production passes the app's configured client. The hosted native journey
    /// tests (Tests/AuthState/ServiceJourneyTests.swift) pass an SDK client
    /// whose URLSession is a local fixture, so the same request, session and
    /// decoding path runs without contacting any host.
    private let provider: @MainActor () throws -> SupabaseClient
    private let scopedSession: URLSession
    init(provider: @escaping @MainActor () throws -> SupabaseClient, session: URLSession) {
        self.provider = provider; scopedSession = session
    }

    private var client: SupabaseClient {
        get throws {
            do { return try provider() }
            catch { throw CommunityError.notConfigured }
        }
    }
    nonisolated var hasSession: Bool {
        MainActor.assumeIsolated { (try? provider().auth.currentSession) != nil }
    }
    nonisolated var sessionAccountID: UUID? {
        MainActor.assumeIsolated { (try? provider().auth.currentSession)?.user.id }
    }

    func rpc<P: Encodable & Sendable>(_ name: String, params: P) async throws -> CommunityReply {
        try CommunityOperationContext.check()
        let client = try client
        guard client.auth.currentSession != nil else { throw CommunityError.signedOut }
        if let expected = CommunityOperationContext.scope?.account, client.auth.currentSession?.user.id != expected { throw CommunityError.stale }
        let sentAt = Date()
        let response: PostgrestResponse<Void>
        do {
            if let scope = CommunityOperationContext.scope {
                response = try await scopedDatabase(client, scope: scope).rpc(name, params: params).execute()
            } else { response = try await client.rpc(name, params: params).execute() }
        }
        catch { throw Self.map(error) }
        try CommunityOperationContext.check()
        return Self.reply(data: response.data, http: response.response, sentAt: sentAt)
    }

    func rows(_ table: String, select: String, filters: [CommunityRowFilter], limit: Int) async throws -> CommunityReply {
        try CommunityOperationContext.check()
        let client = try client
        guard client.auth.currentSession != nil else { throw CommunityError.signedOut }
        if let expected = CommunityOperationContext.scope?.account, client.auth.currentSession?.user.id != expected { throw CommunityError.stale }
        let sentAt = Date()
        let database = CommunityOperationContext.scope.map { scopedDatabase(client, scope: $0) }
        var query = (database?.from(table) ?? client.from(table)).select(select)
        for filter in filters {
            switch filter.op {
            case .eq: query = query.eq(filter.column, value: filter.value)
            }
        }
        let response: PostgrestResponse<Void>
        do { response = try await query.limit(limit).execute() }
        catch { throw Self.map(error) }
        try CommunityOperationContext.check()
        return Self.reply(data: response.data, http: response.response, sentAt: sentAt)
    }

    /// Public SDK2.55.6 configuration hook, copied per call. Never install one caller's lease on
    /// the shared SDK/gateway. Unscoped auth and community requests keep their original SDK path.
    private func scopedDatabase(_ client: SupabaseClient, scope: CommunityOperationScope) -> PostgrestClient {
        var configuration = client.schema("public").configuration
        let account = client.auth.currentSession?.user.id
        let base = configuration.url, session = scopedSession
        configuration.fetch = { request in
            try await Self.scopedFetch(request, client: client, session: session, base: base, account: account, scope: scope)
        }
        return PostgrestClient(configuration: configuration)
    }
    private static func scopedFetch(_ original: URLRequest, client: SupabaseClient, session: URLSession,
                                    base: URL, account: UUID?, scope: CommunityOperationScope) async throws -> (Data, URLResponse) {
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard scope.isCurrent, let account, client.auth.currentSession?.user.id == account,
                  scope.account == nil || scope.account == account else { throw CancellationError() }
        }
        try checkCurrent() // A queued stale call must not even start an auth refresh.
        guard let url = original.url, url.scheme?.lowercased() == "https", base.scheme?.lowercased() == "https",
              url.host?.lowercased() == base.host?.lowercased(), url.port == base.port,
              url.user == nil, url.password == nil, url.path.hasPrefix(base.path + "/") else {
            throw CommunityError.stale
        }
        let authenticated = try await client.auth.session
        try checkCurrent() // Refresh can suspend; no SDK adaptRequest is used after this point.
        guard authenticated.user.id == account, !authenticated.isExpired else { throw CommunityError.stale }
        var request = original
        // Keep the SDK's apikey and other headers; replace only Authorization with the refreshed JWT.
        request.setValue("Bearer \(authenticated.accessToken)", forHTTPHeaderField: "Authorization")
        let pending = CommunityDataTask()
        let result: (Data, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try checkCurrent()
                    let task = session.dataTask(with: request) { data, response, error in pending.complete(data, response, error) }
                    // MainActor check -> create -> resume has no await or executor hop between it.
                    // Cancellation before installation is remembered; completion resumes only once.
                    pending.start(task, continuation: continuation)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { pending.cancel() }
        try checkCurrent()
        return result
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

/// The URLSession completion/cancellation seam only; it owns no auth, view or SDK mutable state.
private final class CommunityDataTask: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        if cancelled || finished {
            finished = true; lock.unlock(); task.cancel(); continuation.resume(throwing: CancellationError()); return
        }
        self.task = task; self.continuation = continuation
        task.resume() // Synchronous and under the cancellation gate, before the caller suspends.
        lock.unlock()
    }
    func complete(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil; task = nil; lock.unlock()
        if let error { continuation?.resume(throwing: error) }
        else if let data, let response { continuation?.resume(returning: (data, response)) }
        else { continuation?.resume(throwing: CommunityError.invalidResponse("The service response was incomplete.")) }
    }
    func cancel() {
        lock.lock(); cancelled = true
        guard !finished else { lock.unlock(); return }
        let task = task, continuation = continuation
        if continuation != nil { finished = true; self.task = nil; self.continuation = nil }
        lock.unlock()
        task?.cancel(); continuation?.resume(throwing: CancellationError())
    }
}
