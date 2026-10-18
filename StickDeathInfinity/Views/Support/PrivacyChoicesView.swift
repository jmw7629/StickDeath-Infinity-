// ═══════════════════════════════════════════════════════════════════
// PrivacyChoicesView — policies and marketing permission (#273).
// Links open the versioned policy pages on the canonical website. Marketing
// reuse is a separate permission from channel publication: it is shown,
// granted and withdrawn here from the server's record
// (`sdi_consent_action`); channel-publication permissions stay per video in
// Profile → Publishing. Nothing is shown as granted unless the server says so.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

/// The policy links shared by Profile → Settings and the legacy Settings screen.
struct PolicyLinksList: View {
    var body: some View {
        Link(destination: PolicyLinks.terms) { Label("Terms of service", systemImage: "doc.text") }
            .accessibilityIdentifier("settings.policy.terms")
        Link(destination: PolicyLinks.privacy) { Label("Privacy policy", systemImage: "hand.raised") }
            .accessibilityIdentifier("settings.policy.privacy")
        Link(destination: PolicyLinks.publishing) { Label("Publishing permissions", systemImage: "square.and.arrow.up") }
        Link(destination: PolicyLinks.attribution) { Label("Asset attribution", systemImage: "music.note.list") }
        Text("These pages open on stickdeathinfinity.com. They are versioned drafts awaiting legal review; the version you accept is recorded by the server.")
            .font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.secondary)
    }
}

struct PrivacyChoicesView: View {
    @ObservedObject private var auth = AuthService.shared
    @State private var state: MarketingPermissionState?
    @State private var problem: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var confirmGrant = false
    @State private var confirmWithdraw = false
    @State private var generation = UUID()

    private var client: PrivacyChoicesClient { PrivacyChoicesClient(gateway: CommunityServices.gateway) }

    var body: some View {
        List {
            Section("Policies") { PolicyLinksList() }
            Section("Marketing reuse") { marketingContent }
            Section("Other permissions") {
                Text("Permission to publish a video to the official SDI channels is separate and is given or withdrawn per video in Profile → Publishing. Account data export and deletion are in Profile → Settings.")
                    .font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy and policies")
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated)") {
            generation = UUID(); busy = false; state = nil; problem = nil; notice = nil
            if auth.isAuthenticated && CommunityServices.isConfigured { await load() }
        }
        .confirmationDialog("Allow marketing reuse?", isPresented: $confirmGrant) {
            if let version = state?.currentPolicy?.version {
                Button("Allow") { Task { await grant(version) } }
            }
            Button("Not now", role: .cancel) {}
        } message: { Text(state?.currentPolicy?.summary ?? "") }
        .confirmationDialog("Withdraw marketing permission?", isPresented: $confirmWithdraw) {
            Button("Withdraw", role: .destructive) { Task { await withdraw() } }
            Button("Keep", role: .cancel) {}
        } message: { Text("Your videos are no longer selected for marketing. Channel-publication permissions are not changed.") }
    }

    @ViewBuilder private var marketingContent: some View {
        if !CommunityServices.isConfigured {
            Text(CommunityError.notConfigured.errorDescription ?? "").accessibilityIdentifier("privacy.not-configured")
        } else if !auth.isAuthenticated {
            Text("Sign in with a full account to see or change marketing permission. Without an account nothing of yours is used for marketing.")
        } else if let state {
            Text(state.granted ? "Allowed: approved videos you publish may be used to promote StickDeath Infinity." : "Not allowed: your videos are not used for marketing.")
                .accessibilityIdentifier("privacy.marketing.status")
            if let latest = state.latest {
                Text(latest.withdrawn_at.map { "Withdrawn \($0.formatted(date: .abbreviated, time: .shortened))." }
                     ?? "Version \(latest.version) accepted \(latest.accepted_at.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.secondary)
            }
            if state.granted {
                Button("Withdraw marketing permission", role: .destructive) { confirmWithdraw = true }
                    .disabled(busy)
                    .accessibilityIdentifier("privacy.marketing.withdraw")
            } else if let policy = state.currentPolicy {
                Text(policy.summary).font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
                Button("Allow marketing reuse (version \(policy.version))") { confirmGrant = true }
                    .disabled(busy)
                    .accessibilityIdentifier("privacy.marketing.allow")
            } else {
                Text("No marketing permission has been published yet, so none can be given.")
                    .font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
            }
        } else if busy {
            ProgressView()
        }
        if let problem { Text(problem).foregroundStyle(.red).accessibilityIdentifier("privacy.problem") }
        if let notice { Text(notice).font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary) }
        if auth.isAuthenticated && CommunityServices.isConfigured {
            Button("Refresh") { Task { await load() } }.disabled(busy)
        }
    }

    @MainActor private func load() async {
        guard !busy else { return }
        let epoch = generation; busy = true
        defer { if epoch == generation { busy = false } }
        do {
            let loaded = try await client.marketingState()
            guard epoch == generation else { return }
            state = loaded; problem = nil
        } catch {
            if epoch == generation { problem = CommunityGateway.normalize(error).errorDescription }
        }
    }

    @MainActor private func grant(_ version: String) async {
        await mutate("Marketing permission recorded.") { try await client.grantMarketing(version: version) }
    }
    @MainActor private func withdraw() async {
        await mutate("Marketing permission withdrawn.") { try await client.withdrawMarketing() }
    }
    @MainActor private func mutate(_ success: String, _ operation: () async throws -> Void) async {
        guard !busy else { return }
        let epoch = generation; busy = true; notice = nil
        do {
            try await operation()
            guard epoch == generation else { return }
            busy = false; problem = nil
            await load()
            if epoch == generation { notice = success }
        } catch {
            if epoch == generation { busy = false; problem = CommunityGateway.normalize(error).errorDescription }
        }
    }
}
