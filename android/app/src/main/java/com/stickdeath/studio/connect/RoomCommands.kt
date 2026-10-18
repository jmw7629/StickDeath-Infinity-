package com.stickdeath.studio.connect

import org.json.JSONObject
import java.util.UUID

// Shared-project command sync over `sdi_room_command` (backend/sql/rooms-v2.sql), a Kotlin port of
// the iOS RoomCommandSync / RoomSessionCoordinator protocol. Operation ids make retries idempotent;
// the base revision fences every append. The server rebases an edit whose target no intervening
// command touched; anything else is an explicit conflict, and an overlapping conflict is held until
// the creator decides (keep mine on top, or discard mine) — never silently overwritten. Remote
// commands go to the editor in order and the head advances only after the editor acknowledges them.
// No chat, calls, camera, microphone or screen sharing exist in this protocol.

object RoomQuotaPolicy {
    const val COMMAND_PAYLOAD_BYTES = 65_536
    const val ROOM_REVISION_LIMIT = 100_000
    fun remainingRevisions(head: Int) = maxOf(0, ROOM_REVISION_LIMIT - maxOf(0, head))
    fun payloadFits(payload: JSONObject) = payload.toString().toByteArray(Charsets.UTF_8).size <= COMMAND_PAYLOAD_BYTES
}

data class RoomCommandRecord(val revision: Int, val opId: String, val author: String?, val baseRevision: Int, val kind: String, val payload: JSONObject, val createdAt: String) {
    companion object {
        fun parse(o: JSONObject): RoomCommandRecord {
            val revision = o.int("revision") ?: throw CommunityException.InvalidResponse("A room command was incomplete.")
            val payload = o.optJSONObject("payload") ?: throw CommunityException.InvalidResponse("A room command was incomplete.")
            return RoomCommandRecord(revision, requireUuidOr(o.need("op_id")), o.str("author")?.let(::requireUuidOr), o.int("base_revision") ?: 0,
                o.need("kind"), payload, o.str("created_at").orEmpty())
        }
    }
}

/** Decoded `sdi_room_command` reply; a server `error` (including `conflict`) stays in [error]. */
data class RoomCommandResponse(val error: String?, val status: String?, val revision: Int?, val head: Int?,
                               val commands: List<RoomCommandRecord>?, val missing: List<RoomCommandRecord>?) {
    companion object {
        fun parse(o: JSONObject) = RoomCommandResponse(o.str("error")?.takeIf { it.isNotEmpty() }, o.str("status"), o.int("revision"), o.int("head"),
            o.optJSONArray("commands")?.objects()?.map(RoomCommandRecord::parse), o.optJSONArray("missing")?.objects()?.map(RoomCommandRecord::parse))
    }
}

data class RoomCommandRequest(val action: String, val room: String, val opId: String? = null, val baseRevision: Int? = null,
                              val kind: String? = null, val payload: JSONObject? = null, val after: Int = 0, val pageSize: Int = 200) {
    fun json(): JSONObject = JSONObject().put("action", action).put("room", room).put("op_id", opId ?: JSONObject.NULL)
        .put("base_revision", baseRevision ?: JSONObject.NULL).put("kind", kind ?: JSONObject.NULL).put("payload", payload ?: JSONObject.NULL)
        .put("after", after).put("page_size", pageSize)
}

class RoomCommandClient(private val gateway: CommunityGateway) {
    fun commands(request: RoomCommandRequest): RoomCommandResponse {
        require(request.action == "since") { "Not a catch-up request." }
        return RoomCommandResponse.parse(gateway.callKeepingServerError("sdi_room_command", request.json()))
    }
    fun append(request: RoomCommandRequest): RoomCommandResponse {
        require(request.action == "append") { "Not an append request." }
        return RoomCommandResponse.parse(gateway.callKeepingServerError("sdi_room_command", request.json()))
    }
}

/** The entity a command edits, from its payload's `target` ("frame:<id>", "layer:<id>", "audio:<id>").
 * Null means the whole document, which overlaps every other edit. */
object RoomCommandTarget {
    fun of(payload: JSONObject): String? = payload.str("target")?.takeIf { it.length in 1..200 }
    fun overlaps(local: String?, remote: String?) = local == null || remote == null || local == remote
}

/** Client state machine for shared edits (iOS `RoomCommandSync`). Not thread-safe; the coordinator
 * serialises access. */
