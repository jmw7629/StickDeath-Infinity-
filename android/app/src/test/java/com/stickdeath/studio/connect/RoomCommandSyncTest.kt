package com.stickdeath.studio.connect

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RoomCommandSyncTest {
    private val room = "0eeeeeee-1111-4222-8333-444444444444"
    private fun op(n: Int) = "00000000-0000-4000-8000-%012d".format(n)
    private fun record(revision: Int, opId: String, target: String? = null, kind: String = "edit") = RoomCommandRecord(revision, opId, Fixtures.OTHER, revision - 1, kind,
        JSONObject().apply { if (target != null) put("target", target) }, "2026-10-18T00:00:00+00:00")
    private fun response(error: String? = null, status: String? = null, revision: Int? = null, head: Int? = null,
                         commands: List<RoomCommandRecord>? = null, missing: List<RoomCommandRecord>? = null) =
        RoomCommandResponse(error, status, revision, head, commands, missing)

    @Test fun payloadsKeepTheIosMarginBelowTheServerBound() {
        val sync = RoomCommandSync(room, 0)
        // {"b":"…"} is 8 bytes of envelope around the text.
        assertTrue(sync.enqueue("edit", JSONObject().put("b", "x".repeat(60_000 - 8)), op(1)))
        assertFalse(sync.enqueue("edit", JSONObject().put("b", "x".repeat(60_000 - 7)), op(2)))
        assertEquals(60_000, RoomQuotaPolicy.CLIENT_PAYLOAD_BYTES)
    }

    @Test fun appliedAppendAdvancesTheHeadAndFencesTheNext() {
        val sync = RoomCommandSync(room, 5)
        assertTrue(sync.enqueue("edit", JSONObject().put("target", "layer:a"), op(1)))
        assertFalse(sync.enqueue("edit", JSONObject(), op(1))) // duplicate op id
        val request = sync.nextAppend()!!
        assertEquals(5, request.baseRevision); assertEquals(op(1), request.opId)
        assertTrue(sync.handleAppend(response(status = "applied", revision = 6), op(1)) is RoomCommandSync.AppendOutcome.Applied)
        assertEquals(6, sync.head); assertNull(sync.nextAppend())
    }

    @Test fun overlappingConflictIsHeldUntilTheCreatorDecides() {
        val sync = RoomCommandSync(room, 5)
        sync.enqueue("edit", JSONObject().put("target", "layer:a"), op(1))
        val outcome = sync.handleAppend(response(error = "conflict", head = 6, missing = listOf(record(6, op(9), "layer:a"))), op(1))
        assertTrue(outcome is RoomCommandSync.AppendOutcome.Conflict)
        assertNotNull(sync.held); assertNull(sync.nextAppend())
        // The editor applies the remote edit; the head moves only on acknowledgement.
        val remote = sync.nextRemoteToApply()!!
        assertEquals(5, sync.head); sync.acknowledgeRemote(remote); assertEquals(6, sync.head)
        assertTrue(sync.resolveHeld(keepMine = true))
        assertEquals(6, sync.nextAppend()!!.baseRevision)
    }

    @Test fun nonOverlappingConflictIsNotHeld() {
        val sync = RoomCommandSync(room, 5)
        sync.enqueue("edit", JSONObject().put("target", "layer:a"), op(1))
        sync.handleAppend(response(error = "conflict", head = 6, missing = listOf(record(6, op(9), "frame:b"))), op(1))
        assertNull(sync.held)
        assertNull(sync.nextAppend()) // remote edit must reach the editor first
        sync.acknowledgeRemote(sync.nextRemoteToApply()!!)
        assertEquals(6, sync.nextAppend()!!.baseRevision)
    }

    @Test fun rebasedOwnRevisionIsSkippedAfterRemoteEditsApply() {
        val sync = RoomCommandSync(room, 5)
        sync.enqueue("edit", JSONObject().put("target", "layer:a"), op(1))
        val outcome = sync.handleAppend(response(status = "rebased", revision = 7, head = 7, missing = listOf(record(6, op(9), "frame:b"))), op(1))
        assertTrue(outcome is RoomCommandSync.AppendOutcome.Rebased)
        assertEquals(5, sync.head)
        sync.acknowledgeRemote(sync.nextRemoteToApply()!!)
        assertEquals(7, sync.head)
    }

    @Test fun catchUpDetectsGapsAndAccessEnd() {
        val sync = RoomCommandSync(room, 5)
        assertEquals(RoomCommandSync.CatchUpOutcome.Received(2), sync.handleCatchUp(response(commands = listOf(record(7, op(3)), record(6, op(2))), head = 7)))
        assertEquals(RoomCommandSync.CatchUpOutcome.Gap(8), sync.handleCatchUp(response(commands = listOf(record(9, op(4))), head = 9)))
        assertEquals(RoomCommandSync.CatchUpOutcome.AccessEnded, sync.handleCatchUp(response(error = "Room is unavailable.")))
        assertTrue(sync.accessEnded); assertFalse(sync.enqueue("edit", JSONObject(), op(5)))
    }

    @Test fun undoIsLimitedToOwnAcknowledgedEdits() {
        val sync = RoomCommandSync(room, 0)
        assertFalse(sync.enqueueUndo(op(9)))
        sync.enqueue("edit", JSONObject().put("target", "layer:a"), op(1))
        sync.handleAppend(response(status = "applied", revision = 1), op(1))
        assertTrue(sync.enqueueUndo(op(1), op(2)))
        assertFalse(sync.enqueueUndo(op(1), op(3)))
        assertEquals("undo", sync.nextAppend()!!.kind)
    }

    @Test fun viewOnlyRefusalStopsEditing() {
        val sync = RoomCommandSync(room, 0)
        sync.enqueue("edit", JSONObject(), op(1))
        sync.handleAppend(response(error = "You can view this project but not edit it."), op(1))
        assertTrue(sync.editingRevoked); assertNull(sync.nextAppend())
    }

    @Test fun coordinatorDrainsOverTheRpcAndKeepsRemoteEditsQueuedWithoutAnEditor() {
        val command = """{"revision":1,"op_id":"${op(9)}","author":"${Fixtures.OTHER}","base_revision":0,"kind":"edit","payload":{"target":"layer:b"},"created_at":"2026-10-18T00:00:00+00:00"}"""
        val transport = ScriptedTransport { request ->
            val sent = JSONObject(String(request.body!!))
            if (sent.getString("action") == "since") ScriptedTransport.json(200, """{"commands":[$command],"head":1}""")
            else ScriptedTransport.json(200, """{"status":"applied","revision":${sent.getInt("base_revision") + 1}}""")
        }
        val coordinator = RoomSessionCoordinator(RoomCommandClient(CommunityGateway(FixedSession(), transport)))
        coordinator.begin(room, 0, canEdit = true, account = Fixtures.USER)
        assertEquals(RoomCommandSync.CatchUpOutcome.Received(1), coordinator.catchUp())
        assertEquals(1, coordinator.pendingRemoteCount); assertFalse(coordinator.editorAttached)
        val since = JSONObject(String(transport.requests.first().body!!))
        assertEquals(room, since.getString("room")); assertEquals(0, since.getInt("after")); assertFalse(since.has("op_id"))
        // Local edits wait until the remote edit reaches the editor.
        assertTrue(coordinator.publishLocalEdit("edit", JSONObject().put("target", "layer:a")))
        assertEquals(RoomSessionCoordinator.DrainOutcome.Idle, coordinator.drain())
        coordinator.applyRemote = { true }
        coordinator.applyQueued()
        assertEquals(RoomSessionCoordinator.DrainOutcome.Sent(1), coordinator.drain())
        assertEquals(2, coordinator.head)
        val append = JSONObject(String(transport.requests.last().body!!))
        assertEquals("append", append.getString("action")); assertEquals(1, append.getInt("base_revision"))
        coordinator.begin(room, 0, canEdit = false, account = Fixtures.USER)
        assertFalse(coordinator.publishLocalEdit("edit", JSONObject()))
    }

    @Test fun replyRecordsParse() {
        val parsed = RoomCommandResponse.parse(JSONObject().put("error", "conflict").put("head", 3)
            .put("missing", JSONArray().put(JSONObject().put("revision", 3).put("op_id", op(1)).put("author", JSONObject.NULL).put("base_revision", 2)
                .put("kind", "edit").put("payload", JSONObject()).put("created_at", "t"))))
        assertEquals("conflict", parsed.error); assertNull(parsed.missing!!.single().author)
    }
}
