// ═══════════════════════════════════════════════════════════════════
// CommunityModels — request/response contracts and pure logic for the
// community clients (feed, Rooms, War Room, challenges, Calendar, profile
// records, achievements and the admin panels).
//
// Every type here is Foundation-only so the Tests/Community* suites compile
// and run on a Linux host without SwiftUI, Combine or the Supabase SDK. The
// wire shapes follow the unapplied SQL candidates in backend/sql; nothing in
// this file invents counts, matches, viewers, badges or balances. Values are
// shown only when a server reply supplies them.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Shared state and errors

/// Truthful presentation states shared by every community screen.
enum CommunityServiceState<Value: Equatable>: Equatable {
    case notConfigured(String)
    case signedOut
    case loading
    case empty(String)
    case failed(String)
    case loaded(Value)

    var value: Value? { if case .loaded(let value) = self { return value }; return nil }
    var isLoading: Bool { if case .loading = self { return true }; return false }
}

enum CommunityError: LocalizedError, Equatable {
    /// AppConfig has no validated Supabase configuration; no request was made.
    case notConfigured
    /// No current session; the server would refuse and the UI shows sign-in.
    case signedOut
    /// A transport failure (network, cancellation surfaced as an error, HTTP status).
    case transport(String)
    /// The server returned `{"error": message, "code"?: code}`.
    case server(message: String, code: String?)
    /// The body decoded but did not satisfy the contract (missing fields, bounds).
    case invalidResponse(String)
    /// The reply arrived for an earlier account, screen or request generation.
    case stale

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "This service is not configured in this build. Nothing was sent."
        case .signedOut: return "Sign in with a full account to continue."
        case .transport(let detail): return detail
        case .server(let message, _): return message
        case .invalidResponse(let detail): return detail
        case .stale: return "The screen changed before the reply arrived. Refresh to continue."
        }
    }
    /// Server gate codes from backend/sql/admin-hardening.sql `admin_gate`.
    var isStepUpRequired: Bool { if case .server(_, let code) = self { return code == "step_up_required" }; return false }
    var isRateLimited: Bool { if case .server(_, let code) = self { return code == "rate_limited" }; return false }
}

/// Every RPC body carries an optional `error`; many carry `status`/`code`.
protocol CommunityResponse: Decodable {
    var error: String? { get }
}
extension CommunityResponse {
    var code: String? { nil }
}

// MARK: - JSON value (jsonb payloads)

/// Bounded JSON value for `jsonb` parameters such as room command payloads and
/// agent configuration. Objects keep key order undefined, as Postgres does.
indirect enum CommunityJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CommunityJSONValue])
    case object([String: CommunityJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([CommunityJSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: CommunityJSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
    var objectValue: [String: CommunityJSONValue]? { if case .object(let value) = self { return value }; return nil }
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
}

// MARK: - Dates and coding

/// Deterministic ISO 8601 parsing for PostgREST `timestamptz` JSON
/// (`2026-10-12T20:33:11.123456+00:00`), independent of platform formatter
/// quirks. Accepts `Z`, `±HH`, `±HHMM` and `±HH:MM` offsets and any number of
/// fractional digits (rounded to microseconds).
enum CommunityDates {
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let scalars = Array(text.utf8)
        func digits(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= scalars.count else { return nil }
            var value = 0
            for index in range {
                let byte = scalars[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard scalars.count >= 19,
              let year = digits(0..<4), scalars[4] == 45, let month = digits(5..<7), scalars[7] == 45,
              let day = digits(8..<10), scalars[10] == 84 || scalars[10] == 32,
              let hour = digits(11..<13), scalars[13] == 58, let minute = digits(14..<16), scalars[16] == 58,
              let second = digits(17..<19) else { return nil }
        var cursor = 19
        var fraction = 0.0
        if cursor < scalars.count, scalars[cursor] == 46 {
            cursor += 1
            var scale = 0.1
            var sawDigit = false
            while cursor < scalars.count, scalars[cursor] >= 48, scalars[cursor] <= 57 {
                fraction += Double(scalars[cursor] - 48) * scale
                scale /= 10; cursor += 1; sawDigit = true
            }
            guard sawDigit else { return nil }
        }
        var offsetSeconds = 0
        if cursor < scalars.count {
            let sign = scalars[cursor]
            if sign == 90 { // Z
                cursor += 1
            } else if sign == 43 || sign == 45 {
                cursor += 1
                guard let offsetHour = digits(cursor..<cursor + 2) else { return nil }
                cursor += 2
                var offsetMinute = 0
                if cursor < scalars.count, scalars[cursor] == 58 { cursor += 1 }
                if cursor < scalars.count, let value = digits(cursor..<cursor + 2) { offsetMinute = value; cursor += 2 }
                guard offsetHour <= 23, offsetMinute <= 59 else { return nil }
                offsetSeconds = (offsetHour * 3600 + offsetMinute * 60) * (sign == 45 ? -1 : 1)
            } else { return nil }
        }
        guard cursor == scalars.count, (1...12).contains(month), (1...31).contains(day),
              hour <= 23, minute <= 59, second <= 60 else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let base = calendar.date(from: components) else { return nil }
        let micro = (fraction * 1_000_000).rounded() / 1_000_000
        return base.addingTimeInterval(micro - Double(offsetSeconds))
    }

    static func string(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let millis = (parts.nanosecond ?? 0) / 1_000_000
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, millis)
    }

    /// RFC 7231 HTTP `Date` header (`Sun, 06 Nov 1994 08:49:37 GMT`).
    static func parseHTTPDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }
}

enum CommunityCoding {
    /// Bodies above this size are refused before decoding (lists are server-bounded).
    static let maximumBodyBytes = 4 * 1024 * 1024

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = CommunityDates.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized timestamp")
            }
            return date
        }
        return decoder
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CommunityDates.string(date))
        }
        return encoder
    }
    /// Decode a reply and surface a server `error` as `CommunityError.server`.
    static func decode<R: CommunityResponse>(_ type: R.Type, from data: Data) throws -> R {
        guard data.count <= maximumBodyBytes else { throw CommunityError.invalidResponse("The reply was larger than this screen accepts.") }
        let value: R
        do { value = try decoder().decode(R.self, from: data) }
        catch { throw CommunityError.invalidResponse("The reply did not match the expected contract.") }
        if let problem = value.error, !problem.isEmpty {
            throw CommunityError.server(message: problem, code: (value as? CommunityCodedResponse)?.code)
        }
        return value
    }
    static func decodeKeepingServerError<R: CommunityResponse>(_ type: R.Type, from data: Data) throws -> R {
        guard data.count <= maximumBodyBytes else { throw CommunityError.invalidResponse("The reply was larger than this screen accepts.") }
        do { return try decoder().decode(R.self, from: data) }
        catch { throw CommunityError.invalidResponse("The reply did not match the expected contract.") }
    }
    static func decodeRows<R: Decodable>(_ type: R.Type, from data: Data) throws -> [R] {
        guard data.count <= maximumBodyBytes else { throw CommunityError.invalidResponse("The reply was larger than this screen accepts.") }
        do { return try decoder().decode([R].self, from: data) }
        catch { throw CommunityError.invalidResponse("The rows did not match the expected contract.") }
    }
}

