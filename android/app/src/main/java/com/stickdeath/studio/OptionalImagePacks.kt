package com.stickdeath.studio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.Proxy
import java.util.concurrent.TimeUnit
import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.URI
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipInputStream

/** Public CC0 assets only. No account tokens, automatic downloads or signed-URL persistence.
 * A pack is available only after a complete private stage has passed all release pins and
 * a no-replace atomic publication. Projects receive their own ordinary ImageArtwork copy. */
internal object OptionalImagePacks {
    private const val ROOT = "studio-optional-images-v1"
    private const val PACK_LIMIT = 8 * 1024 * 1024
    private const val CACHE_LIMIT = 32L * 1024 * 1024
    private val mutation = Mutex()
    data class Operation(val id: UUID, val packID: String, val message: String, val busy: Boolean)
    private val state = MutableStateFlow<Operation?>(null)
    val operation = state.asStateFlow()
    private val control = Any()
    private var active: Pair<UUID, Job?>? = null
    data class Entry(val id: String, val title: String, val category: String, val tags: List<String>,
                     val path: String, val sourceHash: String, val crop: List<Int>?, val pixelHash: String,
                     val width: Int, val height: Int)
    data class Pack(val id: String, val title: String, val archiveURL: String, val archiveBytes: Int,
                    val archiveHash: String, val licensePath: String, val licenseHash: String,
                    val licenseBytes: Int, val sourceURL: String, val fingerprint: String, val entries: List<Entry>)
    data class Status(val pack: Pack, val images: List<BundledImage> = emptyList(), val problem: String? = null) {
        val installed: Boolean get() = images.size == pack.entries.size && problem == null
    }
    internal fun interface Transport { fun archive(pack: Pack, check: () -> Unit): ByteArray }
    fun cancel(id: UUID) {
        val owned = synchronized(control) {
            val handle = active
            if (handle?.first == id && state.value?.id == id && state.value?.busy == true) {
                state.value = state.value?.copy(message = "Cancelling; waiting for owned work to stop…")
                handle.second
            } else null
        }
        owned?.cancel() // Captured exact job: an old Cancel can never cancel its successor.
    }
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun bounded(input: java.io.InputStream, limit: Int, check: () -> Unit): ByteArray {
        val out = ByteArrayOutputStream(); val buffer = ByteArray(8192)
        while (true) {
            check(); val count = input.read(buffer); if (count < 0) break
            require(count > 0 && count <= limit - out.size()) { "Image pack exceeds its byte limit." }
            out.write(buffer, 0, count)
        }
        check(); return out.toByteArray()
    }
    fun descriptors(context: Context): List<Pack> {
        fun resource(name: String, pin: String, limit: Int): ByteArray {
            val bytes = context.assets.open("StudioImages/$name").use { bounded(it, limit) {} }
            require(digest(bytes) == pin) { "Optional image descriptors are not approved for this release." }
            return bytes
        }
        val primary = JSONObject(String(resource("remote-pack.json", "6978b7eb815f122b9d1afd9c37de457d523177ae35a3adcd86e7d8a619156c3b", 64 * 1024), Charsets.UTF_8))
        val others = JSONArray(String(resource("additional-packs.json", "1dd09bdc3deedc749a0a82900238f353b1c7febadc9a4112feba138ae40ef967", 1024 * 1024), Charsets.UTF_8))
        val rows = listOf(primary) + (0 until others.length()).map { others.getJSONObject(it) }
        return rows.map { p ->
            val extra = p.optJSONObject("additional")
            val entries = if (extra == null) {
                val tiles = p.getJSONArray("tiles")
                (0 until tiles.length()).map { i -> val tile = tiles.getJSONObject(i); val x = tile.getInt("x"); val y = tile.getInt("y")
                    Entry("kenney.1-bit-scenery.x$x.y$y", "1-Bit scenery ${y + 1}–${x + 1}", "scenery",
                        listOf("monochrome", "pixel", "scenery", "terrain", "furniture", "1-bit"),
                        "Tilesheet/monochrome-transparent.png", p.getString("sheetSHA256"), listOf(x * 17, y * 17, 16, 16), tile.getString("pixelSHA256"), 16, 16)
                }
            } else {
                val array = extra.getJSONArray("entries")
                (0 until array.length()).map { i -> val e = array.getJSONObject(i)
                    Entry(e.getString("id"), e.getString("title"), e.getString("category"),
                        e.getJSONArray("tags").let { tags -> (0 until tags.length()).map { tags.getString(it) } },
                        e.getString("path"), e.getString("sourceSHA256"), e.optJSONArray("crop")?.let { c -> (0 until c.length()).map { c.getInt(it) } },
                        e.getString("pixelSHA256"), e.getInt("width"), e.getInt("height"))
                }
            }
            Pack(p.getString("id"), p.getString("title"), p.getString("archiveURL"), p.getInt("archiveBytes"), p.getString("archiveSHA256"),
                extra?.getString("licensePath") ?: "License.txt", p.getString("licenseSHA256"), p.getInt("licenseBytes"),
                extra?.getString("sourceURL") ?: "https://kenney.nl/assets/1-bit-pack", digest(p.toString().toByteArray()), entries)
        }.also { require(it.size == 6 && it.sumOf { p -> p.entries.size } == 1818) }
    }
    private data class FileIdentity(val dev: Long, val ino: Long) {
        companion object { fun at(file: File): FileIdentity { val s = Os.lstat(file.path); return FileIdentity(s.st_dev, s.st_ino) } }
    }
    private class Directory(val path: File, private val parent: Directory? = null) : Closeable {
        private val fd = Os.open(path.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC or OsConstants.O_NONBLOCK, 0)
        val identity: FileIdentity
        init {
            val s = Os.fstat(fd)
            if (!OsConstants.S_ISDIR(s.st_mode) || s.st_uid != android.os.Process.myUid()) { Os.close(fd); error("Image cache directory is not private.") }
            identity = FileIdentity(s.st_dev, s.st_ino)
            try { check() } catch (failure: Exception) { Os.close(fd); throw failure }
        }
        fun check() {
            parent?.check(); val s = Os.lstat(path.path); val opened = Os.fstat(fd)
            require(OsConstants.S_ISDIR(s.st_mode) && s.st_uid == android.os.Process.myUid() &&
                FileIdentity(s.st_dev, s.st_ino) == identity && FileIdentity(opened.st_dev, opened.st_ino) == identity) { "Image cache ownership changed; files were preserved." }
        }
        fun sync() { check(); Os.fsync(fd); check() }
        override fun close() { Os.close(fd) }
    }
    private class Root(context: Context, create: Boolean) : Closeable {
        val base = Directory(context.filesDir.canonicalFile)
        val path = File(base.path, ROOT)
        val directory: Directory?
        init {
            try {
                if (!exists(path) && create) { base.check(); Os.mkdir(path.path, 448); base.sync() }
                directory = if (exists(path)) Directory(path, base) else null
            } catch (failure: Exception) { base.close(); throw failure }
        }
        override fun close() { directory?.close(); base.close() }
    }
    private fun exists(file: File) = java.nio.file.Files.exists(file.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)
    private fun readVerified(directory: Directory, name: String, limit: Int, check: () -> Unit): Pair<ByteArray, FileIdentity> {
        require(name == File(name).name && name.length <= 160)
        directory.check(); check(); val file = File(directory.path, name)
        val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC or OsConstants.O_NONBLOCK, 0)
        try {
            val s = Os.fstat(fd)
            require(OsConstants.S_ISREG(s.st_mode) && s.st_uid == android.os.Process.myUid() && s.st_nlink == 1L && s.st_size in 1..limit.toLong()) { "Invalid private image file." }
            val bytes = FileInputStream(fd).use { bounded(it, limit, check) }
            require(bytes.size.toLong() == s.st_size && FileIdentity.at(file) == FileIdentity(s.st_dev, s.st_ino)) { "Private image changed while reading." }
            directory.check(); return bytes to FileIdentity(s.st_dev, s.st_ino)
        } finally { if (fd.valid()) Os.close(fd) }
    }
    private fun read(directory: Directory, name: String, limit: Int, check: () -> Unit): ByteArray =
        readVerified(directory, name, limit, check).first
    private fun write(directory: Directory, name: String, bytes: ByteArray, owned: MutableMap<String, FileIdentity>) {
        require(name == File(name).name && bytes.isNotEmpty() && bytes.size <= PACK_LIMIT)
        directory.check(); val file = File(directory.path, name)
        val fd = Os.open(file.path, OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 384)
        try {
            val s = Os.fstat(fd); require(OsConstants.S_ISREG(s.st_mode) && s.st_nlink == 1L && s.st_uid == android.os.Process.myUid())
            owned[name] = FileIdentity(s.st_dev, s.st_ino)
            FileOutputStream(fd).use { it.write(bytes); it.fd.sync() }
            require(read(directory, name, bytes.size) {}.contentEquals(bytes)) { "Image output could not be verified after writing." }
        } finally { if (fd.valid()) Os.close(fd) }
    }
    private fun storageBytes(root: Directory): Long {
        root.check(); val dirs = root.path.listFiles() ?: error("Image cache cannot be listed.")
        require(dirs.size <= 24) { "Too many unfinished image operations; existing cache was preserved." }
        var bytes = 0L; var files = 0
        for (dir in dirs) Directory(dir, root).use { lease ->
            for (file in lease.path.listFiles() ?: error("Image cache cannot be listed.")) {
                val s = Os.lstat(file.path)
                require(OsConstants.S_ISREG(s.st_mode) && s.st_nlink == 1L && s.st_uid == android.os.Process.myUid()) { "Unexpected image cache entry." }
                bytes += s.st_size; files++; require(bytes <= CACHE_LIMIT && files <= 5000) { "Optional image storage limit reached." }
            }
            lease.check()
        }
        root.check(); return bytes
    }
    private fun eraseOwned(directory: Directory, parent: Directory, owned: Map<String, FileIdentity>) {
        directory.check(); parent.check()
        val files = directory.path.listFiles() ?: error("Image cache cannot be listed.")
        require(files.map { it.name }.toSet() == owned.keys) { "Unexpected files were preserved in the image cache." }
        for (file in files) {
            directory.check(); val s = Os.lstat(file.path)
            require(OsConstants.S_ISREG(s.st_mode) && s.st_nlink == 1L && s.st_uid == android.os.Process.myUid() && FileIdentity(s.st_dev, s.st_ino) == owned[file.name])
            Os.remove(file.path)
        }
        directory.check(); parent.check(); Os.remove(directory.path.path); parent.sync()
    }
    private data class VerifiedPack(val images: List<BundledImage>, val directoryIdentity: FileIdentity,
                                    val ownedFiles: Map<String, FileIdentity>)
    private fun installed(root: Directory, pack: Pack, check: () -> Unit, verifyAllFiles: Boolean = true): VerifiedPack {
        Directory(File(root.path, pack.id), root).use { dir ->
            val owned = mutableMapOf<String, FileIdentity>()
            fun verifiedRead(name: String, limit: Int): ByteArray {
                val (bytes, identity) = readVerified(dir, name, limit, check)
                require(owned.put(name, identity) == null)
                return bytes
            }
            val receipt = JSONObject(String(verifiedRead("receipt.json", 2 * 1024 * 1024), Charsets.UTF_8))
            require(receipt.keys().asSequence().toSet() == setOf("packID", "fingerprint", "images"))
            require(receipt.getString("packID") == pack.id && receipt.getString("fingerprint") == pack.fingerprint)
            val licenseName = pack.licenseHash + ".txt"
            val license = verifiedRead(licenseName, pack.licenseBytes)
            require(license.size == pack.licenseBytes && digest(license) == pack.licenseHash)
            val rows = receipt.getJSONArray("images"); require(rows.length() == pack.entries.size)
            val names = mutableSetOf("receipt.json", licenseName); var total = license.size.toLong()
            val result = pack.entries.mapIndexed { i, e ->
                check(); val row = rows.getJSONObject(i)
                require(row.keys().asSequence().toSet() == setOf("id", "sha256", "bytes"))
                require(row.getString("id") == e.id)
                val hash = row.getString("sha256"); require(hash.matches(Regex("[0-9a-f]{64}")))
                val bytes = row.getInt("bytes"); require(bytes in 1..PACK_LIMIT)
                val filename = "$hash.png"; require(names.add(filename))
                if (verifyAllFiles) {
                    val data = verifiedRead(filename, bytes)
                    require(data.size == bytes && digest(data) == hash)
                    val bitmap = decode(data)
                    try {
                        check()
                        require(bitmap.width == e.width && bitmap.height == e.height && pixelHash(bitmap, check) == e.pixelHash) {
                            "Installed image pixels differ from the approved source."
                        }
                    } finally { bitmap.recycle() }
                }
                if (e.crop == null) require(hash == e.sourceHash)
                total += bytes; require(total <= PACK_LIMIT)
                BundledImage(e.id, e.title, e.category, e.tags, filename, hash, bytes, e.width, e.height, "Kenney", pack.sourceURL, pack.id)
            }
            require(dir.path.list()?.toSet() == names) { "Unexpected installed image cache files." }
            if (verifyAllFiles) {
                require(owned.keys == names)
                // Bind the same inodes whose bytes/pixels were verified, never a later directory listing.
                require(owned.all { (name, identity) -> FileIdentity.at(File(dir.path, name)) == identity }) {
                    "Verified image files changed; cache was preserved."
                }
            }
            dir.check(); root.check(); return VerifiedPack(result, dir.identity, owned.toMap())
        }
    }
    suspend fun inspect(context: Context, progress: suspend (String) -> Unit = {}): List<Status> = withContext(Dispatchers.IO) {
        val coroutine = currentCoroutineContext(); val deadline = SystemClock.elapsedRealtime() + 120_000
        val check = { coroutine.ensureActive(); require(SystemClock.elapsedRealtime() < deadline) { "Image cache inspection exceeded its time limit." } }
        val packs = descriptors(context)
        Root(context, false).use { root ->
            packs.mapIndexed { index, pack ->
                check(); progress("Checking optional pack ${index + 1}/${packs.size}: ${pack.title}…")
                val directory = root.directory
                if (directory == null || !exists(File(directory.path, pack.id))) Status(pack)
                else try { Status(pack, installed(directory, pack, check).images) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { Status(pack, problem = "Installed files could not be verified; existing files were preserved.") }
            }
        }
    }
    fun checkedPNG(context: Context, image: BundledImage, check: () -> Unit): ByteArray {
        val pack = descriptors(context).single { it.id == image.packID }
        Root(context, false).use { root ->
            val directory = requireNotNull(root.directory) { "This image pack is no longer installed." }
            val canonical = installed(directory, pack, check, verifyAllFiles = false).images.single { it.id == image.id }
            require(canonical == image) { "The selected image changed; choose it again." }
            val entry = pack.entries.single { it.id == image.id }
            Directory(File(directory.path, pack.id), directory).use { dir ->
                val bytes = read(dir, image.filename, image.byteCount, check)
                require(digest(bytes) == image.sha256)
                val bitmap = decode(bytes)
                try { require(bitmap.width == entry.width && bitmap.height == entry.height && pixelHash(bitmap, check) == entry.pixelHash) { "Image pixels differ from the approved source." } }
                finally { bitmap.recycle() }
                return bytes
            }
        }
    }
    private fun decode(bytes: ByteArray): Bitmap {
        require(bytes.size >= 33 && bytes.copyOfRange(0, 8).contentEquals(byteArrayOf(-119,80,78,71,13,10,26,10))) { "Only pinned PNG images are accepted." }
        fun number(offset: Int): Long = (0..3).fold(0L) { value, i -> (value shl 8) or (bytes[offset + i].toLong() and 255) }
        var offset = 8; var pixels = false; var ended = false
        while (offset < bytes.size) {
            require(bytes.size - offset >= 12)
            val length = number(offset); require(length <= bytes.size - offset - 12)
            val count = length.toInt(); val type = String(bytes, offset + 4, 4, Charsets.US_ASCII)
            require(type != "acTL" && type != "fcTL" && type != "fdAT") { "Animated PNG is not supported." }
            if (offset == 8) require(type == "IHDR" && count == 13)
            val crc = java.util.zip.CRC32().apply { update(bytes, offset + 4, count + 4) }.value
            require(crc == number(offset + 8 + count)) { "PNG checksum failed." }
            if (type == "IDAT") pixels = true
            offset += count + 12
            if (type == "IEND") { require(count == 0 && offset == bytes.size); ended = true }
        }
        require(ended && pixels)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outMimeType == "image/png" && bounds.outWidth in 1..4096 && bounds.outHeight in 1..4096 && bounds.outWidth.toLong() * bounds.outHeight <= 16_777_216)
        return requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888; inPremultiplied = true; inScaled = false
            inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB); inMutable = true
        })) { "PNG decode failed." }
    }
    /** Android documents ARGB_8888 raw buffers as packed AABBGGRR, already premultiplied.
     * Read rows without padding and serialize the same sRGB premultiplied RGBA bytes as iOS.
     * Never use getPixels(), which returns unpremultiplied colors. A mismatch fails closed. */
    internal fun pixelHash(bitmap: Bitmap, check: () -> Unit = {}): String {
        require(bitmap.config == Bitmap.Config.ARGB_8888 && (!bitmap.hasAlpha() || bitmap.isPremultiplied) &&
            bitmap.colorSpace == ColorSpace.get(ColorSpace.Named.SRGB) && ByteOrder.nativeOrder() == ByteOrder.LITTLE_ENDIAN)
        val raw = ByteBuffer.allocate(bitmap.byteCount).order(ByteOrder.LITTLE_ENDIAN)
        bitmap.copyPixelsToBuffer(raw); val hash = MessageDigest.getInstance("SHA-256")
        val row = ByteArray(bitmap.width * 4)
        for (y in 0 until bitmap.height) {
            check(); raw.position(y * bitmap.rowBytes); raw.get(row); hash.update(row)
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }
    private fun unpack(archive: ByteArray, allowed: Set<String>, check: () -> Unit): Map<String, ByteArray> {
        val found = mutableMapOf<String, ByteArray>(); val names = mutableSetOf<String>(); var total = 0L; var selected = 0
        ZipInputStream(ByteArrayInputStream(archive)).use { zip ->
            while (true) {
                check(); val entry = zip.nextEntry ?: break; val name = entry.name
                require(names.add(name) && names.size <= 5000 && name.length <= 1024 && !name.startsWith("/") && '\\' !in name && name.split('/').none { it == ".." } && name.none { it.isISOControl() })
                val bytes = bounded(zip, PACK_LIMIT, check); total += bytes.size; require(total <= 128L * 1024 * 1024)
                zip.closeEntry() // ZipInputStream verifies each member's CRC at end-of-entry.
                if (name in allowed) { selected += bytes.size; require(selected <= PACK_LIMIT); found[name] = bytes }
            }
        }
        require(found.keys == allowed) { "Publisher archive is missing approved files." }; return found
    }
    suspend fun install(context: Context, packID: String, transport: Transport? = null, checkpoint: (String) -> Unit = {}) = withContext(Dispatchers.IO) {
        mutation.withLock {
            val coroutine = currentCoroutineContext(); val id = UUID.randomUUID(); val deadline = SystemClock.elapsedRealtime() + 180_000
            val check = { coroutine.ensureActive(); require(SystemClock.elapsedRealtime() < deadline) { "Image operation exceeded its time limit." }; checkpoint("current") }
            synchronized(control) { active = id to coroutine[Job] }; state.value = Operation(id, packID, "Verifying image pack…", true)
            try {
                val pack = descriptors(context).single { it.id == packID }; check()
                Root(context, true).use { owner ->
                    val root = requireNotNull(owner.directory)
                    if (exists(File(root.path, pack.id))) { installed(root, pack, check); state.value = Operation(id, packID, "Pack is already installed and verified.", false); return@withLock }
                    require(root.path.usableSpace >= 64L * 1024 * 1024 + pack.archiveBytes + PACK_LIMIT) { "Not enough private storage for this pack." }
                    require(storageBytes(root) + PACK_LIMIT <= CACHE_LIMIT) { "Optional image cache is full; remove a pack first." }
                    state.value = Operation(id, packID, "Downloading ${pack.title} from Kenney…", true)
                    val archive = (transport ?: PublisherTransport).archive(pack, check)
                    check(); root.check(); require(archive.size == pack.archiveBytes && digest(archive) == pack.archiveHash) { "Publisher archive differs from the approved release." }
                    val members = unpack(archive, pack.entries.map { it.path }.toSet() + pack.licensePath, check)
                    val license = members.getValue(pack.licensePath); require(license.size == pack.licenseBytes && digest(license) == pack.licenseHash)
                    val stagePath = File(root.path, ".stage-${UUID.randomUUID()}"); root.check(); Os.mkdir(stagePath.path, 448)
                    val written = mutableMapOf<String, FileIdentity>()
                    Directory(stagePath, root).use { stage ->
                        try {
                            write(stage, pack.licenseHash + ".txt", license, written)
                            val rows = JSONArray(); var total = license.size
                            for ((index, entry) in pack.entries.withIndex()) {
                                check(); root.check(); state.value = Operation(id, packID, "Verifying image ${index + 1}/${pack.entries.size}…", true)
                                val source = members.getValue(entry.path); require(digest(source) == entry.sourceHash)
                                val original = decode(source); var image = original
                                try {
                                    entry.crop?.let { crop ->
                                        require(crop.size == 4 && crop[0] >= 0 && crop[1] >= 0 && crop[2] == entry.width && crop[3] == entry.height && crop[0] + crop[2] <= original.width && crop[1] + crop[3] <= original.height)
                                        image = Bitmap.createBitmap(original, crop[0], crop[1], crop[2], crop[3])
                                    }
                                    require(image.width == entry.width && image.height == entry.height && pixelHash(image, check) == entry.pixelHash) { "Android pixels differ from the approved source; pack was not installed." }
                                    val bytes = if (entry.crop == null) source else ByteArrayOutputStream().let { output -> require(image.compress(Bitmap.CompressFormat.PNG, 100, output)); output.toByteArray() }
                                    total += bytes.size; require(total <= PACK_LIMIT)
                                    val hash = digest(bytes); write(stage, "$hash.png", bytes, written); checkpoint("staged-image")
                                    // Reopen the actual encoded output and verify the pixel pin again.
                                    val reopened = decode(read(stage, "$hash.png", bytes.size, check))
                                    try { require(pixelHash(reopened, check) == entry.pixelHash) } finally { reopened.recycle() }
                                    rows.put(JSONObject().put("id", entry.id).put("sha256", hash).put("bytes", bytes.size))
                                } finally { if (image !== original) image.recycle(); original.recycle() }
                            }
                            val receipt = JSONObject().put("packID", pack.id).put("fingerprint", pack.fingerprint).put("images", rows).toString().toByteArray()
                            total += receipt.size; require(total <= PACK_LIMIT)
                            write(stage, "receipt.json", receipt, written); stage.sync(); check(); checkpoint("before-publish"); root.check()
                            // The same existing JNI no-replace commit works for a complete directory.
                            RoomAtomicPublish.commit(stage.path, File(root.path, pack.id)); root.sync()
                            state.value = Operation(id, packID, "Verifying published pack files and pixels…", true)
                            val verified = installed(root, pack, {}) // Finish this admitted atomic commit before reporting success.
                            state.value = Operation(id, packID, "Installed and verified ${verified.images.size} images. Project copies remain independent.", false)
                        } finally {
                            if (exists(stagePath)) runCatching { eraseOwned(stage, root, written) }
                        }
                    }
                }
            } catch (cancelled: CancellationException) { state.value = Operation(id, packID, "Image operation cancelled; existing packs and project copies were preserved.", false); throw cancelled }
            catch (_: Exception) { state.value = Operation(id, packID, "Image pack could not be verified or published. Existing packs and project copies were preserved; retry or inspect storage.", false) }
            finally { synchronized(control) { if (active?.first == id) active = null } }
        }
    }
    suspend fun remove(context: Context, packID: String, checkpoint: (String) -> Unit = {}) = withContext(Dispatchers.IO) {
        mutation.withLock {
            val coroutine = currentCoroutineContext(); val check = { coroutine.ensureActive() }; val id = UUID.randomUUID()
            synchronized(control) { active = id to coroutine[Job] }; state.value = Operation(id, packID, "Verifying local pack before removal…", true)
            try {
                val pack = descriptors(context).single { it.id == packID }
                Root(context, false).use { owner ->
                    val root = requireNotNull(owner.directory)
                    val verified = installed(root, pack, check)
                    checkpoint("after-verification")
                    Directory(File(root.path, pack.id), root).use { directory ->
                        check(); root.check(); directory.check()
                        require(directory.identity == verified.directoryIdentity &&
                            directory.path.list()?.toSet() == verified.ownedFiles.keys &&
                            verified.ownedFiles.all { (name, identity) -> FileIdentity.at(File(directory.path, name)) == identity }) {
                            "Verified image cache changed; all files were preserved."
                        }
                        val removed = File(root.path, ".remove-${UUID.randomUUID()}")
                        RoomAtomicPublish.commit(directory.path, removed); root.sync()
                        Directory(removed, root).use { quarantine ->
                            require(quarantine.identity == verified.directoryIdentity)
                            eraseOwned(quarantine, root, verified.ownedFiles) // Rechecks this exact set and each inode after quarantine.
                        }
                    }
                }
                state.value = Operation(id, packID, "Removed local pack. Images already copied into projects were not changed.", false)
            } catch (cancelled: CancellationException) { state.value = Operation(id, packID, "Removal cancelled; project copies were preserved.", false); throw cancelled }
            catch (_: Exception) { state.value = Operation(id, packID, "Pack removal did not finish. Project copies were preserved; remaining private cache files were retained.", false) }
            finally { synchronized(control) { if (active?.first == id) active = null } }
        }
    }
    internal fun checkedSignedURL(text: String, asset: String, now: Long): URI {
        require(text.length <= 2048 && asset.matches(Regex("[0-9a-f]{1,160}")))
        val uri = URI(text)
        require(uri.toASCIIString() == text && uri.scheme == "https" && uri.rawAuthority == "kenney.nl" && uri.rawFragment == null &&
            uri.rawPath.matches(Regex("/download/$asset/[0-9a-f]{64}")) && uri.rawQuery?.matches(Regex("expires=[0-9]{1,12}")) == true)
        val expires = uri.rawQuery.substringAfter("expires=").toLong(); require(expires > now && expires <= now + 900)
        return uri
    }
    /** Dedicated public-asset client: never consult global cookie/auth/proxy handlers. */
    private val publicImageClient by lazy {
        OkHttpClient.Builder()
            .authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
            .cookieJar(CookieJar.NO_COOKIES).proxy(Proxy.NO_PROXY).cache(null)
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .build()
    }
    private object PublisherTransport : Transport {
        override fun archive(pack: Pack, check: () -> Unit): ByteArray {
            require(BuildConfig.SDI_NETWORK_DECLARED) { "This build does not declare network access." }
            val slug = pack.sourceURL.removePrefix("https://kenney.nl/assets/")
            require(slug in setOf("1-bit-pack", "1-bit-platformer-pack", "monochrome-rpg", "micro-roguelike", "smoke-particles"))
            val asset = ("assets/$slug").toByteArray().joinToString("") { "%02x".format(it) }
            val deadline = SystemClock.elapsedRealtime() + 120_000
            fun request(url: String, limit: Int, page: String? = null): Pair<Int, Any> {
                check(); require(SystemClock.elapsedRealtime() < deadline)
                val uri = URI(url); require(uri.scheme == "https" && uri.host == "kenney.nl" && uri.port == -1 && uri.userInfo == null && uri.fragment == null)
                val remainingFlow = deadline - SystemClock.elapsedRealtime()
                require(remainingFlow > 0) { "Public image flow deadline expired." }
                val inactivity = remainingFlow.coerceAtMost(30_000)
                val client = publicImageClient.newBuilder().connectTimeout(inactivity, TimeUnit.MILLISECONDS)
                    .readTimeout(inactivity, TimeUnit.MILLISECONDS).callTimeout(remainingFlow, TimeUnit.MILLISECONDS).build()
                val request = Request.Builder().url(uri.toASCIIString()).get()
                    .header("Accept", if (page == null) "application/zip" else "application/json")
                    .header("Accept-Encoding", "identity")
                if (page != null) request.header("Referer", page)
                val call = client.newCall(request.build())
                try {
                    return call.execute().use { response ->
                        check(); require(SystemClock.elapsedRealtime() < deadline)
                        if (response.code == 302) 302 to (response.header("Location") ?: "")
                        else {
                            require(response.code == 200)
                            val body = requireNotNull(response.body)
                            require(body.contentLength() in -1L..limit.toLong())
                            200 to body.byteStream().use { bounded(it, limit) { check(); require(SystemClock.elapsedRealtime() < deadline) } }
                        }
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { error("Publisher download failed; no pack was installed.") }
                finally { call.cancel() }
            }
            val direct = request(pack.archiveURL, pack.archiveBytes)
            if (direct.first == 200) return direct.second as ByteArray
            require(direct.second == pack.sourceURL)
            val metadata = request("https://kenney.nl/download-link/$asset", 16 * 1024, pack.sourceURL)
            require(metadata.first == 200)
            val record = JSONObject(String(metadata.second as ByteArray, Charsets.UTF_8))
            require(record.keys().asSequence().toSet() == setOf("url"))
            val text = record.get("url"); require(text is String && text.length <= 2048)
            checkedSignedURL(text, asset, System.currentTimeMillis() / 1000)
            val resolved = request(text, pack.archiveBytes); require(resolved.first == 200)
            return resolved.second as ByteArray // Never persist or include the signed URL in an exception.
        }
    }
}
