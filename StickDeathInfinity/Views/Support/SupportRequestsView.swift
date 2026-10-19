// ═══════════════════════════════════════════════════════════════════
// SupportRequestsView — Contact support (#272). Files a bounded request
// through SupportClient and lists the account's own requests with their
// receipt and status. Customer support only: no member-to-member messages,
// no attachments and no project upload. Without a configured backend or a
// signed-in account the screen says so and sends nothing.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SupportRequestsView: View {
    @ObservedObject private var auth = AuthService.shared
    @State private var category: SupportCategory = .studio
    @State private var subject = ""
    @State private var detail = ""
    /// One key per draft: a retry after a lost reply returns the same receipt.
    @State private var draftKey = UUID()
    @State private var requests: [SupportRequestSummary] = []
    @State private var busy = false
    @State private var message: String?
    @State private var listProblem: String?
    @State private var receipt: SupportReceipt?
    @State private var pendingWithdraw: SupportRequestSummary?
    @State private var pendingDelete: SupportRequestSummary?
    @State private var generation = UUID()

    private var client: SupportClient { SupportClient(gateway: CommunityServices.gateway) }
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }
    private var draftProblem: String? { SupportLimits.problem(subject: subject, body: detail) }

    var body: some View {
        List {
            if !CommunityServices.isConfigured {
                Section { Text(CommunityError.notConfigured.errorDescription ?? "").accessibilityIdentifier("support.not-configured") }
            } else if !auth.isAuthenticated {
                Section { Text("Sign in with a full account to contact support. Projects on this device do not need an account.") }
            } else {
                composeSection
                requestsSection
            }
            Section("Before you write") {
                Text("Support requests reach the StickDeath Infinity team only. Do not include passwords or payment card numbers. Projects stay on this device and are never attached; describe the problem instead. Up to \(SupportLimits.dailyRequests) requests per day.")
                    .font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
                Text("Requests are kept for up to 180 days, 90 days after they are resolved and 30 days after you withdraw or delete them.")
                    .font(.specialElite(12, relativeTo: .caption)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Contact support")
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated)") {
            generation = UUID(); busy = false; requests = []; receipt = nil; message = nil; listProblem = nil
            if auth.isAuthenticated && CommunityServices.isConfigured { await refresh() }
        }
        .confirmationDialog("Withdraw this request?", isPresented: Binding(get: { pendingWithdraw != nil }, set: { if !$0 { pendingWithdraw = nil } })) {
            if let item = pendingWithdraw {
                Button("Withdraw request", role: .destructive) { pendingWithdraw = nil; Task { await change(item, delete: false) } }
            }
            Button("Keep open", role: .cancel) { pendingWithdraw = nil }
        } message: { Text("The team stops working on it. Its text is kept for 30 days and then removed.") }
        .confirmationDialog("Delete this request's text?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            if let item = pendingDelete {
                Button("Delete text", role: .destructive) { pendingDelete = nil; Task { await change(item, delete: true) } }
            }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: { Text("The subject and description are removed from the server now. The receipt remains for 30 days for the daily limit.") }
    }

    private var composeSection: some View {
        Section("New request") {
            Picker("Topic", selection: $category) {
                ForEach(SupportCategory.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("support.category")
            TextField("Subject", text: $subject)
                .accessibilityIdentifier("support.subject")
            ZStack(alignment: .topLeading) {
                if detail.isEmpty {
                    Text("What happened, and what did you expect?").foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 4)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $detail).frame(minHeight: 140)
                    .accessibilityLabel("Description")
                    .accessibilityIdentifier("support.body")
            }
            Text("\(SupportLimits.length(SupportLimits.trimmed(detail))) of \(SupportLimits.body.upperBound) characters")
                .font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.secondary)
            Button(busy ? "Sending…" : "Send to support") { Task { await send() } }
                .disabled(busy || draftProblem != nil)
                .accessibilityIdentifier("support.send")
            if let receipt {
                Text(receipt.duplicate
                     ? "This request was already received. Receipt \(receipt.receipt)."
                     : "Received. Your receipt is \(receipt.receipt). Its status appears below.")
                    .accessibilityIdentifier("support.receipt")
            }
            if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("support.message") }
        }
    }

    private var requestsSection: some View {
        Section("Your requests") {
            if let listProblem { Text(listProblem).foregroundStyle(.secondary) }
            if requests.isEmpty && listProblem == nil && !busy { Text("No support requests.").foregroundStyle(.secondary) }
            ForEach(requests) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.subject).font(.specialElite(15, relativeTo: .body))
                    Text("\(item.statusTitle) · \(item.categoryTitle)").font(.specialElite(12, relativeTo: .caption))
                    Text("Receipt \(item.receipt) · sent \(item.created_at.formatted(date: .abbreviated, time: .shortened))")
                        .font(.specialElite(11, relativeTo: .caption)).foregroundStyle(.secondary)
                    HStack {
                        if item.canWithdraw {
                            Button("Withdraw") { pendingWithdraw = item }.buttonStyle(.borderless).disabled(busy)
                        }
                        Button("Delete text", role: .destructive) { pendingDelete = item }.buttonStyle(.borderless).disabled(busy)
                    }
                }
                .accessibilityElement(children: .contain)
            }
            Button("Refresh") { Task { await refresh() } }.disabled(busy)
        }
    }

    @MainActor private func send() async {
        guard !busy, draftProblem == nil else { return }
        let epoch = generation; busy = true; message = nil
        defer { if epoch == generation { busy = false } }
        do {
            let result = try await client.create(category: category, subject: subject, body: detail, appVersion: appVersion, idempotency: draftKey)
            guard epoch == generation else { return }
            receipt = result
            subject = ""; detail = ""; draftKey = UUID()
            busy = false
            await refresh()
        } catch {
            // The draft and its key are kept so a retry cannot file it twice.
            if epoch == generation { message = (CommunityGateway.normalize(error).errorDescription ?? "Not sent.") + " Your draft is kept." }
        }
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        let epoch = generation; busy = true
        defer { if epoch == generation { busy = false } }
        do {
            let rows = try await client.listMine()
            guard epoch == generation else { return }
            requests = rows; listProblem = nil
        } catch {
            if epoch == generation { listProblem = CommunityGateway.normalize(error).errorDescription }
        }
    }

    @MainActor private func change(_ item: SupportRequestSummary, delete: Bool) async {
        guard !busy else { return }
        let epoch = generation; busy = true; message = nil
        do {
            if delete { try await client.delete(item.id) } else { try await client.withdraw(item.id) }
            guard epoch == generation else { return }
            busy = false
            await refresh()
            message = nil
        } catch {
            if epoch == generation { busy = false; message = CommunityGateway.normalize(error).errorDescription }
        }
    }
}