/// Replies that can carry an `admin_gate` code alongside `error`.
protocol CommunityCodedResponse: CommunityResponse {
    var code: String? { get }
}

/// Strict HTTPS media address: no credentials, no non-HTTPS schemes.
enum CommunityMediaURL {
    static func checked(_ raw: String?) -> URL? {
        guard let raw, let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
}

// MARK: - Server clock

/// Estimates (server − device) clock offset from HTTP `Date` headers using the
/// lowest round-trip sample. Header granularity is one second, so uncertainty
/// is at least that plus half the round trip. Used by Watch Together and the
/// challenge phase display so members on skewed clocks agree within seconds.
struct ServerClockEstimator: Equatable {
    struct Sample: Equatable { let offset: TimeInterval; let roundTrip: TimeInterval; let recordedAt: Date }
    private(set) var best: Sample?
    private(set) var samples = 0
    static let headerGranularity: TimeInterval = 1
    static let staleAfter: TimeInterval = 10 * 60

    mutating func record(sentAt: Date, receivedAt: Date, serverDate: Date?) {
        guard let serverDate else { return }
        let roundTrip = receivedAt.timeIntervalSince(sentAt)
        guard roundTrip.isFinite, roundTrip >= 0, roundTrip <= 30 else { return }
        // The server stamped the reply roughly at the midpoint of the exchange.
        let midpoint = sentAt.addingTimeInterval(roundTrip / 2)
        let offset = serverDate.timeIntervalSince(midpoint)
        guard offset.isFinite, abs(offset) <= 365 * 24 * 3600 else { return }
        samples += 1
        if let current = best, current.roundTrip <= roundTrip, receivedAt.timeIntervalSince(current.recordedAt) < Self.staleAfter { return }
        best = Sample(offset: offset, roundTrip: roundTrip, recordedAt: receivedAt)
    }
    var offset: TimeInterval { best?.offset ?? 0 }
    var uncertainty: TimeInterval { (best?.roundTrip ?? 0) / 2 + Self.headerGranularity }
    func isStale(at now: Date) -> Bool { best.map { now.timeIntervalSince($0.recordedAt) > Self.staleAfter } ?? true }
    func serverNow(deviceNow: Date) -> Date { deviceNow.addingTimeInterval(offset) }
    /// Shared playback position: server-stamped `updatedAt` plus elapsed server time.
    func sharedPosition(position: Double, playing: Bool, updatedAt: Date, duration: Double, deviceNow: Date) -> Double {
        guard position.isFinite, duration.isFinite, duration > 0 else { return 0 }
        let elapsed = playing ? max(0, serverNow(deviceNow: deviceNow).timeIntervalSince(updatedAt)) : 0
        return min(duration, max(0, position + elapsed))
    }
}

// MARK: - Protected offline cache

/// Last successful reply per account and key in Application Support (never
/// Documents), protected until first unlock on iOS. The account key is a
/// digest, never the identifier. Cached values are shown only with an
/// "Offline · last updated" label and never replace a successful fetch.
struct CommunityOfflineCache<Value: Codable> {
    struct Entry: Codable { let updatedAt: Date; let value: Value }
    private struct Store: Codable { var version: Int; var entries: [String: Entry] }
    let directory: URL
    let name: String
    let maximumEntries: Int
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StickDeathInfinity/community-cache", isDirectory: true)
    }
    init(name: String, directory: URL? = nil, maximumEntries: Int = 24) {
        self.name = name; self.directory = directory ?? Self.defaultDirectory; self.maximumEntries = maximumEntries
    }
    static func accountDigest(_ account: String) -> String {
        // FNV-1a 64-bit over the lower-cased identifier; collision risk is
        // irrelevant because entries are only ever read back by the same account.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in account.lowercased().utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }
    private func file(for account: String) -> URL {
        directory.appendingPathComponent("\(name)-\(Self.accountDigest(account)).json")
    }
    private func load(_ account: String) -> Store {
        guard let data = try? Data(contentsOf: file(for: account)), data.count <= 8 * 1024 * 1024,
              let store = try? CommunityCoding.decoder().decode(Store.self, from: data), store.version == 1 else {
            return Store(version: 1, entries: [:])
        }
        return store
    }
    func entry(account: String, key: String) -> Entry? { load(account).entries[key] }
    func store(_ value: Value, account: String, key: String, now: Date = Date()) throws {
        var store = load(account)
        store.entries[key] = Entry(updatedAt: now, value: value)
        while store.entries.count > maximumEntries,
              let oldest = store.entries.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            store.entries.removeValue(forKey: oldest)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: directory.path)
        #endif
        try CommunityCoding.encoder().encode(store).write(to: file(for: account), options: options)
    }
    func removeAll(account: String) { try? FileManager.default.removeItem(at: file(for: account)) }
}

// MARK: - Feed (backend/sql/video-feed.sql, feed-integrity.sql, feed-publication.sql)

enum FeedCategory: String, CaseIterable, Codable {
    case trending, recent, following, featured
    var title: String { rawValue.capitalized }
    var explanation: String {
        switch self {
        case .trending: return "Ranked by likes in the last seven days, then newest."
        case .recent: return "Newest approved videos first."
        case .following: return "Approved videos from creators you follow."
        case .featured: return "Videos an administrator placed in Featured, newest first."
        }
    }
}

