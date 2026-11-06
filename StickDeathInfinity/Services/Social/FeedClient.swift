// ═══════════════════════════════════════════════════════════════════
// FeedClient — social video wall over `sdi_feed_page` (keyset listing) and
// `sdi_feed_action` (reactions) in video-feed.sql / feed-integrity.sql.
// Pages are server-ranked keyset pages of 25 (the client keeps at most 40 in memory);
// likes/follows are idempotent on the server, so a retried request cannot
// double count. The client only ever shows counts the server returned,
// except the ±1 optimistic change on the tapped card, which is rolled back
// when the server does not confirm.
// ═══════════════════════════════════════════════════════════════════

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class FeedClient {
    enum PageSource: Equatable { case server, cache(updatedAt: Date) }
    struct Page: Equatable {
        let posts: [FeedPost]; let hasMore: Bool; let source: PageSource; var asOf: String? = nil
        var cursor: String? = nil; var downloadRequiresPlan = true
    }

    let gateway: CommunityGateway
    let cache: CommunityOfflineCache<[FeedPost]>
    init(gateway: CommunityGateway, cache: CommunityOfflineCache<[FeedPost]> = .init(name: "feed")) {
        self.gateway = gateway; self.cache = cache
    }

    /// One server page from `sdi_feed_page` (keyset paging). Page 0 sends no
    /// cursor and receives the snapshot instant; every later page must send the
    /// previous page's opaque cursor together with that snapshot, so posts
    /// published, liked or removed meanwhile cannot duplicate or skip rows.
    /// Page 0 of each category is cached per account for the offline label;
    /// later pages are never served from cache.
    func page(_ category: FeedCategory, page: Int, account: String, asOf: String? = nil, cursor: String? = nil) async throws -> Page {
        try CommunityOperationContext.check()
        if let caller = CommunityOperationContext.scope?.account, UUID(uuidString: account) != caller { throw CommunityError.stale }
        guard (0..<FeedTimeline.maximumPages).contains(page) else { throw CommunityError.invalidResponse("Feed page out of range.") }
        if page > 0, cursor == nil || asOf == nil { throw CommunityError.stale }
        do {
            let request = FeedPageRequest(category: category.rawValue, page_cursor: page == 0 ? nil : cursor, as_of: page == 0 ? nil : asOf)
            let response = try await gateway.call("sdi_feed_page", params: request, as: FeedListResponse.self)
            try CommunityOperationContext.check()
            guard let posts = response.posts, let more = response.has_more else { throw CommunityError.invalidResponse("The feed returned an incomplete response.") }
            guard !more || response.next_cursor != nil else { throw CommunityError.invalidResponse("The feed did not return the next page position.") }
            if page == 0 { try? cache.store(posts, account: account, key: category.rawValue) }
            try CommunityOperationContext.check()
            return Page(posts: posts, hasMore: more, source: .server, asOf: response.as_of, cursor: response.next_cursor,
                        downloadRequiresPlan: response.download_requires_plan ?? true)
        } catch let error as CommunityError {
            try CommunityOperationContext.check()
            if page == 0, case .transport = error, let cached = cache.entry(account: account, key: category.rawValue) {
                return Page(posts: cached.value, hasMore: false, source: .cache(updatedAt: cached.updatedAt))
            }
            throw error
        }
    }

    /// `like`/`follow`/`block`/`report`; true only when the server says confirmed.
    func mutate(_ request: FeedRequest) async throws -> Bool {
        try CommunityOperationContext.check()
        guard request.action != "list" else { throw CommunityError.invalidResponse("Use page(_:page:account:asOf:cursor:) for listing.") }
        let response = try await gateway.call("sdi_feed_action", params: request, as: FeedListResponse.self)
        try CommunityOperationContext.check()
        return response.status == "confirmed"
    }
    func like(_ post: UUID, enabled: Bool) async throws -> Bool { try await mutate(FeedRequest(action: "like", post_id: post, enabled: enabled)) }
    func follow(_ creator: UUID, enabled: Bool) async throws -> Bool { try await mutate(FeedRequest(action: "follow", target: creator, enabled: enabled)) }
    func block(_ creator: UUID) async throws -> Bool { try await mutate(FeedRequest(action: "block", target: creator, enabled: true)) }
    func report(_ post: UUID, reason: FeedReportReason) async throws -> Bool { try await mutate(FeedRequest(action: "report", post_id: post, reason: reason.rawValue)) }

    /// Production export streams directly to an owned temporary file. Its media
    /// session is deliberately separate from the authenticated RPC transport.
    func downloadExportFile(for permission: FeedExportListing.Authorization, isCurrent: () -> Bool,
                            progress: @escaping @Sendable (FeedExportDownload.Progress) -> Void = { _ in }) async throws -> URL {
        try await exportFile(for: permission, isCurrent: isCurrent) { url in
            try await FeedExportDownload.fetch(url, progress: progress)
        }
    }

    /// Production transfers accept only a row resolved from the current viewer's
    /// committed listing, rather than a FeedPost captured by an obsolete card.
    func exportFile(for permission: FeedExportListing.Authorization, isCurrent: () -> Bool,
                    download: (URL) async throws -> (URL, Int64)) async throws -> URL {
        try await exportFile(for: permission.post, isCurrent: isCurrent, download: download)
    }

    /// The injected transfer remains useful for fixtures. Recheck cancellation
    /// and caller scope after suspension, before any returned file can be shared.
    func exportFile(for post: FeedPost, isCurrent: () -> Bool = { true },
                    download: (URL) async throws -> (URL, Int64)) async throws -> URL {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        switch FeedExportPolicy.state(post) {
        case .notPermitted: throw CommunityError.server(message: "The creator has not permitted export of this video.", code: nil)
        case .needsPaidPlan: throw CommunityError.server(message: "Saving video files needs a paid plan. Sharing the link is still available.", code: nil)
        case .providerDownloadUnavailable: throw CommunityError.server(message: "YouTube videos cannot be downloaded from the feed. Watch or share the YouTube link instead.", code: nil)
        case .allowed: break
        }
        guard let url = post.downloadableURL else { throw CommunityError.invalidResponse("Video address is unavailable.") }
        let (file, length) = try await download(url)
        do {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard file.isFileURL, attributes[.type] as? FileAttributeType == .typeRegular,
                  let actual = (attributes[.size] as? NSNumber)?.int64Value,
                  length > 0, actual == length, FeedExportPolicy.acceptsLength(actual) else {
                throw CommunityError.invalidResponse("This video is empty or exceeds the export limit.")
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}

/// A server listing's viewer-specific export decisions. Auth/scope publication
/// revokes the view's binding immediately; every committed snapshot gets a new
/// revision, so an old same-ID card cannot reuse a replaced download decision.
struct FeedExportListing: Equatable {
    struct Context: Equatable {
        let account: String
        let generation: UUID
    }
    struct Tap: Equatable {
        fileprivate let revision: UUID
        fileprivate let context: Context
        fileprivate let post: FeedPost
    }
    struct Authorization {
        fileprivate let revision: UUID
        fileprivate let context: Context
        let post: FeedPost
    }
    private let context: Context
    private let revision = UUID()
    private let rows: [FeedPost]
    private init(rows: [FeedPost], context: Context) { self.rows = rows; self.context = context }

    /// The request context must be captured before page I/O. Passing the live
    /// context at completion rejects an old response even after A → B → A.
    static func commit(rows incoming: [FeedPost], previous: FeedExportListing? = nil,
                       captured: Context, current: Context?) -> FeedExportListing? {
        guard current == captured, previous == nil || previous?.matches(current) == true else { return nil }
        // Carry forward only committed server decisions. An optimistic reaction
        // rollback in FeedTimeline must never restore old download permissions.
        var rows = previous?.rows ?? []
        for row in incoming {
            if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row }
            else { rows.append(row) }
        }
        return FeedExportListing(rows: rows, context: captured)
    }
    func matches(_ current: Context?) -> Bool { current == context }
    func capture(for rendered: FeedPost) -> Tap? {
        guard let row = rows.first(where: { $0.id == rendered.id }), Self.sameDecision(row, rendered) else { return nil }
        return Tap(revision: revision, context: context, post: row)
    }
    /// Called synchronously at the tap, before queuing a transfer. Resolve the
    /// current authorized row and require the card's exact listing revision.
    func authorize(_ tap: Tap, rendered: FeedPost, current: Context?, visibleRows: [FeedPost]) -> Authorization? {
        guard let row = checkedRow(revision: tap.revision, context: tap.context, post: tap.post,
                                   current: current, visibleRows: visibleRows), Self.sameDecision(row, rendered) else { return nil }
        return Authorization(revision: revision, context: context, post: row)
    }
    func contains(_ permission: Authorization, current: Context?, visibleRows: [FeedPost]) -> Bool {
        checkedRow(revision: permission.revision, context: permission.context, post: permission.post,
                   current: current, visibleRows: visibleRows) != nil
    }
    private func checkedRow(revision capturedRevision: UUID, context capturedContext: Context, post: FeedPost,
                            current: Context?, visibleRows: [FeedPost]) -> FeedPost? {
        guard matches(current), capturedContext == context, capturedRevision == revision,
              let row = rows.first(where: { $0.id == post.id }), row == post,
              let visible = visibleRows.first(where: { $0.id == post.id }), Self.sameDecision(row, visible),
              FeedExportPolicy.canExport(row) else { return nil }
        return row
    }
    private static func sameDecision(_ lhs: FeedPost, _ rhs: FeedPost) -> Bool {
        // Optimistic reaction counters do not grant or revoke export permission.
        lhs.id == rhs.id && lhs.creator == rhs.creator && lhs.published_at == rhs.published_at &&
            lhs.title == rhs.title && lhs.url == rhs.url && lhs.allow_export == rhs.allow_export &&
            lhs.can_download == rhs.can_download
    }
}

/// One unauthenticated, uncached transfer. Delegate callbacks and cancellation
/// serialize on the same queue; the cap is checked before each disk write, so
/// absent or dishonest Content-Length cannot grow the partial file past policy.
final class FeedExportDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Progress: Sendable {
        let receivedBytes: Int64
        let expectedBytes: Int64?
    }
    private let queue = DispatchQueue(label: "sdi.feed-export.download")
    private let cancellationGate = NSLock()
    private var cancellationRequested = false
    private var isCancelled: Bool { cancellationGate.lock(); defer { cancellationGate.unlock() }; return cancellationRequested }
    private let delegateQueue = OperationQueue()
    private let maximumBytes: Int64
    private let timeout: TimeInterval
    private let directory: URL
    private let partial: URL
    private let destination: URL
    private let protocolClasses: [AnyClass]
    private let progress: @Sendable (Progress) -> Void
    private var session: URLSession?
    private var continuation: CheckedContinuation<(URL, Int64), Error>?
    private var handle: FileHandle?
    private var deadline: DispatchWorkItem?
    private var received: Int64 = 0
    private var lastReportedBytes: Int64 = 0
    private var lastProgressTime: TimeInterval = 0
    private var expected: Int64?
    private var acceptedResponse = false
    private var redirects = 0
    private var finished = false
    private var terminalError: Error?

    // Fixtures can lower the cap and timeout, never raise production's limits.
    static func fetch(_ url: URL, directory: URL = FileManager.default.temporaryDirectory,
                      maximumBytes: Int64 = FeedExportPolicy.maximumDownloadBytes,
                      timeout: TimeInterval = 120, protocolClasses: [AnyClass] = [],
                      progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> (URL, Int64) {
        try Task.checkCancellation()
        guard FeedPlaybackSource.resolve(url.absoluteString)?.renditionURL != nil,
              maximumBytes > 0, maximumBytes <= FeedExportPolicy.maximumDownloadBytes,
              timeout.isFinite, timeout > 0, timeout <= 120, directory.isFileURL else {
            throw CommunityError.invalidResponse("Video download settings are unavailable.")
        }
        let transfer = FeedExportDownload(directory: directory, maximumBytes: maximumBytes, timeout: timeout,
                                          protocolClasses: protocolClasses, progress: progress)
        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in transfer.start(url, continuation: continuation) }
        }, onCancel: { transfer.cancel() })
        do {
            try Task.checkCancellation()
            return result
        } catch {
            try? FileManager.default.removeItem(at: result.0)
            throw error
        }
    }
    private init(directory: URL, maximumBytes: Int64, timeout: TimeInterval, protocolClasses: [AnyClass],
                 progress: @escaping @Sendable (Progress) -> Void) {
        self.directory = directory; self.maximumBytes = maximumBytes; self.timeout = timeout
        self.protocolClasses = protocolClasses; self.progress = progress
        let name = "sdi-export-" + UUID().uuidString
        partial = directory.appendingPathComponent(name + ".part")
        destination = directory.appendingPathComponent(name + ".mp4")
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
    }
    private static func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(30, timeout))
        request.httpShouldHandleCookies = false
        request.setValue("video/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
    private func start(_ url: URL, continuation: CheckedContinuation<(URL, Int64), Error>) {
        queue.async {
            guard !self.finished, !self.isCancelled else { continuation.resume(throwing: self.terminalError ?? CancellationError()); return }
            self.continuation = continuation
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try Data().write(to: self.partial, options: .withoutOverwriting)
                self.handle = try FileHandle(forWritingTo: self.partial)
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = self.protocolClasses.isEmpty ? config.protocolClasses : self.protocolClasses
                config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                config.httpAdditionalHeaders = nil
                config.timeoutIntervalForRequest = min(30, self.timeout)
                config.timeoutIntervalForResource = self.timeout
                let session = URLSession(configuration: config, delegate: self, delegateQueue: self.delegateQueue)
                self.session = session
                let deadline = DispatchWorkItem { [weak self] in
                    self?.fail(CommunityError.transport("The video download timed out. Try again."))
                }
                self.deadline = deadline
                self.queue.asyncAfter(deadline: .now() + self.timeout, execute: deadline)
                let task = session.dataTask(with: Self.request(url, timeout: self.timeout))
                self.cancellationGate.lock()
                if self.cancellationRequested {
                    self.cancellationGate.unlock(); task.cancel(); self.fail(CancellationError()); return
                }
                task.resume()
                self.cancellationGate.unlock()
            } catch { self.fail(CommunityError.transport("The temporary video file could not be created.")) }
        }
    }
    private func cancel() {
        // Remember cancellation immediately, including before queued start reaches resume.
        cancellationGate.lock(); cancellationRequested = true; cancellationGate.unlock()
        queue.async { self.fail(CancellationError()) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard !finished, !isCancelled, redirects < 5, let url = request.url,
              FeedPlaybackSource.resolve(url.absoluteString)?.renditionURL != nil else {
            completionHandler(nil)
            fail(CommunityError.invalidResponse("The video redirected to an unavailable address."))
            return
        }
        redirects += 1
        // Build a fresh request: never forward credentials, cookies or headers
        // supplied by another host, URLSession, or the account RPC session.
        cancellationGate.lock()
        guard !cancellationRequested else {
            cancellationGate.unlock(); completionHandler(nil); fail(CancellationError()); return
        }
        completionHandler(Self.request(url, timeout: timeout))
        cancellationGate.unlock()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished, !isCancelled, let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, FeedPlaybackSource.resolve(url.absoluteString)?.renditionURL != nil else {
            completionHandler(.cancel)
            fail(CommunityError.invalidResponse("The video could not be downloaded."))
            return
        }
        let length = response.expectedContentLength
        guard length < 0 || length <= maximumBytes else {
            completionHandler(.cancel)
            fail(CommunityError.invalidResponse("This video is larger than the export limit."))
            return
        }
        acceptedResponse = true; expected = length < 0 ? nil : length
        publishProgress(force: true)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard acceptedResponse, Int64(data.count) <= maximumBytes - received else {
            fail(CommunityError.invalidResponse("This video is larger than the export limit.")); return
        }
        do {
            guard let handle else { throw CocoaError(.fileWriteUnknown) }
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            publishProgress()
        } catch { fail(CommunityError.transport("The temporary video file could not be saved.")) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled { fail(CancellationError()) }
            else { fail(CommunityError.transport("The video download was interrupted. Try again.")) }
            return
        }
        guard acceptedResponse, received > 0, expected == nil || expected == received else {
            fail(CommunityError.invalidResponse("The video download was incomplete.")); return
        }
        do {
            try handle?.close(); handle = nil
            try FileManager.default.moveItem(at: partial, to: destination)
            publishProgress(force: true)
            complete(.success((destination, received)))
        } catch { fail(CommunityError.transport("The temporary video file could not be saved.")) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(Security)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil); return
        }
        #endif
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    private func publishProgress(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        // Tiny server chunks must not enqueue an unbounded number of UI tasks.
        guard force || (lastReportedBytes == 0 && received > 0) || now - lastProgressTime >= 0.1 else { return }
        lastProgressTime = now; lastReportedBytes = received
        progress(Progress(receivedBytes: received, expectedBytes: expected))
    }
    private func fail(_ error: Error) {
        guard !finished else { return }
        try? handle?.close(); handle = nil
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: destination)
        terminalError = error
        complete(.failure(error))
    }
    private func complete(_ result: Result<(URL, Int64), Error>) {
        guard !finished else { return }
        finished = true; deadline?.cancel(); deadline = nil
        session?.invalidateAndCancel(); session = nil
        let waiting = continuation; continuation = nil
        waiting?.resume(with: result)
    }
}

