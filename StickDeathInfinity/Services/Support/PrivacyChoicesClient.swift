// ═══════════════════════════════════════════════════════════════════
// PrivacyChoicesClient — policy links and the member's marketing
// permission (#273) over `sdi_consent_action`
// (backend/sql/consent-versions.sql). Channel-publication permission stays
// per render in Profile → Publishing; marketing reuse is a separate,
// separately withdrawable permission and is handled here.
//
// Foundation-only so Tests/AccountServices runs on a Linux host. The policy
// pages are the versioned drafts in website/policies, addressed from the
// canonical base in scripts/website/site_constants.mjs.
// ═══════════════════════════════════════════════════════════════════

import Foundation

enum PolicyLinks {
    /// Must match `CANONICAL_BASE` in scripts/website/site_constants.mjs.
    static let canonicalBase = "https://stickdeathinfinity.com/"
    static let termsPath = "policies/terms-v1.html"
    static let privacyPath = "policies/privacy-v1.html"
    static let publishingPath = "policies/publishing-v1.html"
    static let attributionPath = "policies/attribution.html"

    static var terms: URL { url(termsPath) }
    static var privacy: URL { url(privacyPath) }
    static var publishing: URL { url(publishingPath) }
    static var attribution: URL { url(attributionPath) }

    static func url(_ path: String) -> URL {
        // Both parts are constants; a failure here is a programming error caught by the tests.
        guard let url = URL(string: canonicalBase + path) else { preconditionFailure("Invalid policy URL") }
        return url
    }
}

struct PolicyVersionSummary: Decodable, Equatable {
    let policy: String
    let version: String
    let summary: String
    let effective_at: Date
}

struct ConsentRecord: Decodable, Equatable {
    let policy: String
    let version: String
    let source: String
    let accepted_at: Date
    let withdrawn_at: Date?
    let current: Bool
}

struct ConsentActionRequest: Encodable, Equatable, Sendable {
    let action: String
    var policy: String? = nil
    var version: String? = nil
    var source: String? = nil
}

struct ConsentActionResponse: CommunityResponse {
    let error: String?
    let status: String?
    let policy: String?
    let version: String?
    let policies: [PolicyVersionSummary]?
    let consents: [ConsentRecord]?
    let publishing_current: Bool?
    let marketing_current: Bool?
}

/// What the Privacy screen shows about marketing reuse.
struct MarketingPermissionState: Equatable {
    /// The owner-published marketing permission text, or nil when none is published yet.
    let currentPolicy: PolicyVersionSummary?
    /// The server's answer: an unwithdrawn acceptance of the current version.
    let granted: Bool
    /// The most recent acceptance or withdrawal the server recorded, for the status line.
    let latest: ConsentRecord?
}

@MainActor
final class PrivacyChoicesClient {
    let gateway: CommunityGateway
    init(gateway: CommunityGateway) { self.gateway = gateway }

    func marketingState() async throws -> MarketingPermissionState {
        let current = try await gateway.call("sdi_consent_action", params: ConsentActionRequest(action: "current"), as: ConsentActionResponse.self)
        guard let policies = current.policies else { throw CommunityError.invalidResponse("Policy versions unavailable.") }
        let mine = try await gateway.call("sdi_consent_action", params: ConsentActionRequest(action: "mine"), as: ConsentActionResponse.self)
        guard let consents = mine.consents, let granted = mine.marketing_current else { throw CommunityError.invalidResponse("Your permissions could not be read.") }
        let latest = consents.filter { $0.policy == "marketing" }.max { ($0.withdrawn_at ?? $0.accepted_at) < ($1.withdrawn_at ?? $1.accepted_at) }
        return MarketingPermissionState(currentPolicy: policies.first { $0.policy == "marketing" }, granted: granted, latest: latest)
    }

    /// Accepts exactly the version the member was shown; the server refuses a stale one.
    func grantMarketing(version: String) async throws {
        let response = try await gateway.call("sdi_consent_action",
                                              params: ConsentActionRequest(action: "accept", policy: "marketing", version: version, source: "ios"),
                                              as: ConsentActionResponse.self)
        guard response.status == "accepted", response.policy == "marketing", response.version == version else {
            throw CommunityError.invalidResponse("The server did not confirm the permission. Refresh before retrying.")
        }
    }

    /// Withdraws marketing reuse for every version; channel-publication permissions are unaffected.
    func withdrawMarketing() async throws {
        let response = try await gateway.call("sdi_consent_action", params: ConsentActionRequest(action: "withdraw", policy: "marketing"),
                                              as: ConsentActionResponse.self)
        guard response.status == "withdrawn", response.policy == "marketing" else {
            throw CommunityError.invalidResponse("The server did not confirm the withdrawal. Refresh before retrying.")
        }
    }
}
