// ═══════════════════════════════════════════════════════════════════
// SubscriptionView — Settings → Subscription
//
// Contract: docs/BILLING_CONTRACT.md
// - Shows only real StoreKit data: product display prices once loaded,
//   and the current entitlement from Apple's signed transaction.
// - No simulated purchase, no invented renewal date, no hard-coded price.
// - This view is compiled but not mounted anywhere yet.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import StoreKit

struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = StripeService.shared
    @State private var showPurchase = false
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
                Text(showPurchase ? "Choose Plan" : "Subscription")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
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
        .task {
            if store.productLoadState == .notLoaded {
                await store.loadProducts()
            }
            await store.refreshEntitlements()
        }
    }

    // MARK: - Current plan (real entitlement only)

    var currentPlanView: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard

                if let notice = store.reconciliationNotice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }

                if let error = store.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
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

                Button(action: {
                    Task { await store.restorePurchases() }
                }) {
                    Text(store.isProcessing ? "Restoring..." : "Restore Purchases")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1)))
                }
                .disabled(store.isProcessing)

                Text("Billed by Apple through the App Store. Manage or cancel in Settings → Apple ID → Subscriptions. Projects stay on this device.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    private var isSubscribed: Bool {
        if case .active = store.subscriptionStatus { return true }
        return false
    }

    @ViewBuilder
    private var statusCard: some View {
        switch store.subscriptionStatus {
        case .active(let entitlement):
            VStack(spacing: 8) {
                Text(planName(for: entitlement.productID))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text("Active")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)
                if let product = store.availableProducts.first(where: { $0.id == entitlement.productID }) {
                    Text("\(product.displayPrice)/month")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Text("Purchased \(entitlement.purchaseDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if let expiration = entitlement.expirationDate {
                    Text("Current period ends \(expiration.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Text("Transaction \(entitlement.transactionID)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))

        case .pending:
            infoCard(title: "Purchase pending",
                     detail: "Apple is waiting for approval (for example Ask to Buy). The plan activates when Apple confirms it.")

        case .none:
            infoCard(title: "No active subscription",
                     detail: "You are using the free Studio. Nothing is billed.")
        }
    }

    private func infoCard(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
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

    private func planName(for productID: String) -> String {
        if let product = store.availableProducts.first(where: { $0.id == productID }) {
            return product.displayName.isEmpty ? productID : product.displayName
        }
        switch StoreProductID.tier(for: productID) {
        case .creator: return "Creator (monthly)"
        case .pro:     return "Pro (monthly)"
        case .free, .studio: return productID
        }
    }

    // MARK: - Plans (real StoreKit products only)

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
                    ForEach(store.availableProducts, id: \.id) { product in
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
                    .disabled(store.isProcessing || selectedProduct == nil)
                }

                VStack(spacing: 2) {
                    Text("Payment is processed by Apple via StoreKit. The price Apple shows at checkout is the price charged.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Cancel anytime in Settings → Apple ID → Subscriptions")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
            .padding()
        }
    }

    private var selectedProduct: Product? {
        guard let id = selectedProductID else { return nil }
        return store.availableProducts.first { $0.id == id }
    }

    private var subscribeLabel: String {
        guard let product = selectedProduct else { return "Select a plan" }
        return "Subscribe — \(product.displayPrice)/month"
    }

    private func productRow(_ product: Product) -> some View {
        let isSelected = selectedProductID == product.id
        return Button(action: { selectedProductID = product.id }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName.isEmpty ? product.id : product.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    if !product.description.isEmpty {
                        Text(product.description)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(product.displayPrice)
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundColor(.white)
                    Text("/month")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
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
        } catch {
            purchaseError = error.localizedDescription
        }
    }
}
