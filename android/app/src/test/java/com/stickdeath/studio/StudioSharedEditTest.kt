package com.stickdeath.studio

import com.stickdeath.studio.connect.RoomCommandRecord
import com.stickdeath.studio.connect.RoomSessionCoordinator
import com.stickdeath.studio.connect.RoomCommandClient
import com.stickdeath.studio.connect.CommunityGateway
import com.stickdeath.studio.connect.FixedSession
import com.stickdeath.studio.connect.Fixtures
import com.stickdeath.studio.connect.ScriptedTransport
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Shared Studio edits (#288): publishing, strict replay and divergence refusal on the plain JVM. */
class StudioSharedEditTest {
    private val base = Document.create("Shared", 64, 64, 12).let { d ->
        val second = Layer(name = "Ink")
        d.copy(id = "0aaaaaaa-1111-4222-8333-444444444444", layers = d.layers + second, frames = d.frames + Frame())
    }.validated()
    private val frame get() = base.frames.first().id
    private val layer get() = base.layers.first().id
    private fun pencil(id: String = newID(), layerID: String = layer) = Stroke(id = id, layerID = layerID, points = listOf(Point(4f, 4f), Point(30f, 30f)),
        color = 0xff112233.toInt(), width = 6f, tool = Tool.Pencil, brushSeed = 77)
    private fun withStrokes(d: Document, vararg strokes: Stroke) = d.copy(frames = d.frames.map { if (it.id == frame) it.copy(strokes = it.strokes + strokes) else it })
    private fun replay(share: StudioSharedEdit.Share): StudioSharedEdit.Encoded = StudioSharedEdit.encode((share as StudioSharedEdit.Share.Replay).commands)!!

    @Test fun selectionAndGuidesAreViewOnly() {
        val after = base.copy(activeFrameID = base.frames.last().id, onion = OnionSettings(enabled = true), grid = GridSettings(enabled = true))
        assertEquals(StudioSharedEdit.Share.ViewOnly, StudioSharedEdit.share(base, after))
    }

    @Test fun androidDrawingTravelsInTheAndroidKindAndReplaysExactly() {
        val stroke = pencil()
        val after = withStrokes(base, stroke)
        val encoded = replay(StudioSharedEdit.share(base, after))
        assertEquals(StudioSharedEdit.ANDROID_KIND, encoded.kind)
        assertEquals("frame:$frame", encoded.payload.getString("target"))
        assertEquals(stroke.id, encoded.payload.getJSONArray("createdElementIDs").getString(0))
        // Through the wire, as the other device receives it.
        val received = JSONObject(encoded.payload.toString())
        val replayed = StudioSharedEdit.apply(base, StudioSharedEdit.decode(encoded.kind, received))
        assertEquals(StudioSharedEdit.content(after), StudioSharedEdit.content(replayed))
    }

    @Test fun layerTimingTrackAndRenameUseTheIosVocabulary() {
        val after = base.copy(name = "Renamed", layers = base.layers.map { if (it.id == layer) it.copy(opacity = 0.5f, blend = LayerBlend.Screen, lockMode = LayerLockMode.Position) else it },
            frames = base.frames.map { if (it.id == frame) it.copy(hold = 3) else it },
            audioTracks = base.audioTracks.mapIndexed { i, t -> if (i == 1) t.copy(volume = 0.25f, muted = true) else t })
        val encoded = replay(StudioSharedEdit.share(base, after))
        assertEquals(StudioSharedEdit.KIND, encoded.kind)
        assertFalse(encoded.payload.has("target")) // several entities: overlaps every edit
        val commands = JSONArray(encoded.payload.getString("commands"))
        val keys = (0 until commands.length()).map { commands.getJSONObject(it).keys().next() }
        assertEquals(listOf("renameProject", "updateLayer", "setFrameHold", "updateAudioTrack"), keys)
        val layerSettings = commands.getJSONObject(1).getJSONObject("updateLayer").getJSONObject("settings")
        assertEquals("screen", layerSettings.getString("blend")); assertEquals("position", layerSettings.getString("lock"))
        assertEquals(2, commands.getJSONObject(3).getJSONObject("updateAudioTrack").getInt("track"))
        val replayed = StudioSharedEdit.apply(base, StudioSharedEdit.decode(encoded.kind, JSONObject(encoded.payload.toString())))
        assertEquals(StudioSharedEdit.content(after), StudioSharedEdit.content(replayed))
    }

    @Test fun deletionsReplayAndDivergentCopiesAreRefused() {
        val stroke = pencil()
        val drawn = withStrokes(base, stroke)
        val after = drawn.copy(frames = drawn.frames.map { it.copy(strokes = emptyList()) })
        val encoded = replay(StudioSharedEdit.share(drawn, after))
        assertEquals(StudioSharedEdit.KIND, encoded.kind)
        val commands = StudioSharedEdit.decode(encoded.kind, encoded.payload)
        assertEquals(StudioSharedEdit.content(after), StudioSharedEdit.content(StudioSharedEdit.apply(drawn, commands)))
        // The other copy never had that drawing: refused, nothing changes.
        try { StudioSharedEdit.apply(base, commands); fail("Divergent delete accepted") } catch (e: StudioSharedEdit.Refused) { assertTrue(e.message!!.contains("diverged")) }
        // A drawing replayed twice is refused instead of duplicated.
        val draw = StudioSharedEdit.decode(StudioSharedEdit.ANDROID_KIND, replay(StudioSharedEdit.share(base, drawn)).payload)
        try { StudioSharedEdit.apply(drawn, draw); fail("Duplicate drawing accepted") } catch (_: StudioSharedEdit.Refused) { }
    }

    @Test fun unsupportedChangesAreReportedNotApproximated() {
        val stroke = pencil()
        val drawn = withStrokes(base, stroke)
        val moved = drawn.copy(frames = drawn.frames.map { f -> f.copy(strokes = f.strokes.map { it.copy(points = it.points.map { p -> Point(p.x + 1, p.y) }) }) })
        assertTrue(StudioSharedEdit.share(drawn, moved) is StudioSharedEdit.Share.Unsupported)
        assertTrue(StudioSharedEdit.share(base, base.copy(frames = base.frames + Frame())) is StudioSharedEdit.Share.Unsupported)
        assertTrue(StudioSharedEdit.share(base, base.copy(width = 80)) is StudioSharedEdit.Share.Unsupported)
        assertTrue(StudioSharedEdit.share(base, base.copy(layers = base.layers.map { it.copy(label = LayerLabel.Blue) })) is StudioSharedEdit.Share.Unsupported)
    }

    @Test fun iosPenStrokesDecodeLikeTheProjectImport() {
        val commands = JSONArray().put(JSONObject().put("draw", JSONObject().put("frame", JSONObject().put("id", frame)).put("layer", JSONObject().put("id", layer))
            .put("strokes", JSONArray().put(JSONObject().put("id", "ios-1").put("tool", "pencil").put("color", "#FF0000").put("width", 10.0).put("opacity", 1.0)
                .put("points", JSONArray().put(JSONObject().put("x", 1.0).put("y", 2.0)).put(JSONObject().put("x", 9.0).put("y", 9.0)))))))
        val payload = JSONObject().put("schemaVersion", 1).put("target", "frame:$frame").put("commands", commands.toString())
            .put("createdElementIDs", JSONArray().put("ELEMENT-A"))
        val draw = StudioSharedEdit.decode(StudioSharedEdit.KIND, payload).single() as StudioSharedEdit.Command.Draw
        val stroke = draw.strokes.single()
        assertEquals("ELEMENT-A", stroke.id) // the author's created identity
        assertEquals(8f, stroke.width); assertTrue(stroke.swiftLegacyPath && stroke.swiftLegacyButtCap)
        assertEquals(0xffff0000.toInt(), stroke.color)
        // The same stroke written back is iOS-portable and exact.
        val encoded = StudioSharedEdit.encode(listOf(draw))!!
        assertEquals(StudioSharedEdit.KIND, encoded.kind)
    }

    @Test fun strictDecoderRefusesUnknownOrMismatchedInput() {
        fun payload(commands: String, target: String? = null) = JSONObject().put("schemaVersion", 1).put("commands", commands).apply { target?.let { put("target", it) } }
        val refusals = listOf(
            "custom.kind" to payload("[]"),
            StudioSharedEdit.KIND to payload("""[{"addFrame":{"after":{"id":"x"},"result":"f"}}]"""),
            StudioSharedEdit.KIND to payload("""[{"setFrameHold":{"frame":{"id":"$frame"},"ticks":2}}]"""), // target missing
            StudioSharedEdit.KIND to payload("""[{"setFrameHold":{"frame":{"id":"$frame"},"ticks":2,"extra":1}}]""", "frame:$frame"),
            StudioSharedEdit.KIND to payload("""[{"updateLayer":{"layer":{"id":"$layer"},"settings":{"glowEnabled":true}}}]""", "layer:$layer"),
            StudioSharedEdit.KIND to payload("not json"),
            StudioSharedEdit.KIND to JSONObject().put("schemaVersion", 2).put("commands", "[]"),
        )
        refusals.forEach { (kind, p) ->
            try { StudioSharedEdit.decode(kind, p); fail("Accepted $kind $p") } catch (_: StudioSharedEdit.Refused) { }
        }
        val hold = StudioSharedEdit.decode(StudioSharedEdit.KIND, payload("""[{"setFrameHold":{"frame":{"id":"$frame"},"ticks":2}}]""", "frame:$frame"))
        assertEquals(listOf(StudioSharedEdit.Command.SetFrameHold(frame, 2)), hold)
        try { StudioSharedEdit.apply(base, listOf(StudioSharedEdit.Command.SetFrameHold("missing", 2))); fail() } catch (_: StudioSharedEdit.Refused) { }
    }

    // MARK: Bridge

    private class Host(var doc: Document?) : SharedStudioHost {
        var blocker: String? = null
        val notices = mutableListOf<String>()
        override val sharedDocument get() = doc
        override val replayBlocker get() = blocker
        override fun commitRemote(next: Document): Boolean { val before = doc!!; doc = next.copy(revision = before.revision + 1, activeFrameID = before.activeFrameID); return true }
        override fun roomNotice(text: String) { notices += text }
    }
    private val room = "0eeeeeee-1111-4222-8333-444444444444"
    private fun coordinator(): Pair<RoomSessionCoordinator, ScriptedTransport> {
        val transport = ScriptedTransport { request ->
            val sent = JSONObject(String(request.body!!))
            ScriptedTransport.json(200, """{"status":"applied","revision":${sent.getInt("base_revision") + 1}}""")
        }
        val c = RoomSessionCoordinator(RoomCommandClient(CommunityGateway(FixedSession(), transport)))
        c.begin(room, 0, canEdit = true, account = Fixtures.USER, projectID = base.id)
        return c to transport
    }

    @Test fun bridgePublishesOnlyWhileTheSharedProjectIsHandedOff() {
        val host = Host(base)
        val bridge = StudioRoomBridge(host)
        val (c, transport) = coordinator()
        bridge.attach(c)
        val drawn = withStrokes(base, pencil()).copy(revision = 1)
        assertNull(bridge.committed(base, drawn)) // not handed off yet: nothing is sent
        assertFalse(c.handOffToStudio(room, "Room", "0bbbbbbb-1111-4222-8333-444444444444"))
        assertTrue(c.handOffToStudio(room, "Room", base.id))
        host.doc = drawn
        assertEquals(StudioSharedEdit.ANDROID_KIND, bridge.committed(base, drawn))
        assertEquals(1, c.pendingLocalCount)
        assertEquals(RoomSessionCoordinator.DrainOutcome.Sent(1), c.drain())
        assertEquals(StudioSharedEdit.ANDROID_KIND, JSONObject(String(transport.requests.last().body!!)).getString("kind"))
        // An unsupported change is counted and reported, not sent.
        val bigger = drawn.copy(width = 80, revision = 2)
        assertNull(bridge.committed(drawn, bigger))
        assertEquals(1, c.unsharedLocalCount); assertTrue(host.notices.last().startsWith("Not shared with the room"))
        bridge.historyJump()
        assertEquals(2, c.unsharedLocalCount)
    }

    @Test fun bridgeReplaysRemoteEditsKeepingSelectionAndBlocksHonestly() {
        val viewing = base.copy(activeFrameID = base.frames.last().id)
        val host = Host(viewing)
        val bridge = StudioRoomBridge(host)
        val (c, _) = coordinator()
        bridge.attach(c)
        assertTrue(c.handOffToStudio(room, "Room", base.id))
        val remote = replay(StudioSharedEdit.share(base, withStrokes(base, pencil(id = "remote-1"))))
        val record = RoomCommandRecord(1, "00000000-0000-4000-8000-000000000009", Fixtures.OTHER, 0, remote.kind, remote.payload, "t")
        host.blocker = "your drawing gesture"
        assertFalse(bridge.applyRemote(record))
        host.blocker = null
        assertTrue(bridge.applyRemote(record))
        assertEquals(viewing.activeFrameID, host.doc!!.activeFrameID)
        assertTrue(host.doc!!.frames.first().strokes.any { it.id == "remote-1" })
        // Replaying it again would duplicate: refused (the copy has diverged).
        assertFalse(bridge.applyRemote(record))
        val undo = record.copy(kind = "undo", payload = JSONObject().put("undo_op", record.opId))
        assertFalse(bridge.applyRemote(undo))
        assertNotNull(bridge.coordinator)
        bridge.detach(); assertFalse(c.editorAttached)
    }
}
