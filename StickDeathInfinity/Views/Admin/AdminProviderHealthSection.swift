import SwiftUI

// MARK: - Provider health (#248)
/// Masked per-integration health from `sdi_admin_provider_health`: whether each
/// integration's named settings were reported present (yes/no only), the last
/// success and failure, and a closed error class. The secret store keeps no
/// fingerprint, so no masked suffix is shown; nothing here reveals a value.
@MainActor
struct AdminProviderHealthSection: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var reply: AdminProviderHealthResponse?
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("admin.providers.error") }
            if let reply { rows(reply) }
        }
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await load() }
        }
        .onDisappear { clear() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Provider health").font(.specialElite(18))
            Text("Configured yes/no, last success, last failure and error class per integration. Keys, tokens, URLs and provider messages are never shown.").font(.caption)
            Button("Refresh") { Task { await load() } }.disabled(busy).accessibilityIdentifier("admin.providers.refresh")
        }
    }

    @ViewBuilder private func rows(_ reply: AdminProviderHealthResponse) -> some View {
        ForEach(reply.providers ?? []) { item in
            AdminProviderHealthRow(item: item)
        }
        if let note = reply.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
    }

    private func clear() { requestID = UUID(); busy = false; reply = nil; error = nil }
    private func load() async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let value = try await CommunityServices.admin.providerHealth()
            guard !Task.isCancelled, requestID == id else { return }
            reply = value; error = nil
        } catch { if requestID == id { reply = nil; self.error = CommunityServices.admin.noteRefusal(error).errorDescription } }
    }
}

private struct AdminProviderHealthRow: View {
    let item: AdminProviderHealth

    var body: some View {
        HStack(alignment: .top) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.title) · \(Self.healthText(item.health))").font(.specialElite(14))
                Text(configurationText).font(.caption)
                Text("Last success: \(item.last_success_at?.formatted() ?? "none recorded")").font(.caption)
                if let failed = item.last_failure_at {
                    Text("Last failure: \(failed.formatted()) · \(Self.words(item.last_error_class ?? "other"))\(item.consecutive_failures > 1 ? " · \(item.consecutive_failures) in a row" : "")")
                        .font(.caption).foregroundStyle(StudioCraftTheme.warning)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("admin.providers.\(item.provider)")
    }

    private var color: Color {
        switch item.health {
        case "healthy": return .green
        case "failing", "unconfigured": return StudioCraftTheme.warning
        default: return .gray
        }
    }
    private var configurationText: String {
        switch item.configured {
        case "yes": return "Configured: yes\(item.configuration_stale ? " (report over a day old)" : "")"
        case "no": return "Configured: no · missing \(item.missing.joined(separator: ", "))"
        default: return "Configured: not reported by any worker"
        }
    }
    static func healthText(_ health: String) -> String {
        switch health {
        case "healthy": return "healthy"
        case "failing": return "failing"
        case "unconfigured": return "not configured"
        case "no_activity": return "no activity yet"
        default: return "unreported"
        }
    }
    static func words(_ value: String) -> String { value.replacingOccurrences(of: "_", with: " ") }
}
