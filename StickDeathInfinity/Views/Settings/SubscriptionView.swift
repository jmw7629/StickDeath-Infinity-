// ═══════════════════════════════════════════════════════════════════
// SubscriptionView — Settings → Subscription
//
// Contract: docs/BILLING_CONTRACT.md (#259)
// - Renders `StripeService.billing` (the StoreKit state machine in
//   BillingPlanCatalog.swift) through `BillingCopy`: plan, renewal or
//   cancellation date, grace/billing retry, pending, revoked, server
//   verification state and Spatter prompt allowance.
// - Prices are Apple's `Product.displayPrice`. Every paid plan has a 3-day
//   free trial (owner decision 2026-10-20); trial copy is shown only when the
//   App Store reports an eligible introductory free-trial offer. During the
//   trial the Studio is unlocked and Spatter is preview-only, which the
//   status card says. Annual plans appear only when the build configuration
//   enables them.
// - Manage/cancel opens Apple's subscription sheet; restore runs AppStore.sync.
// - The server's own record (`sdi_my_entitlement`) is read when the screen
//   opens and shown beside Apple's; a plan billed elsewhere (the website)
//   appears as the server reports it.
// - No simulated purchase, no invented renewal date, no hard-coded price.
// - Presented from Profile → Subscription, Settings → Current Plan and the
//   Spatter upgrade prompts.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import StoreKit

struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @StateObject private var store = StripeService.shared
    @State private var showPurchase = false
    @State private var showManage = false
    @State private var period: BillingPeriod = .monthly
    @State private var selectedProductID: String?
    @State private var purchaseError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    if showPurchase { showPurchase = false }
                    else { dismiss() }
                }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .accessibilityLabel(showPurchase ? "Back to subscription" : "Close")
                Text(showPurchase ? "Choose Plan" : "Subscription")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding()
            .background(Color(hex: "0A0A14"))

            if showPurchase {
                purchaseView
            } else {
                currentPlanView
            }
        }
        .background(Color(hex: "0A0A14"))
        .navigationBarHidden(true)
        .manageSubscriptionsSheet(isPresented: $showManage)
        .onChange(of: showManage) { _, presented in
            // Apple's sheet may have cancelled or changed the plan.
            if !presented { Task { await store.refreshEntitlements() } }
        }
        .task {
            if store.productLoadState == .notLoaded {
                await store.loadProducts()
            }
            await store.refreshEntitlements()
            await store.refreshServerEntitlement()
        }
    }

    // MARK: - Current plan (state machine only)

    private var status: (title: String, detail: String) {
        BillingCopy.status(store.billing, catalog: store.catalog, locale: locale, timeZone: .current)
    }

    private var currentPlan: BillingPlanDefinition? {
        if let entitlement = store.billing.activeEntitlement {
            return store.catalog.plan(forProductID: entitlement.productID)
        }
        if let server = store.currentServerEntitlement, server.tier != .free,
           let plan = store.catalog.plans.first(where: { $0.tier == server.tier }) {
            return plan
        }
        return store.catalog.plans.first { $0.tier == .free }
    }

    var currentPlanView: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard

                if let message = store.billing.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let notice = store.reconciliationNotice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("subscription.server-notice")
                }

                if let error = store.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                if let plan = currentPlan {
                    entitlementList(plan)
                }

                Button(action: { showPurchase = true }) {
                    Text(isSubscribed ? "Change Plan" : "See Plans")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Color.red)
                        .cornerRadius(12)
                }

                if isSubscribed {
                    Button(action: { showManage = true }) {
                        secondaryLabel("Manage or Cancel Subscription")
                    }
                }

                creditsCard

                Button(action: {
                    Task { await store.restorePurchases() }
                }) {
                    secondaryLabel(store.isProcessing ? "Restoring..." : "Restore Purchases")
                }
                .disabled(store.isProcessing)

                Text(BillingCopy.manageNote)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    private var isSubscribed: Bool { store.billing.activeEntitlement != nil }

    // MARK: - Spatter credits (owner decision 2026-10-15)

    private var creditsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spatter credits")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .accessibilityAddTraits(.isHeader)
            Text(BillingCopy.creditsNote)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if store.creditPacks.isEmpty {
                Text(BillingCopy.creditsNotConfigured)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.creditPacks, id: \.id) { pack in
                    Button(action: { Task { await buyCredits(pack) } }) {
                        HStack {
                            Text(pack.displayName).foregroundColor(.white)
                            Spacer()
                            Text(pack.displayPrice).foregroundColor(.white).bold()
                        }
                        .font(.system(size: 13))
                        .padding(12)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(10)
                    }
                    .disabled(store.isProcessing)
                    .accessibilityHint(Text("Buys this Spatter credit pack from Apple"))
                }
            }
            if let notice = store.creditNotice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    private func buyCredits(_ pack: Product) async {
        do { try await store.purchaseCredits(pack) }
        catch StripeService.PaymentError.cancelled { }
        catch StripeService.PaymentError.pending { }
        catch { store.creditNotice = error.localizedDescription }
    }

    private func secondaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(Color.white.opacity(0.06))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1)))
    }

    private var statusCard: some View {
        VStack(spacing: 8) {
            Text(status.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            Text(status.detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let entitlement = store.billing.activeEntitlement {
                if store.billing.inTrial {
                    Text(BillingCopy.spatterTrialNote)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let product = store.availableProducts.first(where: { $0.id == entitlement.productID }) {
                    Text(BillingCopy.price(product.displayPrice, period: entitlement.period))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Text(BillingCopy.server(store.billing.server))
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                Text("Transaction \(entitlement.transactionID)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if let server = store.currentServerEntitlement, server.tier != .free {
                // A plan the server applied from a verified provider event that this
                // device's Apple account does not hold (for example a website plan).
                Text(serverPlanLine(server))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("subscription.server-plan")
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }

    private func serverPlanLine(_ server: ServerEntitlement) -> String {
        let source: String
        switch server.provider {
        case "stripe": source = "billed through the StickDeath website"
        case "apple": source = "billed by Apple to another Apple account or device"
        default: source = "billed by a provider the server verified"
        }
        var line = "The StickDeath server reports the \(server.tier.rawValue.capitalized) plan, \(source)."
        if let end = server.paidThrough {
            let day = BillingCopy.date(end, locale: locale, timeZone: .current)
            line += server.cancelAtPeriodEnd ? " Access ends on \(day)." : " Paid through \(day)."
        }
        if server.status == "grace" || server.status == "past_due" {
            line += " The provider is retrying a payment."
        }
        if server.inTrial {
            line += " " + BillingCopy.spatterTrialNote
        }
        return line
    }

    private func entitlementList(_ plan: BillingPlanDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your plan includes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            ForEach(plan.entitlements, id: \.text) { entitlement in
                entitlementRow(entitlement)
            }
            // The server has no prompt count to report yet, so nothing is invented.
            Text(BillingCopy.prompts(plan.promptAllowance, remaining: nil))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if plan.entitlements.contains(where: { !$0.isLive }) {
                Text("* " + BillingCopy.pendingEntitlementNote)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    private func entitlementRow(_ entitlement: BillingEntitlement) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: entitlement.isLive ? "checkmark" : "clock")
                .font(.system(size: 10))
                .foregroundColor(entitlement.isLive ? .green : .secondary)
                .accessibilityHidden(true)
            Text(entitlement.text + (entitlement.isLive ? "" : " *"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entitlement.isLive ? entitlement.text : "\(entitlement.text), pending")
    }

    // MARK: - Plans (real StoreKit products only)

    private var periodProducts: [Product] {
        let ids = Set(store.catalog.plans(for: period).compactMap(\.productID))
        return store.availableProducts.filter { ids.contains($0.id) && store.plan(for: $0)?.period == period }
    }

    var purchaseView: some View {
        ScrollView {
            VStack(spacing: 10) {
                switch store.productLoadState {
                case .notLoaded, .loading:
                    ProgressView()
                        .tint(.white)
                        .padding(.vertical, 24)
                    Text("Loading plans from the App Store...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                case .notConfigured:
                    notConfiguredCard(detail: "The App Store has no products for this app yet. Plans appear here once they are created in App Store Connect.")

                case .failed(let message):
                    notConfiguredCard(detail: "The App Store could not be reached: \(message)")
                    Button("Try Again") { Task { await store.loadProducts() } }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)

                case .loaded:
                    if store.catalog.periods.count > 1 {
                        Picker("Billing period", selection: $period) {
                            Text("Monthly").tag(BillingPeriod.monthly)
                            Text("Annual").tag(BillingPeriod.annual)
                        }
                        .pickerStyle(.segmented)
                    }

                    ForEach(periodProducts, id: \.id) { product in
                        productRow(product)
                    }

                    if let error = purchaseError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: { Task { await purchaseSelected() } }) {
                        Text(store.isProcessing ? "Waiting for Apple..." : subscribeLabel)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Color.red)
                            .cornerRadius(12)
                            .opacity(store.isProcessing || selectedProduct == nil ? 0.6 : 1.0)
                    }
                    .disabled(store.isProcessing || selectedProduct == nil || !store.billing.canStartPurchase)
                }

                VStack(spacing: 2) {
                    Text("Payment is processed by Apple via StoreKit. The price Apple shows at checkout is the price charged.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Subscriptions renew automatically until cancelled in Apple subscription settings.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
            }
            .padding()
        }
    }

    private var selectedProduct: Product? {
        guard let id = selectedProductID else { return nil }
        return periodProducts.first { $0.id == id }
    }

    private var subscribeLabel: String {
        guard let product = selectedProduct else { return "Select a plan" }
        return "Subscribe — " + BillingCopy.price(product.displayPrice, period: period)
    }

    private func productRow(_ product: Product) -> some View {
        let isSelected = selectedProductID == product.id
        let plan = store.plan(for: product)
        return Button(action: { selectedProductID = product.id }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(plan.map(BillingCopy.planTitle) ?? product.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(BillingCopy.price(product.displayPrice, period: period))
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(.white)
                }
                if let trial = store.trialCopy(for: product) {
                    Text(trial)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                }
                if let plan {
                    ForEach(plan.entitlements, id: \.text) { entitlementRow($0) }
                }
            }
            .padding()
            .background(isSelected ? Color.red.opacity(0.12) : Color.white.opacity(0.04))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.red : Color.white.opacity(0.06), lineWidth: 2)
            )
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func notConfiguredCard(detail: String) -> some View {
        VStack(spacing: 8) {
            Text("Plans are not configured yet")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))
    }

    private func purchaseSelected() async {
        guard let product = selectedProduct else { return }
        purchaseError = nil
        do {
            try await store.purchase(product)
            showPurchase = false
        } catch StripeService.PaymentError.cancelled {
            // User backed out of Apple's sheet; nothing to report.
        } catch StripeService.PaymentError.pending {
            // Ask to Buy: the status card explains it; nothing was billed.
            showPurchase = false
        } catch {
            purchaseError = error.localizedDescription
        }
    }
}
