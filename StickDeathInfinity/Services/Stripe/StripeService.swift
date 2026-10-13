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
// PLACEHOLDERS. The owner must create two monthly auto-renewable
// subscriptions in App Store Connect and either keep these identifiers or
// override them from the build configuration (Info.plist keys
// `SDI_STOREKIT_PLAN_4_99_PRODUCT_ID` and `SDI_STOREKIT_PLAN_9_99_PRODUCT_ID`,
// following the existing `$(VAR)` xcconfig pattern). Until App Store Connect
// has matching products, `Product.products(for:)` returns nothing and the UI
// shows an honest "not configured" state.
enum StoreProductID {
    /// Info.plist key for the USD 4.99/month plan identifier.
    static let plan499InfoKey = "SDI_STOREKIT_PLAN_4_99_PRODUCT_ID"
    /// Info.plist key for the USD 9.99/month plan identifier.
    static let plan999InfoKey = "SDI_STOREKIT_PLAN_9_99_PRODUCT_ID"

    /// Placeholder identifier for the USD 4.99/month plan (owner must confirm in App Store Connect).
    static let placeholderCreatorMonthly = "com.stickdeath.infinity.creator.monthly"
    /// Placeholder identifier for the USD 9.99/month plan (owner must confirm in App Store Connect).
    static let placeholderProMonthly = "com.stickdeath.infinity.pro.monthly"

    /// USD 4.99/month plan — maps to `AppConfig.SubscriptionTier.creator`.
    static var creatorMonthly: String {
        configured(plan499InfoKey) ?? placeholderCreatorMonthly
    }

    /// USD 9.99/month plan — maps to `AppConfig.SubscriptionTier.pro`.
    static var proMonthly: String {
        configured(plan999InfoKey) ?? placeholderProMonthly
    }

    // TODO(owner): Annual plans. No annual product identifiers or prices are
    // configured. Adding one requires the owner's explicit annual amount and
    // entitlement decision plus matching App Store Connect products. Do not
    // add an identifier here without that configuration.

    /// The complete approved catalogue: two monthly plans, nothing else.
    static var allSubscriptions: [String] { [creatorMonthly, proMonthly] }

    /// Whether the identifiers in use are the unverified placeholders.
    static var usesPlaceholderIdentifiers: Bool {
        configured(plan499InfoKey) == nil || configured(plan999InfoKey) == nil
    }

    static func tier(for productId: String) -> AppConfig.SubscriptionTier {
        if productId == creatorMonthly { return .creator }
        if productId == proMonthly { return .pro }
        // `.studio` has no approved product; unknown ids grant nothing.
        return .free
    }

    static func productId(for tier: AppConfig.SubscriptionTier) -> String? {
        switch tier {
        case .creator: return creatorMonthly
        case .pro:     return proMonthly
        case .free, .studio: return nil
        }
    }

    private static func configured(_ key: String) -> String? {
        guard let raw = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unexpanded `$(VAR)` build settings are not configuration.
        guard !trimmed.isEmpty, !trimmed.contains("$("), !trimmed.contains("${") else { return nil }
        return trimmed
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
        } catch {
            availableProducts = []
            productLoadState = .failed(error.localizedDescription)
            lastError = "Could not load subscription plans from the App Store."
        }
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

        let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)

            // Local entitlement view from Apple's signed transaction.
            currentTier = StoreProductID.tier(for: transaction.productID)
            subscriptionStatus = .active(ActiveEntitlement(transaction))

            // Server reconciliation is the authority for entitlements.
            await attemptReconciliation()

            await transaction.finish()

        case .userCancelled:
            throw PaymentError.cancelled

        case .pending:
            // Transaction needs approval (Ask to Buy, etc.)
            subscriptionStatus = .pending
            throw PaymentError.pending

        @unknown default:
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
            subscriptionStatus = .none
        }
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
        } catch {
            reconciliationNotice = error.localizedDescription
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
