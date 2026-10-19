// ═══════════════════════════════════════════════════════════════════
// NotificationCenterView — in-app announcements and notification
// preferences (#290) over NotificationsClient.
//
// Push delivery is an owner gate: this build has no APNs entitlement and
// registers no device, so the push switches only record the member's choice
// for when delivery exists, and the screen says so. Announcements appear
// only when the server delivered them to this account.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct NotificationCenterView: View {
    @ObservedObject private var auth = AuthService.shared
    @State private var inbox: AnnouncementInbox?
    @State private var stored: NotificationPreferences?
    @State private var draft: NotificationPreferences?
    @State private var inboxProblem: String?
    @State private var preferencesProblem: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var expanded: Set<UUID> = []
    @State private var generation = UUID()

    private var client: NotificationsClient { NotificationsClient(gateway: CommunityServices.gateway) }
    private var hasChanges: Bool {
        guard let stored, let draft else { return false }
        return !NotificationPreferenceChanges.between(stored, draft).isEmpty
    }

    var body: some View {
        List {
            if !CommunityServices.isConfigured {
                Section { Text(CommunityError.notConfigured.errorDescription ?? "").accessibilityIdentifier("notifications.not-configured") }
            } else if !auth.isAuthenticated {
                Section { Text("Sign in with a full account to see announcements and choose notifications.") }
            } else {
                inboxSection
                preferencesSection
            }
        }
        .navigationTitle("Notifications")
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated)") {
            generation = UUID(); busy = false; inbox = nil; stored = nil; draft = nil
            inboxProblem = nil; preferencesProblem = nil; notice = nil; expanded = []
            if auth.isAuthenticated && CommunityServices.isConfigured { await load() }
        }
    }

    private var inboxSection: some View {
        Section("Announcements") {
            if let inboxProblem { Text(inboxProblem).foregroundStyle(.secondary) }
            if let inbox {
                if inbox.notices.isEmpty {
                    Text("No announcements.").foregroundStyle(.secondary)
                } else {
                    Text(inbox.unread == 0 ? "All read." : "\(inbox.unread) unread.")
                        .font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("notifications.unread")
                }
                ForEach(inbox.notices) { notice in
                    Button { Task { await open(notice) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                if notice.isUnread {
                                    Circle().fill(Color.sdRed).frame(width: 8, height: 8).accessibilityHidden(true)
                                }
                                Text(notice.title).font(.specialElite(15, relativeTo: .body))
                            }
                            Text("\(notice.categoryTitle) · \(notice.delivered_at.formatted(date: .abbreviated, time: .shortened))")
                                .font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.secondary)
                            Text(notice.body).font(.specialElite(13, relativeTo: .footnote))
                                .lineLimit(expanded.contains(notice.id) ? nil : 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(notice.isUnread ? "Unread. " : "")\(notice.title). \(notice.body)")
                }
            }
            Button("Refresh") { Task { await load() } }.disabled(busy)
        }
    }

    @ViewBuilder private var preferencesSection: some View {
        Section {
            if let preferencesProblem { Text(preferencesProblem).foregroundStyle(.red) }
            if let binding = Binding($draft) {
                Text("Account and service notices are \(binding.wrappedValue.transactional).")
                    .font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
                Toggle("Product news by push", isOn: binding.pushProduct)
                Toggle("Marketing by push", isOn: binding.pushMarketing)
                Toggle("Product news by email", isOn: binding.emailProduct)
                Toggle("Marketing by email", isOn: binding.emailMarketing)
                Stepper("At most \(binding.wrappedValue.dailyCap) optional notice\(binding.wrappedValue.dailyCap == 1 ? "" : "s") a day",
                        value: binding.dailyCap, in: NotificationPreferences.dailyCapRange)
                Button(busy ? "Saving…" : "Save choices") { Task { await save() } }
                    .disabled(busy || !hasChanges)
                    .accessibilityIdentifier("notifications.save")
                Text(binding.wrappedValue.devices.isEmpty
                     ? "Push delivery is not set up in this build and no device is registered, so nothing is pushed to this device yet. Your push choices are kept for when it is."
                     : "Push delivery is not set up in this build. The server lists \(binding.wrappedValue.devices.count) registered device\(binding.wrappedValue.devices.count == 1 ? "" : "s") for this account.")
                    .font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("notifications.push-status")
            } else if busy {
                ProgressView()
            }
            if let notice { Text(notice).font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary) }
        } header: {
            Text("Choices")
        } footer: {
            Text("Product news and marketing are off until you turn them on. Withdrawing marketing permission for your videos is in Privacy and policies.")
        }
    }

    @MainActor private func load() async {
        guard !busy else { return }
        let epoch = generation; busy = true
        defer { if epoch == generation { busy = false } }
        do {
            let loaded = try await client.inbox()
            if epoch == generation { inbox = loaded; inboxProblem = nil }
        } catch {
            if epoch == generation { inboxProblem = CommunityGateway.normalize(error).errorDescription }
        }
        guard epoch == generation else { return }
        do {
            let preferences = try await client.preferences()
            if epoch == generation { stored = preferences; draft = preferences; preferencesProblem = nil }
        } catch {
            if epoch == generation { preferencesProblem = CommunityGateway.normalize(error).errorDescription }
        }
    }

    @MainActor private func save() async {
        guard !busy, let stored, let draft else { return }
        let epoch = generation; busy = true; notice = nil
        defer { if epoch == generation { busy = false } }
        do {
            let saved = try await client.save(from: stored, to: draft)
            guard epoch == generation else { return }
            self.stored = saved; self.draft = saved; preferencesProblem = nil
            notice = "Choices saved."
        } catch {
            if epoch == generation { preferencesProblem = CommunityGateway.normalize(error).errorDescription }
        }
    }

    @MainActor private func open(_ notice: AnnouncementNotice) async {
        expanded.insert(notice.id)
        guard notice.isUnread, !busy else { return }
        let epoch = generation
        do {
            try await client.markRead(notice.delivery)
            guard epoch == generation else { return }
            // Show the server's state rather than assuming the change.
            let refreshed = try await client.inbox()
            if epoch == generation { inbox = refreshed }
        } catch {
            if epoch == generation { inboxProblem = CommunityGateway.normalize(error).errorDescription }
        }
    }
}
