// SubscriptionView.swift
// Layer 3 — ACTION SCREEN (sheet — closes, returns to Profile)
// Stripe-powered subscription management

import SwiftUI

struct SubscriptionView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var loading = false
    @State private var selectedTier: String = "pro"

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.yellow)
                            Text("Go Pro").font(.title.bold())
                            Text("Unlock the full STICKDEATH ∞ experience")
                                .font(.subheadline).foregroundStyle(.gray)
                        }
                        .padding(.top, 20)

                        // Pro tier
                        tierCard(
                            title: "Pro",
                            price: "$4.99/mo",
                            features: [
                                "No watermarks",
                                "Unlimited projects",
                                "HD export (1080p+)",
                                "All sound effects",
                                "Priority Spatter AI",
                                "All asset packs"
                            ],
                            isSelected: selectedTier == "pro",
                            color: .red
                        ) { selectedTier = "pro" }

                        // Subscribe button
                        Button {
                            Task { await subscribe() }
                        } label: {
                            if loading {
                                ProgressView().tint(.black)
                                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                                    .background(.red).clipShape(RoundedRectangle(cornerRadius: 14))
                            } else {
                                Text("Subscribe — $4.99/mo")
                                    .font(.headline).foregroundStyle(.black)
                                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                                    .background(.red).clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .disabled(loading)
                        .padding(.horizontal)

                        // Restore
                        Button("Restore Purchases") {}
                            .font(.caption).foregroundStyle(.gray)

                        Text("Cancel anytime. Billed monthly.")
                            .font(.caption2).foregroundStyle(.gray)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.foregroundStyle(.gray)
                }
            }
        }
    }

    func tierCard(title: String, price: String, features: [String], isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.title3.bold())
                    Spacer()
                    Text(price).font(.headline).foregroundStyle(color)
                }
                ForEach(features, id: \.self) { feature in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(color)
                        Text(feature).font(.subheadline)
                    }
                }
            }
            .padding()
            .background(isSelected ? color.opacity(0.1) : ThemeManager.surfaceLight)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? color : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    func subscribe() async {
        loading = true
        // TODO: Stripe checkout via StripeService
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        loading = false
    }
}
