// ═══════════════════════════════════════════════════════════════════
// ChoosePlanView — Subscription plan selection
// Matches: src/pages/ChoosePlan.tsx exactly
// - Skull + "Choose Your Plan" + "Unlock your creative potential"
// - 4 vertical plan cards: Free, Creator, Pro (POPULAR), Studio
// - Feature tags as small pills
// - CTA button changes based on selection
// - "Start Free →" skip at bottom
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import StoreKit

struct ChoosePlanView: View {
    let onSelected: () -> Void

    @StateObject private var stripe = StripeService.shared
    @State private var selectedPlan: String? = nil
    @State private var loading = false
    @State private var showError = false
    @State private var errorMessage = ""

    private let plans: [PlanInfo] = [
        PlanInfo(id: "free", name: "Free", price: "$0", per: "",
                 features: ["5 projects", "Basic tools", "720p export", "Watermark"],
                 color: Color(hex: "#9CA3AF"), popular: false),
        PlanInfo(id: "creator", name: "Creator", price: "$4.99", per: "/mo",
                 features: ["25 projects", "Advanced tools", "1080p export", "No watermark", "5 AI queries/day"],
                 color: Color(hex: "#DC2626"), popular: false),
        PlanInfo(id: "pro", name: "Pro", price: "$9.99", per: "/mo",
                 features: ["Unlimited projects", "All tools", "4K export", "Cloud sync", "50 AI queries/day", "Collab rooms"],
                 color: Color(hex: "#DC2626"), popular: true),
        PlanInfo(id: "studio", name: "Studio", price: "$19.99", per: "/mo",
                 features: ["Everything in Pro", "Team workspace", "Commercial license", "Unlimited AI", "API access"],
                 color: Color(hex: "#A855F7"), popular: false),
    ]

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

                    Text("Unlock your creative potential")
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
                                isSelected: selectedPlan == plan.id,
                                onSelect: { selectedPlan = plan.id }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // CTA section
                VStack(spacing: 12) {
                    if let selected = selectedPlan {
                        let plan = plans.first { $0.id == selected }
                        Button {
                            handleSelect(selected)
                        } label: {
                            Text(loading
                                 ? "Processing..."
                                 : (selected == "free"
                                    ? "Continue with Free"
                                    : "Start \(plan?.name ?? "") Plan"))
                                .font(.specialElite(16))
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    loading
                                        ? Color(hex: "#DC2626").opacity(0.5)
                                        : Color(hex: "#DC2626")
                                )
                                .cornerRadius(12)
                        }
                        .disabled(loading)
                    }

                    // Start Free skip
                    Button {
                        onSelected()
                    } label: {
                        Text("Start Free →")
                            .font(.specialElite(14))
                            .foregroundColor(.sdTextSecondary)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
        }
    }

    private func handleSelect(_ planId: String) {
        loading = true
        Task {
            if planId == "free" {
                onSelected()
            } else {
                // Map to subscription tier
                if let tier = AppConfig.SubscriptionTier(rawValue: planId) {
                    do {
                        try await stripe.subscribe(to: tier)
                        onSelected()
                    } catch StripeService.PaymentError.cancelled {
                        loading = false
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                        loading = false
                        // Graceful fallback — proceed anyway
                        onSelected()
                    }
                } else {
                    onSelected()
                }
            }
        }
    }
}

// MARK: - Plan Info Model
private struct PlanInfo: Identifiable {
    let id: String
    let name: String
    let price: String
    let per: String
    let features: [String]
    let color: Color
    let popular: Bool
}

// MARK: - Plan Card Row
private struct PlanCardRow: View {
    let plan: PlanInfo
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

                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(plan.price)
                            .font(.specialElite(18))
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        if !plan.per.isEmpty {
                            Text(plan.per)
                                .font(.specialElite(12))
                                .foregroundColor(.sdTextSecondary)
                        }
                    }
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
