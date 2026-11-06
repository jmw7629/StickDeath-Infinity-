package com.stickdeath.studio.connect

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64
import java.util.concurrent.CancellationException

/** Actual production gateway and handoff client; the transport is deterministic, never a backend. */
class RoomProjectHandoffTest {
    private val room = "0eeeeeee-1111-4222-8333-444444444444"
    private val project = "0aaaaaaa-1111-4222-8333-444444444444"
    private val snapshot = "0bbbbbbb-1111-4222-8333-444444444444"
    private val detail = RoomDetail(room, "R", Fixtures.USER, "device-project:$project", "P", listOf("view", "edit"), 2, 9, "owner", true, 1)
    private fun body(request: HttpRequest) = JSONObject(String(request.body!!, Charsets.UTF_8))
    private fun summary(revision: Int = 2, role: String = "owner") = JSONObject()
        .put("room_id", room).put("owner_id", Fixtures.USER).put("project_ref", "device-project:$project")
        .put("project_revision", revision).put("command_revision", 9).put("my_role", role)
    private fun record(bytes: ByteArray, mine: Boolean, state: String = "available") = JSONObject()
        .put("snapshot_id", snapshot).put("title", "P").put("project_ref", "device-project:$project").put("project_revision", 2)
        .put("byte_size", bytes.size).put("chunk_count", RoomProjectHandoffPolicy.chunks(bytes.size))
        .put("sha256", RoomProjectHandoffPolicy.sha256(bytes)).put("state", state).put("expires_at", "2099-01-01T00:00:00Z")
        .put("mine", mine).put("received_by_me", false)
    private fun json(value: JSONObject) = ScriptedTransport.json(200, value.toString())
    private fun refuses(block: () -> Unit) {
        try { block(); fail("An invalid handoff was accepted") } catch (_: IllegalArgumentException) { }
    }

    @Test fun ownerUploadsExactBackupChunksAndServerHashConfirmationBeforeOfferingIt() {
        val bytes = ByteArray(RoomProjectHandoffPolicy.CHUNK_BYTES + 7) { (it % 251).toByte() }
        val held = mutableMapOf<Int, ByteArray>(); var available = false
        val transport = ScriptedTransport { request ->
            val b = body(request)
            if (request.url.endsWith("/sdi_room_manage")) json(summary()) else when (b.getString("action")) {
                "offer" -> {
                    assertEquals(bytes.size, b.getInt("byte_size")); assertEquals(RoomProjectHandoffPolicy.sha256(bytes), b.getString("sha256"))
                    json(JSONObject().put("status", "declared").put("snapshot_id", snapshot).put("chunk_size", 262144).put("chunk_count", 2))
                }
                "current" -> json(JSONObject().put("chunk_size", 262144).put("snapshot", record(bytes, true, if (available) "available" else "receiving")))
                "put" -> {
                    assertEquals(snapshot, b.getString("snapshot"))
                    held[b.getInt("chunk_index")] = Base64.getDecoder().decode(b.getString("data"))
                    json(JSONObject().put("status", "stored"))
                }
                "finalize" -> {
                    assertArrayEquals(bytes, held.getValue(0) + held.getValue(1)); available = true
                    json(JSONObject().put("status", "available").put("snapshot_id", snapshot))
                }
                else -> error("Unexpected request")
            }
        }
        val result = RoomProjectHandoffClient(CommunityGateway(FixedSession(), transport)).send(detail, Fixtures.USER, bytes, { true })
        assertEquals("available", result.state); assertEquals(2, held.size)
        assertTrue(transport.requests.all { it.method == "POST" && it.headers["Authorization"] == "Bearer member-token" })
        assertTrue(transport.requests.all { !String(it.body!!).contains("member-token") })
    }

    @Test fun ownerResumesOnlyServerConfirmedMissingChunksWithoutReplacingPendingOffer() {
        val bytes = ByteArray(262145) { 5 }; var available = false
        val puts = mutableListOf<Int>()
        val transport = ScriptedTransport { request ->
            val b = body(request)
            if (request.url.endsWith("/sdi_room_manage")) json(summary()) else when (b.getString("action")) {
                "offer" -> json(JSONObject().put("status", "existing").put("snapshot_id", snapshot).put("chunk_size", 262144).put("chunk_count", 2).put("received", JSONArray(listOf(0))))
                "current" -> json(JSONObject().put("chunk_size", 262144).put("snapshot", record(bytes, true, if (available) "available" else "receiving")))
                "put" -> { puts += b.getInt("chunk_index"); json(JSONObject().put("status", "stored")) }
                "finalize" -> { available = true; json(JSONObject().put("status", "available").put("snapshot_id", snapshot)) }
                else -> error("Unexpected request")
            }
        }
        RoomProjectHandoffClient(CommunityGateway(FixedSession(), transport)).send(detail, Fixtures.USER, bytes, { true })
        assertEquals(listOf(1), puts)
        assertFalse(transport.requests.any { body(it).optString("action") == "revoke" })
    }

