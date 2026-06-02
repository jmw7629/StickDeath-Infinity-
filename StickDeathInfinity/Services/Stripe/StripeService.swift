// ═══════════════════════════════════════════════════════════════════
// StripeService — StoreKit 2 Subscriptions + Stripe Tips/Calls
//
// iOS App Store rules: Digital subscriptions MUST use StoreKit IAP.
// Stripe is used ONLY for:
//   - Creator-to-creator tips (non-digital goods / services)
//   - R3 call billing charges (consumable services)
//   - Web-side payments (not in-app)
//
// Subscription tiers via StoreKit 2:
//   Free / Creator ($4.99/mo) / Pro ($9.99/mo) / Studio ($19.99/mo)
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase
import StoreKit

// MARK: - Product IDs (register these in App Store Connect)
enum StoreProductID {
    static let creatorMonthly = "com.stickdeath.infinity.creator.monthly"
    static let proMonthly     = "com.stickdeath.infinity.pro.monthly"
    static let studioMonthly  = "com.stickdeath.infinity.studio.monthly"

    static let creatorYearly  = "com.stickdeath.infinity.creator.yearly"
    static let proYearly      = "com.stickdeath.infinity.pro.yearly"
    static let studioYearly   = "com.stickdeath.infinity.studio.yearly"

    static let allSubscriptions: [String] = [
        creatorMonthly, proMonthly, studioMonthly,
        creatorYearly, proYearly, studioYearly
    ]

    static func tier(for productId: String) -> AppConfig.SubscriptionTier {
        switch productId {
        case creatorMonthly, creatorYearly: return .creator
        case proMonthly, proYearly:        return .pro
        case studioMonthly, studioYearly:  return .studio
        default:                           return .free
        }
    }

