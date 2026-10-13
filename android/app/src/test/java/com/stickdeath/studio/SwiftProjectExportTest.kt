package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Base64

/** The Android → iOS portable envelope and its JSON contract, checked on the plain JVM. The
 * instrumented SwiftProjectImportTest re-imports the same bytes with the production importer. */
class SwiftProjectExportTest {
    private val magic = "SDIPROJECT000001\n".toByteArray(Charsets.US_ASCII)
    private val layerA = Layer(id = "layer-a", name = "Ink", lockMode = LayerLockMode.Position, blend = LayerBlend.Multiply, label = LayerLabel.Red)
    private val layerB = Layer(id = "layer-b", name = "Shade", opacity = 0.6f, lockMode = LayerLockMode.Alpha, blend = LayerBlend.LinearDodge)
    private val descriptor = """{"family":"round","grain":0.3,"pressureEnabled":true,"seed":7,"smoothing":3,"texture":0.5,"tipAngleDegrees":45,"version":1}"""
    private val pen = Stroke(id = "stroke-pen", layerID = "layer-a", points = listOf(Point(8f, 8f), Point(40f, 20f)), color = 0xff2563eb.toInt(), width = 10f, tool = Tool.Pencil)
    private val pencil = pen.copy(id = "stroke-pencil", points = listOf(Point(8f, 24f), Point(40f, 30f)), width = 8f, swiftLegacyPath = true, swiftLegacyButtCap = true)
    private val brush = pen.copy(id = "stroke-brush", layerID = "layer-b", points = listOf(Point(8f, 40f), Point(40f, 44f), Point(48f, 50f)),
        swiftRoundBrush = SwiftRoundBrush(descriptor, listOf(0.2, 0.6, 1.0)))
    private val line = Stroke(id = "stroke-line", layerID = "layer-a", points = listOf(Point(4f, 60f), Point(60f, 60f)), color = 0xff000000.toInt(), width = 2f, tool = Tool.Line, opacity = 0.5f)
    private val document = Document(id = "00000000-0000-4000-8000-000000000035", name = "Export fixture", width = 64, height = 64, fps = 12,
        frames = listOf(Frame(id = "frame-1", strokes = listOf(pen, pencil, line), hold = 1), Frame(id = "frame-2", strokes = listOf(brush), hold = 3)),
        layers = listOf(layerA, layerB), activeFrameID = "frame-1", activeLayerID = "layer-a", revision = 4, modified = 1_700_000_000_000L,
        audioTracks = listOf(AudioTrackMix(pan = -0.25f), AudioTrackMix(volume = 0.7f, soloed = true), AudioTrackMix(), AudioTrackMix(muted = true)))

    private fun decode(bytes: ByteArray): Map<String, Any?> {
        val header = magic.size + 8 + 32
        assertTrue(bytes.copyOfRange(0, magic.size).contentEquals(magic))
        val count = ByteBuffer.wrap(bytes, magic.size, 8).order(ByteOrder.BIG_ENDIAN).long
        assertEquals((bytes.size - header).toLong(), count)
        val payload = bytes.copyOfRange(header, bytes.size)
        assertTrue(MessageDigest.getInstance("SHA-256").digest(payload).contentEquals(bytes.copyOfRange(magic.size + 8, header)))
        return TestJson.obj(TestJson.parse(String(payload, Charsets.UTF_8)))
    }

    @Test fun envelopeIsSignedAndCarriesTheRevisionLayout() {
        val root = decode(SwiftProjectExport.encode(document, nowMillis = 1_700_000_000_000L))
        assertEquals(1L, root["version"])
        val project = TestJson.obj(root["project"])
        assertEquals(setOf("id", "metadata", "frames", "audioTracks", "editableDocumentData"), project.keys)
        assertEquals("00000000-0000-4000-8000-000000000035", project["id"])
        assertEquals(listOf(emptyMap<String, Any?>(), emptyMap()), project["frames"])
        assertEquals(emptyList<Any?>(), project["audioTracks"])
        val metadata = TestJson.obj(project["metadata"])
        assertEquals(setOf("id", "title", "fps", "canvasWidth", "canvasHeight", "frameCount", "layerCount", "createdAt", "modifiedAt"), metadata.keys)
        assertEquals("Export fixture", metadata["title"]); assertEquals(2L, metadata["frameCount"]); assertEquals(2L, metadata["layerCount"])
        assertEquals(SwiftDates.fromEpochMillis(1_700_000_000_000L), (metadata["modifiedAt"] as Number).toDouble(), 1e-9)
        val archive = TestJson.obj(TestJson.parse(String(Base64.getDecoder().decode(project["editableDocumentData"] as String), Charsets.UTF_8)))
        assertEquals(setOf("document", "rasterFrameIndices"), archive.keys)
        assertEquals(emptyMap<String, Any?>(), archive["rasterFrameIndices"])
    }

