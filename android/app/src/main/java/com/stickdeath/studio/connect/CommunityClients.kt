package com.stickdeath.studio.connect

import org.json.JSONArray
import org.json.JSONObject

// Kotlin mirrors of the iOS FeedClient, ProfileClient and RoomsClient over the same RPC contracts
// (backend/sql/video-feed.sql, profile-records.sql, achievements.sql, feed-publication.sql,
// room-invitations.sql, rooms-v2.sql). Values are shown only when a server reply supplies them:
// nothing here invents counts, matches, viewers, badges or balances. No messaging or calls exist.

internal fun JSONObject.str(key: String): String? = if (isNull(key)) null else optString(key).takeIf { has(key) }
internal fun JSONObject.int(key: String): Int? = if (!has(key) || isNull(key)) null else (opt(key) as? Number)?.toInt()
internal fun JSONObject.bool(key: String): Boolean? = if (!has(key) || isNull(key)) null else opt(key) as? Boolean
internal fun JSONObject.need(key: String): String = str(key)?.takeIf { it.isNotEmpty() } ?: throw CommunityException.InvalidResponse("The reply did not match the expected contract.")
internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { optJSONObject(it) ?: throw CommunityException.InvalidResponse("The reply did not match the expected contract.") }
internal val UUID_PATTERN = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
internal fun requireUuid(value: String): String { require(UUID_PATTERN.matches(value)) { "Not a UUID" }; return value.lowercase() }

// MARK: Feed

enum class FeedCategory(val wire: String, val explanation: String) {
    Trending("trending", "Ranked by likes in the last seven days, then newest."),
    Recent("recent", "Newest approved videos first."),
    Following("following", "Approved videos from creators you follow."),
    Featured("featured", "Videos an administrator placed in Featured, newest first.");
    val title get() = name
}
enum class FeedReportReason(val wire: String) { Rights("rights"), Abuse("abuse"), Unsafe("unsafe"), Spam("spam") }

data class FeedPost(
    val id: String, val creator: String, val creatorName: String, val caption: String, val publishedAt: String,
    val allowExport: Boolean, val title: String, val url: String, val likes: Int, val liked: Boolean, val following: Boolean,
) {
    val safeUrl: String? get() = CommunityGateway.checkedMediaUrl(url)
    companion object {
        fun parse(o: JSONObject): FeedPost {
            fun b(key: String) = o.bool(key) ?: throw CommunityException.InvalidResponse("The feed returned an incomplete post.")
            val likes = o.int("likes")?.takeIf { it >= 0 } ?: throw CommunityException.InvalidResponse("The feed returned an incomplete post.")
            return FeedPost(requireUuidOr(o.need("id")), requireUuidOr(o.need("creator")), o.str("creator_name").orEmpty(), o.str("caption").orEmpty(),
                o.need("published_at"), b("allow_export"), o.str("title").orEmpty(), o.need("url"), likes, b("liked"), b("following"))
        }
    }
}
internal fun requireUuidOr(value: String) = if (UUID_PATTERN.matches(value)) value.lowercase() else throw CommunityException.InvalidResponse("The reply carried an invalid identifier.")

data class FeedPage(val posts: List<FeedPost>, val hasMore: Boolean, val asOf: String?)

class FeedClient(private val gateway: CommunityGateway) {
    /** One server page (25 posts, at most 40 pages). Later pages send page 0's `as_of` snapshot. */
    fun page(category: FeedCategory, page: Int, asOf: String? = null): FeedPage {
        if (page !in 0 until MAXIMUM_PAGES) throw CommunityException.InvalidResponse("Feed page out of range.")
        val request = JSONObject().put("action", "list").put("category", category.wire).put("page", page).put("enabled", true)
        if (page != 0 && asOf != null) request.put("as_of", asOf)
        val reply = gateway.call("sdi_feed_action", request)
        val posts = reply.optJSONArray("posts") ?: throw CommunityException.InvalidResponse("The feed returned an incomplete response.")
        val more = reply.bool("has_more") ?: throw CommunityException.InvalidResponse("The feed returned an incomplete response.")
        if (posts.length() > PAGE_SIZE) throw CommunityException.InvalidResponse("The feed page exceeded the server bound.")
        return FeedPage(posts.objects().map(FeedPost::parse), more && page + 1 < MAXIMUM_PAGES, reply.str("as_of"))
    }

