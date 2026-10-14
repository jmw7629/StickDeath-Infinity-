// ═══════════════════════════════════════════════════════════════════
// StripeService — StoreKit 2 subscriptions (client side)
//
// Contract: docs/BILLING_CONTRACT.md
//
// - Exactly two monthly auto-renewable plans are approved: USD 4.99 and
//   USD 9.99. Apple shows the real localized price from the loaded
//   `Product`; nothing in this file states a price.
// - Annual plans are NOT configured. No annual product id or price exists
//   until the owner explicitly configures amounts and entitlements.
// - Entitlements are reconciled server-side from Apple's signed
//   transactions. This client never writes subscription tier/status to the
//   `users` table. See `reconcileEntitlementsWithServer()`.
// - Call billing and tips were removed: calls are retired scope and tips
//   are not in the current contract. The historical name "StripeService"
//   is kept only because this file is referenced by the Xcode project;
//   no Stripe API is called from the client.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import StoreKit

// MARK: - Product IDs
//
// The identifiers come from `BillingPlanCatalog` (one configuration for
// plans, periods and copy). PLACEHOLDERS remain until the owner creates the
// two monthly auto-renewable subscriptions in App Store Connect and sets the
// Info.plist keys `SDI_STOREKIT_PLAN_4_99_PRODUCT_ID` and
// `SDI_STOREKIT_PLAN_9_99_PRODUCT_ID` (existing `$(VAR)` xcconfig pattern).
// Annual ids are offered only when `SDI_BILLING_ANNUAL_OWNER_CONFIGURED` is
// `YES` and the annual keys are set; neither exists today. Until App Store
// Connect has matching products, `Product.products(for:)` returns nothing and
// the UI shows an honest "not configured" state.
enum StoreProductID {
    static let catalog = BillingPlanCatalog.load(info: Bundle.main.infoDictionary ?? [:])

    /// Info.plist key for the USD 4.99/month plan identifier.
    static let plan499InfoKey = BillingPlanCatalog.creatorMonthlyKey
    /// Info.plist key for the USD 9.99/month plan identifier.
    static let plan999InfoKey = BillingPlanCatalog.proMonthlyKey

    /// USD 4.99/month plan — maps to `AppConfig.SubscriptionTier.creator`.
    static var creatorMonthly: String {
        monthlyID(for: .creator) ?? BillingPlanCatalog.placeholderCreatorMonthly
    }

    /// USD 9.99/month plan — maps to `AppConfig.SubscriptionTier.pro`.
    static var proMonthly: String {
        monthlyID(for: .pro) ?? BillingPlanCatalog.placeholderProMonthly
    }

    /// The approved catalogue: two monthly plans, plus annual plans only when
    /// the owner configured them explicitly.
    static var allSubscriptions: [String] { catalog.productIDs }

    /// Whether the identifiers in use are the unverified placeholders.
    static var usesPlaceholderIdentifiers: Bool { catalog.usesPlaceholderIdentifiers }

    static func tier(for productId: String) -> AppConfig.SubscriptionTier {
        switch catalog.tier(forProductID: productId) {
        case .creator: return .creator
        case .pro: return .pro
        // `.studio` has no approved product; unknown ids grant nothing.
        case .free: return .free
        }
    }

    static func productId(for tier: AppConfig.SubscriptionTier) -> String? {
        switch tier {
        case .creator: return creatorMonthly
        case .pro:     return proMonthly
        case .free, .studio: return nil
        }
    }

