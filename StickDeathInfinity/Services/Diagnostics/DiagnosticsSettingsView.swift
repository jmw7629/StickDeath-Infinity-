// ═══════════════════════════════════════════════════════════════════
// DiagnosticsSettingsView — opt-in switch, "what will be sent" preview,
// delete and send controls for first-party diagnostics (#291), plus the
// app-wide runtime that owns the queue and the MetricKit source.
//
// Off by default. The preview shows the exact JSON the uploader sends. When
// the build has no backend configuration the screen says so and nothing is
// attempted; counts stay on the device and expire after 30 days.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

@MainActor
final class DiagnosticsRuntime {
    static let shared = DiagnosticsRuntime()

    let center: DiagnosticsCenter
    let uploader: DiagnosticsUploader
    #if canImport(MetricKit) && os(iOS)
    private let source: DiagnosticsMetricKitSource
    #endif
    private var started = false

    private init() {
        center = DiagnosticsCenter()
        uploader = DiagnosticsUploader(center: center,
                                       submitter: DiagnosticsBackendSubmitter.configured(transport: SupabaseCommunityTransport.shared))
        #if canImport(MetricKit) && os(iOS)
        source = DiagnosticsMetricKitSource(center: center)
        #endif
    }

    /// Call once at launch: registers MetricKit only when opted in and counts the launch.
    func start() {
        guard !started else { return }
        started = true
        sync()
        center.record(.appLaunch)
    }

    func setOptedIn(_ value: Bool) {
        center.setOptedIn(value)
        sync()
    }

    private func sync() {
        #if canImport(MetricKit) && os(iOS)
        source.update()
        #endif
    }
}

@MainActor
struct DiagnosticsSettingsView: View {
    @ObservedObject private var center = DiagnosticsRuntime.shared.center
    @State private var showPreview = false
    @State private var status: String?
    @State private var sending = false

    private var queuedDays: Int { center.queue.reports.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { center.isOptedIn }, set: { DiagnosticsRuntime.shared.setOptedIn($0); status = nil })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share diagnostics").font(.specialElite(15)).foregroundColor(.sdTextPrimary)
                    Text("Daily counts of launches, crashes, hangs and terminations with the app version and iOS major version. No drawings, project names, prompts, account details, device identifiers or exact times.")
                        .font(.specialElite(11, relativeTo: .caption)).foregroundColor(.sdTextSecondary)
                }
            }
            .accessibilityIdentifier("settings.diagnostics.toggle")

            if center.isOptedIn {
                Text(queuedDays == 0 ? "Nothing queued on this device." : "\(queuedDays) day(s) queued on this device.")
                    .font(.specialElite(12, relativeTo: .caption)).foregroundColor(.sdTextSecondary)
                    .accessibilityIdentifier("settings.diagnostics.queued")
                HStack(spacing: 12) {
                    Button("View what will be sent") { showPreview = true }
                        .accessibilityIdentifier("settings.diagnostics.preview")
                    Button("Delete queued", role: .destructive) {
                        DiagnosticsRuntime.shared.center.deleteQueued()
                        status = center.lastError ?? "Queued diagnostics deleted."
                    }
                    .disabled(queuedDays == 0)
                    .accessibilityIdentifier("settings.diagnostics.delete")
                }
                .font(.specialElite(13))
                Button(sending ? "Sending…" : "Send completed days now") {
                    sending = true
                    Task {
                        status = await DiagnosticsRuntime.shared.uploader.uploadPending().message
                        sending = false
                    }
                }
                .font(.specialElite(13))
                .disabled(sending)
                .accessibilityIdentifier("settings.diagnostics.send")
            } else {
                Text(DiagnosticsUploadOutcome.disabled.message)
                    .font(.specialElite(12, relativeTo: .caption)).foregroundColor(.sdTextSecondary)
            }
            if let status {
                Text(status).font(.specialElite(12, relativeTo: .caption)).foregroundColor(.sdTextSecondary)
                    .accessibilityIdentifier("settings.diagnostics.status")
            }
        }
        .padding(16)
        .sheet(isPresented: $showPreview) {
            NavigationStack {
                ScrollView {
                    Text(center.previewJSON)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .accessibilityIdentifier("settings.diagnostics.payload")
                }
                .navigationTitle("Diagnostics payload")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPreview = false } } }
            }
        }
    }
}