class RoomCommandSync(val room: String, head: Int) {
    sealed class AppendOutcome {
        data class Applied(val revision: Int) : AppendOutcome()
        data class Rebased(val revision: Int, val missing: List<RoomCommandRecord>) : AppendOutcome()
        data class Duplicate(val revision: Int) : AppendOutcome()
        data class Conflict(val head: Int, val missing: List<RoomCommandRecord>) : AppendOutcome()
        data class Refused(val message: String) : AppendOutcome()
    }
    sealed class CatchUpOutcome {
        object UpToDate : CatchUpOutcome()
        data class Received(val count: Int) : CatchUpOutcome()
        data class Gap(val expected: Int) : CatchUpOutcome()
        object AccessEnded : CatchUpOutcome()
    }
    data class PendingCommand(val opId: String, val kind: String, val payload: JSONObject, val target: String?)
    data class HeldConflict(val opId: String, val target: String?, val overlapping: List<String>)

    var head: Int = maxOf(0, head); private set
    private val pendingList = mutableListOf<PendingCommand>()
    private val inboxList = mutableListOf<RoomCommandRecord>()
    private val acknowledged = mutableSetOf<String>()
    /** This client's acknowledged edits (op id → target): the only edits it may undo. */
    private val ownCommands = mutableMapOf<String, String?>()
    private val undone = mutableSetOf<String>()
    private val ownRebasedRevisions = mutableSetOf<Int>()
    val pending: List<PendingCommand> get() = pendingList.toList()
    val inbox: List<RoomCommandRecord> get() = inboxList.toList()
    var accessEnded = false; private set
    var editingRevoked = false; private set
    var held: HeldConflict? = null; private set
    var lastProblem: String? = null; private set

    fun enqueue(kind: String, payload: JSONObject, opId: String = UUID.randomUUID().toString()): Boolean =
        enqueue(kind, payload, opId.lowercase(), RoomCommandTarget.of(payload))
    private fun enqueue(kind: String, payload: JSONObject, opId: String, target: String?): Boolean {
        if (accessEnded || editingRevoked || kind.length !in 1..64 || !RoomQuotaPolicy.payloadFits(payload)) return false
        if (pendingList.any { it.opId == opId } || opId in acknowledged) return false
        pendingList += PendingCommand(opId, kind, JSONObject(payload.toString()), target)
        return true
    }
    /** Undo only this client's own acknowledged edit, once. */
    fun enqueueUndo(op: String, opId: String = UUID.randomUUID().toString()): Boolean {
        val key = op.lowercase()
        if (!ownCommands.containsKey(key) || key in undone) return false
        if (pendingList.any { it.kind == "undo" && it.payload.str("undo_op") == key }) return false
        return enqueue("undo", JSONObject().put("undo_op", key), opId.lowercase(), ownCommands[key])
    }
    /** Next append fenced on the current head; null when nothing is pending, remote commands still
     * await the editor, or a conflict is held. */
    fun nextAppend(): RoomCommandRequest? {
        skipOwnAtFront()
        if (accessEnded || editingRevoked || held != null || inboxList.isNotEmpty()) return null
        val next = pendingList.firstOrNull() ?: return null
        return RoomCommandRequest("append", room, next.opId, head, next.kind, next.payload)
    }
    fun catchUpRequest(pageSize: Int = 200) = RoomCommandRequest("since", room, after = head, pageSize = pageSize)

