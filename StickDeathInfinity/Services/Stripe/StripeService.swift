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
//   `users` table. `reconcileEntitlementsWithServer()` reads the server's
//   record (`sdi_my_entitlement`) and compares it with Apple's.
// - No free trial is offered (owner decision 2026-10-15): no trial copy is
//   produced even if App Store Connect reports an introductory offer.
// - Call billing and tips were removed: calls are retired scope and tips
//   are not in the current contract. The historical name "StripeService"
//   is kept only because this file is referenced by the Xcode project;
//   no Stripe API is called from the client.
// ═══════════════════════════════════════════════════════════════════

import Combine
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
    @Published var currentTier: AppConfig.SubscriptionTier = .free { didSet { applyStudioLimits() } }
    @Published var subscriptionStatus: SubscriptionStatus = .none
    @Published var availableProducts: [Product] = []
    @Published var productLoadState: ProductLoadState = .notLoaded { didSet { applyStudioLimits() } }
    @Published var isProcessing = false
    @Published var lastError: String?
    /// Set when a purchase or restore succeeded with Apple but the server
    /// reconciliation could not run. Shown to the user; never hidden.
    @Published var reconciliationNotice: String?
    /// The purchase/subscription state machine the plan screens render
    /// (`BillingPlanCatalog.swift`). Fed only from StoreKit results.
    @Published private(set) var billing = BillingState()
    /// The server's entitlement for the signed-in account (`sdi_my_entitlement`),
    /// read after purchase, restore and when Plans opens. Nil until read.
    @Published private(set) var serverEntitlement: ServerEntitlement?
    /// The account `serverEntitlement` belongs to; a different account ignores it.
    private var serverEntitlementAccount: String?
    /// Loaded Spatter credit packs (consumables), cheapest first. Empty until
    /// both pack ids are configured and App Store Connect has the products.
    @Published private(set) var creditPacks: [Product] = []
    /// Honest status of the last credit purchase; shown under the packs.
    @Published var creditNotice: String?

    /// Sends Apple's signed transaction (JWS) for a credit pack to the StickDeath
    /// server, which verifies it and grants the credits exactly once. Returns the
    /// new balance when the server reports it. Nil means the grant endpoint is not
    /// configured: the transaction then stays unfinished so StoreKit redelivers it
    /// and nothing is lost.
    var creditGrant: ((_ signedTransaction: String, _ productID: String) async throws -> Int?)?

    let catalog = StoreProductID.catalog

    /// Free-plan Studio limits (owner decision 2026-10-15) apply only once the
    /// App Store has loaded real plans, so nobody is locked out of a feature
    /// they cannot buy. Paid tiers are unrestricted.
    private func applyStudioLimits() {
        let storeTier: BillingPlanTier
        switch currentTier {
        case .free: storeTier = .free
        case .creator: storeTier = .creator
        case .pro, .studio: storeTier = .pro
        }
        // A plan the server applied from a verified provider event (for example a
        // website subscription) counts as well; the higher tier wins.
        let serverTier = ServerEntitlementReconciliation.grantedTier(currentServerEntitlement)
        let tier = serverTier.rank > storeTier.rank ? serverTier : storeTier
        let loaded: Bool
        if case .loaded = productLoadState { loaded = true } else { loaded = false }
        let enforcing = StudioPlanLimits.enforcing(catalog: catalog, storeLoaded: loaded)
        StudioPlanLimits.current = StudioPlanLimits.effective(tier: tier, enforcing: enforcing)
    }

    private var transactionListener: Task<Void, Error>?
    private var accountObserver: AnyCancellable?

    private init() {
        // Start listening for StoreKit transactions immediately
        transactionListener = listenForTransactions()
        Task { await loadProducts() }
        Task { await refreshEntitlements() }
        // Studio limits follow the signed-in account: a server plan read for one
        // account never applies to the next, and a plan billed elsewhere (the
        // website) applies from sign-in, not only after Plans is opened. The read
        // is silent; Plans still shows its own verification state.
        accountObserver = AuthService.shared.$state.combineLatest(AuthService.shared.$currentUser.map { $0?.id })
            .map { state, user in state == .authenticated ? user : nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyStudioLimits()
                Task { [weak self] in _ = try? await self?.reconcileEntitlementsWithServer() }
            }
    }

    /// Retry credit grants Apple delivered but the server has not confirmed yet.
    /// Call after `creditGrant` is configured (for example after sign-in).
    func retryUnfinishedCreditGrants() async {
        for await result in Transaction.unfinished {
            guard let transaction = try? checkVerified(result), catalog.isCreditPack(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            await grantCredits(transaction, signed: result.jwsRepresentation)
        }
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
        } catch {
            availableProducts = []
            productLoadState = .failed(error.localizedDescription)
            lastError = "Could not load subscription plans from the App Store."
            send(.catalogFailed(error.localizedDescription))
        }
        await loadCreditPacks()
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Spatter credits (consumables)
    // ═══════════════════════════════════════════════════════════════

    /// Load the credit packs. Placeholder ids are never requested.
    func loadCreditPacks() async {
        guard catalog.creditPacksConfigured else { creditPacks = []; return }
        do {
            let products = try await Product.products(for: catalog.creditPackProductIDs)
            creditPacks = products.filter { $0.type == .consumable }.sorted { $0.price < $1.price }
        } catch {
            creditPacks = []
            creditNotice = "Could not load Spatter credit packs from the App Store."
        }
    }

    /// Buy one credit pack. Credits count only after the server confirms the grant.
    func purchaseCredits(_ product: Product) async throws {
        guard catalog.isCreditPack(product.id), catalog.creditPacksConfigured else { throw PaymentError.invalidProduct }
        guard let userIdString = AuthService.shared.userId, let appAccountToken = UUID(uuidString: userIdString) else {
            throw PaymentError.notAuthenticated
        }
        isProcessing = true
        creditNotice = nil
        defer { isProcessing = false }
        let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await grantCredits(transaction, signed: verification.jwsRepresentation)
        case .userCancelled:
            throw PaymentError.cancelled
        case .pending:
            creditNotice = "Apple is waiting for approval. Credits are added when Apple confirms the purchase."
            throw PaymentError.pending
        @unknown default:
            throw PaymentError.unknown
        }
    }

    /// Finish a credit transaction only after the server granted it.
    private func grantCredits(_ transaction: Transaction, signed: String) async {
        guard let creditGrant else {
            creditNotice = "Purchase received. Credits are added once the StickDeath server can confirm it; the purchase is kept until then."
            return
        }
        do {
            let balance = try await creditGrant(signed, transaction.productID)
            await transaction.finish()
            creditNotice = "Credits added. " + BillingCopy.credits(balance)
        } catch {
            creditNotice = "Purchase received, but the server could not confirm it yet (\(error.localizedDescription)). It will be retried; nothing is lost."
        }
    }

    /// Apply one StoreKit fact to the plan state machine.
    func send(_ event: BillingEvent) {
        billing = BillingState.reduce(billing, event)
    }

    /// No plan offers a free trial (owner decision 2026-10-15), so no trial copy
    /// is shown even if App Store Connect reports an introductory offer. Kept as
    /// a function so existing plan screens compile; it always answers nil.
    func trialCopy(for product: Product) -> String? { nil }

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
    /// signed transaction (App Store Server Notifications keyed by
    /// `appAccountToken`) or a Stripe webhook; see backend/sql/billing.sql.
    /// This reads that server record with `sdi_my_entitlement` for the
    /// signed-in account. It never writes a tier: the former client-side
    /// write of `subscription_tier` / `subscription_status` to the `users`
    /// table was removed on purpose, because a client must not assert its own
    /// entitlement. Throws `CommunityError.notConfigured` without a
    /// validated backend configuration, `.signedOut` without a session and
    /// `.transport` when the server cannot be reached.
    @discardableResult
    func reconcileEntitlementsWithServer() async throws -> ServerEntitlement {
        guard CommunityServices.isConfigured else { throw CommunityError.notConfigured }
        let account = AuthService.shared.userId
        guard AuthService.shared.isAuthenticated, account != nil else { throw CommunityError.signedOut }
        let entitlement = try await ServerEntitlementClient(gateway: CommunityServices.gateway).current()
        guard AuthService.shared.userId == account else { throw CommunityError.stale }
        serverEntitlement = entitlement
        serverEntitlementAccount = account
        applyStudioLimits()
        return entitlement
    }

    /// The server record for the account signed in now, if one was read.
    var currentServerEntitlement: ServerEntitlement? {
        guard let account = serverEntitlementAccount, account == AuthService.shared.userId else { return nil }
        return serverEntitlement
    }

    /// Reads the server's record when Plans opens. Unlike a purchase or restore it
    /// raises no notice for an account that has nothing to reconcile.
    func refreshServerEntitlement() async {
        guard AuthService.shared.isAuthenticated else { return }
        await attemptReconciliation(quietWhenFree: true)
    }

    private func attemptReconciliation(quietWhenFree: Bool = false) async {
        let storeTier = catalog.plan(forProductID: billing.activeEntitlement?.productID ?? "")?.tier ?? .free
        let verification: BillingServerVerification
        do {
            let server = try await reconcileEntitlementsWithServer()
            verification = ServerEntitlementReconciliation.verification(storeTier: storeTier, server: server)
        } catch {
            verification = ServerEntitlementReconciliation.verification(for: error)
        }
        send(.serverVerification(verification))
        switch verification {
        case .verified:
            reconciliationNotice = nil
        case .deferred, .failed:
            reconciliationNotice = (quietWhenFree && storeTier == .free) ? nil : BillingCopy.server(verification)
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

                    // Credit packs finish only after the server grants them.
                    if StoreProductID.catalog.isCreditPack(transaction.productID) {
                        if transaction.revocationDate == nil {
                            await self.grantCredits(transaction, signed: result.jwsRepresentation)
                        } else {
                            await transaction.finish()
                        }
                        continue
                    }

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
                return "The StickDeath server is not configured in this build, so it has not verified this purchase. Apple holds your receipt; no account entitlement was changed."
            }
        }
    }
}