struct FeedRequest: Encodable, Equatable {
    let action: String
    var post_id: UUID? = nil
    var target: UUID? = nil
    var enabled = true
    var category = FeedCategory.recent.rawValue
    var page = 0
    var reason: String? = nil
    /// Snapshot instant returned by page 0; sent back on later pages so posts
    /// published meanwhile shift nothing until the member refreshes (#217/#220).
    var as_of: String? = nil
}

struct FeedPost: Codable, Identifiable, Equatable {
    let id: UUID
    let creator: UUID
    let creator_name: String
    let caption: String
    let published_at: Date
    let allow_export: Bool
    let title: String
    let url: String
    var likes: Int
    var liked: Bool
    var following: Bool
    var safeURL: URL? { CommunityMediaURL.checked(url) }
}

struct FeedListResponse: CommunityResponse {
    let error: String?
    let status: String?
    let posts: [FeedPost]?
    let has_more: Bool?
    /// Kept as the server's own text so it round-trips exactly.
    let as_of: String?
}

enum FeedReportReason: String, CaseIterable { case rights, abuse, unsafe, spam
    var title: String { rawValue.capitalized }
}

/// Client-side page assembly over the server's offset ranking: identity
/// de-duplication, the 40-page cap and optimistic reactions with rollback.
/// Nothing here changes a count the server did not report.
struct FeedTimeline: Equatable {
    static let pageSize = 25
    static let maximumPages = 40
    private(set) var posts: [FeedPost] = []
    private(set) var nextPage = 0
    private(set) var hasMore = true
    private(set) var inFlight: Set<UUID> = []
    /// Server snapshot instant from page 0, sent with every later page of this timeline.
    private(set) var asOf: String?

    mutating func reset() { posts = []; nextPage = 0; hasMore = true; inFlight = []; asOf = nil }

    /// Merge a page; existing cards keep their position with refreshed values.
    /// The first page's snapshot is kept; a later page carrying a different
    /// snapshot belongs to another listing and is refused as stale.
    mutating func merge(page: Int, posts incoming: [FeedPost], hasMore more: Bool, asOf snapshot: String? = nil) throws {
        guard page == nextPage else { throw CommunityError.stale }
        if page == 0 { asOf = snapshot }
        else if let snapshot, let asOf, snapshot != asOf { throw CommunityError.stale }
        guard incoming.count <= Self.pageSize else { throw CommunityError.invalidResponse("The feed page exceeded the server bound.") }
        for post in incoming {
            guard post.likes >= 0 else { throw CommunityError.invalidResponse("The feed reported a negative count.") }
            if let index = posts.firstIndex(where: { $0.id == post.id }) { posts[index] = post } else { posts.append(post) }
        }
        nextPage = page + 1
        hasMore = more && nextPage < Self.maximumPages
    }
    var canLoadMore: Bool { hasMore && nextPage < Self.maximumPages }

    struct Snapshot: Equatable { let posts: [FeedPost] }

    /// Begin an optimistic like: the only client-side count change allowed is
    /// ±1 on the tapped card, reverted if the server does not confirm.
    mutating func beginLike(_ postID: UUID, enabled: Bool) -> Snapshot? {
        guard !inFlight.contains(postID), let index = posts.firstIndex(where: { $0.id == postID }),
              posts[index].liked != enabled else { return nil }
        let snapshot = Snapshot(posts: posts)
        inFlight.insert(postID)
        posts[index].liked = enabled
        posts[index].likes = max(0, posts[index].likes + (enabled ? 1 : -1))
        return snapshot
    }
    mutating func beginFollow(_ creator: UUID, enabled: Bool) -> Snapshot? {
        guard !inFlight.contains(creator), posts.contains(where: { $0.creator == creator && $0.following != enabled }) else { return nil }
        let snapshot = Snapshot(posts: posts)
        inFlight.insert(creator)
        for index in posts.indices where posts[index].creator == creator { posts[index].following = enabled }
        return snapshot
    }
    mutating func finish(_ key: UUID, confirmed: Bool, snapshot: Snapshot?) {
        inFlight.remove(key)
        if !confirmed, let snapshot { posts = snapshot.posts }
    }
    /// A blocked creator disappears immediately; the server also filters them.
    mutating func removeCreator(_ creator: UUID) { posts.removeAll { $0.creator == creator } }
}

enum FeedExportPolicy {
    /// Maximum bytes the client will download for a creator-permitted export.
    static let maximumDownloadBytes: Int64 = 200 * 1024 * 1024
    static func canExport(_ post: FeedPost) -> Bool { post.allow_export && post.safeURL != nil }
    static func acceptsLength(_ expected: Int64) -> Bool { expected < 0 || expected <= maximumDownloadBytes }
}

// MARK: - Rooms (collaboration-watch.sql, room-invitations.sql, rooms-v2.sql)

enum RoomPermission: String, Codable, CaseIterable { case view, edit }
enum RoomRole: String, Codable, CaseIterable { case editor, viewer }

/// `public.sdi_rooms` row. v2 columns are optional so the browser still works
/// before rooms-v2.sql is applied; the UI then shows "project not shared".
struct RoomSummary: Decodable, Identifiable, Equatable {
    let id: UUID
    let owner_id: UUID
    let title: String
    var closed: Bool? = nil
    var project_ref: String? = nil
    var project_title: String? = nil
    var permissions: [String]? = nil
    var project_revision: Int? = nil
    var command_revision: Int? = nil
    var sharesEdit: Bool { permissions?.contains(RoomPermission.edit.rawValue) ?? false }
}

struct RoomMember: Decodable, Identifiable, Equatable {
    var id: UUID { user_id }
    let user_id: UUID
    let owner_approved: Bool
    let member_accepted: Bool
    let revoked: Bool
    var role: String? = nil
    var request_expires_at: Date? = nil
    var statusText: String {
        if revoked { return "Removed" }
        if owner_approved && member_accepted { return "Accepted" }
        if member_accepted { return "Awaiting owner approval" }
        return "Pending"
    }
    var isActive: Bool { owner_approved && member_accepted && !revoked }
}

/// `sdi_room_action` (room-invitations.sql): create, preview, request, invite,
/// revoke_invites, approve, remove, block, leave, close.
struct RoomActionRequest: Encodable, Equatable {
    let action: String
    var room: UUID? = nil
    var subject: UUID? = nil
    var code: String? = nil
    var title: String? = nil
    var consent = false
}
struct RoomActionResponse: CommunityResponse {
    let error: String?
    let status: String?
    let room_id: UUID?
    let title: String?
    let code: String?
}