    /** True only when the server says `confirmed`; the caller rolls back any optimistic ±1 otherwise. */
    private fun mutate(request: JSONObject): Boolean = gateway.call("sdi_feed_action", request.put("category", "recent").put("page", 0)).str("status") == "confirmed"
    fun like(post: String, enabled: Boolean) = mutate(JSONObject().put("action", "like").put("post_id", requireUuid(post)).put("enabled", enabled))
    fun follow(creator: String, enabled: Boolean) = mutate(JSONObject().put("action", "follow").put("target", requireUuid(creator)).put("enabled", enabled))
    fun block(creator: String) = mutate(JSONObject().put("action", "block").put("target", requireUuid(creator)).put("enabled", true))
    fun report(post: String, reason: FeedReportReason) = mutate(JSONObject().put("action", "report").put("post_id", requireUuid(post)).put("reason", reason.wire).put("enabled", true))

    companion object { const val PAGE_SIZE = 25; const val MAXIMUM_PAGES = 40 }
}

// MARK: Profile records, achievements, portfolio, export permission

data class EarnedBadge(val id: String, val title: String, val criterionVersion: String, val earnedAt: String)
data class ProfileRecords(
    val showRecords: Boolean?, val showBadges: Boolean?, val revision: Int?,
    val wins: Int?, val losses: Int?, val ties: Int?, val badges: List<EarnedBadge>?,
) {
    /** Own-account replies must carry every field; another account's reply omits hidden totals. */
    val isCompleteOwnRecord get() = showRecords != null && showBadges != null && revision != null && wins != null && losses != null && ties != null && badges != null
    companion object {
        fun parse(o: JSONObject) = ProfileRecords(o.bool("show_records"), o.bool("show_badges"), o.int("revision"),
            o.int("wins"), o.int("losses"), o.int("ties"),
            o.optJSONArray("badges")?.objects()?.map { EarnedBadge(it.need("id"), it.need("title"), it.need("criterion_version"), it.need("earned_at")) })
    }
}
data class Achievement(val key: String, val title: String, val description: String, val kind: String, val threshold: Int, val earnedAt: String?, val badgeId: String?) {
    val isEarned get() = earnedAt != null && badgeId != null
    val category get() = when (kind) { "war_matches", "war_wins" -> "War Room"; "challenge_wins" -> "Challenges"; else -> kind.replace('_', ' ').replaceFirstChar { it.uppercase() } }
}
data class ApprovedMedia(val id: String, val title: String, val url: String)

class ProfileClient(private val gateway: CommunityGateway) {
    fun readRecords(): ProfileRecords {
        val records = ProfileRecords.parse(gateway.call("sdi_profile_records", JSONObject().put("action", "read")))
        if (!records.isCompleteOwnRecord) throw CommunityException.InvalidResponse("Records response incomplete. Refresh before saving.")
        return records
    }
    /** Another creator's record: hidden totals arrive as null and stay hidden. */
    fun readRecords(subject: String) = ProfileRecords.parse(gateway.call("sdi_profile_records", JSONObject().put("action", "read").put("subject", requireUuid(subject))))
    fun saveRecords(revision: Int, showRecords: Boolean, showBadges: Boolean): ProfileRecords {
        val reply = ProfileRecords.parse(gateway.call("sdi_profile_records", JSONObject().put("action", "save").put("revision", revision).put("records", showRecords).put("badges", showBadges)))
        if (!reply.isCompleteOwnRecord || reply.showRecords != showRecords || reply.showBadges != showBadges) {
            throw CommunityException.InvalidResponse("The server did not confirm the display preferences.")
        }
        return reply
    }
    fun achievements(): List<Achievement> {
        val items = gateway.call("sdi_achievement_catalog").optJSONArray("achievements") ?: throw CommunityException.InvalidResponse("Achievement catalogue unavailable.")
        return items.objects().map { Achievement(it.need("badge_key"), it.need("title"), it.str("description").orEmpty(), it.need("kind"),
            it.int("threshold") ?: 0, it.str("earned_at"), it.str("badge_id")) }
    }
    /** The creator's own approved, unexpired renditions (RLS already limits rows). */
    fun portfolio(account: String): List<ApprovedMedia> =
        gateway.rows("sdi_watch_media", "id,title,url,duration,expires_at,approved", listOf("owner_id" to requireUuid(account)), 100)
            .objects().filter { it.bool("approved") != false && CommunityGateway.checkedMediaUrl(it.str("url")) != null }
            .map { ApprovedMedia(it.need("id"), it.str("title").orEmpty(), it.need("url")) }
            .sortedBy { it.title.lowercase() }
    fun setExportPermission(review: String, version: Int, allowed: Boolean): Boolean {
        val reply = gateway.call("sdi_export_consent", JSONObject().put("review", requireUuid(review)).put("version", version).put("allowed", allowed))
        return reply.str("status") == "confirmed" && reply.bool("allow_export") == allowed
    }
}

