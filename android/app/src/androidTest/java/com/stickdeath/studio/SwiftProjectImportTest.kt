package com.stickdeath.studio

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Base64
import org.json.JSONObject

/** Runs against Android JSONObject, the production importer and actual AtomicFile storage.
 * Fixture is a format-contract fixture, not evidence of an iOS device export.
 */
class SwiftProjectImportTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun fixture() = instrumentation.context.assets.open("swift-legacy.sdi").use { it.readBytes() }
    private fun rejects(bytes: ByteArray) {
        try { SwiftProjectImport.decode(bytes); fail("Invalid/unsupported project was accepted") }
        catch (_: IllegalArgumentException) { }
        catch (_: org.json.JSONException) { }
    }
    @Test fun testLegacyGeometryAndNewIdentitySurviveActualStore() {
        val original = fixture()
        val document = SwiftProjectImport.decode(original)
        assertEquals(3, document.frame.strokes.size)
        val strokes = document.frame.strokes
        assertTrue(strokes.all { it.swiftLegacyPath })
        assertFalse(strokes[0].swiftLegacyButtCap)
        assertTrue(strokes[1].swiftLegacyButtCap)
        assertEquals(8f, strokes[1].width, 0f)
        assertEquals(15f, strokes[2].width, 0f)
        assertEquals(4, document.frame.hold)
        val store = ProjectStore(instrumentation.targetContext)
        val owned = mutableListOf<String>()
        try {
            val imported = store.importProject(original.inputStream()).also { owned.add(it.id) }
            val another = store.importProject(original.inputStream()).also { owned.add(it.id) }
            assertFalse(imported.id == document.id)
            assertFalse(imported.id == another.id)
            assertFalse(imported.frame.id == document.frame.id)
            val reopened = ProjectStore(instrumentation.targetContext).load(imported.id)
            assertEquals(imported, reopened)
            assertTrue(reopened.frame.strokes[1].swiftLegacyButtCap)
            assertTrue(original.contentEquals(fixture()))
        } finally {
            // Only records freshly allocated by this test; never clear the user's library.
            owned.forEach { id -> listOf(".json", ".json.bak", ".json.new").forEach { suffix ->
                java.io.File(instrumentation.targetContext.filesDir, "studio-projects/$id$suffix").delete()
            } }
        }
    }
    @Test fun testRoundPressureTransformAndPersistence() {
        val original = SwiftProjectImport.decode(fixture())
        val descriptor = JSONObject().put("version", 1).put("family", "round").put("seed", 7)
            .put("smoothing", 3.0).put("pressureEnabled", true).put("tipAngleDegrees", 45.0)
            .put("texture", 0.5).put("grain", 0.3)
        val brush = SwiftRoundBrush(descriptor.toString(), listOf(0.0, 1.0))
        val stroke = original.frame.strokes.first().copy(points = listOf(Point(30f,30f), Point(60f,30f)),
            width = 10f, swiftLegacyPath = false, swiftLegacyButtCap = false, swiftRoundBrush = brush)
        val source = original.frame.copy(strokes = listOf(stroke))
        val bounds = ArtworkBounds.of(stroke)
        val transformed = ArtworkTransform(scale = 2f, heightScale = 1f, angle = 90f)
            .apply(source, setOf(stroke.id), bounds).strokes.single()
        val before = brush.dabs(stroke)
        val after = brush.dabs(transformed)
        assertEquals(before.size, after.size)
        before.zip(after).forEach { (a,b) ->
            assertEquals(a.x, b.x, 0.0001); assertEquals(a.y, b.y, 0.0001)
            assertEquals(a.pressure, b.pressure, 0.0001)
        }
        val document = original.copy(frames = listOf(source.copy(strokes = listOf(transformed))))
        val store = ProjectStore(instrumentation.targetContext)
        val decoded = store.importProject(store.encode(document).inputStream())
        try { assertEquals(transformed.swiftRoundBrush, store.load(decoded.id).frame.strokes.single().swiftRoundBrush) }
        finally { listOf(".json", ".json.bak", ".json.new").forEach { suffix ->
            java.io.File(instrumentation.targetContext.filesDir, "studio-projects/${decoded.id}$suffix").delete()
        } }
    }
    @Test fun testIntegrityLengthAndUnsupportedDescriptorReject() {
        val bytes = fixture()
        rejects(bytes.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() })
        rejects(bytes.copyOf(bytes.size - 1))
        rejects(bytes + byteArrayOf(0))
        val root = JSONObject(String(bytes.copyOfRange("SDIPROJECT000001\n".toByteArray(Charsets.US_ASCII).size + 8 + 32, bytes.size), Charsets.UTF_8))
        val project = root.getJSONObject("project")
        val archive = JSONObject(String(Base64.getDecoder().decode(project.getString("editableDocumentData")), Charsets.UTF_8))
        archive.getJSONObject("document").getJSONArray("frames").getJSONObject(0)
            .getJSONArray("elements").getJSONObject(0).put("brush", JSONObject().put("family", "round"))
        project.put("editableDocumentData", Base64.getEncoder().encodeToString(archive.toString().toByteArray(Charsets.UTF_8)))
        val payload = root.toString().toByteArray(Charsets.UTF_8)
        val envelope = "SDIPROJECT000001\n".toByteArray(Charsets.US_ASCII) +
            ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(payload.size.toLong()).array() +
            MessageDigest.getInstance("SHA-256").digest(payload) + payload
        rejects(envelope)
    }
}