    static func productId(for tier: AppConfig.SubscriptionTier, yearly: Bool = false) -> String? {
        switch (tier, yearly) {
        case (.creator, false): return creatorMonthly
        case (.creator, true):  return creatorYearly
        case (.pro, false):     return proMonthly
        case (.pro, true):      return proYearly
        case (.studio, false):  return studioMonthly
        case (.studio, true):   return studioYearly
        case (.free, _):        return nil
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - StripeService (StoreKit 2 + Stripe hybrid)
// ═══════════════════════════════════════════════════════════════════

@MainActor
final class StripeService: ObservableObject {
    static let shared = StripeService()

    // Subscription state
    @Published var currentTier: AppConfig.SubscriptionTier = .free
    @Published var subscriptionStatus: SubscriptionStatus = .none
    @Published var availableProducts: [Product] = []
    @Published var isProcessing = false
    @Published var lastError: String?

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

    /// Fetch subscription products from App Store Connect
    func loadProducts() async {
        do {
            let products = try await Product.products(for: StoreProductID.allSubscriptions)
            availableProducts = products.sorted { $0.price < $1.price }
        } catch {
            print("[StripeService] Failed to load products: \(error)")
            lastError = "Failed to load subscription plans"
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - StoreKit 2: Purchase Subscription
    // ═══════════════════════════════════════════════════════════════

    /// Purchase a subscription tier via StoreKit 2
    func subscribe(to tier: AppConfig.SubscriptionTier, yearly: Bool = false) async throws {
        guard tier != .free else {
            // Downgrade to free — user must cancel in Settings
            lastError = "To cancel, go to Settings → Subscriptions on your device."
            return
        }

        guard let productId = StoreProductID.productId(for: tier, yearly: yearly) else {
            throw PaymentError.invalidProduct
        }

        guard let product = availableProducts.first(where: { $0.id == productId }) else {
            throw PaymentError.productNotFound
        }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        // StoreKit 2 purchase
        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            // Verify the transaction
            let transaction = try checkVerified(verification)

            // Update entitlements
            currentTier = tier
            subscriptionStatus = .active(String(transaction.id))

            // Sync to Supabase so the server knows
            await syncSubscriptionToSupabase(
                tier: tier,
                transactionId: String(transaction.id),
                productId: product.id,
                status: "active"
            )

            // Finish the transaction
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

    /// Check current entitlements from StoreKit (call on app launch)
    func refreshEntitlements() async {
        var highestTier: AppConfig.SubscriptionTier = .free
        var activeSubId: String?

        // Iterate through current entitlements
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                if transaction.revocationDate == nil {
                    let tier = StoreProductID.tier(for: transaction.productID)
                    if tier.price > highestTier.price {
                        highestTier = tier
                        activeSubId = String(transaction.id)
                    }
                }
            } catch {
                print("[StripeService] Invalid entitlement: \(error)")
            }
        }

        currentTier = highestTier
        if let subId = activeSubId {
            subscriptionStatus = .active(subId)
        } else {
            subscriptionStatus = .none
        }

        // Sync to Supabase
        await syncSubscriptionToSupabase(
            tier: highestTier,
            transactionId: activeSubId,
            productId: nil,
            status: highestTier == .free ? "none" : "active"
        )
    }

    /// Restore purchases (user-initiated)
    func restorePurchases() async {
        isProcessing = true
        defer { isProcessing = false }

        try? await AppStore.sync()
        await refreshEntitlements()
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

    func hasAccess(to feature: Feature) -> Bool {
        switch feature {
        case .basicStudio:          return true
        case .noWatermark:          return currentTier != .free
        case .export1080p:          return currentTier != .free
        case .export4K:             return currentTier == .pro || currentTier == .studio
        case .unlimitedProjects:    return currentTier == .pro || currentTier == .studio
        case .cloudSync:            return currentTier == .pro || currentTier == .studio
        case .collabRooms:          return currentTier == .pro || currentTier == .studio
        case .commercialLicense:    return currentTier == .studio
        case .teamWorkspace:        return currentTier == .studio
        case .apiAccess:            return currentTier == .studio
        case .customBranding:       return currentTier == .studio
        case .prioritySupport:      return currentTier == .pro || currentTier == .studio
        }
    }

    var maxProjects: Int { currentTier.maxProjects }
    var maxAIQueries: Int { currentTier.maxAIQueries }

    enum Feature {
        case basicStudio, noWatermark, export1080p, export4K
        case unlimitedProjects, cloudSync, collabRooms
        case commercialLicense, teamWorkspace, apiAccess
        case customBranding, prioritySupport
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Stripe: Tips (creator-to-creator, non-digital goods)
    // ═══════════════════════════════════════════════════════════════

    /// Send a tip — uses Stripe because tips are person-to-person
    /// payments, not digital content purchases (Apple allows this)
    func sendTip(toUserId: String, amount: Double) async throws {
        guard let fromUserId = AuthService.shared.userId else {
            throw PaymentError.notAuthenticated
        }

        isProcessing = true
        defer { isProcessing = false }

        let amountCents = Int(amount * 100)

        // Record in Supabase (actual Stripe charge via Edge Function)
        try await SupabaseManager.shared.client.from("tips").insert([
            "from_user_id": AnyJSON.string(fromUserId),
            "to_user_id": .string(toUserId),
            "amount_cents": .integer(amountCents),
            "type": .string("tip"),
        ]).execute()
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Stripe: R3 Call Billing (consumable service charges)
    // ═══════════════════════════════════════════════════════════════

    /// Log a call charge — uses Supabase tips table (same as web)
    /// Call billing is a consumable service, not a subscription.
    func chargeForCall(
        calleeId: String,
        durationSeconds: Int,
        rateTier: AppConfig.CallRateTier,
        callType: String = "video",
        spendCap: Double
    ) async throws {
        guard let callerId = AuthService.shared.userId else {
            throw PaymentError.notAuthenticated
        }

        let totalCost = Double(durationSeconds) / 60.0 * rateTier.ratePerMinute
        let amountCents = Int(totalCost * 100)

        try await SupabaseManager.shared.client.from("tips").insert([
            "from_user_id": AnyJSON.string(callerId),
            "to_user_id": .string("platform"),
            "amount_cents": .integer(amountCents),
            "message": .string("Call: \(durationSeconds)s \(callType) @ \(rateTier.displayName)"),
            "type": .string("call_charge"),
        ]).execute()
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Private Helpers
    // ═══════════════════════════════════════════════════════════════

    /// Verify a StoreKit transaction
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw PaymentError.verificationFailed(error.localizedDescription)
        case .verified(let safe):
            return safe
        }
    }

    /// Sync subscription status to Supabase (so server/web knows)
    private func syncSubscriptionToSupabase(
        tier: AppConfig.SubscriptionTier,
        transactionId: String?,
        productId: String?,
        status: String
    ) async {
        guard let userId = AuthService.shared.userId else { return }

        var updates: [String: AnyJSON] = [
            "subscription_tier": .string(tier.rawValue),
            "subscription_status": .string(status),
        ]
        if let txId = transactionId {
            updates["apple_transaction_id"] = .string(txId)
        }
        if let pid = productId {
            updates["apple_product_id"] = .string(pid)
        }

        do {
            try await SupabaseManager.shared.client
                .from("users")
                .update(updates)
                .eq("id", value: userId)
                .execute()
        } catch {
            print("[StripeService] syncSubscriptionToSupabase error: \(error)")
        }
    }

    // MARK: - Subscription Status
    enum SubscriptionStatus: Equatable {
        case none
        case active(String)
        case pending
        case expired(String)
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

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:       return "Not signed in"
            case .invalidProduct:         return "Invalid product"
            case .productNotFound:        return "Product not available"
            case .cancelled:              return "Purchase cancelled"
            case .pending:                return "Purchase pending approval"
            case .unknown:                return "Unknown error"
            case .verificationFailed(let msg): return "Verification failed: \(msg)"
            }
        }
    }
}
