// ═══════════════════════════════════════════════════════════════════
// DiagnosticsUploader — sends completed day-buckets to the first-party
// intake RPC `sdi_diagnostics_submit` (backend/sql/diagnostics.sql) (#291).
//
// Foundation only. The transport is injected: with no configured backend the
// uploader reports a truthful "not available" state and keeps the queue on
// the device, where it still expires after 30 days or is deleted on request.
// Only buckets the server acknowledges are removed. No third-party SDK.
// ═══════════════════════════════════════════════════════════════════

import Foundation

/// The server's answer for one report.
enum DiagnosticsSubmitReply: Equatable {
    case accepted
    /// The account already sent this bucket (an earlier acknowledgement was lost).
    case duplicate
    /// The server refused the payload or the account; the message is the server's.
    case refused(String)
    case rateLimited

    /// Parses `{"status":"accepted"|"duplicate"}` or `{"error":"…","code":"…"}`.
    static func parse(_ data: Data) -> DiagnosticsSubmitReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .refused("The diagnostics service returned an unreadable response.")
        }
        if let status = object["status"] as? String {
            if status == "accepted" { return .accepted }
            if status == "duplicate" { return .duplicate }
        }
        if (object["code"] as? String) == "rate_limited" { return .rateLimited }
        let message = (object["error"] as? String).map { String($0.prefix(200)) }
        return .refused(message ?? "The diagnostics service refused the report.")
    }
}

/// One call per report. Implementations send exactly this sanitized report
/// (its `DiagnosticsCoding` JSON) and return the raw reply body.
@MainActor
protocol DiagnosticsSubmitting: AnyObject {
    func submit(_ report: DiagnosticsReport) async throws -> Data
}

enum DiagnosticsUploadOutcome: Equatable {
    case disabled
    case notConfigured
    case nothingToSend
    case sent(Int)
    case partial(sent: Int, message: String)
    case failed(String)

    var message: String {
        switch self {
        case .disabled: return "Diagnostics are off. Nothing is collected or sent."
        case .notConfigured: return "Diagnostics upload is not available in this build. Counts stay on this device and are deleted after 30 days or when you delete them."
        case .nothingToSend: return "Nothing to send yet. Only completed days are sent."
        case .sent(let count): return count == 1 ? "Sent 1 day of diagnostics." : "Sent \(count) days of diagnostics."
        case .partial(let sent, let message): return "Sent \(sent) of the queued days. \(message)"
        case .failed(let message): return message
        }
    }
}

@MainActor
final class DiagnosticsUploader {
    let center: DiagnosticsCenter
    let submitter: DiagnosticsSubmitting?

    init(center: DiagnosticsCenter, submitter: DiagnosticsSubmitting?) {
        self.center = center; self.submitter = submitter
    }

    func uploadPending() async -> DiagnosticsUploadOutcome {
        guard center.isOptedIn else { return .disabled }
        guard let submitter else { return .notConfigured }
        let pending = center.queue.uploadable(now: center.currentDate)
        guard !pending.isEmpty else { return .nothingToSend }
        var sent: [DiagnosticsReport] = []
        var dropped: [DiagnosticsReport] = []
        var problem: String?
        for report in pending {
            // Opting out mid-upload stops further sends; the queue is already gone.
            guard center.isOptedIn, !Task.isCancelled else { break }
            guard let clean = DiagnosticsSanitizer.sanitized(report) else {
                dropped.append(report) // Contract-breaking buckets are dropped, never sent.
                continue
            }
            do {
                switch DiagnosticsSubmitReply.parse(try await submitter.submit(clean)) {
                case .accepted, .duplicate: sent.append(report)
                case .rateLimited: problem = "The diagnostics service asked to wait; the rest will be sent later."
                case .refused(let message): problem = message
                }
            } catch {
                problem = "The diagnostics service could not be reached. Queued days stay on this device."
            }
            if problem != nil { break }
        }
        if center.isOptedIn { center.acknowledge(sent + dropped) }
        let delivered = sent.count
        if let problem { return delivered == 0 ? .failed(problem) : .partial(sent: delivered, message: problem) }
        return delivered == 0 ? .nothingToSend : .sent(delivered)
    }
}
