// ═══════════════════════════════════════════════════════════════════
// Spatter plan controls (#209, owner decisions 2026-10-14)
//
// - Free: while cloud advice is on, only the suggested prompts can be sent,
//   5 per calendar month; the text field is disabled with the reason and an
//   upgrade link. The remaining count is whatever the server reports.
// - Creator / Pro: free text, plus an optional own AI key kept only in this
//   device's Keychain (SpatterOwnKeySettingsView).
// Nothing here decides an entitlement; the server enforces every prompt.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

/// The suggested-prompt chips. When free text is locked a chip sends its
/// suggested prompt directly; otherwise it fills the draft as before.
struct SpatterSuggestionChips: View {
    @ObservedObject var vm: SpatterAIViewModel
    let onFill: (String) -> Void
    let onSend: (SpatterSuggestedPrompt) -> Void
    var dark = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SpatterSuggestedPrompt.all) { suggestion in
                    Button {
                        if vm.useCloud && vm.freeTextLocked { onSend(suggestion) } else { onFill(suggestion.label) }
                    } label: {
                        Text(suggestion.chipTitle)
                            .font(.system(size: 12))
                            .foregroundColor(dark ? Color.white.opacity(0.85) : Color.sdTextSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(dark ? Color(hex: "1A1A24") : Color.sdSurface2)
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.sdBorder, lineWidth: 1))
                    }
                    .disabled(vm.isThinking || (vm.useCloud && vm.suggestionsLockout != nil))
                    .accessibilityIdentifier("spatter.suggestion.\(suggestion.id)")
                    .accessibilityHint(Text(vm.useCloud && vm.freeTextLocked ? "Sends this suggested prompt" : "Fills the message field"))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

/// Plan line, Free lockout, upgrade link and the own-key entry point.
struct SpatterPlanControls: View {
    @ObservedObject var vm: SpatterAIViewModel
    let accountID: String?
    var dark = false
    @State private var showPlans = false
    @State private var showOwnKey = false

    private var secondary: Color { dark ? Color.white.opacity(0.7) : Color.sdTextSecondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if vm.useCloud {
                if let lockout = vm.allowanceLockout {
                    Text(lockout).font(.caption).foregroundColor(secondary)
                        .accessibilityIdentifier("spatter.plan.lockout")
                } else if let reason = vm.freeTextLockReason {
                    Text(reason).font(.caption2).foregroundColor(secondary)
                        .accessibilityIdentifier("spatter.plan.free-text-locked")
                }
                HStack(spacing: 12) {
                    if vm.freeTextLocked || vm.allowanceLockout != nil {
                        Button("See Creator and Pro plans") { showPlans = true }
                            .font(.caption).accessibilityIdentifier("spatter.plan.upgrade")
                    }
                    if vm.planCheck == .unavailable {
                        Button("Check plan again") { vm.refreshUsage() }
                            .font(.caption).accessibilityIdentifier("spatter.plan.retry")
                    }
                }
            }
            if accountID != nil {
                Button("Own AI key…") { showOwnKey = true }
                    .font(.caption).disabled(vm.isThinking)
                    .accessibilityIdentifier("spatter.plan.own-key")
            }
        }
        .sheet(isPresented: $showPlans) { SubscriptionView() }
        .sheet(isPresented: $showOwnKey) {
            SpatterOwnKeySettingsView(accountID: accountID, plan: vm.cloudAllowance?.plan, onUpgrade: {
                showOwnKey = false
                showPlans = true
            })
        }
    }
}

/// Spatter settings: add, replace or remove the member's own AI key.
struct SpatterOwnKeySettingsView: View {
    let accountID: String?
    /// The plan the server last reported; nil when it has not reported one.
    let plan: SpatterPlanTier?
    var onUpgrade: () -> Void = {}
    var store: SpatterOwnKeyStore = KeychainSpatterOwnKeyStore()
    @Environment(\.dismiss) private var dismiss
    @State private var saved: SpatterOwnKeyCredential?
    @State private var provider: SpatterOwnKeyProvider = .openAI
    @State private var model = ""
    @State private var key = ""
    @State private var message: String?
    @State private var confirmRemove = false

