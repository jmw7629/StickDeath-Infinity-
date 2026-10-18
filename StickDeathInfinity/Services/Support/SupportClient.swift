// ═══════════════════════════════════════════════════════════════════
// SupportClient — the member side of customer support intake (#272) over
// `sdi_support_action` (backend/sql/support-requests.sql): file a bounded
// request with a server receipt, list the account's own requests and
// withdraw or delete one. This is support, not messaging: nothing here
// reaches another member, no attachment is sent and no project is uploaded.
//
// Foundation-only so Tests/AccountServices runs on a Linux host. Every
// outcome comes from the server reply; a request counts as filed only when
// the server returns its receipt.
// ═══════════════════════════════════════════════════════════════════

import Foundation

enum SupportCategory: String, CaseIterable, Identifiable, Equatable {
    case account, billing, studio, publishing, rights, safety, bug, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .account: return "Account and sign-in"
        case .billing: return "Plans and billing"
        case .studio: return "Studio and projects"
        case .publishing: return "Publishing and reviews"
        case .rights: return "Rights and attribution"
        case .safety: return "Safety or abuse"
        case .bug: return "Something is broken"
        case .other: return "Something else"
        }
    }
}

/// Bounds mirror the server's checks so the form explains a refusal before sending.
enum SupportLimits {
    static let subject = 1...120
    static let body = 1...2000
    static let appVersion = 50
    static let dailyRequests = 5

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nil when the draft can be sent; otherwise the reason it cannot.
    static func problem(subject: String, body: String) -> String? {
        let subjectCount = trimmed(subject).count
        let bodyCount = trimmed(body).count
        if !Self.subject.contains(subjectCount) { return "Add a subject of up to \(Self.subject.upperBound) characters." }
        if !Self.body.contains(bodyCount) { return "Describe the issue in up to \(Self.body.upperBound) characters." }
        return nil
    }
}

struct SupportRequestSummary: Decodable, Equatable, Identifiable {
    let id: UUID
    let receipt: String
    let category: String
    let platform: String
    let app_version: String?
    let subject: String
    let body: String
    let status: String
    let revision: Int64
    let created_at: Date
    let updated_at: Date

    /// The server allows withdrawal only while a request is still open.
    var canWithdraw: Bool { ["open", "in_progress", "waiting_on_member"].contains(status) }
    var statusTitle: String { SupportRequestSummary.statusTitle(status) }
    var categoryTitle: String { SupportCategory(rawValue: category)?.title ?? category }

    static func statusTitle(_ status: String) -> String {
        switch status {
        case "open": return "Received"
        case "in_progress": return "In progress"
        case "waiting_on_member": return "Waiting for your reply"
        case "resolved": return "Resolved"
        case "withdrawn": return "Withdrawn"
        case "deleted": return "Deleted"
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Server receipt for a filed request. `duplicate` means the same draft was
/// already filed (for example a retry after a lost reply); nothing new was created.
struct SupportReceipt: Equatable {
    let requestID: UUID
    let receipt: String
    let status: String
    let duplicate: Bool
}

struct SupportActionRequest: Encodable, Equatable, Sendable {
    let action: String
    var request: UUID? = nil
    var category: String? = nil
    var platform: String? = nil
    var app_version: String? = nil
    var subject: String? = nil
    var body: String? = nil
    var idempotency: UUID? = nil
}

struct SupportActionResponse: CommunityResponse {
    let error: String?
    let status: String?
    let request_id: UUID?
    let receipt: String?
    let request_status: String?
    let requests: [SupportRequestSummary]?
}

@MainActor
final class SupportClient {
    static let receiptPattern = "^SDI-[A-Z0-9]{10}$"
    let gateway: CommunityGateway
    init(gateway: CommunityGateway) { self.gateway = gateway }

    /// Files one request. Reuse the same `idempotency` key when retrying a draft
    /// whose reply was lost, so the server returns the existing receipt.
    func create(category: SupportCategory, subject: String, body: String, appVersion: String,
                platform: String = "ios", idempotency: UUID) async throws -> SupportReceipt {
        if let problem = SupportLimits.problem(subject: subject, body: body) { throw CommunityError.server(message: problem, code: nil) }
        let version = String(appVersion.prefix(SupportLimits.appVersion))
        let request = SupportActionRequest(action: "create", category: category.rawValue, platform: platform, app_version: version,
                                           subject: SupportLimits.trimmed(subject), body: SupportLimits.trimmed(body), idempotency: idempotency)
        let response = try await gateway.call("sdi_support_action", params: request, as: SupportActionResponse.self)
        guard let status = response.status, ["created", "duplicate"].contains(status),
              let id = response.request_id, let receipt = response.receipt,
              receipt.range(of: Self.receiptPattern, options: .regularExpression) != nil else {
            throw CommunityError.invalidResponse("The server did not return a receipt. Refresh your requests before sending again.")
        }
        return SupportReceipt(requestID: id, receipt: receipt, status: response.request_status ?? "open", duplicate: status == "duplicate")
    }

    func listMine() async throws -> [SupportRequestSummary] {
        let response = try await gateway.call("sdi_support_action", params: SupportActionRequest(action: "list_mine"), as: SupportActionResponse.self)
        guard let requests = response.requests, requests.count <= 50 else { throw CommunityError.invalidResponse("Support requests unavailable.") }
        return requests
    }

    func withdraw(_ request: UUID) async throws { try await confirm(SupportActionRequest(action: "withdraw", request: request)) }
    /// Scrubs the request's text on the server; the receipt stub expires after 30 days.
    func delete(_ request: UUID) async throws { try await confirm(SupportActionRequest(action: "delete", request: request)) }

    private func confirm(_ request: SupportActionRequest) async throws {
        let response = try await gateway.call("sdi_support_action", params: request, as: SupportActionResponse.self)
        guard response.status == "confirmed" else { throw CommunityError.invalidResponse("The server did not confirm the change. Refresh before retrying.") }
    }
}
