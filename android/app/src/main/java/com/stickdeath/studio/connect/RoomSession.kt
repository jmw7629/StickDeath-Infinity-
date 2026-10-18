package com.stickdeath.studio.connect

import org.json.JSONObject
import java.util.concurrent.locks.ReentrantLock

/** The one active shared-project session (iOS `RoomSessionCoordinator`). Network calls are blocking:
 * run [fetchRemote], [catchUp] and [drain] off the main thread. They never hold the state lock while
 * waiting on the network, so the editor's quick calls ([publishLocalEdit], [applyQueued], notes and
 * decisions) do not stall behind a slow reply. Remote commands go to the [applyRemote] editor hook in
 * order; until the shared project is open in Studio they stay queued and are reported as such. */
class RoomSessionCoordinator(private val client: RoomCommandClient) {
    data class Session(val room: String, val canEdit: Boolean, val account: String, val projectID: String? = null)
    /** The room whose shared device project is open in Studio. */
    data class Handoff(val room: String, val roomTitle: String, val projectID: String)
    /** A remote command the editor could not apply yet; it stays first in line with its reason. */
    data class BlockedRemote(val opId: String, val revision: Int, val reason: String)
    sealed class DrainOutcome {
        object Idle : DrainOutcome()
        data class Sent(val count: Int) : DrainOutcome()
        data class Conflict(val missing: Int) : DrainOutcome()
        data class Held(val overlapping: Int) : DrainOutcome()
        data class Stopped(val reason: String) : DrainOutcome()
    }
    private val lock = Any()
    /** Serialises network exchanges so one append is never sent twice concurrently. */
    private val network = ReentrantLock()

    @Volatile var session: Session? = null; private set
    @Volatile var sync: RoomCommandSync? = null; private set
    @Volatile var handoff: Handoff? = null; private set
    /** Why the last session ended; device projects are never modified or deleted when it ends. */
    @Volatile var endReason: String? = null; private set
    @Volatile var blockedRemote: BlockedRemote? = null; private set
    /** Remote commands the creator chose to skip; their device copy differs from the room's. */
    @Volatile var skippedRemote: List<String> = emptyList(); private set
    @Volatile var appliedRemoteCount = 0; private set
    @Volatile var publishedLocalCount = 0; private set
    /** Local changes that could not be sent (unsupported edit, view-only role, size bound). They stay
     * on this device; the reason is shown, never hidden. */
    @Volatile var unsharedLocalCount = 0; private set
    @Volatile var lastUnsharedReason: String? = null; private set
    /** Editor hook: true when the remote command was applied (or deliberately skipped). */
    @Volatile var applyRemote: ((RoomCommandRecord) -> Boolean)? = null

    fun begin(room: String, head: Int, canEdit: Boolean, account: String, projectID: String? = null): Unit { return synchronized(lock) {
        val key = requireUuid(room)
        val project = projectID?.let(::requireUuid)
        val current = session
        if (current != null && current.room == key && current.account == account) {
            // Same session: only a permission or project-reference change is applied.
            if (current.canEdit != canEdit || (project != null && current.projectID != project))
                session = current.copy(canEdit = canEdit, projectID = project ?: current.projectID)
            return
        }
        session = Session(key, canEdit, account, project)
        sync = RoomCommandSync(key, head)
        endReason = null
        if (handoff?.room != key) handoff = null
        blockedRemote = null; skippedRemote = emptyList(); appliedRemoteCount = 0; publishedLocalCount = 0
        unsharedLocalCount = 0; lastUnsharedReason = null
    } }
    fun end(reason: String? = null): Unit { return synchronized(lock) {
        session = null; sync = null; handoff = null; blockedRemote = null
        if (reason != null) endReason = reason
    } }

    /** Record that the room's shared project is now open in Studio. Refused unless the session's
     * project reference names exactly that device project. */
    fun handOffToStudio(room: String, roomTitle: String, projectID: String): Boolean { return synchronized(lock) {
        val current = session ?: return false
        if (current.room != room.lowercase() || current.projectID == null || current.projectID != projectID.lowercase()) return false
        handoff = Handoff(current.room, roomTitle, current.projectID)
        true
    } }
    /** The creator explicitly stopped working on the shared project in Studio. */
    fun finishHandoff(): Unit { return synchronized(lock) { handoff = null } }
    /** Whether this room's shared project is the one open in the editor. */
    fun isSharing(projectID: String): Boolean {
        val current = session ?: return false
        val open = handoff ?: return false
        return open.room == current.room && open.projectID == projectID.lowercase()
    }

    fun publishLocalEdit(kind: String, payload: JSONObject): Boolean { return synchronized(lock) {
        val s = session ?: return false
        val accepted = s.canEdit && (sync?.enqueue(kind, payload) ?: false)
        if (accepted) publishedLocalCount += 1
        accepted
    } }
    fun undoOwnEdit(op: String): Boolean { return synchronized(lock) { session?.canEdit == true && (sync?.enqueueUndo(op) ?: false) } }
    fun resolveHeldConflict(keepMine: Boolean): Boolean { return synchronized(lock) { sync?.resolveHeld(keepMine) ?: false } }
    val heldConflict: RoomCommandSync.HeldConflict? get() = sync?.held