    fun handleAppend(response: RoomCommandResponse, opId: String): AppendOutcome {
        val index = pendingList.indexOfFirst { it.opId == opId }
        if (index < 0) return AppendOutcome.Refused("Unknown operation.")
        val command = pendingList[index]
        val error = response.error
        if (error != null) {
            if (error == "conflict" && response.head != null) {
                val missing = queueMissing(response.missing)
                val overlapping = missing.filter { RoomCommandTarget.overlaps(command.target, entity(it)) }.map { it.opId }
                if (overlapping.isNotEmpty()) {
                    held = HeldConflict(opId, command.target, overlapping)
                    lastProblem = "Another creator changed the same part of the project. Review their edit, then keep yours on top or discard yours."
                } else {
                    lastProblem = "Another editor changed the project. Apply ${missing.size} remote edit${if (missing.size == 1) "" else "s"} before yours is sent."
                }
                return AppendOutcome.Conflict(response.head, missing)
            }
            if (error.contains("unavailable") || error.contains("Sign in")) accessEnded = true
            if (error.startsWith("You can view")) editingRevoked = true
            lastProblem = error
            return AppendOutcome.Refused(error)
        }
        val revision = response.revision
        return when {
            response.status == "applied" && revision != null -> {
                if (revision != head + 1) { lastProblem = "Revision sequence broke; resynchronising."; return AppendOutcome.Refused("Resynchronise before continuing.") }
                head = revision; acknowledge(command, index); lastProblem = null
                AppendOutcome.Applied(revision)
            }
            response.status == "rebased" && revision != null -> {
                if (revision <= head) { lastProblem = "Revision sequence broke; resynchronising."; return AppendOutcome.Refused("Resynchronise before continuing.") }
                val missing = queueMissing(response.missing)
                ownRebasedRevisions += revision; acknowledge(command, index); lastProblem = null
                skipOwnAtFront()
                AppendOutcome.Rebased(revision, missing)
            }
            response.status == "duplicate" && revision != null -> {
                acknowledge(command, index)
                if (revision > head) head = revision
                AppendOutcome.Duplicate(revision)
            }
            else -> { lastProblem = "Append was not confirmed."; AppendOutcome.Refused("Append was not confirmed.") }
        }
    }
    /** Explicit decision on a held conflict, after the editor applied the other creator's edit. */
    fun resolveHeld(keepMine: Boolean): Boolean {
        val current = held ?: return false
        val index = pendingList.indexOfFirst { it.opId == current.opId }
        if (index < 0) return false
        if (!keepMine) pendingList.removeAt(index)
        held = null; lastProblem = null
        return true
    }
    /** Merge a `since` reply: contiguous records newer than the head enter the inbox; a gap means an
     * older page is still needed. */
    fun handleCatchUp(response: RoomCommandResponse): CatchUpOutcome {
        response.error?.let { error ->
            if (error.contains("unavailable") || error.contains("Sign in")) { accessEnded = true; return CatchUpOutcome.AccessEnded }
            lastProblem = error; return CatchUpOutcome.UpToDate
        }
        val records = (response.commands ?: emptyList()).sortedBy { it.revision }
        var expected = (inboxList.lastOrNull()?.revision ?: head) + 1
        var added = 0
        for (record in records) {
            if (record.revision < expected) continue
            if (record.revision != expected) {
                if (expected in ownRebasedRevisions && record.revision == expected + 1) expected += 1 else return CatchUpOutcome.Gap(expected)
            }
            if (inboxList.none { it.opId == record.opId }) { inboxList += record; added += 1 }
            expected += 1
        }
        val serverHead = response.head
        if (serverHead != null && serverHead > expected - 1 && records.isEmpty()) return CatchUpOutcome.Gap(expected)
        return if (added == 0) CatchUpOutcome.UpToDate else CatchUpOutcome.Received(added)
    }
    fun nextRemoteToApply(): RoomCommandRecord? { skipOwnAtFront(); return inboxList.firstOrNull() }
    /** The editor applied (or deliberately skipped) a remote command. */
    fun acknowledgeRemote(record: RoomCommandRecord) {
        val first = inboxList.firstOrNull() ?: return
        if (first.opId != record.opId) return
        inboxList.removeAt(0); head = maxOf(head, record.revision); acknowledged += record.opId
        if (record.kind == "undo") record.payload.str("undo_op")?.let { undone += it.lowercase() }
        skipOwnAtFront()
    }
    fun endAccess() { accessEnded = true; pendingList.clear(); inboxList.clear(); held = null }
    val remainingRevisions get() = RoomQuotaPolicy.remainingRevisions(head)

    private fun acknowledge(command: PendingCommand, index: Int) {
        acknowledged += command.opId; pendingList.removeAt(index)
        if (command.kind == "undo") command.payload.str("undo_op")?.let { undone += it.lowercase() }
        else ownCommands[command.opId] = command.target
    }
    private fun queueMissing(records: List<RoomCommandRecord>?): List<RoomCommandRecord> {
        val missing = (records ?: emptyList()).filter { it.revision > head }.sortedBy { it.revision }
        missing.forEach { record -> if (inboxList.none { it.opId == record.opId }) inboxList += record }
        inboxList.sortBy { it.revision }
        return missing
    }
    /** Drop own acknowledged records at the inbox front and step the head over own rebased revisions
     * once everything below them is applied. */
    private fun skipOwnAtFront() {
        var moved = true
        while (moved) {
            moved = false
            val first = inboxList.firstOrNull()
            if (first != null && first.opId in acknowledged) {
                inboxList.removeAt(0); head = maxOf(head, first.revision); ownRebasedRevisions -= first.revision; moved = true
            }
            if ((head + 1) in ownRebasedRevisions && (inboxList.firstOrNull()?.let { it.revision > head + 1 } ?: true)) {
                ownRebasedRevisions -= (head + 1); head += 1; moved = true
            }
        }
    }
    /** A remote record's entity; an undo of an unknown edit counts as the whole document. */
    private fun entity(record: RoomCommandRecord): String? {
        if (record.kind == "undo") {
            val op = record.payload.str("undo_op")?.lowercase() ?: return null
            if (ownCommands.containsKey(op)) return ownCommands[op]
            return inboxList.firstOrNull { it.opId == op }?.let { RoomCommandTarget.of(it.payload) }
        }
        return RoomCommandTarget.of(record.payload)
    }
}
