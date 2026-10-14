// ═══════════════════════════════════════════════════════════════════
// BillingPlanCatalog — one source for plans, purchase state and plan copy
//
// Contract: docs/BILLING_CONTRACT.md (#250, #251, #259)
//
// Foundation only, so the standalone suite Tests/BillingPlans compiles it
// without StoreKit. `StripeService` feeds StoreKit facts in as events and the
// settings/onboarding views render only what this file returns.
//
// - Plans: Free, Creator (USD 4.99/month) and Pro (USD 9.99/month), the
//   owner's 2026-10-07 decisions. Amounts are never stored here: the price
//   shown is Apple's `Product.displayPrice` or "Price shown when configured".
// - Annual plans appear only when the build configuration names annual product
//   ids AND sets the explicit owner flag. Neither exists today.
// - Every paid entitlement is labelled pending until the server enforces it.
//   Nothing here claims a server check that has not run.
// ═══════════════════════════════════════════════════════════════════

import Foundation

enum BillingPlanTier: String, CaseIterable, Equatable {
    case free, creator, pro

    /// Higher wins when several Apple entitlements exist on one device.
    var rank: Int {
        switch self {
        case .free: return 0
        case .creator: return 1
        case .pro: return 2
        }
    }
}

enum BillingPeriod: String, Equatable {
    case monthly, annual
}

enum SpatterPromptAllowance: Equatable {
    /// A one-time allowance (the owner's 5 free prompts; one-time until the owner says otherwise).
    case trial(Int)
    /// Counted per billing period on the server, resetting at each renewal.
    case perMonth(Int)
    case unlimited
}

struct BillingEntitlement: Equatable {
    let text: String
    /// True only when the app enforces this today. Paid extras stay false until
    /// the server applies the plan from verified provider events.
    let isLive: Bool
}

struct BillingPlanDefinition: Equatable, Identifiable {
    let tier: BillingPlanTier
    let name: String
    let period: BillingPeriod
    /// App Store product id; nil for the free plan.
    let productID: String?
    let entitlements: [BillingEntitlement]
    let promptAllowance: SpatterPromptAllowance

    var id: String { productID ?? "free" }
}

struct BillingPlanCatalog: Equatable {
    // Info.plist keys (filled from xcconfig `$(VAR)` settings).
    static let creatorMonthlyKey = "SDI_STOREKIT_PLAN_4_99_PRODUCT_ID"
    static let proMonthlyKey = "SDI_STOREKIT_PLAN_9_99_PRODUCT_ID"
    static let creatorAnnualKey = "SDI_STOREKIT_PLAN_4_99_ANNUAL_PRODUCT_ID"
    static let proAnnualKey = "SDI_STOREKIT_PLAN_9_99_ANNUAL_PRODUCT_ID"
    /// Must be exactly "YES" before any annual id is offered (owner decision, #250).
    static let annualOwnerFlagKey = "SDI_BILLING_ANNUAL_OWNER_CONFIGURED"

    static let placeholderCreatorMonthly = "com.stickdeath.infinity.creator.monthly"
    static let placeholderProMonthly = "com.stickdeath.infinity.pro.monthly"

    let plans: [BillingPlanDefinition]
    let usesPlaceholderIdentifiers: Bool
    let annualConfigured: Bool

    static let freeEntitlements = [
        BillingEntitlement(text: "Full Studio on this device", isLive: true),
        BillingEntitlement(text: "Projects stay on this device", isLive: true),
        BillingEntitlement(text: "Video upload and download not included", isLive: false),
        BillingEntitlement(text: "5 Spatter prompts to try", isLive: false),
    ]
    static let creatorEntitlements = [
        BillingEntitlement(text: "Everything in Free", isLive: true),
        BillingEntitlement(text: "No watermark", isLive: false),
        BillingEntitlement(text: "Upload and download your videos", isLive: false),
        BillingEntitlement(text: "15 Spatter prompts per month", isLive: false),
    ]
    static let proEntitlements = [
        BillingEntitlement(text: "Everything in Creator", isLive: true),
        BillingEntitlement(text: "Unlimited Spatter prompts", isLive: false),
    ]

