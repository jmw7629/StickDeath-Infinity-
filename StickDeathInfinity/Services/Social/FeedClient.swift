// ═══════════════════════════════════════════════════════════════════
// FeedClient — social video wall over `sdi_feed_action` (video-feed.sql,
// feed-integrity.sql). Pages are server-ranked and bounded (25 × 40);
// likes/follows are idempotent on the server, so a retried request cannot
// double count. The client only ever shows counts the server returned,
// except the ±1 optimistic change on the tapped card, which is rolled back
// when the server does not confirm.
// ═══════════════════════════════════════════════════════════════════

import Foundation

@MainActor
final class FeedClient {
    enum PageSource: Equatable { case server, cache(updatedAt: Date) }
    struct Page: Equatable { let posts: [FeedPost]; let hasMore: Bool; let source: PageSource }

    let gateway: CommunityGateway
    let cache: CommunityOfflineCache<[FeedPost]>
    init(gateway: CommunityGateway, cache: CommunityOfflineCache<[FeedPost]> = .init(name: "feed")) {
        self.gateway = gateway; self.cache = cache
    }

    /// One server page. Page 0 of each category is cached per account for the
    /// offline label; later pages are never served from cache.
    func page(_ category: FeedCategory, page: Int, account: String) async throws -> Page {
        guard (0..<FeedTimeline.maximumPages).contains(page) else { throw CommunityError.invalidResponse("Feed page out of range.") }
        do {
            let response = try await gateway.call("sdi_feed_action", params: FeedRequest(action: "list", category: category.rawValue, page: page), as: FeedListResponse.self)
            guard let posts = response.posts, let more = response.has_more else { throw CommunityError.invalidResponse("The feed returned an incomplete response.") }
            if page == 0 { try? cache.store(posts, account: account, key: category.rawValue) }
            return Page(posts: posts, hasMore: more, source: .server)
        } catch let error as CommunityError {
            if page == 0, case .transport = error, let cached = cache.entry(account: account, key: category.rawValue) {
                return Page(posts: cached.value, hasMore: false, source: .cache(updatedAt: cached.updatedAt))
            }
            throw error
        }
    }

    /// `like`/`follow`/`block`/`report`; true only when the server says confirmed.
    func mutate(_ request: FeedRequest) async throws -> Bool {
        guard request.action != "list" else { throw CommunityError.invalidResponse("Use page(_:page:account:) for listing.") }
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
        guard FeedExportPolicy.canExport(post), let url = post.safeURL else { throw CommunityError.server(message: "The creator has not permitted export of this video.", code: nil) }
        let (file, length) = try await download(url)
        guard FeedExportPolicy.acceptsLength(length) else {
            try? FileManager.default.removeItem(at: file)
            throw CommunityError.invalidResponse("This video is larger than the export limit.")
        }
        return file
    }
}
