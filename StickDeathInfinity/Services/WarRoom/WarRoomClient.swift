// ═══════════════════════════════════════════════════════════════════
// WarRoomClient — moderated contests between two approved renditions
// (war-room.sql, feed-integrity.sql, war-moderation.sql, war-appeals.sql,
// war-finalization.sql). Participants agree explicitly, viewers cast one
// mutable authenticated vote, and the server alone finalises results. The
// client never invents opponents, viewers, tallies or winners.
// ═══════════════════════════════════════════════════════════════════

import Foundation

@MainActor
final class WarRoomClient {
    let gateway: CommunityGateway
    init(gateway: CommunityGateway) { self.gateway = gateway }

    func matches() async throws -> [WarMatch] {
        let response = try await gateway.call("sdi_war_action", params: WarRequest(action: "list"), as: WarListResponse.self)
        guard let matches = response.matches else { throw CommunityError.invalidResponse("Matchup list unavailable.") }
        guard matches.count <= 100 else { throw CommunityError.invalidResponse("The server returned too many matchups.") }
        for match in matches {
            guard match.left_votes >= 0, match.right_votes >= 0 else { throw CommunityError.invalidResponse("The server reported a negative tally.") }
            guard match.leftPlaybackSource != nil, match.status == "pending" || match.rightPlaybackSource != nil else {
                throw CommunityError.invalidResponse("A matchup video address is unsupported or unavailable.")
            }
        }
        return matches
    }
    /// The server binds this projection to auth.uid(); no caller-selected owner
    /// or generic raw-media RLS exception can expose another creator's references.
    func ownedMedia() async throws -> [ApprovedMedia] {
        let response = try await gateway.call("sdi_war_media", params: WarMediaRequest(), as: WarMediaResponse.self)
        guard let media = response.media, media.count <= 100, media.allSatisfy({ $0.playbackSource != nil }) else {
            throw CommunityError.invalidResponse("Eligible videos are unavailable.")
        }
        return media
    }
    /// Challenges still require raw approved renditions. Preserve their existing
    /// call and RLS contract until that consumer has provider-aware playback.
    func ownedMedia(account: UUID) async throws -> [ApprovedMedia] {
        try await gateway.rows("sdi_watch_media", select: "id,title,url,duration,expires_at",
                               filters: [.eq("owner_id", account.uuidString.lowercased())], limit: 100, as: ApprovedMedia.self)
    }
    /// Never start from a stale screen row: listing rechecks exact media identity,
    /// current consent, rights, moderation, provider receipt and account controls.
    func matchForPlayback(_ id: UUID) async throws -> WarMatch {
        guard let match = try await matches().first(where: { $0.id == id }) else {
            throw CommunityError.server(message: "This matchup is no longer available.", code: nil)
        }
        return match
    }
    private func confirmed(_ request: WarRequest) async throws {
        let response = try await gateway.call("sdi_war_action", params: request, as: WarListResponse.self)
        guard response.status == "confirmed" else { throw CommunityError.invalidResponse("The operation was not confirmed.") }
    }
    /// Proposal requires an explicit agreement to the visible rules.
    func propose(media: UUID, opponent: UUID, agreed: Bool) async throws {
        guard agreed else { throw CommunityError.server(message: "Agree to the matchup rules before proposing.", code: nil) }
        try await confirmed(WarRequest(action: "propose", media: media, opponent: opponent))
    }
    func accept(match: UUID, media: UUID, agreed: Bool) async throws {
        guard agreed else { throw CommunityError.server(message: "Agree to the matchup rules before accepting.", code: nil) }
        try await confirmed(WarRequest(action: "accept", match: match, media: media))
    }
    func withdraw(match: UUID) async throws { try await confirmed(WarRequest(action: "withdraw", match: match)) }
    func blockCreator(_ creator: UUID) async throws { try await confirmed(WarRequest(action: "block", opponent: creator)) }
    /// Returns only after the server confirms; callers keep the vote pending
    /// until then and restore the previous server vote on failure.
    func vote(match: UUID, choice: WarVoteChoice) async throws {
        try await confirmed(WarRequest(action: "vote", match: match, choice: choice.rawValue))
    }
    func report(match: UUID, reason: String) async throws {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count) else { throw CommunityError.server(message: "Describe the issue in up to 2000 characters.", code: nil) }
        let response = try await gateway.call("sdi_war_report", params: WarReportRequest(match: match, reason: text), as: WarListResponse.self)
        guard response.status == "recorded" else { throw CommunityError.invalidResponse("Report was not confirmed.") }
    }
    func notices() async throws -> [WarNotice] {
        let response = try await gateway.call("sdi_war_notices", params: WarNoticeRequest(action: "list"), as: WarNoticesResponse.self)
        guard let notices = response.notices else { throw CommunityError.invalidResponse("Notices unavailable.") }
        return notices
    }
    func appeal(decision: UUID, explanation: String) async throws {
        let text = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count) else { throw CommunityError.server(message: "Explain the appeal in up to 2000 characters.", code: nil) }
        let response = try await gateway.call("sdi_war_notices", params: WarNoticeRequest(action: "appeal", decision: decision, explanation: text), as: WarNoticesResponse.self)
        guard response.status == "recorded" else { throw CommunityError.invalidResponse("Appeal was not confirmed.") }
    }
}

private struct WarMediaRequest: Encodable, Sendable {}