// MARK: Rooms — invitation-based collaboration on explicitly shared projects

object RoomInvitationPolicy {
    const val CODE_LENGTH = 64
    fun normalize(raw: String) = raw.trim().lowercase()
    fun isWellFormed(raw: String) = normalize(raw).let { code -> code.length == CODE_LENGTH && code.all { it in '0'..'9' || it in 'a'..'f' } }
    /** Forwardable text: an admission-request code, never an account credential. */
    fun shareText(code: String, roomTitle: String) =
        "StickDeath Infinity room invitation for \"$roomTitle\". Open Rooms, choose Review invitation and paste: $code — the owner still approves every request. Expires after 24 hours or 20 uses."
}

data class RoomSummary(val id: String, val ownerId: String, val title: String, val projectTitle: String?, val permissions: List<String>?, val commandRevision: Int = 0) {
    val sharesEdit get() = permissions?.contains("edit") ?: false
}
data class InvitationPreview(val room: String, val title: String)
sealed class AdmissionOutcome { abstract val room: String
    data class PendingOwnerApproval(override val room: String) : AdmissionOutcome()
    data class AlreadyRequested(override val room: String) : AdmissionOutcome()
}
data class PendingRequest(val roomId: String, val title: String, val ownerId: String, val expiresAt: String)

/** Owner-chosen project share reference: a local project's identifier only (iOS `RoomProjectShare`). */
object RoomProjectShare {
    const val PREFIX = "device-project:"
    /** The device project id named by a room's reference, if it is one. */
    fun projectID(reference: String?): String? =
        reference?.takeIf { it.startsWith(PREFIX) }?.removePrefix(PREFIX)?.takeIf { UUID_PATTERN.matches(it) }?.lowercase()
}

enum class RoomRole(val wire: String) { Editor("editor"), Viewer("viewer") }

/** `sdi_room_manage` summary (rooms-v2.sql). Absent fields stay null and are shown as unavailable. */
data class RoomDetail(val roomId: String, val title: String?, val ownerId: String?, val projectRef: String?, val projectTitle: String?,
                      val permissions: List<String>?, val projectRevision: Int?, val commandRevision: Int?, val myRole: String?,
                      val canEdit: Boolean?, val members: Int?) {
    val projectID get() = RoomProjectShare.projectID(projectRef)
    companion object {
        fun parse(o: JSONObject) = RoomDetail(requireUuidOr(o.need("room_id")), o.str("title"), o.str("owner_id")?.let(::requireUuidOr), o.str("project_ref"),
            o.str("project_title"), o.optJSONArray("permissions")?.let { a -> (0 until a.length()).map { a.getString(it) } },
            o.int("project_revision"), o.int("command_revision")?.coerceAtLeast(0), o.str("my_role"), o.bool("can_edit"),
            o.int("members")?.also { if (it < 0) throw CommunityException.InvalidResponse("The server reported a negative member count.") })
    }
}

/** `sdi_room_members` row visible under RLS (the owner sees every row; a member sees their own). */
data class RoomMember(val userId: String, val ownerApproved: Boolean, val memberAccepted: Boolean, val revoked: Boolean, val role: String?, val requestExpiresAt: String?) {
    val isActive get() = ownerApproved && memberAccepted && !revoked
    /** A recipient's consented request still waiting for the owner. */
    val awaitsApproval get() = memberAccepted && !ownerApproved && !revoked
    val statusText get() = when { revoked -> "Removed"; isActive -> "Accepted"; memberAccepted -> "Awaiting owner approval"; else -> "Pending" }
    companion object {
        fun parse(o: JSONObject): RoomMember {
            fun b(key: String) = o.bool(key) ?: throw CommunityException.InvalidResponse("A membership row was incomplete.")
            return RoomMember(requireUuidOr(o.need("user_id")), b("owner_approved"), b("member_accepted"), b("revoked"), o.str("role"), o.str("request_expires_at"))
        }
    }
}

class RoomsClient(private val gateway: CommunityGateway) {
    /** Rooms visible under RLS (owned or accepted); closed rooms are filtered out. */
    fun myRooms(): List<RoomSummary> = gateway.rows("sdi_rooms", "*", emptyList(), 100).objects()
        .filter { it.bool("closed") != true }
        .map { o -> RoomSummary(o.need("id"), o.need("owner_id"), o.str("title").orEmpty(), o.str("project_title"),
            o.optJSONArray("permissions")?.let { arr -> (0 until arr.length()).map { arr.getString(it) } }, o.int("command_revision")?.coerceAtLeast(0) ?: 0) }

