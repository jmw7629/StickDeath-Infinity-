// ═══════════════════════════════════════════════════════════════════
// FeedClient — social video wall over `sdi_feed_page` (keyset listing) and
// `sdi_feed_action` (reactions) in video-feed.sql / feed-integrity.sql.
// Pages are server-ranked and bounded (25 × 40);
// likes/follows are idempotent on the server, so a retried request cannot
// double count. The client only ever shows counts the server returned,
// except the ±1 optimistic change on the tapped card, which is rolled back
// when the server does not confirm.
// ═══════════════════════════════════════════════════════════════════

import Foundation

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
        guard (0..<FeedTimeline.maximumPages).contains(page) else { throw CommunityError.invalidResponse("Feed page out of range.") }
        if page > 0, cursor == nil || asOf == nil { throw CommunityError.stale }
        do {
            let request = FeedPageRequest(category: category.rawValue, page_cursor: page == 0 ? nil : cursor, as_of: page == 0 ? nil : asOf)
            let response = try await gateway.call("sdi_feed_page", params: request, as: FeedListResponse.self)
            guard let posts = response.posts, let more = response.has_more else { throw CommunityError.invalidResponse("The feed returned an incomplete response.") }
            guard !more || response.next_cursor != nil else { throw CommunityError.invalidResponse("The feed did not return the next page position.") }
            if page == 0 { try? cache.store(posts, account: account, key: category.rawValue) }
            return Page(posts: posts, hasMore: more, source: .server, asOf: response.as_of, cursor: response.next_cursor,
                        downloadRequiresPlan: response.download_requires_plan ?? true)
        } catch let error as CommunityError {
            if page == 0, case .transport = error, let cached = cache.entry(account: account, key: category.rawValue) {
                return Page(posts: cached.value, hasMore: false, source: .cache(updatedAt: cached.updatedAt))
            }
            throw error
        }
    }

    /// `like`/`follow`/`block`/`report`; true only when the server says confirmed.
    func mutate(_ request: FeedRequest) async throws -> Bool {
        guard request.action != "list" else { throw CommunityError.invalidResponse("Use page(_:page:account:asOf:cursor:) for listing.") }
        let response = try await gateway.call("sdi_feed_action", params: request, as: FeedListResponse.self)
        return response.status == "confirmed"
    }
    func like(_ post: UUID, enabled: Bool) async throws -> Bool { try await mutate(FeedRequest(action: "like", post_id: post, enabled: enabled)) }
    func follow(_ creator: UUID, enabled: Bool) async throws -> Bool { try await mutate(FeedRequest(action: "follow", target: creator, enabled: enabled)) }
    func block(_ creator: UUID) async throws -> Bool { try await mutate(FeedRequest(action: "block", target: creator, enabled: true)) }
    func report(_ post: UUID, reason: FeedReportReason) async throws -> Bool { try await mutate(FeedRequest(action: "report", post_id: post, reason: reason.rawValue)) }

    /// Creator-permitted file export: the rendition is fetched over plain HTTPS
    /// only when the post allows export, only on an explicit tap, and only up
    /// to the bounded size. Returns the temporary file to hand to the share sheet.
    func exportFile(for post: FeedPost, download: (URL) async throws -> (URL, Int64)) async throws -> URL {
        switch FeedExportPolicy.state(post) {
        case .notPermitted: throw CommunityError.server(message: "The creator has not permitted export of this video.", code: nil)
        case .needsPaidPlan: throw CommunityError.server(message: "Saving video files needs a paid plan. Sharing the link is still available.", code: nil)
        case .allowed: break
        }
        guard let url = post.safeURL else { throw CommunityError.invalidResponse("Video address is unavailable.") }
        let (file, length) = try await download(url)
        guard FeedExportPolicy.acceptsLength(length) else {
            try? FileManager.default.removeItem(at: file)
            throw CommunityError.invalidResponse("This video is larger than the export limit.")
        }
        return file
    }
}
