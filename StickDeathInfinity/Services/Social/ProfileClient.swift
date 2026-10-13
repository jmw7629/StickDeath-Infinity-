// ═══════════════════════════════════════════════════════════════════
// ProfileClient — records & badges preferences (profile-records.sql),
// the earned/locked achievement catalogue (achievements.sql), the creator's
// own approved renditions as portfolio (sdi_watch_media) and the creator's
// file-export permission (feed-publication.sql). Follower and like totals
// have no server contract yet, so the profile shows them as unavailable
// rather than estimating them.
// ═══════════════════════════════════════════════════════════════════

import Foundation

@MainActor
final class ProfileClient {
    let gateway: CommunityGateway
    init(gateway: CommunityGateway) { self.gateway = gateway }

    /// Own record; both public displays default off on the server.
    func readRecords() async throws -> ProfileRecordsResponse {
        let response = try await gateway.call("sdi_profile_records", params: ProfileRecordsRequest(action: "read"), as: ProfileRecordsResponse.self)
        guard response.isCompleteOwnRecord else { throw CommunityError.invalidResponse("Records response incomplete. Refresh before saving.") }
        return response
    }
    /// Another creator's record: hidden totals arrive as nil and stay hidden.
    func readRecords(of subject: UUID) async throws -> ProfileRecordsResponse {
        try await gateway.call("sdi_profile_records", params: ProfileRecordsRequest(action: "read", subject: subject), as: ProfileRecordsResponse.self)
    }
    func saveRecords(revision: Int, showRecords: Bool, showBadges: Bool) async throws -> ProfileRecordsResponse {
        let request = ProfileRecordsRequest(action: "save", revision: revision, records: showRecords, badges: showBadges)
        let response = try await gateway.call("sdi_profile_records", params: request, as: ProfileRecordsResponse.self)
        guard response.isCompleteOwnRecord, response.show_records == showRecords, response.show_badges == showBadges else {
            throw CommunityError.invalidResponse("The server did not confirm the display preferences.")
        }
        return response
    }
    func achievements() async throws -> [AchievementGroup] {
        let response = try await gateway.call("sdi_achievement_catalog", params: [String: String](), as: AchievementCatalogResponse.self)
        guard let items = response.achievements else { throw CommunityError.invalidResponse("Achievement catalogue unavailable.") }
        return AchievementGroup.group(items)
    }
    /// Approved renditions owned by the account (RLS already limits to approved,
    /// unexpired media; the owner filter keeps other creators' work out).
    func portfolio(account: UUID) async throws -> [ApprovedMedia] {
        let items = try await gateway.rows("sdi_watch_media", select: "id,title,url,duration,expires_at,approved",
                                           filters: [.eq("owner_id", account.uuidString.lowercased())], limit: 100, as: ApprovedMedia.self)
        return items.filter { $0.approved != false && CommunityMediaURL.checked($0.url) != nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    func setExportPermission(review: UUID, version: Int, allowed: Bool) async throws -> Bool {
        let response = try await gateway.call("sdi_export_consent", params: ExportConsentRequest(review: review, version: version, allowed: allowed), as: ExportConsentResponse.self)
        return response.status == "confirmed" && response.allow_export == allowed
    }
}
