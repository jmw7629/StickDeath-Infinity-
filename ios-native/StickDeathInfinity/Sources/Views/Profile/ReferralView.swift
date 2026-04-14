// ReferralView.swift
// Invite friends, share referral code, track stats
// Both referrer and friend get 1 month Pro free

import SwiftUI

struct ReferralView: View {
    @StateObject private var referralService = ReferralService.shared
    @Environment(\.dismiss) var dismiss
    @State private var copied = false
    @State private var redeemCode = ""
    @State private var showRedeem = false
    @State private var redeemError: String?
    @State private var redeemSuccess = false

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        // ── Hero ──
                        heroSection

                        // ── Your Code ──
                        codeCard

                        // ── Stats ──
                        statsSection

                        // ── How It Works ──
                        howItWorks

                        // ── Referred Friends List ──
                        if !referralService.referredUsers.isEmpty {
                            friendsList
                        }

                        // ── Redeem a Code ──
                        redeemSection
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Invite Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadData() }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "gift.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
                .padding(.top, 20)

            Text("Give Pro, Get Pro")
                .font(.title2.bold())

            Text("Invite a friend and you *both* get\n1 month of Pro for free!")
                .font(.subheadline)
                .foregroundStyle(ThemeManager.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Code Card

    private var codeCard: some View {
        VStack(spacing: 16) {
            if let code = referralService.referralCode {
                // Code display
                HStack(spacing: 12) {
                    Text(code)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .kerning(3)

                    Button {
                        UIPasteboard.general.string = code
                        copied = true
                        HapticManager.shared.buttonTap()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.title3)
                            .foregroundStyle(copied ? .green : .red)
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 24)
                .background(ThemeManager.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                // Share button
                Button {
                    HapticManager.shared.buttonTap()
                    referralService.shareReferralLink(code: code)
                } label: {
                    Label("Share Invite Link", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 24)
            } else {
                ProgressView()
                    .tint(.red)
                    .padding()
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("\(referralService.stats.totalInvited)")
                    .font(.title2.bold())
                    .foregroundStyle(.red)
                Text("Friends Invited")
                    .font(.caption2)
                    .foregroundStyle(ThemeManager.textSecondary)
            }
            .frame(maxWidth: .infinity)

            Divider().frame(height: 36).background(ThemeManager.border)

            VStack(spacing: 4) {
                Text("\(referralService.stats.totalRedeemed)")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                Text("Redeemed")
                    .font(.caption2)
                    .foregroundStyle(ThemeManager.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 14)
        .background(ThemeManager.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    // MARK: - How It Works

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it works")
                .font(.subheadline.bold())
                .padding(.horizontal, 16)

            VStack(spacing: 10) {
                StepRow(number: "1", text: "Share your unique code with a friend")
                StepRow(number: "2", text: "They sign up and enter your code")
                StepRow(number: "3", text: "You both get 1 month of Pro — free!")
            }
            .padding(16)
            .background(ThemeManager.surfaceLight)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Friends List

    private var friendsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Referred Friends")
                .font(.subheadline.bold())
                .padding(.horizontal, 16)

            ForEach(referralService.referredUsers) { friend in
                HStack(spacing: 12) {
                    Circle()
                        .fill(.red.opacity(0.2))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(friend.displayName)
                            .font(.subheadline)
                        if !friend.redeemedAt.isEmpty {
                            Text("Joined \(formattedDate(friend.redeemedAt))")
                                .font(.caption2)
                                .foregroundStyle(ThemeManager.textSecondary)
                        }
                    }

                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                .padding(12)
                .background(ThemeManager.surfaceLight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Redeem Section

    private var redeemSection: some View {
        VStack(spacing: 12) {
            Divider().background(ThemeManager.border).padding(.horizontal)

            Button {
                showRedeem.toggle()
            } label: {
                HStack {
                    Text("Have a referral code?")
                        .font(.subheadline)
                        .foregroundStyle(ThemeManager.textSecondary)
                    Image(systemName: showRedeem ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }

            if showRedeem {
                VStack(spacing: 10) {
                    TextField("Enter code", text: $redeemCode)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.allCharacters)
                        .padding()
                        .background(ThemeManager.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    if let error = redeemError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if redeemSuccess {
                        Label("Code redeemed! Enjoy Pro 🎉", systemImage: "checkmark.circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }

                    Button {
                        Task { await redeem() }
                    } label: {
                        Text("Redeem")
                            .font(.subheadline.bold())
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(redeemCode.count >= 6 ? .red : .gray)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(redeemCode.count < 6)
                }
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Actions

    private func loadData() async {
        _ = try? await referralService.fetchOrCreateCode()
        await referralService.fetchStats()
    }

    private func redeem() async {
        redeemError = nil
        redeemSuccess = false
        do {
            try await referralService.redeemCode(redeemCode)
            redeemSuccess = true
            HapticManager.shared.published()
            await referralService.fetchStats()
        } catch {
            redeemError = error.localizedDescription
            HapticManager.shared.error()
        }
    }

    private func formattedDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return "" }
        let display = DateFormatter()
        display.dateStyle = .medium
        return display.string(from: date)
    }
}

// MARK: - Step Row

private struct StepRow: View {
    let number: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(.red)
                .clipShape(Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(ThemeManager.textPrimary)
        }
    }
}
