package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The manifests carry exactly the iOS Codable keys (StudioExportService, StudioMovieExportService,
 * StudioGIFEncoder.Receipt) with values taken from the document and the real encoded size. */
class ExportManifestsTest {
    private val document = Document.create("Sunset over Lagos!", 64, 48, 12).let { d ->
        d.copy(id = "0a1b2c3d-0000-4000-8000-00000000abcd", revision = 7, frames = listOf(d.frame, Frame(id = "frame-2", hold = 3)))
    }

    @Test fun pngSequenceManifestMatchesTheIOSKeys() {
        val manifest = TestJson.obj(TestJson.parse(ExportManifests.image(document, ExportManifests.ImageFormat.PngSequence, transparent = false, layout = null)))
        assertEquals(setOf("version", "projectID", "documentRevision", "format", "background", "fps", "canvasWidth", "canvasHeight",
            "imageWidth", "imageHeight", "audioIncluded", "editorGuidesIncluded", "frames", "filenameBase"), manifest.keys)
        assertEquals(1L, manifest["version"]); assertEquals("0A1B2C3D-0000-4000-8000-00000000ABCD", manifest["projectID"])
        assertEquals(7L, manifest["documentRevision"]); assertEquals("pngSequence", manifest["format"]); assertEquals("white", manifest["background"])
        assertEquals(64L, manifest["imageWidth"]); assertEquals(48L, manifest["imageHeight"]); assertEquals(false, manifest["audioIncluded"])
        assertEquals("Sunset-over-Lagos", manifest["filenameBase"])
        val frames = TestJson.list(manifest["frames"]).map { TestJson.obj(it) }
        assertEquals(2, frames.size)
        assertEquals(setOf("index", "id", "filename", "x", "y", "width", "height", "startTick", "durationTicks"), frames[0].keys)
        assertEquals("Sunset-over-Lagos_000000.png", frames[0]["filename"]); assertEquals("Sunset-over-Lagos_000001.png", frames[1]["filename"])
        assertEquals(0L, frames[0]["startTick"]); assertEquals(1L, frames[0]["durationTicks"]); assertEquals(1L, frames[1]["startTick"]); assertEquals(3L, frames[1]["durationTicks"])
        assertEquals("frame-2", frames[1]["id"])
    }

    @Test fun spritesheetAndTransparencyAreRecorded() {
        val layout = ExportManifests.SheetLayout(columns = 2, rows = 1, imageWidth = 128, imageHeight = 48)
        val manifest = TestJson.obj(TestJson.parse(ExportManifests.image(document, ExportManifests.ImageFormat.Spritesheet, transparent = true, layout = layout)))
        assertEquals("spritesheet", manifest["format"]); assertEquals("transparent", manifest["background"])
        assertEquals(128L, manifest["imageWidth"]); assertEquals(2L, manifest["sheetColumns"]); assertEquals(0L, manifest["cellPadding"])
        val frames = TestJson.list(manifest["frames"]).map { TestJson.obj(it) }
        assertEquals("Sunset-over-Lagos_spritesheet.png", frames[1]["filename"]); assertEquals(64L, frames[1]["x"]); assertEquals(0L, frames[1]["y"])
        // A non-white opaque project background is written as hex rather than reported as white.
        assertEquals("#E52B38", ExportManifests.background(document.copy(backgroundColor = 0xffe52b38.toInt()), false))
        assertEquals("white", ExportManifests.background(document, false))
    }

    @Test fun movieManifestMatchesTheIOSKeys() {
        val manifest = TestJson.obj(TestJson.parse(ExportManifests.movie(document, encodedBytes = 123456L, movieFilename = "Sunset-over-Lagos.mp4", audioIncluded = true)))
        assertEquals(setOf("version", "projectID", "documentRevision", "frameIDs", "fps", "width", "height", "durationNumerator", "durationDenominator",
            "codec", "background", "audioIncluded", "editorGuidesIncluded", "encodedBytes", "canvasWidth", "canvasHeight", "renderRule", "movieFilename"), manifest.keys)
        assertEquals(listOf(document.frames[0].id, "frame-2"), manifest["frameIDs"])
        assertEquals(4L, manifest["durationNumerator"]); assertEquals(12L, manifest["durationDenominator"]); assertEquals("h264", manifest["codec"])
        assertEquals(123456L, manifest["encodedBytes"]); assertEquals(true, manifest["audioIncluded"])
        assertTrue((manifest["renderRule"] as String).startsWith("scale=1.0 (Original); content 64x48 at top-left"))
    }

    @Test fun gifReceiptMatchesTheIOSKeys() {
        val manifest = TestJson.obj(TestJson.parse(ExportManifests.gif(document, encodedBytes = 999L)))
        assertEquals(setOf("version", "projectID", "revision", "frameIDs", "width", "height", "sourceFPS", "delaysCentiseconds", "encodedBytes",
            "background", "audioIncluded", "editorGuidesIncluded"), manifest.keys)
        assertEquals(listOf(8L, 25L), manifest["delaysCentiseconds"])
        assertEquals(12L, manifest["sourceFPS"]); assertEquals(999L, manifest["encodedBytes"]); assertEquals(false, manifest["audioIncluded"])
    }

    @Test fun jsonWriterIsDeterministicAndStrict() {
        assertEquals("""{"a":1,"b":[true,null,"x\"y"],"c":0.5,"d":1}""", SdiJson.encode(mapOf("c" to 0.5, "a" to 1, "d" to 1.0, "b" to listOf(true, null, "x\"y")), pretty = false))
        assertEquals("0.00001", SdiJson.encode(0.00001, pretty = false))
        assertEquals("12345678901234567", SdiJson.encode(12345678901234567L, pretty = false))
        assertEquals("""{"k":{"raw":true}}""", SdiJson.encode(mapOf("k" to SdiJson.Raw("""{"raw":true}""")), pretty = false))
        try { SdiJson.encode(Double.NaN); org.junit.Assert.fail("NaN was encoded") } catch (_: IllegalArgumentException) { }
        val pretty = SdiJson.encode(mapOf("a" to listOf(1)))
        assertEquals(TestJson.parse("""{"a":[1]}"""), TestJson.parse(pretty))
        assertTrue(pretty.contains("\n"))
    }
}
