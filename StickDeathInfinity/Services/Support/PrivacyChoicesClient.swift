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
    /// Owner-set policy metadata; only the content policy's age rule is read.
    var metadata: PolicyMetadata? = nil
    /// The minimum age the owner published for this version (content policy), if any.
    var minimumAge: Int? { metadata?.min_age }
}

/// `metadata` is free-form JSON on the server. `min_age` is validated there as
/// one or two digits and may arrive as a number or a string; anything else is ignored.
struct PolicyMetadata: Decodable, Equatable {
    let min_age: Int?
    init(min_age: Int?) { self.min_age = min_age }
    private enum CodingKeys: String, CodingKey { case min_age }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? container.decodeIfPresent(Int.self, forKey: .min_age) { min_age = number }
        else if let text = try? container.decodeIfPresent(String.self, forKey: .min_age) { min_age = Int(text) }
        else { min_age = nil }
    }
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
    /// Sent only with an acceptance the member explicitly attested (content policy age rule).
    var attestation: [String: Bool]? = nil
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

/// The policies a member accepts when creating an account (#273): terms,
/// privacy and, once the owner publishes it, the content policy with its age
/// rule. Channel publication and marketing reuse are separate permissions and
/// are never bundled into this step.
enum OnboardingPolicies {
    static let order = ["terms", "privacy", "content"]
}

/// What the onboarding consent step shows: the published current versions,
/// split by whether the server records an unwithdrawn acceptance of each.
struct OnboardingConsentState: Equatable {
    let pending: [PolicyVersionSummary]
    let accepted: [PolicyVersionSummary]
    /// Nothing to accept because the owner has not published any of these policies.
    var nothingPublished: Bool { pending.isEmpty && accepted.isEmpty }
    var complete: Bool { pending.isEmpty && !accepted.isEmpty }
    /// The age rule the member must confirm before accepting, when one is published.
    var minimumAge: Int? { pending.compactMap(\.minimumAge).max() }
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

    // MARK: Onboarding acceptance (#273)

    /// Reads the current published versions and the member's own record. Only
    /// the server's `current` flag counts as accepted; nothing is assumed locally.
    func onboardingState() async throws -> OnboardingConsentState {
        let current = try await gateway.call("sdi_consent_action", params: ConsentActionRequest(action: "current"), as: ConsentActionResponse.self)
        guard let policies = current.policies else { throw CommunityError.invalidResponse("Policy versions unavailable.") }
        let mine = try await gateway.call("sdi_consent_action", params: ConsentActionRequest(action: "mine"), as: ConsentActionResponse.self)
        guard let consents = mine.consents else { throw CommunityError.invalidResponse("Your acceptances could not be read.") }
        let held = Set(consents.filter { $0.current && $0.withdrawn_at == nil }.map { $0.policy + ":" + $0.version })
        let published = OnboardingPolicies.order.compactMap { name in policies.first { $0.policy == name } }
        return OnboardingConsentState(pending: published.filter { !held.contains($0.policy + ":" + $0.version) },
                                      accepted: published.filter { held.contains($0.policy + ":" + $0.version) })
    }

    /// Accepts exactly the versions the member was shown, in order, from iOS.
    /// The server refuses a stale version; the first refusal stops the batch and
    /// is surfaced, so a partial acceptance is re-read rather than assumed.
    func acceptOnboarding(_ shown: [PolicyVersionSummary], ageConfirmed: Bool) async throws {
        guard !shown.isEmpty else { return }
        if shown.contains(where: { $0.minimumAge != nil }) && !ageConfirmed {
            throw CommunityError.server(message: "Confirm you meet the minimum age in the content policy before accepting.", code: nil)
        }
        for policy in shown {
            let request = ConsentActionRequest(action: "accept", policy: policy.policy, version: policy.version, source: "ios",
                                               attestation: policy.minimumAge != nil ? ["age_ok": true] : nil)
            let response = try await gateway.call("sdi_consent_action", params: request, as: ConsentActionResponse.self)
            guard response.status == "accepted", response.policy == policy.policy, response.version == policy.version else {
                throw CommunityError.invalidResponse("The server did not confirm acceptance. Refresh before retrying.")
            }
        }
    }
}
