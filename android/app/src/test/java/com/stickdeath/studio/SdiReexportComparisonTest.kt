package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.security.MessageDigest
import java.util.Base64
import java.util.Locale

/** Android half of the both-client `.sdi` re-export comparison (#286). The golden shared fixture
 * (Tests/SDIFixtures) is opened with the production importer, re-exported with the production
 * exporter, and the editable document read back from the exported bytes is reduced with the same
 * projection as `make_fixtures.interchange_projection` and the iOS harness
 * (Tests/SDIInterchange/main.swift). Both clients must equal `reexport.json`, and the iOS harness
 * also opens Android's committed re-export (`android-reexport/<name>.android.sdi`), which this test
 * keeps byte-identical to the current exporter. Regenerate it after a deliberate exporter change with
 * `SDI_UPDATE_ANDROID_REEXPORT=<repo>/Tests/SDIFixtures/android-reexport/<name>.android.sdi`. */
class SdiReexportComparisonTest {
    private fun resource(path: String): ByteArray =
        javaClass.classLoader!!.getResourceAsStream(path)?.use { it.readBytes() } ?: error("Missing shared fixture resource $path")
    private val magicSize = "SDIPROJECT000001\n".length
    /** The golden fixture's multiply/linear-dodge layers need API 29, as on a device (see SwiftProjectImportTest). */
    private val ANDROID_10 = 29

    private fun editableDocument(bytes: ByteArray): Map<String, Any?> {
        val payload = bytes.copyOfRange(magicSize + 8 + 32, bytes.size)
        val project = TestJson.obj(TestJson.obj(TestJson.parse(String(payload, Charsets.UTF_8)))["project"])
        val archive = TestJson.obj(TestJson.parse(String(Base64.getDecoder().decode(project["editableDocumentData"] as String), Charsets.UTF_8)))
        return TestJson.obj(archive["document"])
    }

    @Test fun goldenFixtureReexportMatchesTheSharedExpectation() {
        val expectation = TestJson.obj(TestJson.parse(String(resource("reexport.json"), Charsets.UTF_8)))
        val name = expectation["fixture"] as String
        val original = resource("assets/$name")
        // The importer stamps the open time as `modified`; fix it so the committed Android bytes are reproducible.
        val opened = SwiftProjectImport.decode(original, ANDROID_10).copy(modified = 1_700_000_000_000L)
        val exported = SwiftProjectExport.encode(opened, nowMillis = 1_700_000_000_000L)
        val androidName = "android-reexport/" + name.removeSuffix(".sdi") + ".android.sdi"
        System.getenv("SDI_UPDATE_ANDROID_REEXPORT")?.takeIf { it.isNotBlank() }?.let { java.io.File(it).writeBytes(exported) }
        assertTrue("Tests/SDIFixtures/$androidName is stale; regenerate it from SwiftProjectExport",
            resource(androidName).contentEquals(exported))
        val projected = SdiProjection.project(editableDocument(exported))
        assertEquals(SdiProjection.canonical(expectation["projection"]), SdiProjection.canonical(projected))
        // The source fixture also matches, so the expectation describes the committed bytes.
        assertEquals(SdiProjection.canonical(expectation["projection"]), SdiProjection.canonical(SdiProjection.project(editableDocument(original))))
        // A second open of Android's own export is stable (no drift on repeated round trips).
        val again = SwiftProjectExport.encode(SwiftProjectImport.decode(exported, ANDROID_10).copy(modified = 1_700_000_000_000L), nowMillis = 1_700_000_000_000L)
        assertEquals(SdiProjection.canonical(projected), SdiProjection.canonical(SdiProjection.project(editableDocument(again))))
        assertTrue("opening must not modify the fixture", original.contentEquals(resource("assets/$name")))
    }

