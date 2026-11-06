package com.stickdeath.studio

import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Actual Android codecs/private storage/JNI publication. Offline transport supplies only the
 * existing canonical publisher fixture. These are instrumentation cases, not fake device PASS. */
class OptionalImagePacksTest {
    private val base get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun fixtureBytes() = InstrumentationRegistry.getInstrumentation().context.assets.open("kenney-1-bit-pack.zip").use { it.readBytes() }
    private fun isolated(run: (Context) -> Unit) {
        val directory = File(base.cacheDir, "optional-pack-fixture-${UUID.randomUUID()}")
        check(directory.mkdir())
        val context = object : ContextWrapper(base) { override fun getFilesDir() = directory }
        try { run(context) } finally { directory.deleteRecursively() } // Only this test's new private tree.
    }
    @Test fun canonicalDescriptorsRetainSixPacksAndAllBundledImages() = isolated { context -> runBlocking {
        assertEquals(243, BundledImages.load(context).size)
        val packs = OptionalImagePacks.descriptors(context)
        assertEquals(6, packs.size); assertEquals(1818, packs.sumOf { it.entries.size })
        assertEquals(1818, packs.flatMap { it.entries }.map { it.id }.distinct().size)
        assertTrue(OptionalImagePacks.inspect(context).none { it.installed })
    } }
    @Test fun realPinnedPackPublishesReopensImportsAndRemovalPreservesProjectCopy() = isolated { context -> runBlocking {
        val pack = OptionalImagePacks.descriptors(context).first()
        var requests = 0
        val transport = OptionalImagePacks.Transport { _, _ -> requests++; fixtureBytes() }
        OptionalImagePacks.install(context, pack.id, transport)
        val first = OptionalImagePacks.inspect(context).first()
        assertTrue(OptionalImagePacks.operation.value.toString(), first.installed); assertEquals(458, first.images.size)
        val image = first.images.first(); val bytes = OptionalImagePacks.checkedPNG(context, image) {}
        val artwork = BundledImages.artwork(context, image) {}; val encoded = artwork.encoded
        OptionalImagePacks.install(context, pack.id, transport)
        assertEquals(1, requests) // A verified existing pack is reused; no second download.
        assertArrayEquals(bytes, OptionalImagePacks.checkedPNG(context, image) {})
        OptionalImagePacks.remove(context, pack.id)
        assertFalse(OptionalImagePacks.inspect(context).first().installed)
        assertEquals(encoded, artwork.encoded) // Imported original is owned by the project, not cache.
        assertEquals(243, BundledImages.load(context).size)
    } }
    @Test fun croppedPNGAndSelfConsistentReceiptCannotClaimVerifiedWrongPixelsOrDimensions() {
        for (edge in listOf(16, 8)) isolated { context -> runBlocking {
            val pack = OptionalImagePacks.descriptors(context).first()
            OptionalImagePacks.install(context, pack.id, OptionalImagePacks.Transport { _, _ -> fixtureBytes() })
            val installed = OptionalImagePacks.inspect(context).first()
            assertTrue(installed.installed)
            val old = installed.images.first()
            val bitmap = Bitmap.createBitmap(edge, edge, Bitmap.Config.ARGB_8888)
            val replacement = try {
                bitmap.eraseColor(0xffff0000.toInt())
                java.io.ByteArrayOutputStream().let { out -> check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)); out.toByteArray() }
            } finally { bitmap.recycle() }
            val hash = MessageDigest.getInstance("SHA-256").digest(replacement).joinToString("") { "%02x".format(it) }
            val directory = File(context.filesDir, "studio-optional-images-v1/${pack.id}")
            check(File(directory, old.filename).delete())
            val forgedFile = File(directory, "$hash.png").apply { writeBytes(replacement) }
            val receiptFile = File(directory, "receipt.json")
            val receipt = org.json.JSONObject(receiptFile.readText())
            receipt.getJSONArray("images").getJSONObject(0).put("sha256", hash).put("bytes", replacement.size)
            receiptFile.writeText(receipt.toString()) // Encoded hash/length agree, canonical pixel pin does not.
            val actual = OptionalImagePacks.inspect(context).first()
            assertFalse("A self-consistent receipt cannot vouch for cropped pixels", actual.installed)
            assertTrue(actual.images.isEmpty()); assertNotNull(actual.problem)
            OptionalImagePacks.remove(context, pack.id)
            assertTrue("Invalid cache content must be retained, not deleted", forgedFile.exists())
            assertArrayEquals(replacement, forgedFile.readBytes())
        } }
    }
    @Test fun foreignFileAddedAfterVerificationIsNeverAdoptedOrDeletedByRemoval() = isolated { context -> runBlocking {
        val pack = OptionalImagePacks.descriptors(context).first()
        OptionalImagePacks.install(context, pack.id, OptionalImagePacks.Transport { _, _ -> fixtureBytes() })
        assertTrue(OptionalImagePacks.inspect(context).first().installed)
        val directory = File(context.filesDir, "studio-optional-images-v1/${pack.id}")
        val original = directory.listFiles()!!.associate { it.name to it.readBytes() }
        val foreign = File(directory, "foreign-original.txt"); var reached = false
        OptionalImagePacks.remove(context, pack.id) { checkpoint ->
            if (checkpoint == "after-verification") { foreign.writeText("keep unrelated original"); reached = true }
        }
        assertTrue(reached); assertTrue(directory.isDirectory)
        assertEquals("keep unrelated original", foreign.readText())
        assertEquals(original.keys + foreign.name, directory.list()!!.toSet())
        original.forEach { (name, bytes) -> assertArrayEquals(bytes, File(directory, name).readBytes()) }
        assertTrue(OptionalImagePacks.operation.value?.message?.contains("did not finish") == true)
    } }
    @Test fun changedArchiveNeverPublishesOrDeletesExistingData() = isolated { context -> runBlocking {
        val original = File(context.filesDir, "original.txt").apply { writeText("keep original") }
        val pack = OptionalImagePacks.descriptors(context).first()
        OptionalImagePacks.install(context, pack.id, OptionalImagePacks.Transport { _, _ -> fixtureBytes().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() } })
        assertFalse(OptionalImagePacks.inspect(context).first().installed)
        assertEquals("keep original", original.readText())
        assertTrue(File(context.filesDir, "studio-optional-images-v1").list()!!.isEmpty())
    } }
    @Test fun cancellationAfterActualImageWriteRemovesOnlyOwnedStage() = isolated { context -> runBlocking {
        val pack = OptionalImagePacks.descriptors(context).first(); var wroteImage = false
        try {
            OptionalImagePacks.install(context, pack.id, OptionalImagePacks.Transport { _, _ -> fixtureBytes() }) { stage ->
                if (stage == "staged-image") { wroteImage = true; throw CancellationException("fixture cancellation") }
            }
            fail("Cancelled installation returned normally")
        } catch (_: CancellationException) { }
        assertTrue(wroteImage); assertFalse(OptionalImagePacks.inspect(context).first().installed)
        assertTrue(File(context.filesDir, "studio-optional-images-v1").list()!!.isEmpty())
    } }
    @Test fun replacementOfCacheBeforeCommitPreservesForeignTree() = isolated { context -> runBlocking {
        val pack = OptionalImagePacks.descriptors(context).first(); val cache = File(context.filesDir, "studio-optional-images-v1")
        val preserved = File(context.filesDir, "retained-stage"); var replaced = false
        OptionalImagePacks.install(context, pack.id, OptionalImagePacks.Transport { _, _ -> fixtureBytes() }) { stage ->
            if (stage == "before-publish") {
                check(cache.renameTo(preserved)); check(cache.mkdir()); File(cache, "foreign.txt").writeText("keep foreign"); replaced = true
            }
        }
        assertTrue(replaced); assertEquals("keep foreign", File(cache, "foreign.txt").readText())
        assertFalse(File(cache, pack.id).exists()); assertTrue(preserved.exists())
        assertTrue(OptionalImagePacks.operation.value?.message?.contains("could not") == true)
    } }
    @Test fun symlinkedCacheIsRefusedWithoutFollowingOrDeletingTarget() = isolated { context -> runBlocking {
        val outside = File(context.filesDir, "outside").apply { check(mkdir()) }
        val marker = File(outside, "keep.txt").apply { writeText("keep") }
        val link = File(context.filesDir, "studio-optional-images-v1"); Os.symlink(outside.path, link.path)
        OptionalImagePacks.install(context, OptionalImagePacks.descriptors(context).first().id,
            OptionalImagePacks.Transport { _, _ -> error("A symlinked cache must not reach transport") })
        assertEquals("keep", marker.readText()); assertEquals(listOf("keep.txt"), outside.list()!!.toList())
        check(link.delete()) // Remove only this test-created link before disposable-tree cleanup.
    } }
    @Test fun signedPublisherRouteRejectsForeignExpiredAndExpandedScope() {
        val asset = "6173736574732f312d6269742d7061636b"; val now = 2_000_000_000L
        val valid = "https://kenney.nl/download/$asset/${"a".repeat(64)}?expires=${now + 300}"
        assertEquals(valid, OptionalImagePacks.checkedSignedURL(valid, asset, now).toString())
        for (value in listOf(valid.replace("kenney.nl", "example.com"), valid.replace("https:", "http:"),
                valid.replace("expires=${now + 300}", "expires=$now"), valid + "&extra=1", valid + "#fragment",
                valid.replace("/download/$asset/", "/download/00/"), valid.replace("kenney.nl/", "kenney.nl:443/"))) {
            assertTrue(runCatching { OptionalImagePacks.checkedSignedURL(value, asset, now) }.isFailure)
        }
    }
    @Test fun rawPremultipliedRGBAContractPreservesPartialAlpha() {
        val bitmap = Bitmap.createBitmap(2, 1, Bitmap.Config.ARGB_8888, true, ColorSpace.get(ColorSpace.Named.SRGB))
        try {
            bitmap.setPixel(0, 0, 0x80ff8040.toInt()); bitmap.setPixel(1, 0, 0)
            val expected = MessageDigest.getInstance("SHA-256").digest(byteArrayOf(-128,64,32,-128,0,0,0,0)).joinToString("") { "%02x".format(it) }
            assertEquals(expected, OptionalImagePacks.pixelHash(bitmap))
        } finally { bitmap.recycle() }
    }
}