/// `sdi_room_manage` (rooms-v2.sql): my_requests, summary, report, set_project, set_role.
struct RoomManageRequest: Encodable, Equatable {
    let action: String
    var room: UUID? = nil
    var subject: UUID? = nil
    var role: String? = nil
    var project_ref: String? = nil
    var project_title: String? = nil
    var permissions: [String]? = nil
    var revision: Int? = nil
    var reason: String? = nil
    var detail: String? = nil
}
struct RoomPendingRequest: Decodable, Identifiable, Equatable {
    var id: UUID { room_id }
    let room_id: UUID
    let title: String
    let owner_id: UUID
    let request_expires_at: Date
}
struct RoomManageResponse: CommunityResponse {
    let error: String?
    let status: String?
    let requests: [RoomPendingRequest]?
    let room_id: UUID?
    let title: String?
    let owner_id: UUID?
    let project_ref: String?
    let project_title: String?
    let permissions: [String]?
    let project_revision: Int?
    let command_revision: Int?
    let my_role: String?
    let can_edit: Bool?
    let members: Int?
}

/// Owner-chosen project share: a local project's identifier and title only.
/// Project contents never leave the device through this request.
struct RoomProjectShare: Equatable {
    let projectID: UUID
    let title: String
    let permissions: Set<RoomPermission>
    var reference: String { "device-project:" + projectID.uuidString.lowercased() }
    static func validate(title: String, permissions: Set<RoomPermission>) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 100 { return "The shared project needs a title of 1–100 characters." }
        if !permissions.contains(.view) { return "Shared projects always include view permission." }
        return nil
    }
    func manageRequest(room: UUID, revision: Int) -> RoomManageRequest {
        RoomManageRequest(action: "set_project", room: room, project_ref: reference,
                          project_title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)),
                          permissions: RoomPermission.allCases.filter { permissions.contains($0) }.map(\.rawValue), revision: revision)
    }
    /// Recover the device project id from a room's reference, if it is ours.
    static func projectID(from reference: String?) -> UUID? {
        guard let reference, reference.hasPrefix("device-project:") else { return nil }
        return UUID(uuidString: String(reference.dropFirst("device-project:".count)))
    }
}

