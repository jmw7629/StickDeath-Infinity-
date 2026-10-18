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
    @Environment(\.locale) private var locale
    @ObservedObject private var stripe = StripeService.shared
    @State private var showDeleteConfirm = false
    @State private var sheet: SettingsSheet?

    private enum SettingsSheet: String, Identifiable {
        case plans, support, notifications, privacy
        var id: String { rawValue }
    }
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
                        // Apple's state machine, not the profile column: opens Plans.
                        Button { sheet = .plans } label: {
                            SettingsRow(icon: "creditcard.fill", title: "Current Plan",
                                        value: BillingCopy.status(stripe.billing, catalog: stripe.catalog, locale: locale, timeZone: .current).title)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.current-plan")
                    }

                    SettingsSection(title: "HELP AND PRIVACY") {
                        Button { sheet = .support } label: { SettingsRow(icon: "questionmark.bubble.fill", title: "Contact Support") }
                            .buttonStyle(.plain).accessibilityIdentifier("settings.support")
                        Button { sheet = .notifications } label: { SettingsRow(icon: "bell.fill", title: "Notifications") }
                            .buttonStyle(.plain).accessibilityIdentifier("settings.notifications")
                        Button { sheet = .privacy } label: { SettingsRow(icon: "hand.raised.fill", title: "Privacy and Marketing Permission") }
                            .buttonStyle(.plain).accessibilityIdentifier("settings.privacy")
                        Link(destination: PolicyLinks.terms) { SettingsRow(icon: "doc.text.fill", title: "Terms of Service") }
                            .accessibilityIdentifier("settings.policy.terms")
                        Link(destination: PolicyLinks.privacy) { SettingsRow(icon: "lock.doc.fill", title: "Privacy Policy") }
                            .accessibilityIdentifier("settings.policy.privacy")
                    }

                    if authVM.isAuthenticated {
                        SettingsSection(title: "YOUR DATA") {
                            AccountDataExportRow()
                        }
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
        .sheet(item: $sheet) { page in
            NavigationStack {
                switch page {
                case .plans: SubscriptionView()
                case .support: SupportRequestsView().toolbar { doneButton }
                case .notifications: NotificationCenterView().toolbar { doneButton }
                case .privacy: PrivacyChoicesView().toolbar { doneButton }
                }
            }
        }
    }

    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } }
    }
}

// MARK: - Account data export (#262)

/// Requests the member's server records from `sdi_account_lifecycle('export')` and
/// offers the exact JSON for saving or sharing. The file lives only while this row
/// is on screen (complete file protection) and is removed afterwards. Server
/// refusals, including the three-per-day limit, are shown as the server words them.
struct AccountDataExportRow: View {
    @ObservedObject private var auth = AuthService.shared
    @State private var exporting = false
    @State private var exportFile: URL?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await export() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down.on.square").frame(width: 24)
                    Text(exporting ? "Preparing export…" : "Export my account data")
                    Spacer()
                    if exporting { ProgressView() }
                }
                .font(.specialElite(15, relativeTo: .body))
                .foregroundColor(.sdTextPrimary)
                .frame(minHeight: 44)
            }
            .disabled(exporting || !auth.isAuthenticated)
            .accessibilityIdentifier("settings.export-data")
            if let exportFile {
                ShareLink(item: exportFile) {
                    Label("Save or share the export", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                }
                .accessibilityIdentifier("settings.export-data.share")
            }
            Text("Includes the records the service keeps for your account: profile, consents, posts, votes, rooms, publishing jobs, subscriptions and support requests. Projects and originals stay on this device and are not part of it. Three exports per day.")
                .font(.specialElite(11, relativeTo: .caption))
                .foregroundColor(.sdTextSecondary)
            if let message {
                Text(message).font(.specialElite(12, relativeTo: .caption)).foregroundColor(.sdTextSecondary)
                    .accessibilityIdentifier("settings.export-data.message")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onDisappear { discard() }
        .onChange(of: auth.userId) { _, _ in discard(); message = nil }
    }

    private func export() async {
        guard !exporting else { return }
        exporting = true; message = nil; discard()
        defer { exporting = false }
        let account = auth.userId
        do {
            let data = try await auth.exportAccountData()
            guard auth.userId == account else { return }   // account changed while waiting
            exportFile = try AuthService.writeAccountExport(data)
            message = "Export ready. It is removed from this device when you leave Settings."
        } catch {
            message = error.localizedDescription
        }
    }

    private func discard() {
        if let exportFile { try? FileManager.default.removeItem(at: exportFile.deletingLastPathComponent()) }
        exportFile = nil
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
