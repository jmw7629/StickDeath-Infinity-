// ═══════════════════════════════════════════════════════════════════
// NotificationsClient — the member's notification preferences and in-app
// announcements inbox (#290) over `sdi_notify_action`
// (backend/sql/notifications.sql).
//
// Push delivery is an owner gate: this build registers no device token and
// carries no APNs entitlement, so the push switches only record what the
// member wants once delivery exists. Transactional account and service notices
// are always allowed by the server; product and marketing notices are off
// until the member turns them on, within a daily cap of 0 to 10.
//
// Foundation-only so Tests/AccountServices runs on a Linux host.
// ═══════════════════════════════════════════════════════════════════

import Foundation

struct NotificationDevice: Decodable, Equatable, Identifiable {
    let id: UUID
    let platform: String
    let environment: String
    let created_at: Date
    let last_seen_at: Date
}

struct NotificationPreferences: Equatable {
    var pushProduct: Bool
    var pushMarketing: Bool
    var emailProduct: Bool
    var emailMarketing: Bool
    var dailyCap: Int
    /// The server's wording of the always-on transactional rule.
    let transactional: String
    let devices: [NotificationDevice]

    static let dailyCapRange = 0...10
}

/// Only the fields that changed are sent; the server keeps the rest.
struct NotificationPreferenceChanges: Encodable, Equatable, Sendable {
    var push_product: Bool? = nil
    var push_marketing: Bool? = nil
    var email_product: Bool? = nil
    var email_marketing: Bool? = nil
    var daily_cap: Int? = nil

    var isEmpty: Bool { self == NotificationPreferenceChanges() }

    static func between(_ old: NotificationPreferences, _ new: NotificationPreferences) -> NotificationPreferenceChanges {
        var changes = NotificationPreferenceChanges()
        if old.pushProduct != new.pushProduct { changes.push_product = new.pushProduct }
        if old.pushMarketing != new.pushMarketing { changes.push_marketing = new.pushMarketing }
        if old.emailProduct != new.emailProduct { changes.email_product = new.emailProduct }
        if old.emailMarketing != new.emailMarketing { changes.email_marketing = new.emailMarketing }
        if old.dailyCap != new.dailyCap { changes.daily_cap = new.dailyCap }
        return changes
    }
}

struct AnnouncementNotice: Decodable, Equatable, Identifiable {
    let delivery: UUID
    let title: String
    let body: String
    let category: String
    let state: String
    let delivered_at: Date
    var id: UUID { delivery }
    var isUnread: Bool { state == "sent" }
    var categoryTitle: String {
        switch category {
        case "transactional": return "Account and service"
        case "product": return "Product news"
        case "marketing": return "Marketing"
        default: return category.capitalized
        }
    }
}

struct AnnouncementInbox: Equatable {
    let notices: [AnnouncementNotice]
    let unread: Int
}

struct NotifyActionRequest<Payload: Encodable & Sendable & Equatable>: Encodable, Equatable, Sendable {
    let action: String
    let payload: Payload
}
struct NotifyEmptyPayload: Encodable, Equatable, Sendable {}
struct NotifyDeliveryPayload: Encodable, Equatable, Sendable { let delivery: UUID }

struct NotifyActionResponse: CommunityResponse {
    let error: String?
    let status: String?
    let push_product: Bool?
    let push_marketing: Bool?
    let email_product: Bool?
    let email_marketing: Bool?
    let daily_cap: Int?
    let transactional: String?
    let devices: [NotificationDevice]?
    let notices: [AnnouncementNotice]?
    let unread: Int?
}

@MainActor
final class NotificationsClient {
    let gateway: CommunityGateway
    init(gateway: CommunityGateway) { self.gateway = gateway }

    func preferences() async throws -> NotificationPreferences {
        let response = try await gateway.call("sdi_notify_action", params: NotifyActionRequest(action: "preferences", payload: NotifyEmptyPayload()),
                                              as: NotifyActionResponse.self)
        guard let pushProduct = response.push_product, let pushMarketing = response.push_marketing,
              let emailProduct = response.email_product, let emailMarketing = response.email_marketing,
              let cap = response.daily_cap, NotificationPreferences.dailyCapRange.contains(cap),
              let devices = response.devices else {
            throw CommunityError.invalidResponse("Notification preferences were incomplete.")
        }
        return NotificationPreferences(pushProduct: pushProduct, pushMarketing: pushMarketing, emailProduct: emailProduct,
                                       emailMarketing: emailMarketing, dailyCap: cap,
                                       transactional: response.transactional ?? "always on for account and service notices", devices: devices)
    }

    /// Saves only what changed, then reads the stored values back so the screen
    /// shows the server's record rather than the local edit.
    func save(from old: NotificationPreferences, to new: NotificationPreferences) async throws -> NotificationPreferences {
        let changes = NotificationPreferenceChanges.between(old, new)
        guard !changes.isEmpty else { return old }
        if let cap = changes.daily_cap, !NotificationPreferences.dailyCapRange.contains(cap) {
            throw CommunityError.server(message: "Daily cap must be 0 to 10.", code: nil)
        }
        let response = try await gateway.call("sdi_notify_action", params: NotifyActionRequest(action: "set_preferences", payload: changes),
                                              as: NotifyActionResponse.self)
        guard response.status == "confirmed" else { throw CommunityError.invalidResponse("The server did not confirm the preferences.") }
        return try await preferences()
    }

    func inbox() async throws -> AnnouncementInbox {
        let response = try await gateway.call("sdi_notify_action", params: NotifyActionRequest(action: "inbox", payload: NotifyEmptyPayload()),
                                              as: NotifyActionResponse.self)
        guard let notices = response.notices, notices.count <= 50, let unread = response.unread, unread >= 0 else {
            throw CommunityError.invalidResponse("Announcements unavailable.")
        }
        return AnnouncementInbox(notices: notices, unread: unread)
    }

    /// True when the server marked the notice read; false when it was already read.
    @discardableResult
    func markRead(_ delivery: UUID) async throws -> Bool {
        let response = try await gateway.call("sdi_notify_action", params: NotifyActionRequest(action: "mark_read", payload: NotifyDeliveryPayload(delivery: delivery)),
                                              as: NotifyActionResponse.self)
        switch response.status {
        case "confirmed": return true
        case "unchanged": return false
        default: throw CommunityError.invalidResponse("The server did not confirm the change.")
        }
    }
}