    private var eligible: Bool { plan?.allowsOwnKey ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On the Creator and Pro plans you can use your own AI provider key. Spatter then sends your request directly from this device to that provider, under your account with them, and it does not count against your monthly prompts. StickDeath never receives, stores or logs the key.")
                        .font(.footnote)
                    Text("The key stays in this device's Keychain, available only while the device is unlocked, and is never synced or included in backups. Your provider's own terms and charges apply.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                if accountID == nil {
                    Section { Text(SpatterOwnKeyError.invalidAccount.errorDescription ?? "") }
                } else if !eligible {
                    Section {
                        Text(plan == nil
                             ? "Turn on cloud advice so Spatter can check your plan with the server, then open this again."
                             : SpatterOwnKeyError.planNotEligible.errorDescription ?? "")
                        if plan == .free { Button("See Creator and Pro plans", action: onUpgrade) }
                    }
                    if saved != nil {
                        Section {
                            Text("A key from an earlier paid plan is still saved on this device. It is not used on your current plan.")
                                .font(.footnote)
                            removeButton
                        }
                    }
                } else {
                    if let saved {
                        Section("Saved on this device") {
                            Text("\(saved.provider.displayName) · model \(saved.model)")
                                .accessibilityIdentifier("spatter.own-key.saved")
                            removeButton
                        }
                    }
                    Section(saved == nil ? "Add a key" : "Replace the key") {
                        Picker("Provider", selection: $provider) {
                            ForEach(SpatterOwnKeyProvider.allCases) { Text($0.displayName).tag($0) }
                        }
                        .accessibilityIdentifier("spatter.own-key.provider")
                        TextField("Model name", text: $model)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("spatter.own-key.model")
                        Text(provider.modelHint).font(.caption).foregroundColor(.secondary)
                        SecureField("API key", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textContentType(.password)
                            .accessibilityIdentifier("spatter.own-key.key")
                        Button(saved == nil ? "Save key on this device" : "Replace saved key", action: save)
                            .disabled(key.isEmpty || model.isEmpty)
                            .accessibilityIdentifier("spatter.own-key.save")
                    }
                }
                if let message {
                    Section { Text(message).font(.footnote).accessibilityIdentifier("spatter.own-key.message") }
                }
            }
            .navigationTitle("Own AI key")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove the saved AI key from this device?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove key", role: .destructive, action: remove)
            }
            .onAppear(perform: load)
            .onDisappear { key = "" }
        }
    }

    private var removeButton: some View {
        Button("Remove key", role: .destructive) { confirmRemove = true }
            .accessibilityIdentifier("spatter.own-key.remove")
    }

    private func load() {
        guard let accountID else { saved = nil; return }
        do {
            saved = try store.load(account: accountID)
            if let saved { provider = saved.provider; model = saved.model }
        } catch {
            saved = nil
            message = (error as? SpatterOwnKeyError)?.errorDescription ?? SpatterOwnKeyError.storageFailed.errorDescription
        }
    }

    private func save() {
        guard eligible else { message = SpatterOwnKeyError.planNotEligible.errorDescription; return }
        guard let accountID else { message = SpatterOwnKeyError.invalidAccount.errorDescription; return }
        do {
            let credential = try SpatterOwnKeyCredential.validated(provider: provider, model: model, key: key)
            try store.save(credential, account: accountID)
            saved = credential
            key = ""
            message = "Key saved on this device. Spatter will use it for cloud advice on this account."
        } catch {
            message = (error as? SpatterOwnKeyError)?.errorDescription ?? SpatterOwnKeyError.storageFailed.errorDescription
        }
    }

    private func remove() {
        guard let accountID else { return }
        do {
            try store.remove(account: accountID)
            saved = nil
            key = ""
            message = "Key removed from this device. Cloud advice uses your plan's allowance again."
        } catch {
            message = SpatterOwnKeyError.storageFailed.errorDescription
        }
    }
}
