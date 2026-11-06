package com.stickdeath.studio.connect

import org.json.JSONObject
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import java.util.concurrent.CancellationException

/** Existing rooms-v2.sql `sdi_room_snapshot` wire contract. Bytes are the existing Android-local
 * backup (including its managed media), or an existing Swift portable backup. No new file dialect,
 * public bucket, account token in an invitation, or privileged client credential is introduced. */
object RoomProjectHandoffPolicy {
    const val CHUNK_BYTES = 262_144
    const val MAXIMUM_BYTES = 32 * 1024 * 1024
    const val MAXIMUM_CHUNKS = 128
    fun chunks(bytes: Int) = if (bytes <= 0) 0 else (bytes + CHUNK_BYTES - 1) / CHUNK_BYTES
    fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    fun checkBytes(bytes: ByteArray) {
        require(bytes.size in 1..MAXIMUM_BYTES) { "Rooms carry project backups up to 32 MiB. No project was sent." }
    }
}

data class RoomProjectSnapshot(val id: String, val title: String, val projectRef: String,
    val projectRevision: Int, val byteSize: Int, val chunkCount: Int, val sha256: String,
    val state: String, val expiresAt: Instant, val mine: Boolean, val receivedByMe: Boolean) {
    companion object {
        fun parse(o: JSONObject): RoomProjectSnapshot {
            fun integer(key: String): Int {
                val n = o.get(key)
                require(n is Int) { "Project handoff metadata is incomplete." }
                return n
            }
            val bytes = integer("byte_size"); val count = integer("chunk_count")
            require(bytes in 1..RoomProjectHandoffPolicy.MAXIMUM_BYTES && count in 1..RoomProjectHandoffPolicy.MAXIMUM_CHUNKS &&
                count == RoomProjectHandoffPolicy.chunks(bytes)) { "The shared project exceeds this device's handoff limits." }
            val hash = o.getString("sha256")
            require(Regex("[a-f0-9]{64}").matches(hash)) { "Project handoff integrity metadata is invalid." }
            val revision = integer("project_revision")
            require(revision > 0 && o.getString("state") in setOf("receiving", "available")) { "Project handoff is unavailable." }
            val reference = o.getString("project_ref")
            require(RoomProjectShare.projectID(reference) != null) { "The room does not share a device project." }
            return RoomProjectSnapshot(requireUuid(o.getString("snapshot_id")), o.getString("title"), reference,
                revision, bytes, count, hash, o.getString("state"), Instant.parse(o.getString("expires_at")),
                o.getBoolean("mine"), o.getBoolean("received_by_me"))
        }
    }
}

/** Blocking, bounded transfer. The caller supplies a live account/window/operation fence. Every
 * individual RPC checks it before AND after transport; cancellation stops at the next boundary.
 * A pending upload expires server-side after an hour; an offered copy expires after 72 hours. */
class RoomProjectHandoffClient(private val gateway: CommunityGateway) {
    private val rooms = RoomsClient(gateway)