    fun pendingRequests(): List<PendingRequest> {
        val requests = gateway.call("sdi_room_manage", JSONObject().put("action", "my_requests")).optJSONArray("requests")
            ?: throw CommunityException.InvalidResponse("Pending requests unavailable.")
        return requests.objects().map { PendingRequest(it.need("room_id"), it.str("title").orEmpty(), it.need("owner_id"), it.need("request_expires_at")) }
    }

    /** The room's project share, the caller's role and edit right, and its revisions. */
    fun summary(room: String): RoomDetail {
        val reply = gateway.call("sdi_room_manage", JSONObject().put("action", "summary").put("room", requireUuid(room)))
        val detail = RoomDetail.parse(reply)
        if (detail.roomId != room.lowercase()) throw CommunityException.InvalidResponse("Room summary unavailable.")
        return detail
    }
    fun members(room: String): List<RoomMember> = gateway.rows("sdi_room_members", "*", listOf("room_id" to requireUuid(room)), 100)
        .objects().map(RoomMember::parse).sortedBy { it.userId }
    /** Owner only; the server refuses an editor role unless the project is shared with edit permission. */
    fun setRole(room: String, member: String, role: RoomRole) {
        val reply = gateway.call("sdi_room_manage", JSONObject().put("action", "set_role").put("room", requireUuid(room)).put("subject", requireUuid(member)).put("role", role.wire))
        if (reply.str("status") != "updated") throw CommunityException.InvalidResponse("Role change was not confirmed.")
    }

    fun previewInvitation(raw: String): InvitationPreview {
        val code = RoomInvitationPolicy.normalize(raw)
        if (!RoomInvitationPolicy.isWellFormed(code)) throw CommunityException.Server("Invitation codes are 64 hexadecimal characters.", null)
        val reply = action(JSONObject().put("action", "preview").put("code", code))
        val room = reply.str("room_id"); val title = reply.str("title")
        if (reply.str("status") != "preview" || room == null || title == null) throw CommunityException.InvalidResponse("Invitation preview unavailable.")
        return InvitationPreview(room, title)
    }

    /** The recipient's consent is explicit; without it nothing is sent. The owner still approves. */
    fun requestAdmission(raw: String, consent: Boolean): AdmissionOutcome {
        val code = RoomInvitationPolicy.normalize(raw)
        if (!consent) throw CommunityException.Server("Accept the room invitation before requesting admission.", null)
        if (!RoomInvitationPolicy.isWellFormed(code)) throw CommunityException.Server("Invitation codes are 64 hexadecimal characters.", null)
        val reply = action(JSONObject().put("action", "request").put("code", code).put("consent", true))
        val room = reply.str("room_id") ?: throw CommunityException.InvalidResponse("Admission request was not confirmed.")
        return when (reply.str("status")) {
            "pending_owner_approval" -> AdmissionOutcome.PendingOwnerApproval(room)
            "already_requested" -> AdmissionOutcome.AlreadyRequested(room)
            else -> throw CommunityException.InvalidResponse("Admission request was not confirmed.")
        }
    }

    fun mintInvitation(room: String): String {
        val reply = action(JSONObject().put("action", "invite").put("room", requireUuid(room)))
        val code = reply.str("code")
        if (reply.str("status") != "invitation_created" || code == null || !RoomInvitationPolicy.isWellFormed(code)) {
            throw CommunityException.InvalidResponse("The server did not return a usable invitation code.")
        }
        return code
    }
    fun revokeInvitations(room: String) = expect(JSONObject().put("action", "revoke_invites").put("room", requireUuid(room)), "updated")
    /** Declining a pending request revokes it (room-invitations.sql `remove`); the requester can ask
     * again only with a new code. */
    fun decline(room: String, member: String) = remove(room, member)
    fun approve(room: String, member: String) = expect(JSONObject().put("action", "approve").put("room", requireUuid(room)).put("subject", requireUuid(member)), "updated")
    fun remove(room: String, member: String) = expect(JSONObject().put("action", "remove").put("room", requireUuid(room)).put("subject", requireUuid(member)), "updated")
    fun block(room: String, member: String) = expect(JSONObject().put("action", "block").put("room", requireUuid(room)).put("subject", requireUuid(member)), "updated")
    fun leave(room: String) = expect(JSONObject().put("action", "leave").put("room", requireUuid(room)), "left")
    fun close(room: String) = expect(JSONObject().put("action", "close").put("room", requireUuid(room)), "updated")

    private fun action(request: JSONObject): JSONObject = gateway.call("sdi_room_action", request.apply { if (!has("consent")) put("consent", false) })
    private fun expect(request: JSONObject, status: String) {
        if (action(request).str("status") != status) throw CommunityException.InvalidResponse("The room operation was not confirmed.")
    }
}