    @Test fun memberGetsAndVerifiesEveryByteButReceiptRequiresSeparatePostImportCall() {
        val bytes = ByteArray(262155) { (it % 127).toByte() }
        val selected = RoomProjectSnapshot.parse(record(bytes, false))
        val transport = ScriptedTransport { request ->
            val b = body(request)
            if (request.url.endsWith("/sdi_room_manage")) json(summary(role = "viewer")) else when (b.getString("action")) {
                "current" -> json(JSONObject().put("chunk_size", 262144).put("snapshot", record(bytes, false)))
                "get" -> {
                    val i = b.getInt("chunk_index"); val start = i * 262144
                    json(JSONObject().put("snapshot_id", snapshot).put("chunk_index", i).put("chunk_count", 2)
                        .put("sha256", selected.sha256).put("data", Base64.getMimeEncoder().encodeToString(bytes.copyOfRange(start, minOf(bytes.size, start + 262144)))))
                }
                "receipt" -> {
                    assertEquals(selected.sha256, b.getString("sha256"))
                    json(JSONObject().put("status", "recorded").put("server_copy", "deleted").put("verified", true))
                }
                else -> error("Unexpected request")
            }
        }
        val client = RoomProjectHandoffClient(CommunityGateway(FixedSession(), transport))
        assertArrayEquals(bytes, client.receive(detail.copy(myRole = "viewer"), selected, { true }))
        assertFalse(transport.requests.any { body(it).optString("action") == "receipt" })
        assertTrue(client.receipt(detail.copy(myRole = "viewer"), selected, { true }).contains("verified deletion"))
        assertEquals(1, transport.requests.count { body(it).optString("action") == "receipt" })
    }

    @Test fun corruptionAndCancellationNeverSendAReceiptOrFetchAnotherChunkAfterCancel() {
        val bytes = ByteArray(262145) { 7 }; val selected = RoomProjectSnapshot.parse(record(bytes, false))
        for (cancel in listOf(false, true)) {
            var live = true; var gets = 0
            val transport = ScriptedTransport { request ->
                val b = body(request)
                if (request.url.endsWith("/sdi_room_manage")) json(summary(role = "viewer")) else when (b.getString("action")) {
                    "current" -> json(JSONObject().put("chunk_size", 262144).put("snapshot", record(bytes, false)))
                    "get" -> {
                        val i = b.getInt("chunk_index"); gets++
                        if (cancel) live = false
                        val chunk = ByteArray(if (i == 0) 262144 else 1) { 8 }
                        json(JSONObject().put("snapshot_id", snapshot).put("chunk_index", i).put("chunk_count", 2)
                            .put("sha256", selected.sha256).put("data", Base64.getEncoder().encodeToString(chunk)))
                    }
                    else -> error("Unexpected mutation after receive failed")
                }
            }
            val client = RoomProjectHandoffClient(CommunityGateway(FixedSession(), transport))
            if (cancel) {
                try { client.receive(detail, selected, { live }); fail() } catch (_: CancellationException) { }
                assertEquals(1, gets)
            } else refuses { client.receive(detail, selected, { true }) }
            assertFalse(transport.requests.any { body(it).optString("action") == "receipt" })
        }
    }

    @Test fun changedRevisionOrWithdrawnOwnerRoleBlocksOfferBeforeAnyUpload() {
        for ((revision, role) in listOf(3 to "owner", 2 to "viewer")) {
            val transport = ScriptedTransport { json(summary(revision, role)) }
            refuses { RoomProjectHandoffClient(CommunityGateway(FixedSession(), transport)).send(detail, Fixtures.USER, byteArrayOf(1), { true }) }
            assertEquals(1, transport.requests.size)
            assertTrue(transport.requests.single().url.endsWith("/sdi_room_manage"))
        }
    }

    @Test fun invalidSizeStaleOperationSignedOutAndUnconfiguredMakeNoHttpRequest() {
        val transport = ScriptedTransport { error("No request may reach transport") }
        refuses { RoomProjectHandoffClient(CommunityGateway(FixedSession(), transport)).send(detail, Fixtures.USER, byteArrayOf(), { true }) }
        try { RoomProjectHandoffClient(CommunityGateway(FixedSession(), transport)).current(detail) { false }; fail() } catch (_: CancellationException) { }
        try { RoomProjectHandoffClient(CommunityGateway(FixedSession(token = null), transport)).current(detail) { true }; fail() } catch (_: CommunityException.SignedOut) { }
        try { RoomProjectHandoffClient(CommunityGateway(FixedSession(configured = null), transport)).current(detail) { true }; fail() } catch (_: CommunityException.NotConfigured) { }
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun malformedSnapshotCountsHashesExpiryAndForeignProjectAreRejected() {
        val bytes = byteArrayOf(1)
        for (bad in listOf(record(bytes, false).put("byte_size", 33554433), record(bytes, false).put("chunk_count", 128),
            record(bytes, false).put("sha256", "not-a-hash"))) refuses { RoomProjectSnapshot.parse(bad) }
        for (bad in listOf(record(bytes, false).put("expires_at", "2000-01-01T00:00:00Z"),
            record(bytes, false).put("project_ref", "device-project:${Fixtures.OTHER}"))) {
            val transport = ScriptedTransport { request -> if (request.url.endsWith("/sdi_room_manage")) json(summary())
                else json(JSONObject().put("chunk_size", 262144).put("snapshot", bad)) }
            refuses { RoomProjectHandoffClient(CommunityGateway(FixedSession(), transport)).current(detail) { true } }
            assertEquals(2, transport.requests.size)
        }
    }
}
