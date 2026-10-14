// ═══════════════════════════════════════════════════════════════════
// DiagnosticsMetricKit — iOS MetricKit source for the opt-in diagnostics
// queue (#291).
//
// MetricKit (MXMetricManager) delivers crash, hang, CPU and disk-write
// diagnostics and daily exit metrics from the OS. Only the *number* of each
// kind is kept, rounded to the payload's UTC day; call-stack trees, exception
// reasons, signal details and every other field are never stored or sent.
// While the creator has not opted in the subscriber is not registered at all,
// so the OS delivers nothing to the app. There is no in-process crash handler
// that could interfere with the Studio's save path.
// ═══════════════════════════════════════════════════════════════════

import Foundation

/// Foundation-only counts extracted from one OS payload; testable without MetricKit.
struct DiagnosticsPayloadSummary: Sendable {
    var crashes = 0
    var hangs = 0
    var cpuExceptions = 0
    var diskWriteExceptions = 0
    var memoryLimitExits = 0
    var watchdogExits = 0
    /// End of the payload's window; only its UTC day is used.
    var end: Date

    var counts: [(DiagnosticsCounter, Int)] {
        [(.crash, crashes), (.hang, hangs), (.cpuException, cpuExceptions), (.diskWriteException, diskWriteExceptions),
         (.memoryLimitExit, memoryLimitExits), (.watchdogExit, watchdogExits)].filter { $0.1 > 0 }
    }
}

extension DiagnosticsCenter {
    /// Records a summary's counts on its own day (no-op unless opted in).
    func apply(_ summary: DiagnosticsPayloadSummary) {
        for (counter, amount) in summary.counts { record(counter, amount: amount, at: summary.end) }
    }
}

#if canImport(MetricKit) && os(iOS)
import MetricKit

final class DiagnosticsMetricKitSource: NSObject, MXMetricManagerSubscriber {
    private weak var center: DiagnosticsCenter?
    private var registered = false

    @MainActor init(center: DiagnosticsCenter) { self.center = center; super.init() }

    /// Registers with MetricKit only while opted in; call at launch and after every toggle.
    @MainActor func update() {
        let wanted = center?.isOptedIn ?? false
        if wanted && !registered { MXMetricManager.shared.add(self); registered = true }
        else if !wanted && registered { MXMetricManager.shared.remove(self); registered = false }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let summaries = payloads.map { payload in
            DiagnosticsPayloadSummary(crashes: payload.crashDiagnostics?.count ?? 0,
                                      hangs: payload.hangDiagnostics?.count ?? 0,
                                      cpuExceptions: payload.cpuExceptionDiagnostics?.count ?? 0,
                                      diskWriteExceptions: payload.diskWriteExceptionDiagnostics?.count ?? 0,
                                      end: payload.timeStampEnd)
        }
        deliver(summaries)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let summaries = payloads.compactMap { payload -> DiagnosticsPayloadSummary? in
            guard let exits = payload.applicationExitMetrics else { return nil }
            let foreground = exits.foregroundExitData, background = exits.backgroundExitData
            return DiagnosticsPayloadSummary(
                memoryLimitExits: foreground.cumulativeMemoryResourceLimitExitCount + background.cumulativeMemoryResourceLimitExitCount,
                watchdogExits: foreground.cumulativeAppWatchdogExitCount + background.cumulativeAppWatchdogExitCount,
                end: payload.timeStampEnd)
        }
        deliver(summaries)
    }

    private func deliver(_ summaries: [DiagnosticsPayloadSummary]) {
        guard !summaries.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let center = self?.center else { return }
            for summary in summaries { center.apply(summary) }
        }
    }
}
#endif
