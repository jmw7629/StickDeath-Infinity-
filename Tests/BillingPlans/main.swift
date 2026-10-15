// Standalone checks for StickDeathInfinity/Services/Stripe/BillingPlanCatalog.swift
// (#250, #251, #259). Foundation only; no StoreKit, no network, no purchase.
//
//   swiftc -swift-version 5 -parse-as-library \
//     StickDeathInfinity/Services/Stripe/BillingPlanCatalog.swift \
//     Tests/BillingPlans/main.swift -o /tmp/sdi-billing-plans-tests && /tmp/sdi-billing-plans-tests

import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }

@main struct BillingPlansTests {
    static var checks = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(description: message) }
    }

    static let now = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03
    static let utc = TimeZone(identifier: "UTC")!

    static func snapshot(_ id: String, _ tier: BillingPlanTier, ends: TimeInterval?, renew: Bool? = true,
                         state: BillingRenewalState = .subscribed, intro: Bool = false) -> BillingEntitlementSnapshot {
        BillingEntitlementSnapshot(productID: id, tier: tier, period: .monthly, transactionID: "t-\(id)",
                                   purchaseDate: now.addingTimeInterval(-86_400), expirationDate: ends.map { now.addingTimeInterval($0) },
                                   willAutoRenew: renew, renewalState: state, isIntroductoryOffer: intro)
    }

    static func main() {
        do {
            try catalogue()
            try stateMachine()
            try copy()
            print("BILLING_PLANS=PASS (\(checks) checks)")
        } catch {
            print("BILLING_PLANS=FAIL \(error)")
            exit(1)
        }
    }

    static func catalogue() throws {
        let empty = BillingPlanCatalog.load(info: [:])
        try require(empty.plans.map(\.tier) == [.free, .creator, .pro], "Free, Creator and Pro only")
        try require(empty.productIDs == [BillingPlanCatalog.placeholderCreatorMonthly, BillingPlanCatalog.placeholderProMonthly],
                    "two monthly placeholder ids requested from the App Store")
        try require(empty.usesPlaceholderIdentifiers && !empty.annualConfigured && empty.periods == [.monthly], "no annual without configuration")
        try require(empty.tier(forProductID: "com.example.unknown") == .free, "unknown id grants nothing")
        try require(empty.plans.first { $0.tier == .creator }?.promptAllowance == .perMonth(15), "Creator 15 prompts per month")
        try require(empty.plans.first { $0.tier == .pro }?.promptAllowance == .unlimited, "Pro unlimited prompts")
        try require(empty.plans.first { $0.tier == .free }?.promptAllowance == .suggestedPerMonth(5), "Free 5 suggested prompts per month")
        // Owner decisions 2026-10-14: trial and own AI key on both paid plans, neither on Free.
        try require(empty.plans.map(\.offersTrial) == [false, true, true], "trial applies to Creator and Pro only")
        try require(empty.plans.map(\.includesOwnAIKey) == [false, true, true], "own AI key on Creator and Pro only")
        for tier in [BillingPlanTier.creator, .pro] {
            let texts = empty.plans.first { $0.tier == tier }?.entitlements.map(\.text) ?? []
            try require(texts.contains { $0.hasPrefix("Use your own AI key") }, "\(tier) lists the own AI key")
        }
        try require(empty.plans.first { $0.tier == .free }?.entitlements.map(\.text).contains("5 suggested Spatter prompts per month") == true,
                    "Free lists 5 suggested prompts per month")
        let paidExtras = empty.plans.filter { $0.tier != .free }.flatMap(\.entitlements).filter { !$0.text.hasPrefix("Everything") }
        try require(!paidExtras.isEmpty && paidExtras.allSatisfy { !$0.isLive }, "paid extras stay pending until server enforcement")
        let text = empty.plans.flatMap(\.entitlements).map(\.text).joined(separator: " ")
        for banned in ["$", "USD", "19.99", "Studio plan", "coins", "POPULAR", "sale", "Save "] {
            try require(!text.contains(banned), "no hard-coded price, retired tier or sale claim: \(banned)")
        }

        let unexpanded = BillingPlanCatalog.load(info: [BillingPlanCatalog.creatorMonthlyKey: "$(SDI_STOREKIT_PLAN_4_99_PRODUCT_ID)"])
        try require(unexpanded.usesPlaceholderIdentifiers, "unexpanded build setting is not configuration")

        let monthly = [BillingPlanCatalog.creatorMonthlyKey: "sdi.creator.m", BillingPlanCatalog.proMonthlyKey: "sdi.pro.m"]
        var annualWithoutFlag = monthly
        annualWithoutFlag[BillingPlanCatalog.creatorAnnualKey] = "sdi.creator.y"
        let noFlag = BillingPlanCatalog.load(info: annualWithoutFlag)
        try require(!noFlag.usesPlaceholderIdentifiers && !noFlag.annualConfigured && !noFlag.productIDs.contains("sdi.creator.y"),
                    "annual id without the owner flag is ignored")
        var annualFlagged = annualWithoutFlag
        annualFlagged[BillingPlanCatalog.annualOwnerFlagKey] = "yes"
        try require(!BillingPlanCatalog.load(info: annualFlagged).annualConfigured, "owner flag must be exactly YES")
        annualFlagged[BillingPlanCatalog.annualOwnerFlagKey] = "YES"
        let annual = BillingPlanCatalog.load(info: annualFlagged)
        try require(annual.annualConfigured && annual.periods == [.monthly, .annual], "annual offered once configured")
        try require(annual.plans(for: .annual).map(\.tier) == [.free, .creator], "only the configured annual plan appears")
        try require(annual.plan(forProductID: "sdi.creator.y")?.period == .annual, "annual product maps to its period")

        let clash = BillingPlanCatalog.load(info: [BillingPlanCatalog.creatorMonthlyKey: "same", BillingPlanCatalog.proMonthlyKey: "same"])
        try require(!clash.productIDs.contains("same") && clash.tier(forProductID: "same") == .free, "duplicated id offers neither plan")
    }

    static func stateMachine() throws {
        var s = BillingState()
        try require(!s.canStartPurchase, "no purchase before the catalogue loads")
        s = BillingState.reduce(s, .catalogLoaded(productCount: 0))
        try require(s.phase == .catalogUnavailable(.notConfigured) && !s.canStartPurchase, "empty App Store answer is not configured")
        s = BillingState.reduce(BillingState(), .catalogFailed("offline"))
        try require(s.phase == .catalogUnavailable(.storeUnreachable("offline")) && s.message != nil, "store failure is reported")

        s = BillingState.reduce(BillingState(), .catalogLoaded(productCount: 2))
        try require(s.phase == .free && s.canStartPurchase, "loaded catalogue starts free")
        s = BillingState.reduce(s, .purchaseStarted("sdi.creator.m"))
        try require(s.phase == .purchasing("sdi.creator.m") && s.isBusy && !s.canStartPurchase, "purchasing blocks a second purchase")
        let ignored = BillingState.reduce(s, .purchaseStarted("sdi.pro.m"))
        try require(ignored == s, "second purchase start ignored")
        let cancelled = BillingState.reduce(s, .purchaseCancelled)
        try require(cancelled.phase == .free && cancelled.message == nil, "cancel returns to the previous phase silently")
        let unverified = BillingState.reduce(s, .purchaseUnverified("signature"))
        try require(unverified.phase == .free && unverified.message?.contains("Nothing was granted") == true, "unverified grants nothing")
        let failed = BillingState.reduce(s, .purchaseFailed("network"))
        try require(failed.phase == .free && failed.message?.contains("Nothing was billed or granted") == true, "store failure grants nothing")
        let pending = BillingState.reduce(s, .purchasePending("sdi.creator.m"))
        try require(pending.phase == .pending("sdi.creator.m") && pending.activeEntitlement == nil, "pending grants nothing")
        let stillPending = BillingState.reduce(pending, .entitlementsRefreshed([], now: now))
        try require(stillPending.phase == pending.phase, "refresh without entitlements keeps Ask to Buy pending")
        let oldLapsed = snapshot("sdi.creator.m", .creator, ends: -86_400 * 40, state: .expired)
        try require(BillingState.reduce(pending, .entitlementsRefreshed([oldLapsed], now: now)).phase == pending.phase,
                    "an old expired plan does not hide a pending approval")

        let creator = snapshot("sdi.creator.m", .creator, ends: 86_400 * 20)
        let midPurchase = BillingState.reduce(s, .entitlementsRefreshed([creator], now: now))
        try require(midPurchase.isBusy, "refresh during a purchase does not end it")
        s = BillingState.reduce(s, .purchaseVerified(creator))
        try require(s.activeEntitlement == creator && s.message == "Apple confirmed the purchase.", "verified purchase subscribes")
        try require(s.server == .notConfigured, "server verification stays deferred, never claimed")
        s = BillingState.reduce(s, .serverVerification(.verified))
        try require(s.server == .verified, "server result recorded when it arrives")

        let pro = snapshot("sdi.pro.m", .pro, ends: 86_400 * 5)
        s = BillingState.reduce(s, .entitlementsRefreshed([creator, pro], now: now))
        try require(s.activeEntitlement == pro, "highest tier wins")
        let grace = snapshot("sdi.pro.m", .pro, ends: 86_400 * 3, state: .inGracePeriod)
        try require(BillingState.reduce(s, .entitlementsRefreshed([grace], now: now)).activeEntitlement == grace, "grace keeps access")
        let retry = snapshot("sdi.pro.m", .pro, ends: -60, renew: true, state: .inBillingRetry)
        let lapsed = BillingState.reduce(s, .entitlementsRefreshed([retry], now: now))
        try require(lapsed.phase == .lapsed(retry) && lapsed.server == .notConfigured, "billing retry without grace pauses access")
        let revoked = snapshot("sdi.pro.m", .pro, ends: 86_400, state: .revoked)
        try require(BillingState.reduce(s, .entitlementsRefreshed([revoked], now: now)).phase == .lapsed(revoked), "revocation ends access")
        let expiredByClock = snapshot("sdi.creator.m", .creator, ends: -1)
        try require(BillingState.reduce(s, .entitlementsRefreshed([expiredByClock], now: now)).phase == .lapsed(expiredByClock),
                    "period end in the past grants nothing")
        try require(BillingState.reduce(s, .entitlementsRefreshed([], now: now)).phase == .free, "restore with nothing is free")
        let restoreFailed = BillingState.reduce(s, .restoreFailed("offline"))
        try require(restoreFailed.phase == s.phase && restoreFailed.message?.contains("offline") == true, "restore failure keeps state and reports")
    }

    static func copy() throws {
        let catalog = BillingPlanCatalog.load(info: [BillingPlanCatalog.creatorMonthlyKey: "sdi.creator.m", BillingPlanCatalog.proMonthlyKey: "sdi.pro.m"])
        try require(BillingCopy.price(nil, period: .monthly) == "Price shown when configured", "no price before the App Store answers")
        try require(BillingCopy.price("4,99 €", period: .monthly) == "4,99 € per month", "Apple's localized price is shown verbatim")
        try require(BillingCopy.price("$9.99", period: .annual) == "$9.99 per year", "annual period copy")
        try require(BillingCopy.trial(days: 3, eligible: true) == "3-day free trial", "trial from the store offer")
        try require(BillingCopy.trial(days: 3, eligible: false) == nil && BillingCopy.trial(days: nil, eligible: true) == nil,
                    "no trial claim without an eligible store offer")
        for tier in [BillingPlanTier.creator, .pro] {
            let plan = catalog.plans.first { $0.tier == tier }
            try require(BillingCopy.trial(for: plan, days: 3, eligible: true) == "3-day free trial", "\(tier) trial from the store offer")
            try require(BillingCopy.trial(for: plan, days: 3, eligible: false) == nil, "\(tier) trial needs eligibility")
        }
        try require(BillingCopy.trial(for: catalog.plans.first { $0.tier == .free }, days: 3, eligible: true) == nil, "Free never shows a trial")
        try require(BillingCopy.trial(for: nil, days: 3, eligible: true) == nil, "unknown product shows no trial")

        let end = Date(timeIntervalSince1970: 1_792_800_000) // 2026-10-24 UTC
        let us = BillingCopy.date(end, locale: Locale(identifier: "en_US"), timeZone: utc)
        let de = BillingCopy.date(end, locale: Locale(identifier: "de_DE"), timeZone: utc)
        try require(us == "Oct 24, 2026", "en_US date: \(us)")
        try require(de == "24.10.2026", "de_DE date: \(de)")

        func status(_ snap: BillingEntitlementSnapshot, lapsed: Bool = false) -> (title: String, detail: String) {
            var state = BillingState()
            state.phase = lapsed ? .lapsed(snap) : .subscribed(snap)
            return BillingCopy.status(state, catalog: catalog, locale: Locale(identifier: "en_US"), timeZone: utc)
        }
        let renewing = BillingEntitlementSnapshot(productID: "sdi.creator.m", tier: .creator, period: .monthly, transactionID: "1",
                                                  purchaseDate: now, expirationDate: end, willAutoRenew: true, renewalState: .subscribed,
                                                  isIntroductoryOffer: false)
        try require(status(renewing) == ("Creator (monthly)", "Renews on Oct 24, 2026."), "renewal copy")
        let off = BillingEntitlementSnapshot(productID: "sdi.creator.m", tier: .creator, period: .monthly, transactionID: "1",
                                             purchaseDate: now, expirationDate: end, willAutoRenew: false, renewalState: .subscribed,
                                             isIntroductoryOffer: true)
        try require(status(off).detail == "Free trial. Auto-renew is off. Access ends on Oct 24, 2026.", "cancel-at-period-end copy")
        let unknown = BillingEntitlementSnapshot(productID: "sdi.pro.m", tier: .pro, period: .monthly, transactionID: "1",
                                                 purchaseDate: now, expirationDate: nil, willAutoRenew: nil, renewalState: .subscribed,
                                                 isIntroductoryOffer: false)
        try require(status(unknown).detail == "Apple did not report a period end.", "no invented renewal date")
        let refunded = BillingEntitlementSnapshot(productID: "sdi.pro.m", tier: .pro, period: .monthly, transactionID: "1",
                                                  purchaseDate: now, expirationDate: end, willAutoRenew: nil, renewalState: .revoked,
                                                  isIntroductoryOffer: false)
        try require(status(refunded, lapsed: true).detail.contains("refunded or revoked"), "revocation copy")

        var freeState = BillingState(); freeState.phase = .free
        try require(BillingCopy.status(freeState, catalog: catalog, locale: Locale(identifier: "en_US"), timeZone: utc).detail.contains("Nothing is billed"),
                    "free copy")
        try require(BillingCopy.server(.notConfigured).hasPrefix("Server verification deferred"), "deferred server copy")

        try require(BillingCopy.prompts(.perMonth(15), remaining: nil).contains("once the server reports"), "no invented prompt count")
        try require(BillingCopy.prompts(.perMonth(15), remaining: 4) == "4 of 15 Spatter prompts left this month.", "remaining prompts")
        try require(BillingCopy.prompts(.perMonth(15), remaining: 0).contains("Upgrade to Pro"), "upgrade prompt at the limit")
        try require(BillingCopy.prompts(.perMonth(15), remaining: 99) == "15 of 15 Spatter prompts left this month.", "server count clamped")
        try require(BillingCopy.prompts(.unlimited, remaining: nil) == "Unlimited Spatter prompts.", "Pro unlimited")
        try require(BillingCopy.prompts(.suggestedPerMonth(5), remaining: 0).contains("Creator or Pro"), "free prompts exhausted")
        try require(BillingCopy.prompts(.suggestedPerMonth(5), remaining: 3) == "3 of 5 suggested Spatter prompts left this month.", "free remaining")
        try require(BillingCopy.prompts(.suggestedPerMonth(5), remaining: nil).hasPrefix("5 suggested Spatter prompts per month"), "free plan line")
    }
}
