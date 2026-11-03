// ═══════════════════════════════════════════════════════════════════
// ServerEntitlementClient — reads the account's server entitlement over
// `sdi_my_entitlement` (backend/sql/billing.sql) for
// `StripeService.reconcileEntitlementsWithServer()` (#251).
//
// The server's entitlement comes only from signed provider events (App Store
// Server Notifications, Stripe webhooks) applied by the billing edge
// functions. The client never writes a tier; it compares what Apple reported
// on this device with what the server recorded and says which is which.
//
// Foundation-only so Tests/AccountServices runs on a Linux host.
// ═══════════════════════════════════════════════════════════════════

import Foundation

struct ServerEntitlement: Equatable {
    /// `free`, `creator`, `pro` or `unlimited`; any other server value is refused.
    let tier: BillingPlanTier
    /// `none` for Free; otherwise the subscription status that grants access
    /// (`active`, `trialing`, `grace`, `past_due`).
    let status: String
    let paidThrough: Date?
    /// `apple` or `stripe`; nil for Free.
    let provider: String?
    let cancelAtPeriodEnd: Bool
    /// The paid plan is in its free trial (owner decision 2026-10-20): the
    /// server's `in_trial`/`trial` flag or a `trialing` status. Missing is false.
    var inTrial: Bool = false
}

struct ServerEntitlementResponse: CommunityResponse {
    let error: String?
    let tier: String?
    let status: String?
    let paid_through: Date?
    let provider: String?
    let cancel_at_period_end: Bool?
    /// Optional trial flag; older servers omit it.
    let in_trial: Bool?
    let trial: Bool?
}

/// Pure comparison of Apple's on-device entitlement with the server's record.
enum ServerEntitlementReconciliation {
    static let notRecordedYet = "the StickDeath server has not recorded this Apple purchase yet; Apple holds your receipt and the plan is applied when Apple's signed notification reaches the server"

    static func verification(storeTier: BillingPlanTier, server: ServerEntitlement) -> BillingServerVerification {
        if server.tier == storeTier { return .verified }
        if storeTier == .free {
            // A paid plan from another provider (for example the website) or one this
            // device has not restored; the server record is the authority.
            return .verified
        }
        if server.tier == .free { return .deferred(notRecordedYet) }
        return .deferred("the server reports the \(server.tier.rawValue.capitalized) plan while Apple reports \(storeTier.rawValue.capitalized) on this device; the server applies Apple's latest signed notification")
    }

    /// Honest wording for a reconciliation that could not run or failed.
    static func verification(for error: Error) -> BillingServerVerification {
        let known: CommunityError = (error as? CommunityError) ?? (error is CancellationError ? .stale : .transport(""))
        switch known {
        case .notConfigured:
            return .deferred("the StickDeath server is not configured in this build; Apple holds your receipt")
        case .signedOut:
            return .deferred("sign in so the StickDeath server can check this purchase; Apple holds your receipt")
        case .transport:
            return .failed("the StickDeath server could not be reached. It is checked again next time you open Plans")
        case .stale:
            return .deferred("the account changed before the server replied")
        case .server(let message, _):
            return .failed(message)
        case .invalidResponse(let detail):
            return .failed(detail)
        }
    }

    /// The tier the server grants, if any, for Studio limits.
    static func grantedTier(_ server: ServerEntitlement?) -> BillingPlanTier {
        guard let server, server.tier != .free else { return .free }
        return server.tier
    }
}

@MainActor
final class ServerEntitlementClient {
    let gateway: CommunityGateway
    init(gateway: CommunityGateway) { self.gateway = gateway }

    func current() async throws -> ServerEntitlement {
        let response = try await gateway.call("sdi_my_entitlement", params: [String: String](), as: ServerEntitlementResponse.self)
        guard let rawTier = response.tier, let tier = BillingPlanTier(rawValue: rawTier), let status = response.status else {
            throw CommunityError.invalidResponse("The server's plan record was incomplete.")
        }
        if tier != .free {
            guard ["active", "trialing", "grace", "past_due"].contains(status), response.paid_through != nil,
                  let provider = response.provider, ["apple", "stripe"].contains(provider) else {
                throw CommunityError.invalidResponse("The server's plan record was incomplete.")
            }
        }
        let inTrial = tier != .free && (response.in_trial == true || response.trial == true || status == "trialing")
        return ServerEntitlement(tier: tier, status: status, paidThrough: response.paid_through, provider: response.provider,
                                 cancelAtPeriodEnd: response.cancel_at_period_end ?? false, inTrial: inTrial)
    }
}
