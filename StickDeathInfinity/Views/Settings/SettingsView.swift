// ═══════════════════════════════════════════════════════════════════
// SettingsView — App settings
// Matches: src/pages/SettingsScreen.tsx exactly
// - Account section (email, username, password change)
// - Subscription / Plan
// - Notification preferences
// - About / Legal
// - Delete account / Sign out
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @State private var showDeleteConfirm = false
    var onBack: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Account section
                    SettingsSection(title: "ACCOUNT") {
                        SettingsRow(icon: "person.fill", title: "Username", value: authVM.user?.username ?? "—")
                        SettingsRow(icon: "envelope.fill", title: "Email", value: authVM.user?.email ?? "—")
                        SettingsRow(icon: "lock.fill", title: "Change Password", chevron: true)
                    }

                    // Subscription
                    SettingsSection(title: "SUBSCRIPTION") {
                        SettingsRow(icon: "creditcard.fill", title: "Current Plan", value: authVM.user?.subscriptionTier ?? "Free")
                        SettingsRow(icon: "arrow.up.circle.fill", title: "Upgrade Plan", chevron: true, accent: true)
                    }

                    // Preferences
                    SettingsSection(title: "PREFERENCES") {
                        SettingsToggleRow(icon: "bell.fill", title: "Push Notifications", isOn: .constant(true))
                        SettingsToggleRow(icon: "envelope.badge.fill", title: "Email Notifications", isOn: .constant(false))
                        SettingsToggleRow(icon: "moon.fill", title: "Dark Mode", isOn: .constant(true))
                    }

                    // Studio
                    SettingsSection(title: "STUDIO") {
                        SettingsRow(icon: "square.grid.2x2.fill", title: "Default Canvas Size", value: "1920×1080")
                        SettingsRow(icon: "gauge.medium", title: "Default FPS", value: "12")
                        SettingsToggleRow(icon: "square.3.layers.3d", title: "Auto Onion Skin", isOn: .constant(true))
                    }

                    // About
                    SettingsSection(title: "ABOUT") {
                        SettingsRow(icon: "doc.text.fill", title: "Terms of Service", chevron: true)
                        SettingsRow(icon: "hand.raised.fill", title: "Privacy Policy", chevron: true)
                        SettingsRow(icon: "info.circle.fill", title: "Version", value: "1.0.0 (1)")
                    }

                    // Danger zone
                    VStack(spacing: 12) {
                        Button {
                            Task { await authVM.signOut() }
                        } label: {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                Text("Sign Out")
                            }
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.sdTextPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(12)
                        }

                        Button {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text("Delete Account")
                            }
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.sdDestructive)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.sdDestructive.opacity(0.1))
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 16)
                .padding(.bottom, 100)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete Account?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { try? await AuthService.shared.deleteAccount() }
            }
        } message: {
            Text("This action cannot be undone. All your data will be permanently deleted.")
        }
    }
}

// MARK: - Settings Components
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundColor(.sdTextMuted)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .background(Color.sdSurface)
            .cornerRadius(12)
            .padding(.horizontal, 16)
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    var value: String? = nil
    var chevron: Bool = false
    var accent: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(accent ? .sdRed : .sdTextSecondary)
                .frame(width: 24)

            Text(title)
                .font(.system(size: 15))
                .foregroundColor(accent ? .sdRed : .sdTextPrimary)

            Spacer()

            if let value {
                Text(value)
                    .font(.system(size: 14))
                    .foregroundColor(.sdTextMuted)
            }

            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.sdTextMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(
            Rectangle().fill(Color.sdBorder).frame(height: 1),
            alignment: .bottom
        )
    }
}

struct SettingsToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.sdTextSecondary)
                .frame(width: 24)

            Text(title)
                .font(.system(size: 15))
                .foregroundColor(.sdTextPrimary)

            Spacer()

            Toggle("", isOn: $isOn)
                .tint(.sdRed)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(
            Rectangle().fill(Color.sdBorder).frame(height: 1),
            alignment: .bottom
        )
    }
}