    private fun check(live: () -> Boolean) {
        if (!live() || Thread.currentThread().isInterrupted) throw CancellationException("Project handoff stopped. A copy already imported on this device is retained.")
    }
    private fun call(detail: RoomDetail, action: String, live: () -> Boolean, extra: JSONObject = JSONObject()): JSONObject {
        check(live)
        val reply = gateway.call("sdi_room_snapshot", extra.put("action", action).put("room", requireUuid(detail.roomId)))
        check(live)
        return reply
    }
    /** Refresh the server's role, project reference and revision; a cached owner badge is not proof. */
    fun validateScope(detail: RoomDetail, live: () -> Boolean): RoomDetail {
        check(live)
        val fresh = rooms.summary(detail.roomId)
        check(live)
        require(fresh.projectRef != null && fresh.projectID != null && fresh.projectRef == detail.projectRef &&
            fresh.projectRevision == detail.projectRevision && fresh.projectRevision != null && fresh.ownerId == detail.ownerId &&
            fresh.myRole in setOf("owner", "editor", "viewer")) { "The room's project, revision or membership changed. Refresh the room before continuing." }
        return fresh
    }
    fun current(detail: RoomDetail, live: () -> Boolean): RoomProjectSnapshot? {
        validateScope(detail, live)
        val reply = call(detail, "current", live)
        require(reply.optInt("chunk_size") == RoomProjectHandoffPolicy.CHUNK_BYTES) { "Project handoff is unavailable from this service version." }
        val snapshot = reply.optJSONObject("snapshot")?.let(RoomProjectSnapshot::parse) ?: return null
        require(snapshot.projectRef == detail.projectRef && snapshot.projectRevision == detail.projectRevision && snapshot.expiresAt > Instant.now()) {
            "The shared project changed or expired. Refresh the room."
        }
        return snapshot
    }
    fun send(detail: RoomDetail, account: String, bytes: ByteArray, live: () -> Boolean, progress: (Int, Int) -> Unit = { _, _ -> }): RoomProjectSnapshot {
        RoomProjectHandoffPolicy.checkBytes(bytes)
        val fresh = validateScope(detail, live)
        require(fresh.ownerId == account && fresh.myRole == "owner") { "Only the current room owner can send the shared project." }
        val hash = RoomProjectHandoffPolicy.sha256(bytes); val count = RoomProjectHandoffPolicy.chunks(bytes.size)
        val declared = call(detail, "offer", live, JSONObject().put("byte_size", bytes.size).put("sha256", hash))
        val id = requireUuid(declared.getString("snapshot_id"))
        require(declared.optString("status") in setOf("declared", "existing") && declared.optInt("chunk_size") == RoomProjectHandoffPolicy.CHUNK_BYTES &&
            declared.optInt("chunk_count") == count) { "Sending the project was not confirmed. Check the room before retrying." }
        val offered = current(detail, live) ?: error("The pending upload could not be checked. Check the room before retrying.")
        require(offered.id == id && offered.mine && offered.sha256 == hash && offered.byteSize == bytes.size) { "The pending upload differs from this project. Nothing further was sent." }
        if (offered.state == "available") return offered
        val held = declared.optJSONArray("received")?.let { rows ->
            (0 until rows.length()).map { index ->
                val value = rows.get(index)
                require(value is Int && value in 0 until count) { "The pending upload's chunk inventory is invalid." }
                value
            }.toSet()
        } ?: emptySet()
        for (index in 0 until count) {
            check(live)
            if (index !in held) {
                val chunk = bytes.copyOfRange(index * RoomProjectHandoffPolicy.CHUNK_BYTES, minOf(bytes.size, (index + 1) * RoomProjectHandoffPolicy.CHUNK_BYTES))
                val stored = call(detail, "put", live, JSONObject().put("snapshot", id).put("chunk_index", index)
                    .put("data", Base64.getEncoder().encodeToString(chunk)))
                require(stored.optString("status") == "stored") { "A project chunk was not confirmed. Check the room before retrying." }
            }
            progress(index + 1, count)
        }
        validateScope(detail, live)
        val finished = call(detail, "finalize", live, JSONObject().put("snapshot", id))
        require(finished.optString("status") == "available" && finished.optString("snapshot_id") == id) { "The completed upload was not confirmed. Check the room before retrying." }
        return current(detail, live)?.takeIf { it.id == id && it.state == "available" && it.sha256 == hash }
            ?: error("The uploaded copy could not be confirmed. Check the room before retrying.")
    }
    fun receive(detail: RoomDetail, selected: RoomProjectSnapshot, live: () -> Boolean, progress: (Int, Int) -> Unit = { _, _ -> }): ByteArray {
        require(!selected.mine && selected.state == "available") { "No shared project is waiting for this member." }
        requireSame(detail, selected, live)
        val whole = ByteArray(selected.byteSize)
        for (index in 0 until selected.chunkCount) {
            val reply = call(detail, "get", live, JSONObject().put("snapshot", selected.id).put("chunk_index", index))
            val text = reply.optString("data")
            require(reply.optString("snapshot_id") == selected.id && reply.optInt("chunk_index", -1) == index &&
                reply.optInt("chunk_count") == selected.chunkCount && reply.optString("sha256") == selected.sha256 && text.length <= 360_000) {
                "The shared project chunk did not match the selected copy. No project was imported."
            }
            val chunk = Base64.getDecoder().decode(text.replace("\n", "").replace("\r", ""))
            val offset = index * RoomProjectHandoffPolicy.CHUNK_BYTES
            require(chunk.size == minOf(RoomProjectHandoffPolicy.CHUNK_BYTES, selected.byteSize - offset)) { "The shared project chunk has the wrong size. No project was imported." }
            chunk.copyInto(whole, offset); progress(index + 1, selected.chunkCount)
        }
        check(live)
        require(RoomProjectHandoffPolicy.sha256(whole) == selected.sha256) { "The shared project failed SHA-256 verification. No project was imported." }
        requireSame(detail, selected, live)
        return whole
    }
    fun requireSame(detail: RoomDetail, selected: RoomProjectSnapshot, live: () -> Boolean) {
        require(current(detail, live) == selected) { "The selected copy changed or expired. Refresh the room; nothing was overwritten." }
    }
    /** Call ONLY after ProjectStore saved and reopened a verified, fresh-identity device copy. */
    fun receipt(detail: RoomDetail, selected: RoomProjectSnapshot, live: () -> Boolean): String {
        requireSame(detail, selected, live)
        val reply = call(detail, "receipt", live, JSONObject().put("snapshot", selected.id).put("sha256", selected.sha256))
        require(reply.optString("status") == "recorded") { "Your imported copy is retained; the server receipt was not confirmed." }
        return when (reply.optString("server_copy")) {
            "deleted" -> if (reply.optBoolean("verified")) "Receipt confirmed; the server verified deletion of its copy." else "Receipt confirmed; server-copy deletion was not verified."
            "retained" -> "Receipt confirmed; the server copy remains for other approved members or until expiry."
            else -> "Receipt confirmed; server-copy retention status was not supplied."
        }
    }
    fun revoke(detail: RoomDetail, account: String, selected: RoomProjectSnapshot, live: () -> Boolean): Boolean {
        val fresh = validateScope(detail, live)
        require(fresh.ownerId == account && fresh.myRole == "owner") { "Only the current owner can withdraw the sent copy." }
        val reply = call(detail, "revoke", live, JSONObject().put("snapshot", selected.id))
        require(reply.optString("status") == "revoked") { "Withdrawal was not confirmed. Check the room before retrying." }
        return reply.optBoolean("verified")
    }
}