    @Test fun documentJsonMatchesTheStudioDocumentContract() {
        val json = TestJson.obj(TestJson.parse(SdiJson.encode(SwiftProjectExport.documentJson(document, 1_700_000_000_000L))))
        assertEquals(34L, json["schemaVersion"]) // Linear Dodge, pan and solo need schema 34
        assertEquals(setOf("schemaVersion", "id", "name", "width", "height", "fps", "frames", "layers", "activeFrameID", "activeLayerID", "audioClips",
            "gridEnabled", "onionEnabled", "createdAt", "modifiedAt", "revision", "audioTrackVolumes", "mutedAudioTracks", "audioTrackPans", "soloedAudioTracks"), json.keys)
        assertEquals(listOf(1.0, 0.7f.toDouble(), 1.0, 1.0), TestJson.list(json["audioTrackVolumes"]).map { (it as Number).toDouble() })
        assertEquals(listOf(4L), json["mutedAudioTracks"]); assertEquals(listOf(2L), json["soloedAudioTracks"])
        assertEquals(listOf(-0.25, 0.0, 0.0, 0.0), TestJson.list(json["audioTrackPans"]).map { (it as Number).toDouble() })
        val layers = TestJson.list(json["layers"]).map { TestJson.obj(it) }
        assertEquals(mapOf("id" to "layer-a", "name" to "Ink", "visible" to true, "locked" to false, "opacity" to 1L, "lockMode" to "position",
            "blendMode" to "multiply", "glowEnabled" to false, "colorLabel" to "#FC5D5B"), layers[0])
        assertEquals("alpha", layers[1]["lockMode"]); assertEquals("linear-dodge", layers[1]["blendMode"]); assertNull(layers[1]["colorLabel"])
        assertEquals(0.6f.toDouble(), layers[1]["opacity"] as Double, 1e-9)
        val frames = TestJson.list(json["frames"]).map { TestJson.obj(it) }
        assertEquals(setOf("id", "elements"), frames[0].keys) // one-tick frames omit holdTicks like iOS defaults
        assertEquals(3L, frames[1]["holdTicks"])
        val elements = TestJson.list(frames[0]["elements"]).map { TestJson.obj(it) }
        assertEquals(listOf("pen", "pencil", "line"), elements.map { it["tool"] })
        assertEquals(setOf("id", "tool", "points", "color", "width", "opacity", "layerID"), elements[0].keys)
        assertEquals("#2563EB", elements[0]["color"]); assertEquals(10L, elements[0]["width"])
        // The historical pencil multiplier (0.8) is undone so iOS redraws the same width.
        assertEquals(10.0, (elements[1]["width"] as Number).toDouble(), 1e-5)
        assertEquals(0.5, (elements[2]["opacity"] as Number).toDouble(), 1e-9)
        assertEquals(listOf(mapOf("x" to 8L, "y" to 8L), mapOf("x" to 40L, "y" to 20L)), elements[0]["points"])
        val brushElement = TestJson.obj(TestJson.list(frames[1]["elements"]).single())
        assertEquals(TestJson.parse(descriptor), brushElement["brush"])
        assertEquals(listOf(0.2, 0.6, 1.0), TestJson.list(brushElement["points"]).map { (TestJson.obj(it)["pressure"] as Number).toDouble() })
    }

    @Test fun schemaVersionIsTheLowestThatValidates() {
        assertEquals(21, SwiftProjectExport.schemaVersion(Document.create("Plain", 64, 64, 12)))
        assertEquals(34, SwiftProjectExport.schemaVersion(document))
        val historical = document.copy(layers = document.layers.map { it.copy(blend = LayerBlend.Screen) }, audioTracks = List(4) { AudioTrackMix(muted = it == 0) })
        assertEquals(21, SwiftProjectExport.schemaVersion(historical))
    }

    @Test fun unsupportedContentRejectsTheWholeExport() {
        assertTrue(SwiftProjectExport.isExportable(document))
        fun reasons(stroke: Stroke) = SwiftProjectExport.unsupportedReasons(document.copy(frames = listOf(document.frames[0].copy(strokes = listOf(stroke)))))
        assertTrue(reasons(pen.copy(brush = BrushFamily.Marker)).single().contains("Marker"))
        assertTrue(reasons(pen.copy(preservesLayerAlpha = true)).single().contains("Alpha"))
        assertTrue(reasons(pen.copy(tool = Tool.Eraser)).single().contains("Eraser"))
        assertTrue(reasons(pen.copy(tool = Tool.SoftEraser)).single().contains("Eraser"))
        assertTrue(reasons(Stroke(layerID = "layer-a", points = ShapePath.points(Tool.Rectangle, Point(1f, 1f), Point(20f, 20f), false), color = -16777216, width = 2f, tool = Tool.Rectangle)).single().contains("Rectangle"))
        assertTrue(reasons(brush.copy(brushTransform = BrushTransform(2f, 0f, 0f, 1f))).single().contains("transform"))
        try { SwiftProjectExport.encode(document.copy(frames = listOf(document.frames[0].copy(strokes = listOf(pen.copy(brush = BrushFamily.Crayon)))))); fail("Crayon export was accepted") }
        catch (error: SwiftProjectExport.Unsupported) { assertTrue(error.message!!.contains("unchanged")) }
        assertFalse(SwiftProjectExport.isExportable(document.copy(frames = listOf(document.frames[0].copy(strokes = listOf(pen.copy(tool = Tool.Eraser)))))))
    }

    @Test fun exportIsDeterministicForTheSameInput() {
        val first = SwiftProjectExport.encode(document, nowMillis = 1_700_000_000_000L)
        val second = SwiftProjectExport.encode(document, nowMillis = 1_700_000_000_000L)
        assertTrue(first.contentEquals(second))
    }
}