/// Keeps a file alive after SwiftUI clears its sheet binding. Only the actual
/// UIKit consumer callback releases an offered file. One outstanding consumer
/// bounds abandoned shares to one policy-sized file; no expiry can delete a
/// file while an activity extension is still copying it.
@MainActor
final class FeedExportFile: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let account: String
    let generation: UUID
    private static var consumer: FeedExportFile?
    private var offered = false
    private var closed = false
    static var hasOutstandingConsumer: Bool { consumer != nil }
    init(url: URL, title: String, account: String = "", generation: UUID = UUID()) {
        self.url = url; self.title = title; self.account = account; self.generation = generation
    }
    func offerToShare() -> Bool {
        guard !closed, !offered, Self.consumer == nil else { return false }
        offered = true; Self.consumer = self
        return true
    }
    /// A replacement listing invalidates only files not yet offered to UIKit.
    /// The closed flag also rejects a host whose viewDidAppear was queued.
    @discardableResult
    func revokePendingShare() -> Bool {
        guard !offered else { return false }
        cleanUp()
        return true
    }
    func ownerClosed() { if !offered { cleanUp() } }
    func consumerFinished() {
        guard offered else { return }
        offered = false
        if Self.consumer === self { Self.consumer = nil }
        cleanUp()
    }
    private func cleanUp() {
        guard !closed else { return }
        closed = true
        try? FileManager.default.removeItem(at: url)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