    fun noteUnsharedLocalEdit(reason: String): Unit { return synchronized(lock) {
        if (session == null) return
        unsharedLocalCount += 1; lastUnsharedReason = reason
    } }
    /** The editor could not apply this remote command yet (it stays queued). */
    fun noteRemoteBlocked(record: RoomCommandRecord, reason: String): Unit { return synchronized(lock) {
        if (sync?.inbox?.firstOrNull()?.opId != record.opId) return
        blockedRemote = BlockedRemote(record.opId, record.revision, reason)
    } }
    /** The creator explicitly skips the blocked remote command after reading why it could not be
     * applied. Their copy then differs from the room's; the skip is recorded and shown, and later
     * commands continue in order. */
    fun skipBlockedRemote(): Boolean { return synchronized(lock) {
        val blocked = blockedRemote ?: return false
        val s = sync ?: return false
        val first = s.nextRemoteToApply() ?: return false
        if (first.opId != blocked.opId) return false
        s.acknowledgeRemote(first)
        skippedRemote = skippedRemote + first.opId; blockedRemote = null
        applyQueued()
        true
    } }

    /** Send queued edits in order; stop at the first conflict so the editor applies the missing
     * remote commands before retrying. */
    fun drain(): DrainOutcome {
        network.lock()
        try {
            val s = sync ?: return DrainOutcome.Idle
            if (session == null) return DrainOutcome.Idle
            synchronized(lock) { s.held?.let { return DrainOutcome.Held(it.overlapping.size) } }
            var sent = 0
            while (true) {
                val request = synchronized(lock) { if (sync !== s) null else s.nextAppend() } ?: break
                val opId = request.opId ?: break
                val response = try { client.append(request) } catch (e: CommunityException) {
                    if (e is CommunityException.SignedOut) end("Signed out. Your device copy of the project is unchanged.")
                    return DrainOutcome.Stopped(e.message ?: "Synchronisation failed.")
                }
                val outcome = synchronized(lock) {
                    if (sync !== s) return DrainOutcome.Stopped(endReason ?: "Synchronisation stopped.")
                    s.handleAppend(response, opId)
                }
                when (outcome) {
                    is RoomCommandSync.AppendOutcome.Applied, is RoomCommandSync.AppendOutcome.Duplicate, is RoomCommandSync.AppendOutcome.Rebased -> sent += 1
                    is RoomCommandSync.AppendOutcome.Conflict -> {
                        s.held?.let { return DrainOutcome.Held(it.overlapping.size) }
                        return DrainOutcome.Conflict(outcome.missing.size)
                    }
                    is RoomCommandSync.AppendOutcome.Refused -> {
                        synchronized(lock) {
                            if (s.accessEnded) end("Room access ended. Your device copy of the project is unchanged.")
                            else if (s.editingRevoked) endReason = "Editing permission was withdrawn. Your local edits stay on this device."
                        }
                        return DrainOutcome.Stopped(outcome.message)
                    }
                }
            }
            return if (sent == 0) DrainOutcome.Idle else DrainOutcome.Sent(sent)
        } finally { network.unlock() }
    }

    /** Fetch newer commands into the inbox without applying them (network only; any thread). */
    fun fetchRemote(): RoomCommandSync.CatchUpOutcome {
        network.lock()
        try {
            val s = sync ?: return RoomCommandSync.CatchUpOutcome.AccessEnded
            if (session == null) return RoomCommandSync.CatchUpOutcome.AccessEnded
            val request = synchronized(lock) { s.catchUpRequest() }
            val response = try { client.commands(request) } catch (e: CommunityException) {
                if (e is CommunityException.SignedOut) { end("Signed out. Your device copy of the project is unchanged."); return RoomCommandSync.CatchUpOutcome.AccessEnded }
                throw e
            }
            synchronized(lock) {
                if (sync !== s) return RoomCommandSync.CatchUpOutcome.AccessEnded
                val outcome = s.handleCatchUp(response)
                if (s.accessEnded) { end("Room access ended. Your device copy of the project is unchanged."); return RoomCommandSync.CatchUpOutcome.AccessEnded }
                return outcome
            }
        } finally { network.unlock() }
    }
    /** Fetch newer commands and hand them to the editor hook in order. */
    fun catchUp(): RoomCommandSync.CatchUpOutcome {
        val outcome = fetchRemote()
        applyQueued()
        return outcome
    }
    /** Hand queued remote commands to the editor hook, oldest first, stopping at the first one the
     * editor cannot apply yet. Call it on the editor's thread. */
    fun applyQueued(): Unit { return synchronized(lock) {
        val s = sync ?: return
        while (true) {
            val record = s.nextRemoteToApply() ?: break
            val apply = applyRemote ?: break
            if (!apply(record)) break
            s.acknowledgeRemote(record)
            appliedRemoteCount += 1
            if (blockedRemote?.opId == record.opId) blockedRemote = null
        }
    } }
    val pendingRemoteCount get() = sync?.inbox?.size ?: 0
    val pendingLocalCount get() = sync?.pending?.size ?: 0
    val head get() = sync?.head ?: 0
    val editorAttached get() = applyRemote != null
}

/** The process-wide room session, shared by the Account panel and the Studio editor. */
object RoomRuntime {
    @Volatile private var coordinator: RoomSessionCoordinator? = null
    fun coordinator(context: android.content.Context): RoomSessionCoordinator = coordinator ?: synchronized(this) {
        coordinator ?: RoomSessionCoordinator(RoomCommandClient(CommunityGateway(AccountRuntime.manager(context).asSessionSource(), UrlConnectionTransport())))
            .also { coordinator = it }
    }
}
