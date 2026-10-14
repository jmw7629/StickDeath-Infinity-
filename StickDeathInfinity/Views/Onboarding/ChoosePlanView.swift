// ═══════════════════════════════════════════════════════════════════
// ChoosePlanView — Subscription plan selection (onboarding)
//
// Contract: docs/BILLING_CONTRACT.md
// - Two monthly plans only (USD 4.99 and 9.99 as configured in App Store
//   Connect). Prices come from the loaded StoreKit `Product`; nothing here
//   states a price. No annual plan, no third tier.
// - Feature pills name only what the app really does today. Paid-plan
//   extras are owner configuration and are labelled as pending.
// - "Start Free →" always continues without a purchase. A failed purchase
//   never advances as if it succeeded.
// - This view is compiled but not mounted anywhere yet.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import StoreKit

struct ChoosePlanView: View {
    let onSelected: () -> Void

    @StateObject private var stripe = StripeService.shared
    @State private var selectedTier: AppConfig.SubscriptionTier? = nil
    @State private var loading = false
    @State private var errorMessage: String?

    /// The monthly paid plans from the one billing configuration
    /// (`BillingPlanCatalog`). Entitlement text comes from there; features the
    /// server does not enforce yet carry a pending marker. No plan is marked
    /// "POPULAR": there is no verified purchase data behind such a claim.
    private var plans: [PlanInfo] {
        stripe.catalog.plans(for: .monthly).compactMap { plan -> PlanInfo? in
            let tier: AppConfig.SubscriptionTier
            switch plan.tier {
            case .creator: tier = .creator
            case .pro: tier = .pro
            case .free: return nil
            }
            return PlanInfo(tier: tier, name: plan.name,
                            features: plan.entitlements.map { $0.isLive ? $0.text : $0.text + " *" }
                                + [BillingCopy.prompts(plan.promptAllowance, remaining: nil)],
                            color: Color(hex: "#DC2626"), popular: false)
        }
    }

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 0) {
                    Text("💀")
                        .font(.system(size: 36))
                        .padding(.top, 24)

                    Text("Choose Your Plan")
                        .font(.specialElite(22))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .tracking(1)
                        .padding(.top, 12)

                    Text("Two monthly plans, billed by Apple")
                        .font(.specialElite(14))
                        .foregroundColor(.sdTextSecondary)
                        .padding(.top, 8)
                }
                .padding(.bottom, 24)

                // Plan cards (vertical)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(plans) { plan in
                            PlanCardRow(
                                plan: plan,
                                product: stripe.product(for: plan.tier),
                                trial: stripe.product(for: plan.tier).flatMap { stripe.trialCopy(for: $0) },
                                isSelected: selectedTier == plan.tier,
                                onSelect: { selectedTier = plan.tier }
                            )
                        }

                        availabilityNotice

                        Text("* " + BillingCopy.pendingEntitlementNote + " Subscriptions renew monthly until cancelled in Apple subscription settings.")
                            .font(.specialElite(10))
                            .foregroundColor(.sdTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                }

                // CTA section
                VStack(spacing: 12) {
                    if let message = errorMessage {
                        Text(message)
                            .font(.specialElite(12))
                            .foregroundColor(Color(hex: "#F87171"))
                            .multilineTextAlignment(.center)
                    }

                    if let tier = selectedTier, let plan = plans.first(where: { $0.tier == tier }) {
                        let product = stripe.product(for: tier)
                        Button {
                            handleSelect(tier)
                        } label: {
                            Text(loading
                                 ? "Waiting for Apple..."
                                 : ctaTitle(plan: plan, product: product))
                                .font(.specialElite(16))
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    (loading || product == nil)
                                        ? Color(hex: "#DC2626").opacity(0.5)
                                        : Color(hex: "#DC2626")
                                )
                                .cornerRadius(12)
                        }
                        .disabled(loading || product == nil)
                    }

                    // Continue without a subscription
                    Button {
                        onSelected()
                    } label: {
                        Text("Start Free →")
                            .font(.specialElite(14))
                            .foregroundColor(.sdTextSecondary)
                            .padding(.vertical, 12)
                    }
                    .disabled(loading)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
        }
        .task {
            if stripe.productLoadState == .notLoaded {
                await stripe.loadProducts()
            }
        }
    }

    @ViewBuilder
    private var availabilityNotice: some View {
        switch stripe.productLoadState {
        case .notLoaded, .loading:
            Text("Loading prices from the App Store...")
                .font(.specialElite(11))
                .foregroundColor(.sdTextSecondary)
                .padding(.top, 4)
        case .notConfigured:
            Text("Plans are not configured in App Store Connect yet. You can start free now.")
                .font(.specialElite(11))
                .foregroundColor(.sdTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        case .failed(let message):
            Text("The App Store could not be reached: \(message)")
                .font(.specialElite(11))
                .foregroundColor(.sdTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        case .loaded:
            EmptyView()
        }
    }

    private func ctaTitle(plan: PlanInfo, product: Product?) -> String {
        guard let product else { return "\(plan.name) is not available yet" }
        return "Start \(plan.name) — " + BillingCopy.price(product.displayPrice, period: .monthly)
    }

    private func handleSelect(_ tier: AppConfig.SubscriptionTier) {
        errorMessage = nil
        loading = true
        Task {
            defer { loading = false }
            do {
                try await stripe.subscribe(to: tier)
                onSelected()
            } catch StripeService.PaymentError.cancelled {
                // User dismissed Apple's sheet; stay on this screen.
            } catch {
                // Do not advance as if the purchase succeeded.
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Plan Info Model
private struct PlanInfo: Identifiable {
    let tier: AppConfig.SubscriptionTier
    let name: String
    let features: [String]
    let color: Color
    let popular: Bool

    var id: String { tier.rawValue }
}

// MARK: - Plan Card Row
private struct PlanCardRow: View {
    let plan: PlanInfo
    /// The loaded StoreKit product, if App Store Connect has one for this plan.
    let product: Product?
    /// Trial copy, only when the App Store reports an eligible free-trial offer.
    let trial: String?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                // Name + Price row
                HStack(alignment: .firstTextBaseline) {
                    Text(plan.name)
                        .font(.specialElite(16))
                        .fontWeight(.bold)
                        .foregroundColor(plan.color)

                    Spacer()

                    Text(BillingCopy.price(product?.displayPrice, period: .monthly))
                        .font(.specialElite(product == nil ? 11 : 16))
                        .fontWeight(product == nil ? .regular : .bold)
                        .foregroundColor(product == nil ? Color.sdTextSecondary : Color.white)
                }

                if let trial {
                    Text(trial)
                        .font(.specialElite(11))
                        .foregroundColor(.green)
                }

                // Feature tags (wrapped)
                FlowLayout(spacing: 4) {
                    ForEach(plan.features, id: \.self) { feature in
                        Text(feature)
                            .font(.specialElite(11))
                            .foregroundColor(.sdTextSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: "#1E1E1E"))
                            .cornerRadius(4)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .background(Color(hex: "#141414"))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? Color(hex: "#DC2626") : Color(hex: "#2A2A2A"),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if plan.popular {
                    Text("POPULAR")
                        .font(.specialElite(10))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color(hex: "#DC2626"))
                        .cornerRadius(0)
                        .clipShape(PopularBadgeShape())
                        .offset(y: -1)
                        .padding(.trailing, 16)
                }
            }
        }
    }
}

// Popular badge shape: flat top, rounded bottom
private struct PopularBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 6
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - r))
        path.addQuadCurve(to: CGPoint(x: rect.width - r, y: rect.height),
                          control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: r, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.height - r),
                          control: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}
