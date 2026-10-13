// ═══════════════════════════════════════════════════════════════════
// SettingsView — legacy account settings screen
//
// Not routed from the tab shell: ProfileView hosts the live account,
// authenticator, sign-out and deletion rows. This screen stays compiled
// into the app (it is listed in the Xcode project), so it shows only real
// values and real outcomes: no placeholder toggles, defaults or links that
// go nowhere (#135). Sign-out and deletion use the same AuthViewModel paths
// as Profile; local projects are never touched by either.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @State private var showDeleteConfirm = false
    var onBack: (() -> Void)? = nil

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "Unavailable"
        }
    }

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    SettingsSection(title: "ACCOUNT") {
                        SettingsRow(icon: "person.fill", title: "Username",
                                    value: authVM.user?.username ?? "Not available")
                        SettingsRow(icon: "envelope.fill", title: "Email",
                                    value: authVM.user?.email ?? "Not available")
                        SettingsRow(icon: "creditcard.fill", title: "Current Plan",
                                    value: authVM.user?.subscriptionTier ?? "Free")
                    }

                    SettingsSection(title: "ABOUT") {
                        SettingsRow(icon: "info.circle.fill", title: "Version", value: appVersion)
                        SettingsRow(icon: "internaldrive.fill", title: "Projects",
                                    value: "Stored on this device")
                    }

                    VStack(spacing: 12) {
                        if authVM.isAuthenticated {
                            Button {
                                Task { await authVM.signOut() }
                            } label: {
                                HStack {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                    Text("Sign Out")
                                }
                                .font(.specialElite(16))
                                .foregroundColor(.sdTextPrimary)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(12)
                            }
                            .disabled(authVM.isLoading)
                            .accessibilityIdentifier("settings.sign-out")
                            Text("Signing out closes the open project and returns to the library. Nothing on this device is deleted.")
                                .font(.specialElite(11, relativeTo: .caption))
                                .foregroundColor(.sdTextSecondary)
                                .multilineTextAlignment(.center)

                            Button {
                                showDeleteConfirm = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash.fill")
                                    Text("Delete Account")
                                }
                                .font(.specialElite(16))
                                .foregroundColor(.sdDestructive)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Color.sdDestructive.opacity(0.1))
                                .cornerRadius(12)
                            }
                            .disabled(authVM.isLoading)
                            .accessibilityIdentifier("settings.delete-account")
                        } else {
                            Text("Sign in from Profile to manage your account. Local projects do not require an account.")
                                .font(.specialElite(13, relativeTo: .footnote))
                                .foregroundColor(.sdTextSecondary)
                                .multilineTextAlignment(.center)
                        }
                        if let status = authVM.accountDeletion, status.isOpen {
                            Text(AuthViewModel.deletionSummary(status))
                                .font(.specialElite(12, relativeTo: .caption)).foregroundColor(.sdTextSecondary)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("settings.delete-account.status")
                        }
                        if let notice = authVM.notice {
                            Text(notice).font(.specialElite(12, relativeTo: .caption)).foregroundColor(.sdTextSecondary)
                                .multilineTextAlignment(.center)
                        }
                        if let error = authVM.error {
                            Text(error).font(.specialElite(12, relativeTo: .caption)).foregroundColor(.red)
                                .multilineTextAlignment(.center)
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
        // The request is filed with the server (sdi_account_lifecycle) and completed
        // after a seven-day cooling-off period; the app never deletes anything itself.
        .alert("Delete this account?", isPresented: $showDeleteConfirm) {
            Button("Request deletion", role: .destructive) { Task { await authVM.requestAccountDeletion() } }
            Button("Keep account", role: .cancel) {}
        } message: {
            Text("Server records are deleted after a seven-day cooling-off period; cancel from Profile until then. Projects on this device are not affected. Subscriptions must be cancelled through the App Store or billing portal.")
        }
        .task(id: authVM.userId) { await authVM.refreshAccountDeletion() }
    }
}

// MARK: - Settings Components
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.specialElite(11, relativeTo: .caption))
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.sdTextSecondary)
                .frame(width: 24)

            Text(title)
                .font(.specialElite(15, relativeTo: .body))
                .foregroundColor(.sdTextPrimary)

            Spacer()

            if let value {
                Text(value)
                    .font(.specialElite(14, relativeTo: .subheadline))
                    .foregroundColor(.sdTextMuted)
                    .multilineTextAlignment(.trailing)
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
