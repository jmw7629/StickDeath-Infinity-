package com.stickdeath.studio

import com.stickdeath.studio.connect.RoomCommandRecord
import com.stickdeath.studio.connect.RoomSessionCoordinator

/** What the Studio editor exposes to room synchronisation. */
interface SharedStudioHost {
    /** The document open in the editor, or null. */
    val sharedDocument: Document?
    /** Null when a remote edit may be applied now; otherwise why it must wait (drawing, playback,
     * an import or fill in progress, closing). */
    val replayBlocker: String?
    /** Commit a replayed document through history and saving, keeping this device's selection and
     * view, without cancelling the creator's own work in progress. */
    fun commitRemote(next: Document): Boolean
    /** A short notice for the creator. */
    fun roomNotice(text: String)
    /** A reason this device cannot render a replayed document (for example a blend mode), or null. */
    fun unrenderable(next: Document): String? = null
}

/** Connects the project open in Studio to its room's versioned command stream (iOS
 * `StudioRoomBridge`). Every committed change that another copy can replay is published with its
 * frame:/layer:/audio: target; remote edits replay through [StudioSharedEdit.decode] and
 * [StudioSharedEdit.apply], keeping the author's identities and this device's selection. Conflicts
 * follow the room protocol: fenced appends, explicit held conflicts, and a blocked remote edit waits
 * with its reason until it applies or the creator skips it. Nothing is silently overwritten, dropped
 * or claimed as shared. Not thread-safe: call it on the editor's (main) thread. */
class StudioRoomBridge(private val host: SharedStudioHost) {
    var coordinator: RoomSessionCoordinator? = null; private set
    /** True only while a remote command is being replayed, so it is not re-published. */
    var isApplyingRemote = false; private set
    /** Document revision after the last change the bridge accounted for (shared, replayed or view
     * only). Any other revision change came from a path with no shared command (Undo, Redo) and is
     * reported as not shared. */
    private var accountedRevision: Long? = null

    val isAttached get() = coordinator != null

    fun attach(coordinator: RoomSessionCoordinator) {
        this.coordinator = coordinator
        accountedRevision = host.sharedDocument?.revision
        coordinator.applyRemote = { record -> applyRemote(record) }
    }
    fun detach() {
        coordinator?.let { if (it.applyRemote != null) it.applyRemote = null }
        coordinator = null; accountedRevision = null
    }

    /** The open document is the room's shared project. */
    private fun sharing(): Pair<RoomSessionCoordinator, Document>? {
        val c = coordinator ?: return null
        val d = host.sharedDocument ?: return null
        return if (c.isSharing(d.id)) c to d else null
    }

    /** A change the editor committed through its ordinary history path. Returns the payload kind
     * when an edit was queued for the room. */
    fun committed(before: Document, after: Document): String? {
        if (isApplyingRemote) return null
        val (c, _) = sharing() ?: return null
        noteUnaccounted(before.revision)
        accountedRevision = after.revision
        return when (val share = StudioSharedEdit.share(before, after)) {
            StudioSharedEdit.Share.ViewOnly -> null
            is StudioSharedEdit.Share.Unsupported -> { unshared(share.reason); null }
            is StudioSharedEdit.Share.Replay -> {
                val encoded = StudioSharedEdit.encode(share.commands)
                when {
                    encoded == null -> { unshared("This edit is too large to share with the room in one message."); null }
                    c.session?.canEdit != true -> { unshared("You can view this room's project but not edit it."); null }
                    !c.publishLocalEdit(encoded.kind, encoded.payload) -> {
                        unshared("The room did not accept this edit for sending (size bound, ended access or withdrawn editing)."); null
                    }
                    else -> encoded.kind
                }
            }
        }
    }

    /** Undo, Redo and other whole-document jumps are not commands; they are reported, not sent. */
    fun historyJump() {
        if (sharing() == null) return
        unshared("Undo and Redo are not shared with the room yet; collaborators keep the earlier version.")
        accountedRevision = host.sharedDocument?.revision
    }

    /** Report any revision change the bridge did not see as a command. */
    fun noteUnaccounted(revision: Long) {
        val accounted = accountedRevision
        if (accounted == null) { accountedRevision = revision; return }
        if (revision != accounted) unshared("A change made without a shared Studio command was not sent; collaborators do not see it.")
        accountedRevision = revision
    }

    private fun unshared(reason: String) {
        coordinator?.noteUnsharedLocalEdit(reason)
        host.roomNotice("Not shared with the room: $reason It stays on this device.")
    }

    /** Editor hook for the coordinator: true when [record] was applied; false keeps it queued with a
     * truthful reason. */
    fun applyRemote(record: RoomCommandRecord): Boolean {
        val c = coordinator ?: return false
        val pair = sharing()
        if (pair == null) {
            c.noteRemoteBlocked(record, "Open the shared project in Studio to apply edits from other creators.")
            return false
        }
        val document = pair.second
        host.replayBlocker?.let {
            c.noteRemoteBlocked(record, "Waiting for $it to finish before applying the next shared edit.")
            return false
        }
        if (record.kind == "undo") {
            c.noteRemoteBlocked(record, "Another creator undid one of their edits. Android Studio cannot replay a room undo yet; skip it to continue (your copy will keep that edit).")
            return false
        }
        noteUnaccounted(document.revision)
        val next = try {
            StudioSharedEdit.apply(document, StudioSharedEdit.decode(record.kind, record.payload))
        } catch (e: StudioSharedEdit.Refused) {
            c.noteRemoteBlocked(record, "Shared edit #${record.revision} could not be applied: ${e.message} It is retried automatically; skip it only if your copy has diverged.")
            return false
        }
        host.unrenderable(next)?.let {
            c.noteRemoteBlocked(record, "Shared edit #${record.revision} could not be applied: $it Skip it to continue; your copy will differ.")
            return false
        }
        if (StudioSharedEdit.content(next) == StudioSharedEdit.content(document)) return true
        isApplyingRemote = true
        val committed = try { host.commitRemote(next) } finally { isApplyingRemote = false }
        if (!committed) {
            c.noteRemoteBlocked(record, "Studio could not commit shared edit #${record.revision} right now; it is retried automatically.")
            return false
        }
        accountedRevision = host.sharedDocument?.revision
        return true
    }
}
