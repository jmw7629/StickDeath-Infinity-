package com.stickdeath.studio

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/** Runs against Android JSONObject, the production importer and actual AtomicFile storage.
 * Fixtures are format-contract fixtures, not evidence of an iOS device export.
 */
class SwiftProjectImportTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val magic = "SDIPROJECT000001\n".toByteArray(Charsets.US_ASCII)
    private fun fixture(name: String = "swift-legacy.sdi") = instrumentation.context.assets.open(name).use { it.readBytes() }
    private fun rejects(bytes: ByteArray) {
        try { SwiftProjectImport.decode(bytes); fail("Invalid/unsupported project was accepted") }
        catch (_: IllegalArgumentException) { }
        catch (_: org.json.JSONException) { }
    }
    private fun cleanup(id: String) {
        // Only records freshly allocated by a test; never clear the user's library.
        listOf(".json", ".json.bak", ".json.new").forEach { suffix ->
            java.io.File(instrumentation.targetContext.filesDir, "studio-projects/$id$suffix").delete()
        }
    }
    /** Re-signs a portable root so only the JSON content differs from the fixture. */
    private fun envelope(root: JSONObject): ByteArray {
        val payload = root.toString().toByteArray(Charsets.UTF_8)
        return magic + ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(payload.size.toLong()).array() +
            MessageDigest.getInstance("SHA-256").digest(payload) + payload
    }
    /** Applies [edit] to the embedded editable Swift document and re-signs the envelope. */
    private fun mutated(bytes: ByteArray, edit: (JSONObject) -> Unit): ByteArray {
        val root = JSONObject(String(bytes.copyOfRange(magic.size + 8 + 32, bytes.size), Charsets.UTF_8))
        val project = root.getJSONObject("project")
        val archive = JSONObject(String(Base64.getDecoder().decode(project.getString("editableDocumentData")), Charsets.UTF_8))
        edit(archive.getJSONObject("document"))
        project.put("editableDocumentData", Base64.getEncoder().encodeToString(archive.toString().toByteArray(Charsets.UTF_8)))
        return envelope(root)
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
        assertEquals(List(4) { AudioTrackMix() }, document.audioTracks)
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
        } finally { owned.forEach { cleanup(it) } }
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
        finally { cleanup(decoded.id) }
    }
    @Test fun testIntegrityLengthAndUnsupportedDescriptorReject() {
        val bytes = fixture()
        rejects(bytes.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() })
        rejects(bytes.copyOf(bytes.size - 1))
        rejects(bytes + byteArrayOf(0))
        rejects(mutated(bytes) { document ->
            document.getJSONArray("frames").getJSONObject(0).getJSONArray("elements").getJSONObject(0)
                .put("brush", JSONObject().put("family", "round"))
        })
    }
    /** Schema-34 contract: PhotoCraft blend raw values plus SoundCraft pan/solo (and the older
     * mute/volume lists) import, persist as Android-local v25 and reread, including v24 enum names. */
    @Test fun testSchema34MixerAndBlendModesImportAndPersist() {
        val bytes = fixture("swift-schema34.sdi")
        if (android.os.Build.VERSION.SDK_INT < 29) {
            // Multiply/Color Burn need android.graphics.BlendMode; the import refuses rather than drawing Normal.
            rejects(bytes); return
        }
        val document = SwiftProjectImport.decode(bytes)
        assertEquals(listOf(LayerBlend.Multiply, LayerBlend.ColorBurn), document.layers.map { it.blend })
        assertEquals(0.75f, document.layers[1].opacity, 0f)
        assertEquals(listOf(
            AudioTrackMix(volume = 1f, muted = false, pan = -0.5f, soloed = false),
            AudioTrackMix(volume = 0.5f, muted = false, pan = 0f, soloed = true),
            AudioTrackMix(volume = 1f, muted = true, pan = 0.25f, soloed = false),
            AudioTrackMix(volume = 0.8f, muted = false, pan = 1f, soloed = true)), document.audioTracks)
        assertFalse(StudioCraftAudio.isTrackAudible(1, document.audioTracks))
        assertTrue(StudioCraftAudio.isTrackAudible(2, document.audioTracks))
        assertFalse(StudioCraftAudio.isTrackAudible(3, document.audioTracks))
        assertTrue(StudioCraftAudio.isTrackAudible(4, document.audioTracks))
        assertEquals(3, document.frame.hold)
        assertEquals(2, document.frame.strokes.size)
        val store = ProjectStore(instrumentation.targetContext)
        val encoded = JSONObject(String(store.encode(document), Charsets.UTF_8))
        assertEquals(25, encoded.getInt("version"))
        assertEquals("multiply", encoded.getJSONArray("layers").getJSONObject(0).getString("blend"))
        assertEquals("color-burn", encoded.getJSONArray("layers").getJSONObject(1).getString("blend"))
        assertEquals(0.25, encoded.getJSONArray("audioTracks").getJSONObject(2).getDouble("pan"), 1e-6)
        assertTrue(encoded.getJSONArray("audioTracks").getJSONObject(3).getBoolean("soloed"))
        val owned = mutableListOf<String>()
        try {
            val imported = store.importProject(store.encode(document).inputStream()).also { owned.add(it.id) }
            val reopened = store.load(imported.id)
            assertEquals(document.audioTracks, reopened.audioTracks)
            assertEquals(document.layers.map { it.blend }, reopened.layers.map { it.blend })
            // A v24 record stores enum names and has no pan/solo fields; it must still read.
            val legacy = JSONObject(String(store.encode(document), Charsets.UTF_8)).put("version", 24)
            legacy.getJSONArray("layers").getJSONObject(1).put("blend", "ColorBurn")
            val tracks = legacy.getJSONArray("audioTracks")
            for (index in 0 until tracks.length()) { tracks.getJSONObject(index).remove("pan"); tracks.getJSONObject(index).remove("soloed") }
            val old = store.importProject(legacy.toString().toByteArray(Charsets.UTF_8).inputStream()).also { owned.add(it.id) }
            assertEquals(LayerBlend.ColorBurn, old.layers[1].blend)
            assertEquals(listOf(1f, 0.5f, 1f, 0.8f), old.audioTracks.map { it.volume })
            assertTrue(old.audioTracks.all { it.pan == 0f && !it.soloed })
            // Pan/solo fields claim v25; a v24 envelope carrying them is rejected, original preserved.
            val forged = JSONObject(String(store.encode(document), Charsets.UTF_8)).put("version", 24)
            try { store.importProject(forged.toString().toByteArray(Charsets.UTF_8).inputStream()).also { owned.add(it.id) }; fail("v24 envelope with pan/solo was accepted") }
            catch (_: IllegalArgumentException) { }
        } finally { owned.forEach { cleanup(it) } }
    }
    @Test fun testSchema34InvalidMixerAndUnrenderableBlendsReject() {
        val bytes = fixture("swift-schema34.sdi")
        rejects(mutated(bytes) { it.put("audioTrackPans", JSONArray(listOf(1.5, 0.0, 0.0, 0.0))) })
        rejects(mutated(bytes) { it.put("audioTrackPans", JSONArray(listOf(-1.0, 0.0, 0.0))) })
        rejects(mutated(bytes) { it.put("soloedAudioTracks", JSONArray(listOf(2, 1))) })
        rejects(mutated(bytes) { it.put("soloedAudioTracks", JSONArray(listOf(1, 1))) })
        rejects(mutated(bytes) { it.put("soloedAudioTracks", JSONArray(listOf(5))) })
        rejects(mutated(bytes) { it.put("soloedAudioTracks", JSONArray(listOf(1.5))) })
        rejects(mutated(bytes) { it.put("mutedAudioTracks", JSONArray(listOf(0))) })
        rejects(mutated(bytes) { it.put("audioTrackVolumes", JSONArray(listOf(1.0, 1.2, 1.0, 1.0))) })
        // Pans, solos and extended blends need schema 34, exactly as StudioDocument.validate() requires.
        rejects(mutated(bytes) { it.put("schemaVersion", 33) })
        rejects(mutated(bytes) { it.put("schemaVersion", 35) })
        // Unknown legacy strings are not guessed, and Linear Burn has no Android compositing mode.
        rejects(mutated(bytes) { it.getJSONArray("layers").getJSONObject(0).put("blendMode", "dissolve") })
        rejects(mutated(bytes) { it.getJSONArray("layers").getJSONObject(0).put("blendMode", "colorBurn") })
        rejects(mutated(bytes) { it.getJSONArray("layers").getJSONObject(0).put("blendMode", "linear-burn") })
        // Glow and partial lock modes still have no Android representation.
        rejects(mutated(bytes) { it.getJSONArray("layers").getJSONObject(0).put("glowEnabled", true) })
        rejects(mutated(bytes) { it.getJSONArray("layers").getJSONObject(0).put("lockMode", "position") })
        rejects(mutated(bytes) { it.put("audioClips", JSONArray(listOf(JSONObject().put("id", "clip-1")))) })
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            // Case-insensitive raw values import, matching StudioLayerBlendMode(stored:).
            val upper = SwiftProjectImport.decode(mutated(bytes) { it.getJSONArray("layers").getJSONObject(1).put("blendMode", "Color-Burn") })
            assertEquals(LayerBlend.ColorBurn, upper.layers[1].blend)
            val dodge = SwiftProjectImport.decode(mutated(bytes) { it.getJSONArray("layers").getJSONObject(1).put("blendMode", "linear-dodge") })
            assertEquals(LayerBlend.LinearDodge, dodge.layers[1].blend)
            // Historical six modes do not need schema 34.
            val historical = SwiftProjectImport.decode(mutated(bytes) {
                it.put("schemaVersion", 21); it.remove("audioTrackPans"); it.remove("soloedAudioTracks")
                it.getJSONArray("layers").getJSONObject(1).put("blendMode", "screen")
            })
            assertEquals(listOf(LayerBlend.Multiply, LayerBlend.Screen), historical.layers.map { it.blend })
        }
    }
    private fun constantWav(frames: Int, value: Int, rate: Int = 8000): AudioSource {
        val pcm = frames * 2
        val buffer = ByteBuffer.allocate(44 + pcm).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray(Charsets.US_ASCII)).putInt(36 + pcm).put("WAVEfmt ".toByteArray(Charsets.US_ASCII)).putInt(16)
            .putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
            .put("data".toByteArray(Charsets.US_ASCII)).putInt(pcm)
        repeat(frames) { buffer.putShort(value.toShort()) }
        return AudioSource.decode(android.util.Base64.encodeToString(buffer.array(), android.util.Base64.NO_WRAP))
    }
    /** The deterministic mixer applies the SoundCraft mute/solo rule and balance law per channel. */
    @Test fun testMixerAppliesSoloAndBalanceLaw() {
        val source = constantWav(800, 1000)
        val base = Document.create("Mix contract", 64, 64, 12)
        val clips = listOf(AudioClip(name = "one", source = source, track = 1), AudioClip(name = "two", source = source, track = 2))
        fun mix(tracks: List<AudioTrackMix>): Pair<Int, Int> {
            val mixer = AudioMixer(base.copy(audioClips = clips, audioTracks = tracks))
            val out = ByteBuffer.allocate(16)
            mixer.write(0, 4, out) {}
            return out.getShort(0).toInt() to out.getShort(2).toInt()
        }
        assertEquals(2000 to 2000, mix(List(4) { AudioTrackMix() }))
        // Solo on track 2 silences track 1; pan R50 scales left to 0.5 and leaves right at 1.
        assertEquals(500 to 1000, mix(listOf(AudioTrackMix(), AudioTrackMix(pan = 0.5f, soloed = true), AudioTrackMix(), AudioTrackMix())))
        // A muted track stays silent even when soloed, and its solo still silences the other track.
        assertEquals(0 to 0, mix(listOf(AudioTrackMix(), AudioTrackMix(muted = true, soloed = true), AudioTrackMix(), AudioTrackMix())))
        // Pan L100 removes that track from the right channel; the centred track is unchanged.
        assertEquals(2000 to 1000, mix(listOf(AudioTrackMix(pan = -1f), AudioTrackMix(), AudioTrackMix(), AudioTrackMix())))
        // Track gain still multiplies clip gain.
        assertEquals(1500 to 1500, mix(listOf(AudioTrackMix(volume = 0.5f), AudioTrackMix(), AudioTrackMix(), AudioTrackMix())))
    }
}