    /// Build from the app's Info.plist dictionary. Unexpanded `$(VAR)` values are not configuration.
    static func load(info: [String: Any]) -> BillingPlanCatalog {
        func value(_ key: String) -> String? {
            guard let raw = info[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("$("), !trimmed.contains("${") else { return nil }
            return trimmed
        }
        let creator = value(creatorMonthlyKey)
        let pro = value(proMonthlyKey)
        var plans = [
            BillingPlanDefinition(tier: .free, name: "Free", period: .monthly, productID: nil,
                                  entitlements: freeEntitlements, promptAllowance: .trial(5)),
            BillingPlanDefinition(tier: .creator, name: "Creator", period: .monthly,
                                  productID: creator ?? placeholderCreatorMonthly,
                                  entitlements: creatorEntitlements, promptAllowance: .perMonth(15)),
            BillingPlanDefinition(tier: .pro, name: "Pro", period: .monthly,
                                  productID: pro ?? placeholderProMonthly,
                                  entitlements: proEntitlements, promptAllowance: .unlimited),
        ]
        let ownerFlag = value(annualOwnerFlagKey) == "YES"
        let creatorAnnual = ownerFlag ? value(creatorAnnualKey) : nil
        let proAnnual = ownerFlag ? value(proAnnualKey) : nil
        if let id = creatorAnnual {
            plans.append(BillingPlanDefinition(tier: .creator, name: "Creator", period: .annual, productID: id,
                                               entitlements: creatorEntitlements, promptAllowance: .perMonth(15)))
        }
        if let id = proAnnual {
            plans.append(BillingPlanDefinition(tier: .pro, name: "Pro", period: .annual, productID: id,
                                               entitlements: proEntitlements, promptAllowance: .unlimited))
        }
        let ids = plans.compactMap(\.productID)
        // A misconfigured build that reuses one id for two plans offers neither of the duplicates.
        let duplicates = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
        let offered = plans.filter { $0.productID.map { !duplicates.contains($0) } ?? true }
        return BillingPlanCatalog(plans: offered,
                                  usesPlaceholderIdentifiers: creator == nil || pro == nil,
                                  annualConfigured: offered.contains { $0.period == .annual })
    }

    /// The identifiers requested from the App Store, monthly first.
    var productIDs: [String] { plans.compactMap(\.productID) }

    func plan(forProductID id: String) -> BillingPlanDefinition? {
        plans.first { $0.productID == id }
    }

    /// Unknown ids grant nothing.
    func tier(forProductID id: String) -> BillingPlanTier {
        plan(forProductID: id)?.tier ?? .free
    }

    func plans(for period: BillingPeriod) -> [BillingPlanDefinition] {
        plans.filter { $0.tier == .free || $0.period == period }
    }

    var periods: [BillingPeriod] { annualConfigured ? [.monthly, .annual] : [.monthly] }
}

// MARK: - Purchase and subscription state machine

/// Mirrors `Product.SubscriptionInfo.RenewalState` without importing StoreKit.
enum BillingRenewalState: Equatable {
    case subscribed, inGracePeriod, inBillingRetry, expired, revoked
}

struct BillingEntitlementSnapshot: Equatable {
    let productID: String
    let tier: BillingPlanTier
    let period: BillingPeriod
    let transactionID: String
    let purchaseDate: Date
    /// Apple's period end; nil when Apple did not supply one.
    let expirationDate: Date?
    /// From Apple's signed renewal info; nil when Apple did not report it.
    let willAutoRenew: Bool?
    let renewalState: BillingRenewalState
    let isIntroductoryOffer: Bool

    func grantsAccess(at now: Date) -> Bool {
        guard tier != .free else { return false }
        switch renewalState {
        case .subscribed, .inGracePeriod:
            return expirationDate.map { $0 > now } ?? true
        case .inBillingRetry, .expired, .revoked:
            return false
        }
    }
}

enum BillingCatalogProblem: Equatable {
    /// The App Store returned no products for the configured ids.
    case notConfigured
    case storeUnreachable(String)
}

enum BillingPhase: Equatable {
    case loadingCatalog
    case catalogUnavailable(BillingCatalogProblem)
    case free
    case purchasing(String)
    /// Ask to Buy or another approval; nothing is billed or granted yet.
    case pending(String)
    case subscribed(BillingEntitlementSnapshot)
    /// The latest Apple entitlement no longer grants access (expired, revoked, billing retry).
    case lapsed(BillingEntitlementSnapshot)
}

/// Server confirmation of Apple's transaction. Native acceptance and the
/// server endpoint are deferred, so the default says so.
enum BillingServerVerification: Equatable {
    case deferred(String)
    case verified
    case failed(String)

    static let notConfigured = BillingServerVerification.deferred(
        "the StickDeath server has not verified this purchase yet; Apple holds your receipt")
}

enum BillingEvent: Equatable {
    case catalogLoaded(productCount: Int)
    case catalogFailed(String)
    case purchaseStarted(String)
    case purchaseVerified(BillingEntitlementSnapshot)
    case purchaseUnverified(String)
    case purchaseCancelled
    /// The App Store call failed before any transaction (network, store error).
    case purchaseFailed(String)
    case purchasePending(String)
    case entitlementsRefreshed([BillingEntitlementSnapshot], now: Date)
    case restoreFailed(String)
    case serverVerification(BillingServerVerification)
}

struct BillingState: Equatable {
    var phase: BillingPhase = .loadingCatalog
    var catalogLoaded = false
    var server: BillingServerVerification = .notConfigured
    /// The latest user-facing outcome; never a success Apple did not confirm.
    var message: String?
    /// Where a cancelled or unverified purchase returns to.
    var resumePhase: BillingPhase?

