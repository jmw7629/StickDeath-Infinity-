package com.stickdeath.studio.connect

import org.json.JSONObject

// Account lifecycle (#262) and notification preferences / announcements inbox (#290) over the same
// RPCs iOS and the website use (backend/sql/account-lifecycle.sql, notifications.sql). The client
// never deletes anything itself: it files a server deletion request with a seven-day cooling-off
// period and can cancel it. Exports return the member's own server records unmodified. No push
// transport exists on Android (FCM is an owner gate), so no device token is registered here.

/** Mirrors iOS `AuthService.AccountDeletionStatus`. */
data class AccountDeletionStatus(val state: State, val scheduledFor: String?, val revision: Int?) {
    enum class State(val wire: String) { Pending("pending"), Processing("processing"), Blocked("blocked"), Completed("completed"), Cancelled("cancelled");
        companion object { fun of(raw: String?) = entries.firstOrNull { it.wire == raw } }
    }
    val isOpen get() = state == State.Pending || state == State.Processing || state == State.Blocked
    val canCancel get() = state == State.Pending && revision != null
}
data class AccountLifecycleStatus(val deletion: AccountDeletionStatus?, val exportsRemainingToday: Int?, val note: String)

class AccountLifecycleClient(private val gateway: CommunityGateway) {
    private fun lifecycle(action: String, revision: Int? = null): JSONObject =
        gateway.call("sdi_account_lifecycle", JSONObject().put("action", action).put("revision", revision ?: JSONObject.NULL))

    /** Current request (null when none was ever filed) plus the server's retention note. */
    fun status(): AccountLifecycleStatus {
        val reply = lifecycle("status")
        val deletion = reply.optJSONObject("deletion")?.let { d ->
            val state = AccountDeletionStatus.State.of(d.str("state")) ?: throw CommunityException.InvalidResponse("The server returned an unknown deletion state.")
            AccountDeletionStatus(state, d.str("scheduled_for"), d.int("revision"))
        }
        val remaining = reply.int("exports_remaining_today")?.coerceIn(0, 3)
        return AccountLifecycleStatus(deletion, remaining, reply.str("note").orEmpty())
    }
    /** Files (or returns the already open) deletion request. Nothing is removed now. */
    fun requestDeletion(): AccountDeletionStatus {
        val reply = lifecycle("request_deletion")
        val state = AccountDeletionStatus.State.of(reply.str("status")) ?: throw CommunityException.InvalidResponse("The server returned an unknown deletion state. Nothing was deleted.")
        return AccountDeletionStatus(state, reply.str("scheduled_for"), reply.int("revision"))
    }
    /** Cancels a pending request at the revision the member last saw. */
    fun cancelDeletion(revision: Int) {
        if (lifecycle("cancel_deletion", revision).str("status") != "cancelled") {
            throw CommunityException.InvalidResponse("The deletion request could not be cancelled. Refresh and try again.")
        }
    }
    /** The member's own server records as the server returned them (three exports a day, enforced
     * server-side). Projects and originals stay on the device and are not part of this file. */
    fun export(): String {
        val reply = gateway.call("sdi_account_lifecycle", JSONObject().put("action", "export"))
        if (!reply.has("generated_at") || !reply.has("account")) throw CommunityException.InvalidResponse("The export was incomplete. Nothing was saved.")
        return reply.toString(2)
    }
    companion object {
        /** `stickdeath-account-export-YYYY-MM-DD.json` in UTC, the iOS file name. */
        fun exportFileName(nowMillis: Long = System.currentTimeMillis()): String =
            "stickdeath-account-export-" + java.time.Instant.ofEpochMilli(nowMillis).toString().substring(0, 10) + ".json"
    }
}

// MARK: Notifications (sdi_notify_action)

/** Server-held preferences. Transactional notices are always on; product and marketing are opt-in. */
data class ServerNotificationPreferences(
    val pushProduct: Boolean, val pushMarketing: Boolean, val emailProduct: Boolean, val emailMarketing: Boolean,
    val dailyCap: Int, val transactionalNote: String, val registeredDevices: Int,
)
data class InboxNotice(val delivery: String, val title: String, val body: String, val category: String, val state: String, val deliveredAt: String) {
    val unread get() = state == "sent"
}
data class NotificationInbox(val notices: List<InboxNotice>, val unread: Int)

class NotificationsClient(private val gateway: CommunityGateway) {
    private fun action(name: String, payload: JSONObject = JSONObject()) = gateway.call("sdi_notify_action", JSONObject().put("action", name).put("payload", payload))

    fun preferences(): ServerNotificationPreferences {
        val o = action("preferences")
        fun flag(key: String) = o.bool(key) ?: throw CommunityException.InvalidResponse("Notification preferences were incomplete.")
        val cap = o.int("daily_cap")?.takeIf { it in 0..10 } ?: throw CommunityException.InvalidResponse("Notification preferences were incomplete.")
        return ServerNotificationPreferences(flag("push_product"), flag("push_marketing"), flag("email_product"), flag("email_marketing"),
            cap, o.str("transactional").orEmpty(), o.optJSONArray("devices")?.length() ?: 0)
    }
    /** Saves the four opt-ins and the cap; the server stores them only after this confirms. */
    fun save(value: ServerNotificationPreferences) {
        require(value.dailyCap in 0..10) { "Daily cap must be 0 to 10." }
        val payload = JSONObject().put("push_product", value.pushProduct).put("push_marketing", value.pushMarketing)
            .put("email_product", value.emailProduct).put("email_marketing", value.emailMarketing).put("daily_cap", value.dailyCap)
        if (action("set_preferences", payload).str("status") != "confirmed") throw CommunityException.InvalidResponse("The server did not confirm the notification preferences.")
    }
    fun inbox(): NotificationInbox {
        val reply = action("inbox")
        val items = reply.optJSONArray("notices") ?: throw CommunityException.InvalidResponse("Announcements unavailable.")
        val unread = reply.int("unread")?.takeIf { it >= 0 } ?: throw CommunityException.InvalidResponse("Announcements unavailable.")
        if (items.length() > 50) throw CommunityException.InvalidResponse("The server returned more announcements than allowed.")
        return NotificationInbox(items.objects().map { InboxNotice(requireUuidOr(it.need("delivery")), it.str("title").orEmpty(), it.str("body").orEmpty(),
            it.str("category").orEmpty(), it.need("state"), it.str("delivered_at").orEmpty()) }, unread)
    }
    /** True when the server marked it read; `unchanged` (already read or not this member's) is false. */
    fun markRead(delivery: String): Boolean = action("mark_read", JSONObject().put("delivery", requireUuid(delivery))).str("status") == "confirmed"
}
