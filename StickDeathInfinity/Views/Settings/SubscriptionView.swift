import SwiftUI
// NOTE: In production, import StoreKit for real Apple payment integration
// import StoreKit

struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showPurchase = false
    @State private var selectedPlan = "pro_monthly"
    @State private var purchasing = false
    @State private var purchased = false

    struct Plan: Identifiable {
        let id: String
        let name: String
        let price: String
        let period: String
        let savings: String
        let popular: Bool
    }

    let plans: [Plan] = [
        Plan(id: "pro_monthly", name: "Pro Monthly", price: "$9.99", period: "/month", savings: "", popular: true),
        Plan(id: "pro_annual", name: "Pro Annual", price: "$79.99", period: "/year", savings: "Save 33%", popular: false),
        Plan(id: "studio_monthly", name: "Studio", price: "$19.99", period: "/month", savings: "All features", popular: false),
    ]

    let features = [
        "Unlimited projects & frames",
        "4K HD export (MP4, GIF, PNG)",
        "All brushes, tools & effects",
        "Spatter AI unlimited queries",
        "Live collab rooms",
        "Priority support",
        "No watermark",
        "Cloud backup (device-first storage)",
    ]

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
    }

    var currentPlanView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("👑").font(.system(size: 40))
                Text("Pro Plan")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text("$9.99/month · Renews Jun 15")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("✓ Active")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["Unlimited projects", "HD export", "All brushes & tools", "Spatter AI unlimited", "Priority support", "No watermark"], id: \.self) { feature in
                        HStack(spacing: 8) {
                            Text("✓").foregroundColor(.green)
                            Text(feature)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color.white.opacity(0.04))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))

                Button(action: { showPurchase = true }) {
                    Text("Change Plan")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Color.red)
                        .cornerRadius(12)
                }

                Button(action: {}) {
                    Text("Restore Purchases")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1)))
                }

                Text("Managed via Apple StoreKit · All data stored on device")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }

    var purchaseView: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(plans) { plan in
                    Button(action: { selectedPlan = plan.id }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(plan.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                if !plan.savings.isEmpty {
                                    Text(plan.savings)
                                        .font(.system(size: 10))
                                        .foregroundColor(.green)
                                }
                            }
                            Spacer()
                            HStack(spacing: 0) {
                                Text(plan.price)
                                    .font(.system(size: 20, weight: .heavy))
                                    .foregroundColor(.white)
                                Text(plan.period)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background(selectedPlan == plan.id ? Color.red.opacity(0.12) : Color.white.opacity(0.04))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedPlan == plan.id ? Color.red : Color.white.opacity(0.06), lineWidth: 2)
                        )
                        .overlay(alignment: .topTrailing) {
                            if plan.popular {
                                Text("POPULAR")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.red)
                                    .cornerRadius(8)
                                    .offset(x: 0, y: -8)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("INCLUDED")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .tracking(2)
                    ForEach(features, id: \.self) { feature in
                        HStack(spacing: 8) {
                            Text("✓").foregroundColor(.green).font(.system(size: 12))
                            Text(feature).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color.white.opacity(0.04))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))
                .padding(.top, 8)

                // Purchase button — in production uses StoreKit Product.purchase()
                Button(action: {
                    purchasing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        purchasing = false
                        purchased = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showPurchase = false
                            purchased = false
                        }
                    }
                }) {
                    Text(purchasing ? "Processing..." : (purchased ? "✓ Subscribed!" : "Subscribe — \(plans.first { $0.id == selectedPlan }?.price ?? "")\(plans.first { $0.id == selectedPlan }?.period ?? "")"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(purchased ? Color.green : Color.red)
                        .cornerRadius(12)
                        .opacity(purchasing ? 0.7 : 1.0)
                }
                .disabled(purchasing || purchased)

                VStack(spacing: 2) {
                    Text("Payment processed by Apple via StoreKit")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Cancel anytime in Settings → Apple ID")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
    }
}