    var isBusy: Bool {
        if case .purchasing = phase { return true }
        return false
    }

    var activeEntitlement: BillingEntitlementSnapshot? {
        if case .subscribed(let snapshot) = phase { return snapshot }
        return nil
    }

    var canStartPurchase: Bool {
        guard catalogLoaded else { return false }
        switch phase {
        case .free, .subscribed, .lapsed: return true
        case .loadingCatalog, .catalogUnavailable, .purchasing, .pending: return false
        }
    }

    static func reduce(_ state: BillingState, _ event: BillingEvent) -> BillingState {
        var next = state
        switch event {
        case .catalogLoaded(let count):
            next.catalogLoaded = count > 0
            if isCatalogPhase(state.phase) {
                next.phase = count > 0 ? .free : .catalogUnavailable(.notConfigured)
            }
        case .catalogFailed(let message):
            next.catalogLoaded = false
            if isCatalogPhase(state.phase) {
                next.phase = .catalogUnavailable(.storeUnreachable(message))
            }
            next.message = "Could not load plans from the App Store."
        case .purchaseStarted(let productID):
            guard state.canStartPurchase else { return state }
            next.resumePhase = state.phase
            next.phase = .purchasing(productID)
            next.message = nil
        case .purchaseVerified(let snapshot):
            next.phase = .subscribed(snapshot)
            next.resumePhase = nil
            next.server = .notConfigured
            next.message = "Apple confirmed the purchase."
        case .purchaseUnverified(let reason):
            next.phase = state.resumePhase ?? .free
            next.resumePhase = nil
            next.message = "Apple could not verify the purchase (\(reason)). Nothing was granted."
        case .purchaseCancelled:
            next.phase = state.resumePhase ?? state.phase
            next.resumePhase = nil
            next.message = nil
        case .purchaseFailed(let reason):
            next.phase = state.resumePhase ?? state.phase
            next.resumePhase = nil
            next.message = "The purchase did not complete (\(reason)). Nothing was billed or granted."
        case .purchasePending(let productID):
            next.phase = .pending(productID)
            next.resumePhase = nil
            next.message = "Waiting for approval. Nothing is billed until Apple confirms."
        case .entitlementsRefreshed(let snapshots, let now):
            let best = snapshots.filter { $0.grantsAccess(at: now) }.max { lhs, rhs in
                if lhs.tier.rank != rhs.tier.rank { return lhs.tier.rank < rhs.tier.rank }
                return (lhs.expirationDate ?? .distantFuture) < (rhs.expirationDate ?? .distantFuture)
            }
            if case .purchasing = state.phase {
                // The purchase result decides; a refresh mid-purchase must not end it.
                if let best { next.resumePhase = .subscribed(best) }
                return next
            }
            if let best {
                next.phase = .subscribed(best)
            } else if case .pending = state.phase {
                // Ask to Buy stays pending until Apple delivers the approved transaction.
                next.phase = state.phase
            } else if let latest = snapshots.filter({ $0.tier != .free })
                        .max(by: { ($0.expirationDate ?? $0.purchaseDate) < ($1.expirationDate ?? $1.purchaseDate) }) {
                next.phase = .lapsed(latest)
            } else if state.catalogLoaded || !isCatalogPhase(state.phase) {
                next.phase = .free
            }
            if best == nil { next.server = .notConfigured }
        case .restoreFailed(let message):
            next.message = "Restore could not reach the App Store: \(message)"
        case .serverVerification(let result):
            next.server = result
        }
        return next
    }