    private static func monthlyID(for tier: BillingPlanTier) -> String? {
        catalog.plans.first { $0.tier == tier && $0.period == .monthly }?.productID
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - StripeService (StoreKit 2 client)
// ═══════════════════════════════════════════════════════════════════

@MainActor
final class StripeService: ObservableObject {
    static let shared = StripeService()

    /// Tier derived from Apple's current entitlements on this device. This
    /// is a local, best-effort view; the server reconciliation is the
    /// authority once it is configured.
    @Published var currentTier: AppConfig.SubscriptionTier = .free
    @Published var subscriptionStatus: SubscriptionStatus = .none
    @Published var availableProducts: [Product] = []
    @Published var productLoadState: ProductLoadState = .notLoaded
    @Published var isProcessing = false
    @Published var lastError: String?
    /// Set when a purchase or restore succeeded with Apple but the server
    /// reconciliation could not run. Shown to the user; never hidden.
    @Published var reconciliationNotice: String?
    /// The purchase/subscription state machine the plan screens render
    /// (`BillingPlanCatalog.swift`). Fed only from StoreKit results.
    @Published private(set) var billing = BillingState()
    /// Whether the App Store reports this account as eligible for a product's
    /// introductory offer. Absent means unknown; no trial is shown then.
    @Published private(set) var introOfferEligibility: [String: Bool] = [:]

    let catalog = StoreProductID.catalog

    private var transactionListener: Task<Void, Error>?

    private init() {
        // Start listening for StoreKit transactions immediately
        transactionListener = listenForTransactions()
        Task { await loadProducts() }
        Task { await refreshEntitlements() }
    }

    deinit {
        transactionListener?.cancel()
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - StoreKit 2: Load Products
    // ═══════════════════════════════════════════════════════════════

    /// Fetch the two approved monthly products from the App Store. An empty
    /// result means the products do not exist (yet) in App Store Connect.
    func loadProducts() async {
        productLoadState = .loading
        do {
            let products = try await Product.products(for: StoreProductID.allSubscriptions)
            availableProducts = products.sorted { $0.price < $1.price }
            productLoadState = products.isEmpty ? .notConfigured : .loaded
            send(.catalogLoaded(productCount: products.count))
            var eligibility: [String: Bool] = [:]
            for product in products {
                if let subscription = product.subscription {
                    eligibility[product.id] = await subscription.isEligibleForIntroOffer
                }
            }
            introOfferEligibility = eligibility
        } catch {
            availableProducts = []
            productLoadState = .failed(error.localizedDescription)
            lastError = "Could not load subscription plans from the App Store."
            send(.catalogFailed(error.localizedDescription))
        }
    }

    /// Apply one StoreKit fact to the plan state machine.
    func send(_ event: BillingEvent) {
        billing = BillingState.reduce(billing, event)
    }

    /// Introductory free-trial length in days as configured in App Store
    /// Connect, or nil when the product has no free-trial offer.
    func introductoryTrialDays(for product: Product) -> Int? {
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let value = offer.period.value
        switch offer.period.unit {
        case .day: return value
        case .week: return value * 7
        case .month, .year: return nil
        @unknown default: return nil
        }
    }

    /// Plan copy for a loaded product's trial, only when Apple reports eligibility.
    func trialCopy(for product: Product) -> String? {
        BillingCopy.trial(days: introductoryTrialDays(for: product), eligible: introOfferEligibility[product.id] == true)
    }

    /// The catalogue plan a loaded product belongs to.
    func plan(for product: Product) -> BillingPlanDefinition? {
        catalog.plan(forProductID: product.id)
    }

    /// The loaded product for a tier, if App Store Connect has it.
    func product(for tier: AppConfig.SubscriptionTier) -> Product? {
        guard let id = StoreProductID.productId(for: tier) else { return nil }
        return availableProducts.first { $0.id == id }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - StoreKit 2: Purchase Subscription
    // ═══════════════════════════════════════════════════════════════

    /// Purchase a monthly plan via StoreKit 2.
    func subscribe(to tier: AppConfig.SubscriptionTier) async throws {
        guard tier != .free else {
            // Downgrade to free — user must cancel in Settings
            lastError = "To cancel, go to Settings → Subscriptions on your device."
            return
        }

        guard let productId = StoreProductID.productId(for: tier) else {
            throw PaymentError.invalidProduct
        }

        guard let product = availableProducts.first(where: { $0.id == productId }) else {
            throw PaymentError.productNotFound
        }

        try await purchase(product)
    }

    /// Purchase a loaded StoreKit product. The signed-in user's id is attached
    /// as `appAccountToken` so the server can reconcile Apple's transaction
    /// to the account without any client-side claim of entitlement.
    func purchase(_ product: Product) async throws {
        guard StoreProductID.allSubscriptions.contains(product.id) else {
            throw PaymentError.invalidProduct
        }

        guard let userIdString = AuthService.shared.userId,
              let appAccountToken = UUID(uuidString: userIdString) else {
            throw PaymentError.notAuthenticated
        }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }
        send(.purchaseStarted(product.id))

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
        } catch {
            send(.purchaseFailed(error.localizedDescription))
            throw error
        }

        switch result {
        case .success(let verification):
            let transaction: Transaction
            do {
                transaction = try checkVerified(verification)
            } catch {
                send(.purchaseUnverified(error.localizedDescription))
                throw error
            }

            // Local entitlement view from Apple's signed transaction.
            currentTier = StoreProductID.tier(for: transaction.productID)
            subscriptionStatus = .active(ActiveEntitlement(transaction))
            send(.purchaseVerified(await snapshot(for: transaction)))

            // Server reconciliation is the authority for entitlements.
            await attemptReconciliation()

            await transaction.finish()

        case .userCancelled:
            send(.purchaseCancelled)
            throw PaymentError.cancelled

        case .pending:
            // Transaction needs approval (Ask to Buy, etc.)
            subscriptionStatus = .pending
            send(.purchasePending(product.id))
            throw PaymentError.pending

        @unknown default:
            send(.purchaseFailed(PaymentError.unknown.localizedDescription))
            throw PaymentError.unknown
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - StoreKit 2: Restore & Refresh Entitlements
    // ═══════════════════════════════════════════════════════════════

    /// Read current entitlements from StoreKit (call on app launch).
    func refreshEntitlements() async {
        var highest: (tier: AppConfig.SubscriptionTier, entitlement: ActiveEntitlement)?

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                guard transaction.revocationDate == nil else { continue }

                let tier = StoreProductID.tier(for: transaction.productID)
                guard tier != .free else { continue }

                if let current = highest, current.tier.rank >= tier.rank { continue }
                highest = (tier, ActiveEntitlement(transaction))
            } catch {
                print("[StripeService] Invalid entitlement: \(error)")
            }
        }

        if let highest {
            currentTier = highest.tier
            subscriptionStatus = .active(highest.entitlement)
        } else {
            currentTier = .free
            if subscriptionStatus != .pending { subscriptionStatus = .none }
        }

        // The state machine also sees the latest transaction per product, so an
        // expired, revoked or billing-retry plan is reported instead of hidden.
        var snapshots: [BillingEntitlementSnapshot] = []
        for productID in StoreProductID.allSubscriptions {
            guard let latest = await Transaction.latest(for: productID),
                  let transaction = try? checkVerified(latest) else { continue }
            snapshots.append(await snapshot(for: transaction))
        }
        send(.entitlementsRefreshed(snapshots, now: Date()))
    }

    /// Build the state-machine view of one verified transaction from Apple's
    /// subscription status and signed renewal info. Unverified renewal info
    /// leaves `willAutoRenew` unknown rather than guessed.
    private func snapshot(for transaction: Transaction) async -> BillingEntitlementSnapshot {
        var state: BillingRenewalState = .subscribed
        var willAutoRenew: Bool?
        if let status = await transaction.subscriptionStatus {
            switch status.state {
            case .subscribed: state = .subscribed
            case .inGracePeriod: state = .inGracePeriod
            case .inBillingRetryPeriod: state = .inBillingRetry
            case .expired: state = .expired
            case .revoked: state = .revoked
            default: break
            }
            if case .verified(let renewal) = status.renewalInfo {
                willAutoRenew = renewal.willAutoRenew
            }
        }
        if transaction.revocationDate != nil { state = .revoked }
        let plan = catalog.plan(forProductID: transaction.productID)
        return BillingEntitlementSnapshot(
            productID: transaction.productID,
            tier: plan?.tier ?? .free,
            period: plan?.period ?? .monthly,
            transactionID: String(transaction.id),
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            willAutoRenew: willAutoRenew,
            renewalState: state,
            isIntroductoryOffer: transaction.offerType == .introductory)
    }

    /// Restore purchases (user-initiated).
    func restorePurchases() async {
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        do {
            try await AppStore.sync()
        } catch {
            lastError = "Restore could not reach the App Store: \(error.localizedDescription)"
            send(.restoreFailed(error.localizedDescription))
        }
        await refreshEntitlements()
        if case .active = subscriptionStatus {
            await attemptReconciliation()
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Server Entitlement Reconciliation (owner-gated)
    // ═══════════════════════════════════════════════════════════════

    /// Entitlements are granted by the server after it verifies Apple's
    /// signed transaction (App Store Server API / notifications keyed by
    /// `appAccountToken`). That endpoint is not configured in this
    /// repository, so this stub throws instead of pretending to sync.
    /// The former client-side write of `subscription_tier` /
    /// `subscription_status` to the `users` table was removed on purpose:
    /// a client must not assert its own entitlement.
    func reconcileEntitlementsWithServer() async throws {
        throw PaymentError.entitlementReconciliationNotConfigured
    }

    private func attemptReconciliation() async {
        do {
            try await reconcileEntitlementsWithServer()
            reconciliationNotice = nil
            send(.serverVerification(.verified))
        } catch PaymentError.entitlementReconciliationNotConfigured {
            reconciliationNotice = PaymentError.entitlementReconciliationNotConfigured.localizedDescription
            send(.serverVerification(.notConfigured))
        } catch {
            reconciliationNotice = error.localizedDescription
            send(.serverVerification(.failed(error.localizedDescription)))
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Transaction Listener (background)
    // ═══════════════════════════════════════════════════════════════

    /// Listen for transaction updates (renewals, refunds, revocations)
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)

                    // Refresh entitlements on any transaction update
                    await MainActor.run {
                        _ = Task { await self.refreshEntitlements() }
                    }

                    await transaction.finish()
                } catch {
                    print("[StripeService] Transaction update error: \(error)")
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Entitlement Gating
    // ═══════════════════════════════════════════════════════════════

    // The feature-to-tier mapping is owner configuration that has not been
    // published. Until it is, only the always-free Studio is a known answer;
    // every paid gate reports unavailable rather than inventing a policy.
    func hasAccess(to feature: Feature) -> Bool {
        switch feature {
        case .basicStudio: return true
        }
    }

    // Quotas must come from the approved, verified entitlement policy. No
    // historical screenshot count or invented unlimited allowance is a default.
    var maxProjects: Int {
        get throws { throw PaymentError.limitsUnavailable }
    }
    var maxAIQueries: Int {
        get throws { throw PaymentError.limitsUnavailable }
    }

    enum Feature {
        case basicStudio
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Private Helpers
    // ═══════════════════════════════════════════════════════════════

    /// Verify a StoreKit transaction
    nonisolated private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw PaymentError.verificationFailed(error.localizedDescription)
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Product Load State
    enum ProductLoadState: Equatable {
        case notLoaded
        case loading
        /// The App Store returned products for the approved identifiers.
        case loaded
        /// The App Store returned no products: App Store Connect is not configured yet.
        case notConfigured
        case failed(String)
    }

    // MARK: - Active Entitlement (real values from Apple's signed transaction)
    struct ActiveEntitlement: Equatable {
        let transactionID: String
        let productID: String
        let purchaseDate: Date
        /// Present for auto-renewable subscriptions; nil means Apple did not supply one.
        let expirationDate: Date?

        init(_ transaction: Transaction) {
            transactionID = String(transaction.id)
            productID = transaction.productID
            purchaseDate = transaction.purchaseDate
            expirationDate = transaction.expirationDate
        }
    }

    // MARK: - Subscription Status
    enum SubscriptionStatus: Equatable {
        case none
        case active(ActiveEntitlement)
        case pending
    }

    // MARK: - Errors
    enum PaymentError: LocalizedError {
        case notAuthenticated
        case invalidProduct
        case productNotFound
        case cancelled
        case pending
        case unknown
        case verificationFailed(String)
        case limitsUnavailable
        case entitlementReconciliationNotConfigured

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:       return "Sign in before subscribing so the purchase can be linked to your account."
            case .invalidProduct:         return "This plan is not part of the approved catalogue."
            case .productNotFound:        return "This plan is not available from the App Store yet."
            case .cancelled:              return "Purchase cancelled"
            case .pending:                return "Purchase pending approval"
            case .unknown:                return "Unknown error"
            case .verificationFailed(let msg): return "Verification failed: \(msg)"
            case .limitsUnavailable:      return "Subscription limits are unavailable until the entitlement policy is configured and verified."
            case .entitlementReconciliationNotConfigured:
                return "Entitlement reconciliation not configured: the server has not verified this purchase yet. Apple holds your receipt; no account entitlement was changed."
            }
        }
    }
}
