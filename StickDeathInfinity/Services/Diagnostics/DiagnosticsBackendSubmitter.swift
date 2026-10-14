// ═══════════════════════════════════════════════════════════════════
// DiagnosticsBackendSubmitter — production DiagnosticsSubmitting over the
// existing CommunityTransport seam (#291). Calls `sdi_diagnostics_submit`
// with the member's own session; the server derives nothing from the payload
// beyond the coarse counters. Without validated Supabase configuration or a
// session the call fails before any request, and the uploader keeps the
// queue on the device. App target only (needs CommunityTransport).
// ═══════════════════════════════════════════════════════════════════

import Foundation

@MainActor
final class DiagnosticsBackendSubmitter: DiagnosticsSubmitting {
    private struct Params: Encodable, Sendable {
        let report: DiagnosticsReport
        let consent: Bool
    }

    let transport: CommunityTransport
    init(transport: CommunityTransport) { self.transport = transport }

    /// nil when the build has no backend configuration, so the settings screen
    /// shows "not available" rather than attempting a call that cannot succeed.
    static func configured(transport: CommunityTransport) -> DiagnosticsBackendSubmitter? {
        guard AppConfig.supabaseConfiguration != nil else { return nil }
        return DiagnosticsBackendSubmitter(transport: transport)
    }

    func submit(_ report: DiagnosticsReport) async throws -> Data {
        guard transport.hasSession else { throw CommunityError.signedOut }
        // `consent` records that this upload follows the on-device opt-in; the
        // server refuses any call without it.
        return try await transport.rpc("sdi_diagnostics_submit", params: Params(report: report, consent: true)).data
    }
}
