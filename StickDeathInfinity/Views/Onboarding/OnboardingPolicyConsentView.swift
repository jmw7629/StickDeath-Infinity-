// ═══════════════════════════════════════════════════════════════════
// OnboardingPolicyConsentView — accept the current Terms, Privacy and
// (when published) content-policy versions after creating an account (#273).
//
// Acceptance is recorded only by the server (`sdi_consent_action` accept,
// backend/sql/consent-versions.sql) for exactly the version shown, from
// source "ios". It never blocks Studio: guests and members who skip keep full
// local Studio use, and nothing is shown as accepted unless the server says
// so. Without validated configuration the card says so and sends nothing.
// Channel publication and marketing reuse stay separate permissions
// (Profile → Publishing, Privacy and policies).
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct OnboardingPolicyConsentView: View {
    @ObservedObject private var auth = AuthService.shared
    @State private var state: OnboardingConsentState?
    @State private var problem: String?
    @State private var busy = false
    @State private var ageConfirmed = false
    @State private var generation = UUID()

    private var client: PrivacyChoicesClient { PrivacyChoicesClient(gateway: CommunityServices.gateway) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terms and privacy")
                .font(.specialElite(15, relativeTo: .headline))
                .foregroundColor(.white)
            HStack(spacing: 16) {
                Link("Terms of Service", destination: PolicyLinks.terms)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("onboarding.policies.terms")
                Link("Privacy Policy", destination: PolicyLinks.privacy)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("onboarding.policies.privacy")
            }
            .font(.specialElite(13, relativeTo: .callout))
            .foregroundColor(.sdRed)
            content
        }
        .padding(14)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated)") {
            generation = UUID(); busy = false; state = nil; problem = nil; ageConfirmed = false
            if auth.isAuthenticated && CommunityServices.isConfigured { await load() }
        }
    }

    @ViewBuilder private var content: some View {
        if !CommunityServices.isConfigured {
            caption("Policy acceptance is unavailable: account services are not configured in this build. Nothing is recorded, and Studio works on this device without an account.")
                .accessibilityIdentifier("onboarding.policies.not-configured")
        } else if !auth.isAuthenticated {
            caption("Guests are not asked to accept anything and nothing is recorded. Studio works on this device without an account; create one to accept the current versions.")
                .accessibilityIdentifier("onboarding.policies.guest")
        } else if let state {
            if state.nothingPublished {
                caption("No policy versions have been published yet, so there is nothing to accept.")
                    .accessibilityIdentifier("onboarding.policies.unpublished")
            } else if state.complete {
                caption("Accepted: " + state.accepted.map(label).joined(separator: ", ") + ".")
                    .accessibilityIdentifier("onboarding.policies.accepted")
            } else {
                ForEach(state.pending, id: \.policy) { policy in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(policy)).font(.specialElite(13, relativeTo: .callout)).foregroundColor(.white)
                        caption(policy.summary)
                    }
                }
                if let age = state.minimumAge {
                    Toggle("I am at least \(age) years old", isOn: $ageConfirmed)
                        .font(.specialElite(13, relativeTo: .callout)).foregroundColor(.white)
                        .tint(.sdRed)
                        .accessibilityIdentifier("onboarding.policies.age")
                }
                Button {
                    Task { await accept(state.pending) }
                } label: {
                    Text("Accept these versions")
                        .font(.specialElite(14, relativeTo: .callout)).foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.sdRed.opacity(busy ? 0.4 : 1))
                        .cornerRadius(10)
                }
                .disabled(busy || (state.minimumAge != nil && !ageConfirmed))
                .accessibilityIdentifier("onboarding.policies.accept")
                caption("Optional here: you can open Studio without accepting.")
            }
        } else if busy {
            ProgressView().tint(.sdRed)
        }
        if let problem {
            caption(problem).accessibilityIdentifier("onboarding.policies.problem")
            Button("Retry") { Task { await load() } }
                .font(.specialElite(13, relativeTo: .callout)).foregroundColor(.sdRed)
                .frame(minHeight: 44)
                .disabled(busy)
                .accessibilityIdentifier("onboarding.policies.retry")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.specialElite(12, relativeTo: .caption))
            .foregroundColor(.sdTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func label(_ policy: PolicyVersionSummary) -> String {
        let name: String
        switch policy.policy {
        case "terms": name = "Terms of Service"
        case "privacy": name = "Privacy Policy"
        case "content": name = "Content policy"
        default: name = policy.policy
        }
        return "\(name) (version \(policy.version))"
    }

    @MainActor private func load() async {
        guard !busy else { return }
        let epoch = generation; busy = true
        defer { if epoch == generation { busy = false } }
        do {
            let loaded = try await client.onboardingState()
            guard epoch == generation else { return }
            state = loaded; problem = nil
        } catch {
            if epoch == generation { problem = CommunityGateway.normalize(error).errorDescription }
        }
    }

    @MainActor private func accept(_ shown: [PolicyVersionSummary]) async {
        guard !busy else { return }
        let epoch = generation; busy = true
        var failure: String?
        do { try await client.acceptOnboarding(shown, ageConfirmed: ageConfirmed) }
        catch { failure = CommunityGateway.normalize(error).errorDescription ?? "Acceptance was not confirmed." }
        guard epoch == generation else { return }
        busy = false
        // Re-read the server record either way; a partial batch is never assumed.
        await load()
        if epoch == generation, let failure { problem = failure }
    }
}
