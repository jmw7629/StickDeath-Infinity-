package com.stickdeath.studio

import android.graphics.Bitmap
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import com.stickdeath.studio.connect.RoomProjectHandoffPolicy
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CancellationException

/** Real Android decoder, PNG/WAV assets and AtomicFile storage. Requires instrumentation; never
 * substitutes a fake ProjectStore or claims an actual server/device transfer occurred. */
class RoomProjectImportTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun removeOwnProject(id: String) {
        listOf(".json", ".json.bak", ".json.new").forEach { File(context.filesDir, "studio-projects/$id$it").delete() }
    }
    private fun image(): ImageArtwork {
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(0xffcc3355.toInt())
        val output = ByteArrayOutputStream()
        try { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) } finally { bitmap.recycle() }
        return ImageArtwork.restore(Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP))
    }
    private fun sound(): AudioSource {
        val pcm = ByteBuffer.allocate(60).order(ByteOrder.LITTLE_ENDIAN)
        pcm.put("RIFF".toByteArray()).putInt(52).put("WAVEfmt ".toByteArray()).putInt(16)
            .putShort(1).putShort(1).putInt(44100).putInt(88200).putShort(2).putShort(16)
            .put("data".toByteArray()).putInt(16)
        repeat(8) { pcm.putShort((it * 1000).toShort()) }
        return AudioSource.decode(Base64.encodeToString(pcm.array(), Base64.NO_WRAP))
    }

    @Test fun completeManagedBackupImportsFreshReopensByteIdenticalAndReceiptRetryReusesCopy() {
        val store = ProjectStore(context); val owned = mutableSetOf<String>()
        val account = newID(); val snapshot = newID()
        try {
            val base = Document.create("Room media handoff fixture", 64, 64, 12)
            val png = image(); val wav = sound()
            val credit = AssetCredit("fixture.asset", "Fixture", "Test author", "https://example.com/fixture", "1".repeat(64))
            val picture = Stroke(layerID = base.activeLayerID, points = listOf(Point(1f, 1f), Point(3f, 1f), Point(3f, 3f), Point(1f, 3f)),
                color = 0xff000000.toInt(), width = 1f, tool = Tool.Image, image = png, assetCredit = credit,
                imageCrop = ImageCrop(0.0, 0.0, 0.5, 1.0), imageQuarterTurns = 1)
            val source = base.copy(frames = listOf(base.frame.copy(strokes = listOf(picture))),
                audioClips = listOf(AudioClip(name = "Fixture WAV", source = wav, assetCredit = credit)),
                audioTracks = listOf(AudioTrackMix(.6f, pan = -.25f, soloed = true)) + List(3) { AudioTrackMix() }).validated()
            owned += source.id; store.save(source)
            val sourceFile = File(context.filesDir, "studio-projects/${source.id}.json")
            val originalBytes = sourceFile.readBytes()
            val backup = store.encode(source); val hash = RoomProjectHandoffPolicy.sha256(backup)
            val imported = store.importRoomProject(backup, account, snapshot, "device-project:${source.id}", hash) {}
            owned += imported.document.id
            assertFalse(imported.alreadyImported); assertNotEquals(source.id, imported.document.id)
            assertEquals(source.frame.id, imported.document.frame.id); assertEquals(source.layer.id, imported.document.layer.id)
            assertEquals(picture.id, imported.document.frame.strokes.single().id)
            val reopened = store.load(imported.document.id)
            assertEquals(png.encoded, reopened.frame.strokes.single().image!!.encoded)
            assertEquals(wav.encoded(), reopened.audioClips.single().source.encoded())
            assertEquals(credit, reopened.frame.strokes.single().assetCredit); assertEquals(credit, reopened.audioClips.single().assetCredit)
            assertEquals(source.audioTracks, reopened.audioTracks)
            assertArrayEquals(store.encode(source), store.encode(reopened.copy(id = source.id, name = source.name, modified = source.modified)))
            assertArrayEquals(originalBytes, sourceFile.readBytes())

            // A failed/retried server receipt never duplicates the import or overwrites later work.
            val edited = reopened.copy(name = "Recipient continued editing", revision = reopened.revision + 1)
            store.save(edited)
            val retried = store.importRoomProject(backup, account, snapshot, "device-project:${source.id}", hash) {}
            assertTrue(retried.alreadyImported); assertEquals(reopened.id, retried.document.id)
            assertEquals(edited.name, retried.document.name); assertEquals(edited.revision, retried.document.revision)
            assertArrayEquals(originalBytes, sourceFile.readBytes())
        } finally {
            owned.forEach(::removeOwnProject)
            // Only this test's freshly allocated account receipt directory, never the user's ledger.
            File(context.filesDir, "room-project-imports/$account").deleteRecursively()
        }
    }

    @Test fun corruptForeignCancelledAndCollidingImportsNeverOverwriteAnExistingProject() {
        val store = ProjectStore(context); val source = Document.create("Protected handoff original", 64, 64, 12)
        val account = newID(); val snapshot = newID(); val ref = "device-project:${source.id}"
        val receipts = File(context.filesDir, "room-project-imports/$account")
        try {
            store.save(source)
            val original = File(context.filesDir, "studio-projects/${source.id}.json").readBytes()
            val bytes = store.encode(source); val hash = RoomProjectHandoffPolicy.sha256(bytes)
            fun rejects(block: () -> Unit) {
                try { block(); fail("An invalid import was accepted") } catch (_: IllegalArgumentException) { }
            }
            rejects { store.importRoomProject(bytes, account, snapshot, ref, "0".repeat(64)) {} }
            rejects { store.importRoomProject(bytes, account, snapshot, "device-project:${newID()}", hash) {} }
            try { store.importRoomProject(bytes, account, snapshot, ref, hash) { throw CancellationException("fixture") }; fail() }
            catch (_: CancellationException) { }
            assertFalse(receipts.exists())

            // An unverified ledger pointing at an existing project must refuse, not save over it.
            receipts.mkdirs()
            File(receipts, "$snapshot.json").writeText(org.json.JSONObject().put("version", 1).put("account", account)
                .put("snapshot", snapshot).put("projectRef", ref).put("sha256", hash).put("localID", source.id)
                .put("importedAt", source.modified).put("verified", false).toString())
            rejects { store.importRoomProject(bytes, account, snapshot, ref, hash) {} }
            assertArrayEquals(original, File(context.filesDir, "studio-projects/${source.id}.json").readBytes())
        } finally { removeOwnProject(source.id); receipts.deleteRecursively() }
    }

    @Test fun initialLedgerSyncOrUnpublishedRenameFailureStopsBeforeAnyProjectCommit() {
        for (failure in listOf("ledger-before-sync", "ledger-after-finish")) {
            val store = ProjectStore(context); val source = Document.create("Initial journal failure", 64, 64, 12)
            val account = newID(); val snapshot = newID()
            val receipts = File(context.filesDir, "room-project-imports/$account")
            val ledger = File(receipts, "$snapshot.json"); val owned = mutableSetOf(source.id)
            var abandonedID: String? = null; var fired = false
            try {
                store.save(source)
                val original = File(context.filesDir, "studio-projects/${source.id}.json").readBytes()
                val bytes = store.encode(source); val hash = RoomProjectHandoffPolicy.sha256(bytes)
                store.roomImportCheckpoint = { phase ->
                    if (phase == failure && !fired) {
                        fired = true
                        val pendingJournal = listOf(ledger, File(ledger.path + ".new")).first { it.isFile }
                        abandonedID = org.json.JSONObject(pendingJournal.readText()).getString("localID")
                        owned += abandonedID!!
                        if (failure == "ledger-after-finish") {
                            // Model finishWrite returning without a visible final journal. The
                            // production readback, not an exception from AtomicFile, must stop it.
                            check(ledger.renameTo(File(receipts, "$snapshot.unpublished-fixture")))
                        } else throw java.io.IOException("fixture: explicit journal sync failed")
                    }
                }
                try { store.importRoomProject(bytes, account, snapshot, "device-project:${source.id}", hash) {}; fail("Import ignored the failed journal") }
                catch (_: java.io.IOException) { }
                catch (_: IllegalArgumentException) { }
                assertTrue(fired)
                abandonedID?.let { assertFalse(File(context.filesDir, "studio-projects/$it.json").exists()) }
                assertTrue("A project was published before the initial journal was verified", store.list().entries.none { it.id != source.id && it.id in owned })
                store.roomImportCheckpoint = null
                val retried = store.importRoomProject(bytes, account, snapshot, "device-project:${source.id}", hash) {}
                owned += retried.document.id
                assertFalse(retried.alreadyImported)
                assertArrayEquals(original, File(context.filesDir, "studio-projects/${source.id}.json").readBytes())
                assertEquals(1, store.list().entries.count { it.id in owned && it.id != source.id })
            } finally {
                store.roomImportCheckpoint = null
                owned.forEach(::removeOwnProject); receipts.deleteRecursively()
            }
        }
    }

    @Test fun interruptedOwnedStagingAndPublishedCopiesConvergeOnOneIdIncludingCancellation() {
        val boundaries = listOf("binding-durable", "stage-bound", "stage-partial-write", "stage-synced",
            "stage-reopened", "project-published", "project-reopened", "verified-ledger")
        for (boundary in boundaries + listOf("cancel-binding-durable", "cancel-stage-reopened")) {
            val store = ProjectStore(context); val source = Document.create("Staging interruption", 64, 64, 12)
            val account = newID(); val snapshot = newID(); val receipts = File(context.filesDir, "room-project-imports/$account")
            val owned = mutableSetOf(source.id); var interruptedID: String? = null
            try {
                store.save(source)
                val original = File(context.filesDir, "studio-projects/${source.id}.json").readBytes()
                val bytes = store.encode(source); val hash = RoomProjectHandoffPolicy.sha256(bytes)
                var fired = false; var live = true
                store.roomImportCheckpoint = { phase ->
                    if (phase == boundary.removePrefix("cancel-") && !fired) {
                        fired = true
                        if (boundary.startsWith("cancel-")) live = false else throw java.io.IOException("fixture interruption at $phase")
                    }
                }
                try {
                    store.importRoomProject(bytes, account, snapshot, "device-project:${source.id}", hash) { if (!live) throw CancellationException("fixture window/account cancellation") }
                    fail("The selected interruption did not stop the operation")
                } catch (_: java.io.IOException) { } catch (_: CancellationException) { }
                assertTrue(fired)
                val journal = org.json.JSONObject(File(receipts, "$snapshot.json").readText())
                interruptedID = journal.getString("localID"); owned += interruptedID!!
                val target = File(context.filesDir, "studio-projects/$interruptedID.json")
                if (boundary.removePrefix("cancel-") in listOf("binding-durable", "stage-bound", "stage-partial-write", "stage-synced", "stage-reopened")) {
                    assertFalse("Incomplete data became a final library entry at $boundary", target.exists())
                } else {
                    assertTrue(target.length() > 0)
                    assertEquals(interruptedID, store.load(interruptedID!!).id)
                }
                store.roomImportCheckpoint = null; live = true
                val retried = store.importRoomProject(bytes, account, snapshot, "device-project:${source.id}", hash) {}
                assertEquals(interruptedID, retried.document.id)
                assertEquals(1, store.list().entries.count { it.id in owned && it.id != source.id })
                assertTrue(org.json.JSONObject(File(receipts, "$snapshot.json").readText()).getBoolean("verified"))
                assertArrayEquals(store.encode(source), store.encode(store.load(interruptedID!!).copy(id = source.id, name = source.name, modified = source.modified)))
                assertArrayEquals(original, File(context.filesDir, "studio-projects/${source.id}.json").readBytes())
            } finally {
                store.roomImportCheckpoint = null
                // An exception after journal creation can still identify this test's own copy.
                if (interruptedID == null) runCatching { owned += org.json.JSONObject(File(receipts, "$snapshot.json").readText()).getString("localID") }
                owned.forEach(::removeOwnProject); receipts.deleteRecursively()
            }
        }
    }

    @Test fun stagedRetryNeverOverwritesUnknownFinalOrAtomicFileRecoveryEntries() {
        for (collision in listOf("valid-final", "empty-final", ".bak", ".new")) {
            val store = ProjectStore(context); val source = Document.create("Preserved original", 64, 64, 12)
            val account = newID(); val snapshot = newID(); val receipts = File(context.filesDir, "room-project-imports/$account")
            var localID: String? = null
            try {
                store.save(source)
                val original = File(context.filesDir, "studio-projects/${source.id}.json").readBytes()
                val bytes = store.encode(source); val hash = RoomProjectHandoffPolicy.sha256(bytes)
                store.roomImportCheckpoint = { if (it == "stage-reopened") throw java.io.IOException("fixture before publication") }
                try { store.importRoomProject(bytes, account, snapshot, "device-project:${source.id}", hash) {}; fail() } catch (_: java.io.IOException) { }
                localID = org.json.JSONObject(File(receipts, "$snapshot.json").readText()).getString("localID")
                val occupied = File(context.filesDir, "studio-projects/$localID.json${if (collision.startsWith('.')) collision else ""}")
                val unrelated = if (collision == "empty-final") byteArrayOf() else store.encode(source.copy(id = localID!!, name = "Unrelated existing project"))
                occupied.writeBytes(unrelated)
                store.roomImportCheckpoint = null
                try { store.importRoomProject(bytes, account, snapshot, "device-project:${source.id}", hash) {}; fail("Existing $collision was overwritten") }
                catch (_: IllegalArgumentException) { }
                assertArrayEquals(unrelated, occupied.readBytes())
                assertArrayEquals(original, File(context.filesDir, "studio-projects/${source.id}.json").readBytes())
                assertFalse(org.json.JSONObject(File(receipts, "$snapshot.json").readText()).getBoolean("verified"))
            } finally {
                store.roomImportCheckpoint = null
                removeOwnProject(source.id); localID?.let(::removeOwnProject); receipts.deleteRecursively()
            }
        }
    }

    @Test fun mixedCaseSwiftProjectReferenceStillImportsTheExistingVectorSubsetLosslessly() {
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open("swift-legacy.sdi").use { it.readBytes() }
        val source = SwiftProjectImport.decode(bytes)
        val account = newID(); val snapshot = newID(); val store = ProjectStore(context)
        var localID: String? = null
        try {
            val ref = "device-project:${source.id.uppercase(java.util.Locale.ROOT)}"
            val result = store.importRoomProject(bytes, account, snapshot, ref, RoomProjectHandoffPolicy.sha256(bytes)) {}
            localID = result.document.id
            assertNotEquals(source.id, localID)
            assertArrayEquals(store.encode(source), store.encode(store.load(localID!!).copy(id = source.id, name = source.name, modified = source.modified)))
        } finally { localID?.let(::removeOwnProject); File(context.filesDir, "room-project-imports/$account").deleteRecursively() }
    }
}