    @Test fun androidOutcomesMatchExpectationsAndOriginalsArePreserved() {
        val expectations = TestJson.obj(TestJson.parse(String(resource("expectations.json"), Charsets.UTF_8)))
        expectations.forEach { (name, raw) ->
            val info = TestJson.obj(raw)
            val bytes = resource("assets/$name")
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { String.format(Locale.ROOT, "%02x", it) }
            assertEquals(name, info["sha256"], digest)
            val accepted = try { SwiftProjectImport.decode(bytes, ANDROID_10); true } catch (e: IllegalArgumentException) { false } catch (e: org.json.JSONException) { false }
            assertEquals(name, info["android"] == "accept", accepted)
            assertTrue(name, bytes.contentEquals(resource("assets/$name")))
        }
        if (expectations.isEmpty()) fail("No shared fixtures were found")
    }
}

/** Kotlin port of `make_fixtures.interchange_projection`; keep the three implementations identical. */
object SdiProjection {
    private fun obj(value: Any?) = TestJson.obj(value)
    private fun list(value: Any?) = TestJson.list(value ?: emptyList<Any?>())

    fun project(document: Map<String, Any?>): Map<String, Any?> = linkedMapOf(
        "id" to (document["id"] as String).lowercase(Locale.ROOT), "name" to document["name"],
        "width" to document["width"], "height" to document["height"], "fps" to document["fps"],
        "activeFrameID" to document["activeFrameID"], "activeLayerID" to document["activeLayerID"],
        "layers" to list(document["layers"]).map { raw ->
            val layer = obj(raw)
            val locked = layer["locked"] == true
            linkedMapOf("id" to layer["id"], "name" to layer["name"], "visible" to (layer["visible"] ?: true),
                "locked" to locked, "opacity" to (layer["opacity"] ?: 1L),
                "lockMode" to if (locked) "full" else (layer["lockMode"] ?: "free"),
                "blendMode" to ((layer["blendMode"] as String?) ?: "normal").lowercase(Locale.ROOT),
                "glowEnabled" to (layer["glowEnabled"] ?: false), "colorLabel" to layer["colorLabel"])
        },
        "frames" to list(document["frames"]).map { raw ->
            val frame = obj(raw)
            linkedMapOf("id" to frame["id"], "holdTicks" to (frame["holdTicks"] ?: 1L),
                "elements" to list(frame["elements"]).map { element(obj(it)) })
        },
        "audioClips" to list(document["audioClips"]).size.toLong(),
        "audioTrackVolumes" to (document["audioTrackVolumes"] ?: listOf(1L, 1L, 1L, 1L)),
        "mutedAudioTracks" to list(document["mutedAudioTracks"]).map { (it as Number).toLong() }.sorted(),
        "audioTrackPans" to (document["audioTrackPans"] ?: listOf(0L, 0L, 0L, 0L)),
        "soloedAudioTracks" to list(document["soloedAudioTracks"]).map { (it as Number).toLong() }.sorted())

    private fun element(item: Map<String, Any?>): Map<String, Any?> {
        val brush = item["brush"]?.let { obj(it) }
        return linkedMapOf("id" to item["id"], "tool" to item["tool"], "layerID" to item["layerID"],
            "color" to (item["color"] as String).uppercase(Locale.ROOT), "width" to item["width"], "opacity" to (item["opacity"] ?: 1L),
            "points" to list(item["points"]).map { raw ->
                val point = obj(raw)
                listOfNotNull(point["x"], point["y"], point["pressure"])
            },
            "brush" to brush?.let { linkedMapOf("family" to it["family"], "seed" to it["seed"]) })
    }

    /** Sorted keys, numbers to four decimals; identical in the Swift harness. */
    fun canonical(value: Any?): String = when (value) {
        null -> "null"
        is Boolean -> value.toString()
        is Number -> String.format(Locale.ROOT, "%.4f", value.toDouble()).let { if (it == "-0.0000") "0.0000" else it }
        is String -> "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        is Map<*, *> -> value.keys.map { it as String }.sorted().joinToString(",", "{", "}") { "\"$it\":" + canonical(value[it]) }
        is List<*> -> value.joinToString(",", "[", "]") { canonical(it) }
        else -> error("Unexpected JSON value ${value::class}")
    }
}
