// ═══════════════════════════════════════════════════════════════════
// ChallengeLifecycleClient — scheduled community challenges over
// `sdi_challenge_action` and the Calendar range over `sdi_calendar_range`
// (challenges.sql). Phases come from the server clock, entries reuse the War
// Room digest-eligibility rule, one entry per creator, one mutable favourite
// vote per non-participant. `reward_text` is descriptive; no coins or money.
// ═══════════════════════════════════════════════════════════════════

import Foundation

@MainActor
final class ChallengeLifecycleClient {
    struct Listing: Equatable { let challenges: [ChallengeSummary]; let clock: ChallengeClock }
    let gateway: CommunityGateway
    init(gateway: CommunityGateway) { self.gateway = gateway }

    func list(now: Date = Date()) async throws -> Listing {
        let response = try await gateway.call("sdi_challenge_action", params: ChallengeActionRequest(action: "list"), as: ChallengeListResponse.self)
        guard let challenges = response.challenges, let serverTime = response.server_time else { throw CommunityError.invalidResponse("Challenge list incomplete.") }
        for challenge in challenges where challenge.entry_count < 0 { throw CommunityError.invalidResponse("The server reported a negative entry count.") }
        return Listing(challenges: challenges, clock: ChallengeClock(serverTime: serverTime, receivedAt: now))
    }
    func entries(challenge: UUID) async throws -> (phase: ChallengePhase?, entries: [ChallengeEntry]) {
        let response = try await gateway.call("sdi_challenge_action", params: ChallengeActionRequest(action: "entries", challenge: challenge), as: ChallengeEntriesResponse.self)
        guard let entries = response.entries else { throw CommunityError.invalidResponse("Entries unavailable.") }
        return (response.phase.flatMap(ChallengePhase.init(rawValue:)), entries)
    }
    private func mutate(_ request: ChallengeActionRequest, expecting statuses: Set<String>) async throws -> ChallengeMutationResponse {
        let response = try await gateway.call("sdi_challenge_action", params: request, as: ChallengeMutationResponse.self)
        guard let status = response.status, statuses.contains(status) else { throw CommunityError.invalidResponse("The challenge operation was not confirmed.") }
        return response
    }
    /// Submits the creator's own approved rendition; the server enforces the
    /// active phase, ownership, digest and one-entry rule.
    func submit(challenge: UUID, media: UUID) async throws { _ = try await mutate(ChallengeActionRequest(action: "submit", challenge: challenge, media: media), expecting: ["entered"]) }
    func withdraw(entry: UUID) async throws { _ = try await mutate(ChallengeActionRequest(action: "withdraw", entry: entry), expecting: ["withdrawn"]) }
    func vote(challenge: UUID, entry: UUID) async throws { _ = try await mutate(ChallengeActionRequest(action: "vote", challenge: challenge, entry: entry), expecting: ["confirmed"]) }

    // Moderator lifecycle (moderation capability + MFA server-side).
    func create(title: String, brief: String, reward: String) async throws -> (id: UUID, revision: Int) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(name.count), brief.count <= 2000, reward.count <= 500 else {
            throw CommunityError.server(message: "A title of 1–100 characters, a brief of at most 2000 and reward text of at most 500 characters are required.", code: nil)
        }
        let response = try await mutate(ChallengeActionRequest(action: "create", title: name, brief: brief, reward: reward), expecting: ["created"])
        guard let id = response.challenge_id, let revision = response.revision else { throw CommunityError.invalidResponse("Creation reply incomplete.") }
        return (id, revision)
    }
    func schedule(challenge: UUID, revision: Int, draft: ChallengeScheduleDraft, now: Date = Date()) async throws -> Int {
        if let problem = draft.validation(now: now) { throw CommunityError.server(message: problem, code: nil) }
        let response = try await mutate(ChallengeActionRequest(action: "schedule", challenge: challenge, starts_at: draft.startsAt, closes_at: draft.closesAt, ends_at: draft.endsAt, revision: revision), expecting: ["confirmed"])
        return response.revision ?? revision + 1
    }
    func cancel(challenge: UUID, revision: Int, reason: String) async throws -> Int {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count) else { throw CommunityError.server(message: "A cancellation reason is required.", code: nil) }
        let response = try await mutate(ChallengeActionRequest(action: "cancel", challenge: challenge, revision: revision, reason: text), expecting: ["confirmed"])
        return response.revision ?? revision + 1
    }
    func removeEntry(challenge: UUID, revision: Int, entry: UUID, reason: String) async throws -> Int {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count) else { throw CommunityError.server(message: "A reason is required.", code: nil) }
        let response = try await mutate(ChallengeActionRequest(action: "remove_entry", challenge: challenge, entry: entry, revision: revision, reason: text), expecting: ["confirmed"])
        return response.revision ?? revision + 1
    }
}

/// Calendar month view over `sdi_calendar_range` with the protected offline
/// cache. Only the visible month is fetched; the range never exceeds the
/// server's 62-day bound.
@MainActor
final class CalendarClient {
    enum Source: Equatable { case server, cache(updatedAt: Date) }
    struct MonthResult: Equatable { let placement: CalendarMonthPlacement; let truncated: Bool; let source: Source }
    let gateway: CommunityGateway
    let cache: CommunityOfflineCache<[CalendarItem]>
    init(gateway: CommunityGateway, cache: CommunityOfflineCache<[CalendarItem]> = .init(name: "calendar")) {
        self.gateway = gateway; self.cache = cache
    }
    func month(containing date: Date, calendar: Calendar, account: String) async throws -> MonthResult {
        guard let bounds = CalendarMonthPlacement.monthBounds(containing: date, calendar: calendar) else { throw CommunityError.invalidResponse("Calendar range unavailable.") }
        let key = CalendarMonthPlacement.monthKey(bounds.start, calendar: calendar)
        do {
            let response = try await gateway.call("sdi_calendar_range", params: CalendarRangeRequest(range_start: bounds.start, range_end: bounds.end), as: CalendarRangeResponse.self)
            guard let items = response.items, items.count <= 500 else { throw CommunityError.invalidResponse("Calendar reply incomplete.") }
            try? cache.store(items, account: account, key: key)
            return MonthResult(placement: CalendarMonthPlacement(start: bounds.start, end: bounds.end, items: items), truncated: response.truncated ?? false, source: .server)
        } catch let error as CommunityError {
            if case .transport = error, let cached = cache.entry(account: account, key: key) {
                return MonthResult(placement: CalendarMonthPlacement(start: bounds.start, end: bounds.end, items: cached.value), truncated: false, source: .cache(updatedAt: cached.updatedAt))
            }
            throw error
        }
    }
}