/// Invitation handling rules from room-invitations.sql.
enum RoomInvitationPolicy {
    static let codeLength = 64
    static let lifetime: TimeInterval = 24 * 3600
    static let maximumRedemptions = 20
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    static func isWellFormed(_ raw: String) -> Bool {
        let code = normalize(raw)
        return code.count == codeLength && code.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// Forwardable text: the code is a room admission request credential, not
    /// an account credential, and it never grants access on its own.
    static func shareText(code: String, roomTitle: String) -> String {
        "StickDeath Infinity room invitation for \"\(roomTitle)\". Open Rooms, choose Review invitation and paste: \(code) — the owner still approves every request. Expires after 24 hours or 20 uses."
    }
}

/// Server bounds from rooms-v2.sql / room-invitations.sql shown in the quota panel.
struct RoomQuotaPolicy: Equatable {
    static let commandPayloadBytes = 65_536
    static let commandsPerMinute = 300
    static let roomRevisionLimit = 100_000
    static let membersPerRoom = 50
    static let openRoomsPerOwner = 20
    static let requestsPerMinute = 30
    static let dailyReports = 10
    static func remainingRevisions(head: Int) -> Int { max(0, roomRevisionLimit - max(0, head)) }
    static func payloadFits(_ payload: Data) -> Bool { payload.count <= commandPayloadBytes }
}

/// `sdi_room_command` (rooms-v2.sql): since / append.
struct RoomCommandRequest: Encodable, Equatable {
    let action: String
    var room: UUID? = nil
    var op_id: UUID? = nil
    var base_revision: Int? = nil
    var kind: String? = nil
    var payload: CommunityJSONValue? = nil
    var after: Int = 0
    var page_size: Int = 200
}
struct RoomCommandRecord: Decodable, Identifiable, Equatable {
    var id: UUID { op_id }
    let revision: Int
    let op_id: UUID
    let author: UUID
    let base_revision: Int
    let kind: String
    let payload: CommunityJSONValue
    let created_at: Date
}
struct RoomCommandResponse: CommunityResponse {
    let error: String?
    let status: String?
    let revision: Int?
    let head: Int?
    let commands: [RoomCommandRecord]?
    let missing: [RoomCommandRecord]?
}

struct RoomReportDraft: Equatable {
    var reason: FeedReportReason = .abuse
    var detail = ""
    var validation: String? {
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 2000 { return "Keep the description under 2000 characters." }
        return nil
    }
    func request(room: UUID) -> RoomManageRequest {
        RoomManageRequest(action: "report", room: room, reason: reason.rawValue, detail: detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - War Room (war-room.sql, war-moderation.sql, war-appeals.sql, war-finalization.sql)

struct WarRequest: Encodable, Equatable {
    let action: String
    var match: UUID? = nil
    var media: UUID? = nil
    var opponent: UUID? = nil
    var choice: String? = nil
}
struct WarMatch: Decodable, Identifiable, Equatable {
    let id: UUID
    let creator: UUID
    let opponent: UUID
    let status: String
    let ends_at: Date?
    let left_title: String
    let left_url: String
    let right_title: String?
    let right_url: String?
    let left_votes: Int
    let right_votes: Int
    let my_vote: String?
    let outcome: String?
}
struct WarListResponse: CommunityResponse {
    let error: String?
    let status: String?
    let matches: [WarMatch]?
}
struct WarReportRequest: Encodable, Equatable { let match: UUID; let reason: String }
struct WarNoticeRequest: Encodable, Equatable { let action: String; var decision: UUID? = nil; var explanation = "" }
struct WarNotice: Decodable, Identifiable, Equatable {
    let id: UUID; let match_id: UUID; let message: String; let created_at: Date
    let appeal_state: String?; let appeal_deadline: Date
}
struct WarNoticesResponse: CommunityResponse {
    let error: String?; let status: String?; let notices: [WarNotice]?
}
/// Own approved renditions (`public.sdi_watch_media` filtered by owner).
struct ApprovedMedia: Decodable, Identifiable, Equatable {
    let id: UUID
    let title: String
    var url: String? = nil
    var duration: Double? = nil
    var expires_at: Date? = nil
    var approved: Bool? = nil
}

enum WarVoteChoice: String { case left, right }

/// What a matchup card may show for the signed-in account at a given time.
/// Finalisation (#225) is displayed only from server fields: `completed` plus
/// an `outcome`. An ended but not yet finalised match says so instead of
/// computing a winner from the running tallies.
struct WarMatchPresentation: Equatable {
    enum Phase: Equatable { case proposal, awaitingOpponent, voting, awaitingFinalisation, final, unavailable }
    let phase: Phase
    let heading: String
    let resultText: String?
    let canVote: Bool
    let canAccept: Bool
    let canWithdraw: Bool
    let showsTallies: Bool
    let isParticipant: Bool

    init(match: WarMatch, viewer: UUID?, now: Date) {
        let participant = viewer.map { [match.creator, match.opponent].contains($0) } ?? false
        let ended = match.ends_at.map { $0 <= now } ?? false
        isParticipant = participant
        switch match.status {
        case "pending":
            let mine = viewer == match.opponent
            phase = mine ? .proposal : .awaitingOpponent
            heading = mine ? "You were invited to a matchup" : "Awaiting opponent consent"
            resultText = nil; canVote = false; canAccept = mine; canWithdraw = participant; showsTallies = false
        case "active" where !ended:
            phase = .voting; heading = participant ? "Voting is open on your matchup" : "Choose your favorite"
            resultText = nil; canVote = viewer != nil && !participant; canAccept = false; canWithdraw = participant; showsTallies = true
        case "active":
            phase = .awaitingFinalisation; heading = "Voting closed — awaiting the server's final result"
            resultText = nil; canVote = false; canAccept = false; canWithdraw = false; showsTallies = true
        case "completed":
            phase = .final; heading = "Final result"
            switch match.outcome {
            case "tie": resultText = "Tie — no winner or loser"
            case "left": resultText = "Winner: \(match.left_title)"
            case "right": resultText = "Winner: \(match.right_title ?? "Second video")"
            default: resultText = "Result not yet recorded by the server"
            }
            canVote = false; canAccept = false; canWithdraw = false; showsTallies = true
        default:
            phase = .unavailable; heading = "Matchup unavailable"
            resultText = nil; canVote = false; canAccept = false; canWithdraw = false; showsTallies = false
        }
    }
}

/// One mutable vote per viewer. A tap is pending until the server confirms;
/// a rejected request leaves the server's last known vote in place.
struct WarVoteMachine: Equatable {
    enum State: Equatable { case none, pending(WarVoteChoice), confirmed(WarVoteChoice), failed(String, previous: WarVoteChoice?) }
    private(set) var state: State
    init(serverVote: String?) {
        if let raw = serverVote, let choice = WarVoteChoice(rawValue: raw) { state = .confirmed(choice) } else { state = .none }
    }
    var serverChoice: WarVoteChoice? {
        switch state {
        case .confirmed(let choice): return choice
        case .failed(_, let previous): return previous
        case .pending, .none: return nil
        }
    }
    var isPending: Bool { if case .pending = state { return true }; return false }
    mutating func tap(_ choice: WarVoteChoice) -> Bool {
        guard !isPending else { return false }
        state = .pending(choice); return true
    }
    mutating func confirm(_ choice: WarVoteChoice) { state = .confirmed(choice) }
    mutating func fail(_ message: String, previous: WarVoteChoice?) { state = .failed(message, previous: previous) }
    /// Selection shown in the UI: a pending tap is marked distinctly from a
    /// confirmed vote so no tally change is implied before the server replies.
    func isSelected(_ choice: WarVoteChoice) -> Bool { serverChoice == choice }
    func isPendingChoice(_ choice: WarVoteChoice) -> Bool { if case .pending(let pending) = state { return pending == choice }; return false }
}

enum WarPlaybackMode: String, CaseIterable {
    case sideBySide, sequential
    var title: String { self == .sideBySide ? "Side by side" : "One at a time" }
    /// Two players fit beside each other from about 600 pt of width.
    static func preferred(forWidth width: Double) -> WarPlaybackMode { width >= 600 ? .sideBySide : .sequential }
}

// MARK: - Challenges and Calendar (challenges.sql)

enum ChallengePhase: String, CaseIterable, Decodable {
    case draft, upcoming, active, voting, completed, cancelled
    var title: String { rawValue.capitalized }
    static let listed: [ChallengePhase] = [.active, .upcoming, .voting, .completed]
}

struct ChallengeActionRequest: Encodable, Equatable {
    let action: String
    var challenge: UUID? = nil
    var media: UUID? = nil
    var entry: UUID? = nil
    var title: String? = nil
    var brief: String? = nil
    var reward: String? = nil
    var starts_at: Date? = nil
    var closes_at: Date? = nil
    var ends_at: Date? = nil
    var revision: Int? = nil
    var reason: String? = nil
}

struct ChallengeSummary: Decodable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let brief: String
    let reward_text: String
    let starts_at: Date?
    let submissions_close_at: Date?
    let voting_ends_at: Date?
    let revision: Int
    let phase: String
    let entry_count: Int
    let my_entry: Bool
    let outcome: String?
    let winner_entry: UUID?

    /// Phase from server time: the list reply's `server_time` anchors the
    /// clock, so a device with a wrong clock still shows the server's phase.
    func phase(at serverNow: Date) -> ChallengePhase {
        if phase == "cancelled" { return .cancelled }
        guard let starts = starts_at, let closes = submissions_close_at, let ends = voting_ends_at else { return .draft }
        if serverNow < starts { return .upcoming }
        if serverNow < closes { return .active }
        if serverNow < ends { return .voting }
        return .completed
    }
    var hasReward: Bool { !reward_text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var outcomeText: String? {
        switch outcome {
        case "winner": return "Winner decided by viewer favourite"
        case "tie": return "Tie — no winner recorded"
        case "no_entries": return "Completed without eligible entries"
        default: return nil
        }
    }
}
struct ChallengeListResponse: CommunityResponse {
    let error: String?
    let status: String?
    let challenges: [ChallengeSummary]?
    let server_time: Date?
}
struct ChallengeEntry: Decodable, Identifiable, Equatable {
    let id: UUID
    let creator: UUID
    let title: String
    let url: String
    let created_at: Date
    let votes: Int?
    let my_vote: Bool
    var safeURL: URL? { CommunityMediaURL.checked(url) }
}
struct ChallengeEntriesResponse: CommunityResponse {
    let error: String?
    let status: String?
    let phase: String?
    let entries: [ChallengeEntry]?
}
struct ChallengeMutationResponse: CommunityResponse {
    let error: String?
    let status: String?
    let challenge_id: UUID?
    let revision: Int?
}

/// Server time anchor: `server_time` from the list reply plus the time that
/// has passed on this device since the reply arrived.
struct ChallengeClock: Equatable {
    let serverTime: Date
    let receivedAt: Date
    func now(deviceNow: Date) -> Date { serverTime.addingTimeInterval(max(0, deviceNow.timeIntervalSince(receivedAt))) }
}

/// Moderator scheduling rules mirrored from `challenge_action` `schedule`.
struct ChallengeScheduleDraft: Equatable {
    var startsAt: Date
    var closesAt: Date
    var endsAt: Date
    func validation(now: Date) -> String? {
        if startsAt < now.addingTimeInterval(-5 * 60) { return "Start must be in the future." }
        if closesAt < startsAt.addingTimeInterval(3600) { return "Allow at least one hour of submissions." }
        if endsAt < closesAt.addingTimeInterval(3600) { return "Allow at least one hour of voting." }
        if endsAt > startsAt.addingTimeInterval(60 * 24 * 3600) { return "A challenge may last at most sixty days." }
        return nil
    }
}

/// `sdi_calendar_range` items: challenge milestones and the caller's own
/// War Room voting deadlines. Points in time, never duplicated storage.
struct CalendarItem: Codable, Identifiable, Equatable {
    var id: String { "\(kind):\(recordID.uuidString):\(milestone)" }
    let kind: String
    let recordID: UUID
    let title: String
    let occurs_at: Date
    let milestone: String
    let status: String
    enum CodingKeys: String, CodingKey { case kind, recordID = "id", title, occurs_at, milestone, status }
    var milestoneText: String {
        switch milestone {
        case "opens": return "Submissions open"
        case "submissions_close": return "Submissions close"
        case "voting_ends": return kind == "war_match" ? "Matchup voting ends" : "Voting ends"
        default: return milestone.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var kindText: String { kind == "war_match" ? "War Room" : "Challenge" }
}
struct CalendarRangeRequest: Encodable, Equatable {
    let range_start: Date
    let range_end: Date
    var page_size = 500
}
struct CalendarRangeResponse: CommunityResponse {
    let error: String?
    let items: [CalendarItem]?
    let range_start: Date?
    let range_end: Date?
    let truncated: Bool?
}

/// Visible-month range bounded to the server's 62-day maximum, and DST-safe
/// day placement: an item belongs to the civil day that contains its instant
/// in the user's current calendar, so a 01:30/03:30 transition day still
/// groups correctly and late-evening items do not slide into the next day.
struct CalendarMonthPlacement: Equatable {
    static let maximumRangeDays = 62
    let start: Date
    let end: Date
    let items: [CalendarItem]

    static func monthBounds(containing date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return nil }
        let limit = interval.start.addingTimeInterval(TimeInterval(maximumRangeDays) * 86_400)
        return (interval.start, min(interval.end, limit))
    }
    init(start: Date, end: Date, items: [CalendarItem]) {
        self.start = start; self.end = end
        var unique: [String: CalendarItem] = [:]
        for item in items where item.occurs_at >= start && item.occurs_at < end { unique[item.id] = item }
        self.items = unique.values.sorted { $0.occurs_at == $1.occurs_at ? $0.id < $1.id : $0.occurs_at < $1.occurs_at }
    }
    func items(on day: Date, calendar: Calendar) -> [CalendarItem] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return items.filter { $0.occurs_at >= interval.start && $0.occurs_at < interval.end }
    }
    func hasItems(on day: Date, calendar: Calendar) -> Bool { !items(on: day, calendar: calendar).isEmpty }
    static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

// MARK: - Profile records, achievements, portfolio (profile-records.sql, achievements.sql)

struct ProfileRecordsRequest: Encodable, Equatable {
    let action: String
    var subject: UUID? = nil
    var revision: Int? = nil
    var records: Bool? = nil
    var badges: Bool? = nil
}
struct ProfileEarnedBadge: Decodable, Identifiable, Equatable {
    let id: UUID; let title: String; let criterion_version: String; let earned_at: Date
}
struct ProfileRecordsResponse: CommunityResponse, Equatable {
    let error: String?
    let show_records: Bool?
    let show_badges: Bool?
    let revision: Int?
    let wins: Int?
    let losses: Int?
    let ties: Int?
    let badges: [ProfileEarnedBadge]?
    /// Own-account replies must carry every field; another account's reply
    /// legitimately omits hidden totals, and the UI then says "hidden".
    var isCompleteOwnRecord: Bool {
        show_records != nil && show_badges != nil && revision != nil && wins != nil && losses != nil && ties != nil && badges != nil
    }
}

struct AchievementItem: Decodable, Identifiable, Equatable {
    var id: String { badge_key }
    let badge_key: String
    let title: String
    let description: String
    let criterion_version: String
    let kind: String
    let threshold: Int
    let earned_at: Date?
    let badge_id: UUID?
    var isEarned: Bool { earned_at != nil && badge_id != nil }
    var category: String {
        switch kind {
        case "war_matches", "war_wins": return "War Room"
        case "challenge_wins": return "Challenges"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
struct AchievementCatalogResponse: CommunityResponse {
    let error: String?
    let achievements: [AchievementItem]?
}
struct AchievementGroup: Identifiable, Equatable {
    var id: String { category }
    let category: String
    let earned: [AchievementItem]
    let locked: [AchievementItem]
    static func group(_ items: [AchievementItem]) -> [AchievementGroup] {
        let categories = Array(Set(items.map(\.category))).sorted()
        return categories.map { category in
            let members = items.filter { $0.category == category }
            return AchievementGroup(category: category,
                                    earned: members.filter(\.isEarned).sorted { ($0.earned_at ?? .distantPast) > ($1.earned_at ?? .distantPast) },
                                    locked: members.filter { !$0.isEarned }.sorted { $0.threshold == $1.threshold ? $0.badge_key < $1.badge_key : $0.threshold < $1.threshold })
        }
    }
}

struct ExportConsentRequest: Encodable, Equatable { let review: UUID; let version: Int; let allowed: Bool }
struct ExportConsentResponse: CommunityResponse { let error: String?; let status: String?; let allow_export: Bool? }

/// Public handle rules applied before the profile save: 3–30 characters of
/// letters, digits and underscore, starting with a letter or digit, no reserved
/// names. The server still validates length; this prevents an unusable handle.
enum CreatorHandle {
    static let minimumLength = 3
    static let maximumLength = 30
    static let reserved: Set<String> = ["admin", "administrator", "owner", "moderator", "support", "system",
                                        "official", "stickdeath", "stickdeathinfinity", "sdi", "spatter", "root"]
    static func validate(_ raw: String) -> String? {
        let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if handle.count < minimumLength { return "Use at least \(minimumLength) characters." }
        if handle.count > maximumLength { return "Use at most \(maximumLength) characters." }
        let bytes = Array(handle.utf8)
        guard bytes.count == handle.count else { return "Use letters, digits and underscores only." }
        for (index, byte) in bytes.enumerated() {
            let letter = (65...90).contains(byte) || (97...122).contains(byte)
            let digit = (48...57).contains(byte)
            if index == 0, !(letter || digit) { return "Start with a letter or digit." }
            if !(letter || digit || byte == 95) { return "Use letters, digits and underscores only." }
        }
        if reserved.contains(handle.lowercased()) { return "That name is reserved." }
        return nil
    }
}

/// Avatar upload bounds: square JPEG, at most 512 px and 300 KB after
/// on-device downscaling, uploaded to the account's own storage path.
enum AvatarImagePolicy {
    static let maximumSide = 512
    static let maximumBytes = 300 * 1024
    static let bucket = "avatars"
    static func objectPath(account: String) -> String { account.lowercased() + "/avatar.jpg" }
    static func validate(byteCount: Int, width: Int, height: Int) -> String? {
        if width <= 0 || height <= 0 { return "The selected image could not be read." }
        if width > maximumSide || height > maximumSide { return "The avatar must be downscaled to \(maximumSide) px or less." }
        if byteCount > maximumBytes { return "The avatar must be \(maximumBytes / 1024) KB or less." }
        return nil
    }
    /// Target pixel size that preserves aspect ratio within the maximum side.
    static func targetSize(width: Double, height: Double) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let scale = min(1, Double(maximumSide) / max(width, height))
        return (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    }
}

// MARK: - Admin panels (admin-hardening.sql, agent-controls.sql, billing.sql, rooms-v2.sql, moderation.sql)

struct AdminGateResponse: CommunityCodedResponse {
    let error: String?
    let code: String?
    let status: String?
}

struct AdminAccessResponse: CommunityResponse {
    let error: String?
    let owner: Bool?
    let capabilities: [String]?
    /// Present once admin-hardening.sql is applied; nil means unknown.
    let step_up_current: Bool?
}

/// Recent re-authentication (#210): privileged actions need an MFA factor
/// verified within the server's 15-minute window. The client never sends a
/// flag; it asks the member to re-verify when the window is known to have
/// lapsed, and again whenever the server answers `step_up_required`.
struct AdminStepUpPolicy: Equatable {
    enum Decision: Equatable { case proceed, reverify(String) }
    static let serverWindow: TimeInterval = 15 * 60
    /// Re-verify a little early so an in-flight request is not refused.
    static let safetyMargin: TimeInterval = 30
    static let sensitiveActions: Set<String> = [
        "admin_permissions.save", "agent.emergency_stop", "agent.pause", "agent.resume", "agent.set_caps",
        "agent.set_permissions", "agent.publish_instructions", "agent.rollback_instructions",
        "finance.set_product", "finance.configure_annual", "users.suspend", "users.ban", "users.restore", "users.signout",
        "moderation.remove", "war.remove", "rooms.close", "appeal.accept", "appeal.reject",
    ]
    var stepUpCurrent: Bool?
    var verifiedAt: Date?

    func decision(for action: String, now: Date) -> Decision {
        guard Self.sensitiveActions.contains(action) else { return .proceed }
        if let verifiedAt, now.timeIntervalSince(verifiedAt) < Self.serverWindow - Self.safetyMargin { return .proceed }
        if stepUpCurrent == true, verifiedAt == nil { return .proceed }
        return .reverify("Re-verify your authenticator before this privileged action. Nothing was sent.")
    }
    mutating func recordVerification(at date: Date) { verifiedAt = date; stepUpCurrent = true }
    mutating func recordRefusal() { stepUpCurrent = false; verifiedAt = nil }
}

struct AdminWorkerHeartbeat: Decodable, Identifiable, Equatable {
    var id: String { worker }
    let worker: String
    let seen_at: Date
    let note: String
    let stale: Bool
}
struct AdminHealthResponse: CommunityCodedResponse {
    let error: String?
    let code: String?
    let queues: [String: Int?]?
    let oldest_pending: [String: Date?]?
    let workers: [AdminWorkerHeartbeat]?
    let emergency_stop: Bool?
    let admin_denials_24h: Int?
    let measured_at: Date?

    /// Fail closed: a health reply must carry a measurement time and queues,
    /// and worker names must be the server's bounded identifiers (no hosts).
    func validated() throws -> AdminHealthResponse {
        guard let measured_at, let queues, !queues.isEmpty else { throw CommunityError.invalidResponse("Health reply incomplete.") }
        for (_, value) in queues { if let value, value < 0 { throw CommunityError.invalidResponse("Negative queue count.") } }
        for worker in workers ?? [] {
            guard worker.worker.count <= 40, worker.note.count <= 200,
                  worker.worker.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else {
                throw CommunityError.invalidResponse("Health reply contained an unexpected worker identifier.")
            }
        }
        _ = measured_at
        return self
    }
    static let queueTitles: [(key: String, title: String)] = [
        ("publish_queued", "Publishing queued"), ("publish_leased", "Publishing in progress"),
        ("publish_attention", "Publishing needs attention"), ("removal_jobs_open", "Removal jobs open"),
        ("render_reviews_pending", "Renders awaiting review"), ("feed_reports_pending", "Feed reports pending"),
        ("war_reports_pending", "War Room reports pending"), ("war_appeals_pending", "War Room appeals pending"),
        ("moderation_appeals_pending", "Feed removal appeals pending"), ("room_reports_pending", "Room reports pending"),
        ("account_appeals_pending", "Account appeals pending"), ("support_open", "Support requests open"),
        ("deletion_requests_due", "Deletion requests due"), ("agent_runs_running", "Agent runs running"),
        ("provider_events_unprocessed", "Billing events unprocessed"),
    ]
}

struct AdminAgent: Decodable, Identifiable, Equatable {
    var id: String { key }
    let key: String
    let title: String
    let paused: Bool
    let permissions: [String]
    let daily_run_cap: Int
    let per_run_item_cap: Int
    let monthly_cost_cap_minor: Int
    let active_instruction_version: Int?
    let revision: Int
    let running: Int
    let last_finished: Date?
    let failures_7d: Int
    let cost_month_minor: Int
    let runs_today: Int
}
struct AdminAgentRun: Decodable, Identifiable, Equatable {
    let id: UUID; let agent_key: String; let instruction_version: Int?; let source_ref: String?
    let started_at: Date; let heartbeat_at: Date?; let finished_at: Date?; let state: String
    let items: Int; let cost_minor: Int; let error: String?
}
struct AdminAgentInstruction: Decodable, Identifiable, Equatable {
    var id: Int { version }
    let version: Int; let body: String; let author: UUID; let created_at: Date
}
struct AdminAgentsResponse: CommunityCodedResponse {
    let error: String?
    let code: String?
    let status: String?
    let revision: Int?
    let agents: [AdminAgent]?
    let emergency_stop: Bool?
    let emergency_reason: String?
    let runs: [AdminAgentRun]?
    let instructions: [AdminAgentInstruction]?
    let active: Int?
}
struct AdminAgentRequest: Encodable, Equatable {
    let action: String
    var agent: String? = nil
    var revision: Int? = nil
    var payload: CommunityJSONValue = .object([:])
    var reason = ""
    static func caps(agent: AdminAgent, daily: Int, perRun: Int, monthlyMinor: Int, reason: String) -> AdminAgentRequest? {
        guard (0...9999).contains(daily), (0...99999).contains(perRun), monthlyMinor >= 0 else { return nil }
        return AdminAgentRequest(action: "set_caps", agent: agent.key, revision: agent.revision,
                                 payload: .object(["daily_run_cap": .string(String(daily)), "per_run_item_cap": .string(String(perRun)),
                                                   "monthly_cost_cap_minor": .string(String(monthlyMinor))]), reason: reason)
    }
    static func emergencyStop(enabled: Bool, reason: String) -> AdminAgentRequest {
        AdminAgentRequest(action: "emergency_stop", payload: .object(["enabled": .string(enabled ? "true" : "false")]), reason: reason)
    }
}

struct AdminFinanceRequest: Encodable, Equatable {
    let action: String
    var page = 0
    var product: String? = nil
    var provider: String? = nil
    var tier: String? = nil
    var period: String? = nil
    var approved: Bool? = nil
    var reason = ""
}
struct AdminBillingProduct: Decodable, Identifiable, Equatable {
    var id: String { product_id }
    let product_id: String; let provider: String; let tier: String; let period: String
    let approved: Bool; let owner_configured_at: Date?
}
struct AdminSubscription: Decodable, Identifiable, Equatable {
    let id: UUID; let user_id: UUID; let provider: String; let product_id: String; let status: String
    let paid_through: Date?; let cancel_at_period_end: Bool; let last_event_at: Date?
}
struct AdminLedgerEntry: Decodable, Identifiable, Equatable {
    let id: UUID; let provider: String; let provider_ref: String?; let kind: String
    let amount_minor: Int; let currency: String; let occurred_at: Date; let note: String?
}
struct AdminProviderEvent: Decodable, Identifiable, Equatable {
    let id: UUID; let provider: String; let event_type: String; let occurred_at: Date?
    let received_at: Date; let processed_at: Date?; let outcome: String?; let note: String?
}
struct AdminFinanceTotal: Decodable, Identifiable, Equatable {
    var id: String { "\(provider):\(currency):\(kind)" }
    let provider: String; let currency: String; let kind: String; let amount_minor: Int; let entries: Int
    /// Provider-reported sums in minor units; never a balance.
    var amountText: String { String(format: "%@ %.2f", currency.uppercased(), Double(amount_minor) / 100) }
}
struct AdminFinanceResponse: CommunityCodedResponse {
    let error: String?
    let code: String?
    let status: String?
    let products: [AdminBillingProduct]?
    let approved_offers: String?
    let subscriptions: [AdminSubscription]?
    let ledger: [AdminLedgerEntry]?
    let events: [AdminProviderEvent]?
    let totals: [AdminFinanceTotal]?
    let label: String?
    let entitled_accounts: Int?
}

struct AdminRoomReport: Decodable, Identifiable, Equatable {
    let id: UUID; let room_id: UUID; let reason: String; let detail: String; let revision: Int
    let created_at: Date; let title: String; let owner_id: UUID; let closed: Bool
    let members: Int; let report_count: Int
}
struct AdminRoomModerateRequest: Encodable, Equatable {
    let action: String
    var report: UUID? = nil
    var revision: Int? = nil
    var reason = ""
}
struct AdminRoomModerateResponse: CommunityResponse {
    let error: String?; let status: String?; let reports: [AdminRoomReport]?
}

struct ModerationAppealRequest: Encodable, Equatable {
    let action: String
    var media: UUID? = nil
    var explanation = ""
    var appeal: UUID? = nil
    var revision: Int? = nil
    var note = ""
}
struct ModerationAppeal: Decodable, Identifiable, Equatable {
    let id: UUID; let media_id: UUID; let title: String; let explanation: String
    var state: String? = nil; var reply: String? = nil; let created_at: Date; var decided_at: Date? = nil
    var creator: UUID? = nil; var render_digest: String? = nil; var revision: Int? = nil
    var url: String? = nil; var removal_reason: String? = nil; var removal_state: String? = nil
}
struct ModerationAppealResponse: CommunityResponse {
    let error: String?; let status: String?; let appeals: [ModerationAppeal]?
}

struct AdminReviewHistoryRequest: Encodable, Equatable { let page: Int }
struct AdminRenderDecisionRecord: Decodable, Identifiable, Equatable {
    let id: UUID; let review_id: UUID; let actor: UUID; let owner_at_decision: Bool
    let render_title: String; let source_revision: String; let rights_summary: String
    let render_digest: String; let review_version: Int; let consent_version: String
    let destinations: [String]; let decision: String; let note: String; let created_at: Date
}
struct AdminReviewHistoryResponse: CommunityResponse {
    let error: String?; let decisions: [AdminRenderDecisionRecord]?
}
