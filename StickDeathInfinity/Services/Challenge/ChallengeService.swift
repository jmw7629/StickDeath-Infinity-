// ═══════════════════════════════════════════════════════════════════
// ChallengeService — Animation challenges via Supabase
// Matches: src/services/ChallengeService.ts
// ═══════════════════════════════════════════════════════════════════

import Foundation
import CryptoKit
import Supabase

@MainActor
final class ChallengeService {
    static let shared = ChallengeService()
    private var supabase: SupabaseClient {
        get throws { try SupabaseManager.shared.client }
    }

    /// Fetch all active challenges
    func fetchChallenges() async throws -> [Challenge] {
        let challenges: [Challenge] = try await supabase
            .from("challenges")
            .select()
            .order("start_date", ascending: false)
            .execute()
            .value
        return challenges
    }

    /// Calendar query: only schedules that touch `[start, end)`. Rows with no
    /// end date count when they start inside the range. Bounded to 500 rows;
    /// a month with more schedules than that is reported, not silently cut.
    static let scheduleRangeLimit = 500
    func fetchChallenges(overlapping start: Date, end: Date) async throws -> [Challenge] {
        guard start < end else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let lower = formatter.string(from: start), upper = formatter.string(from: end)
        let challenges: [Challenge] = try await supabase
            .from("challenges")
            .select()
            .lt("start_date", value: upper)
            .or("end_date.gte.\(lower),and(end_date.is.null,start_date.gte.\(lower))")
            .order("start_date", ascending: true)
            .limit(Self.scheduleRangeLimit)
            .execute()
            .value
        return challenges
    }

    /// Submit to a challenge
    func submitEntry(challengeID: Int, userID: String, projectID: String, mediaURL: String?) async throws {
        try await supabase
            .from("challenge_submissions")
            .insert([
                "challenge_id": "\(challengeID)",
                "user_id": userID,
                "project_id": projectID,
                "media_url": mediaURL ?? ""
            ])
            .execute()
    }

    /// Get submissions for a challenge
    func fetchSubmissions(challengeID: Int) async throws -> [ChallengeSubmission] {
        let submissions: [ChallengeSubmission] = try await supabase
            .from("challenge_submissions")
            .select("*, profiles(username, avatar_url)")
            .eq("challenge_id", value: challengeID)
            .order("created_at", ascending: false)
            .execute()
            .value
        return submissions
    }
}

/// Last successful calendar result per account and month, kept in Application
/// Support (not Documents, so it is never mistaken for a project) under the
/// completeUntilFirstUserAuthentication protection class. The account key is a
/// digest, never the identifier itself. Cached rows are shown only with the
/// "Offline · last updated" label and never replace a successful fetch.
struct ChallengeScheduleCache {
    struct Entry: Codable {
        let updatedAt: Date
        let challenges: [Challenge]
    }
    private struct Store: Codable { var version: Int; var months: [String: Entry] }
    static let maximumMonths = 24
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StickDeathInfinity/calendar-cache", isDirectory: true)
    }
    static func monthKey(_ monthStart: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: monthStart)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
    private func file(for account: String) -> URL {
        let digest = SHA256.hash(data: Data(account.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    private func load(_ account: String) -> Store {
        guard let data = try? Data(contentsOf: file(for: account)), data.count <= 8 * 1024 * 1024,
              let store = try? JSONDecoder().decode(Store.self, from: data), store.version == 1 else {
            return Store(version: 1, months: [:])
        }
        return store
    }
    func entry(account: String, month: String) -> Entry? { load(account).months[month] }
    func store(_ challenges: [Challenge], account: String, month: String, now: Date = Date()) throws {
        var store = load(account)
        store.months[month] = Entry(updatedAt: now, challenges: challenges)
        while store.months.count > Self.maximumMonths,
              let oldest = store.months.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            store.months.removeValue(forKey: oldest)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: directory.path)
        #endif
        try JSONEncoder().encode(store).write(to: file(for: account), options: options)
    }
    func removeAll() { try? FileManager.default.removeItem(at: directory) }
}

struct ChallengeSubmission: Codable, Identifiable {
    let id: Int
    var challengeID: Int
    var userID: String
    var projectID: String?
    var mediaURL: String?
    var voteCount: Int?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case challengeID = "challenge_id"
        case userID = "user_id"
        case projectID = "project_id"
        case mediaURL = "media_url"
        case voteCount = "vote_count"
        case createdAt = "created_at"
    }
}