    private static func isCatalogPhase(_ phase: BillingPhase) -> Bool {
        switch phase {
        case .loadingCatalog, .catalogUnavailable: return true
        default: return false
        }
    }
}

// MARK: - Copy

/// Every string the plan screens show about price, renewal and allowance.
/// Dates use the caller's locale and time zone; prices are Apple's strings.
enum BillingCopy {
    static func date(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// `displayPrice` is `Product.displayPrice`; nil until the App Store supplies it.
    static func price(_ displayPrice: String?, period: BillingPeriod) -> String {
        guard let displayPrice, !displayPrice.isEmpty else { return "Price shown when configured" }
        return "\(displayPrice) per \(period == .monthly ? "month" : "year")"
    }

    /// Only shown when the App Store reports an introductory free trial the account is eligible for.
    static func trial(days: Int?, eligible: Bool) -> String? {
        guard eligible, let days, days > 0 else { return nil }
        return days == 1 ? "1-day free trial" : "\(days)-day free trial"
    }

    static func planTitle(_ plan: BillingPlanDefinition) -> String {
        plan.tier == .free ? plan.name : "\(plan.name) (\(plan.period == .monthly ? "monthly" : "annual"))"
    }

    static func status(_ state: BillingState, catalog: BillingPlanCatalog, locale: Locale, timeZone: TimeZone) -> (title: String, detail: String) {
        func day(_ value: Date?) -> String? { value.map { date($0, locale: locale, timeZone: timeZone) } }
        switch state.phase {
        case .loadingCatalog:
            return ("Loading plans", "Loading plans from the App Store...")
        case .catalogUnavailable(.notConfigured):
            return ("Plans are not configured yet", "The App Store has no products for this app yet. You can keep using the free Studio.")
        case .catalogUnavailable(.storeUnreachable(let message)):
            return ("Plans unavailable", "The App Store could not be reached: \(message)")
        case .free:
            return ("Free", "You are using the free Studio. Nothing is billed.")
        case .purchasing:
            return ("Waiting for Apple", "Complete or cancel the purchase in Apple's sheet.")
        case .pending:
            return ("Purchase pending", "Apple is waiting for approval (for example Ask to Buy). The plan activates when Apple confirms it; nothing is billed before then.")
        case .subscribed(let snapshot):
            let title = catalog.plan(forProductID: snapshot.productID).map(planTitle) ?? snapshot.productID
            let trial = snapshot.isIntroductoryOffer ? "Free trial. " : ""
            let detail: String
            switch (snapshot.renewalState, snapshot.willAutoRenew, day(snapshot.expirationDate)) {
            case (.inGracePeriod, _, let end?):
                detail = "Apple could not renew this plan and is retrying. Access continues until \(end); update your payment method in Apple settings."
            case (.inGracePeriod, _, nil):
                detail = "Apple could not renew this plan and is retrying. Update your payment method in Apple settings."
            case (_, .some(true), let end?):
                detail = "\(trial)Renews on \(end)."
            case (_, .some(false), let end?):
                detail = "\(trial)Auto-renew is off. Access ends on \(end)."
            case (_, nil, let end?):
                detail = "\(trial)Current period ends on \(end)."
            case (_, _, nil):
                detail = "\(trial)Apple did not report a period end."
            }
            return (title, detail)
        case .lapsed(let snapshot):
            let title = catalog.plan(forProductID: snapshot.productID).map(planTitle) ?? snapshot.productID
            switch snapshot.renewalState {
            case .revoked:
                return (title, "Apple refunded or revoked this purchase. The free Studio remains available and your projects stay on this device.")
            case .inBillingRetry:
                return (title, "Apple could not renew this plan. Paid features are paused until the payment issue is fixed in Apple settings.")
            case .expired, .subscribed, .inGracePeriod:
                if let end = day(snapshot.expirationDate) {
                    return (title, "This plan ended on \(end). Your projects stay on this device.")
                }
                return (title, "This plan has ended. Your projects stay on this device.")
            }
        }
    }

    static func server(_ verification: BillingServerVerification) -> String {
        switch verification {
        case .deferred(let reason): return "Server verification deferred: \(reason)."
        case .verified: return "Verified by the StickDeath server."
        case .failed(let reason): return "Server verification failed: \(reason). Apple's receipt is unaffected."
        }
    }

    /// `remaining` comes only from the server's count; nil means it has not reported one.
    static func prompts(_ allowance: SpatterPromptAllowance, remaining: Int?) -> String {
        switch (allowance, remaining) {
        case (.unlimited, _):
            return "Unlimited Spatter prompts."
        case (_, nil):
            return "Remaining Spatter prompts appear once the server reports them."
        case (.perMonth(let total), let reported?):
            let left = max(0, min(reported, total))
            return left == 0
                ? "All \(total) Spatter prompts used this month. Upgrade to Pro for unlimited prompts, or wait for your renewal."
                : "\(left) of \(total) Spatter prompts left this month."
        case (.trial(let total), let reported?):
            let left = max(0, min(reported, total))
            return left == 0
                ? "All \(total) trial Spatter prompts used. Choose Creator or Pro to keep using Spatter."
                : "\(left) of \(total) trial Spatter prompts left."
        }
    }

    static let pendingEntitlementNote = "Marked features turn on when the server applies your plan from Apple's verified purchase."
    static let manageNote = "Billed by Apple. Manage, change or cancel in Apple subscription settings; cancelling keeps access until the period ends. Projects stay on this device."
}
