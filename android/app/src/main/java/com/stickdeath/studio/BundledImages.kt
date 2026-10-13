package com.stickdeath.studio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Collections

data class BundledImage(
    val id: String, val title: String, val category: String, val tags: List<String>,
    val filename: String, val sha256: String, val byteCount: Int, val width: Int,
    val height: Int, val author: String, val sourceURL: String
)

/** Release-approved offline originals. A catalogue update must explicitly update the release pin. */
object BundledImages {
    private const val ROOT = "StudioImages/"
    private const val CATALOGUE_HASH = "bf31788360d7062876e2a632b56120b8fa5d289f41addd5de49a15afcd2c9a3a"
    private const val MAX_ENCODED = 8 * 1024 * 1024
    private val hashPattern = Regex("[0-9a-f]{64}")
    private val identifierPattern = Regex("[A-Za-z0-9._-]{1,160}")
    private val approvedLicenses = mapOf(
        "kenney.scribble-platformer.cc0" to "2ac45344f3657a8dbac7360aeb53cfb0187cc24234979dcb0855b6e454c78973",
        "kenney.scribble-platformer-expansion.cc0" to "e95232e20a6cabd13b9211c3293e21c4022ab2068e5ec67d701462276e13617d",
        "kenney.scribble-dungeons.cc0" to "55b8024d2d21d66460d00eebffaa7f6235b70c92be00a42f0de0e61ca675b5c2"
    )
    @Volatile private var cached: List<BundledImage>? = null

    suspend fun load(context: Context): List<BundledImage> = withContext(Dispatchers.IO) {
        val coroutine = currentCoroutineContext()
        catalogue(context) { coroutine.ensureActive() }
    }

    /** Called on the import worker; cancellation remains owned by the project import operation. */
    fun artwork(context: Context, image: BundledImage, check: () -> Unit): ImageArtwork {
        val bytes = source(context, image, check)
        return bytes.inputStream().use { ImageArtwork.importImage(it, check) }
    }

    /** Only the visible browser page calls this; no library-wide decoded bitmap cache. */
    internal fun thumbnail(context: Context, image: BundledImage, check: () -> Unit): Bitmap {
        val bytes = source(context, image, check)
        var sample = 1
        while (maxOf(image.width, image.height) / sample > 128) sample *= 2
        check()
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inScaled = false
        }) ?: error("Image preview could not be decoded.")
        try {
            check()
            require(bitmap.width in 1..128 && bitmap.height in 1..128) { "Image preview exceeds its limit." }
            return bitmap
        } catch (failure: Throwable) {
            bitmap.recycle()
            throw failure
        }
    }

    private fun source(context: Context, image: BundledImage, check: () -> Unit): ByteArray {
        require(catalogue(context, check).any { it == image }) { "Image is not in the approved bundled catalogue." }
        val bytes = readBounded(context, image.filename, image.byteCount, check)
        require(bytes.size == image.byteCount && digest(bytes) == image.sha256) { "Bundled image could not be verified." }
        check()
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outMimeType == "image/png" && bounds.outWidth == image.width && bounds.outHeight == image.height) {
            "Bundled image dimensions do not match the catalogue."
        }
        return bytes
    }

    @Synchronized private fun catalogue(context: Context, check: () -> Unit): List<BundledImage> {
        check()
        cached?.let { return it }
        val bytes = readBounded(context, "catalogue.json", 1024 * 1024, check)
        require(digest(bytes) == CATALOGUE_HASH) { "This image catalogue is not approved for this release." }
        val root = JSONObject(bytes.toString(Charsets.UTF_8))
        root.fields("schemaVersion", "licenses", "images")
        require(root.integer("schemaVersion") == 1) { "Unsupported image catalogue schema." }
        val licenses = root.getJSONArray("licenses")
        require(licenses.length() == approvedLicenses.size)
        val credits = HashMap<String, Pair<String, String>>()
        for (index in 0 until licenses.length()) {
            check()
            val license = licenses.getJSONObject(index)
            license.fields("id", "author", "sourceURL", "license", "licenseURL", "attribution", "licenseFilename", "licenseSHA256", "licenseByteCount", "sourceArchiveSHA256")
            val id = license.label("id", 160)
            val hash = license.label("licenseSHA256", 64)
            require(approvedLicenses[id] == hash && !credits.containsKey(id)) { "Unapproved image license." }
            require(license.label("license") == "CC0-1.0" && license.label("licenseURL") == "https://creativecommons.org/publicdomain/zero/1.0/")
            require(license.label("author") == "Kenney" && hashPattern.matches(license.label("sourceArchiveSHA256", 64)))
            license.label("attribution", 500)
            val source = license.label("sourceURL")
            require(source == "https://kenney.nl/assets/" + id.removePrefix("kenney.").removeSuffix(".cc0"))
            val filename = license.label("licenseFilename")
            require(filename == "$hash.txt")
            val count = license.integer("licenseByteCount")
            require(count in 1..65536)
            val text = readBounded(context, filename, count, check)
            require(text.size == count && digest(text) == hash) { "Bundled image license could not be verified." }
            require(text.toString(Charsets.UTF_8).let { it.contains("CC0") && it.contains("Kenney") })
            credits[id] = "Kenney" to source
        }
        val entries = root.getJSONArray("images")
        require(entries.length() == 207) { "Incomplete bundled image catalogue." }
        val ids = HashSet<String>(); val hashes = HashSet<String>(); val pixels = HashSet<String>()
        val result = ArrayList<BundledImage>(entries.length())
        for (index in 0 until entries.length()) {
            check()
            val entry = entries.getJSONObject(index)
            entry.fields("id", "title", "category", "tags", "contentAdvisory", "licenseID", "originalSHA256", "sha256", "pixelSHA256", "filename", "byteCount", "width", "height")
            val id = entry.label("id", 160)
            require(identifierPattern.matches(id) && ids.add(id))
            val hash = entry.label("sha256", 64)
            val pixelHash = entry.label("pixelSHA256", 64)
            require(hashPattern.matches(hash) && hashes.add(hash) && hashPattern.matches(pixelHash))
            require(hashPattern.matches(entry.label("originalSHA256", 64)))
            val filename = entry.label("filename")
            require(filename == "$hash.png") { "Unsafe bundled image filename." }
            val count = entry.integer("byteCount"); val width = entry.integer("width"); val height = entry.integer("height")
            require(count in 1..MAX_ENCODED && width in 1..4096 && height in 1..4096 && width.toLong() * height <= 16_777_216)
            require(pixels.add("$width:$height:$pixelHash"))
            val category = entry.label("category", 80)
            require(category in setOf("scenery", "props", "effects"))
            require(entry.label("contentAdvisory") in setOf("none", "cartoonWeapons"))
            val tags = entry.getJSONArray("tags").labels()
            val credit = requireNotNull(credits[entry.label("licenseID", 160)]) { "Missing image license." }
            result.add(BundledImage(id, entry.label("title", 160), category, tags, filename, hash, count, width, height, credit.first, credit.second))
        }
        check()
        return Collections.unmodifiableList(result).also { cached = it }
    }

    private fun JSONObject.fields(vararg names: String) {
        require(keys().asSequence().toSet() == names.toSet()) { "Unexpected image catalogue metadata." }
    }
    private fun JSONObject.label(key: String, limit: Int = 512): String {
        val value = get(key)
        require(value is String && value.isNotBlank() && value.length <= limit && value.none { it.isISOControl() }) { "Invalid image catalogue text." }
        return value
    }
    private fun JSONObject.integer(key: String): Int {
        val value = get(key)
        require(value is Int) { "Invalid image catalogue number." }
        return value
    }
    private fun JSONArray.labels(): List<String> {
        require(length() in 1..20)
        val result = (0 until length()).map { index ->
            val value = get(index)
            require(value is String && value.isNotBlank() && value.length <= 60 && value.none { it.isISOControl() })
            value
        }
        require(result.distinct().size == result.size)
        return Collections.unmodifiableList(result)
    }
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun readBounded(context: Context, filename: String, limit: Int, check: () -> Unit): ByteArray {
        val output = ByteArrayOutputStream()
        context.assets.open(ROOT + filename).use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                check()
                val count = input.read(buffer)
                if (count < 0) break
                require(count > 0 && count <= limit - output.size()) { "Bundled image asset exceeds its size limit." }
                output.write(buffer, 0, count)
            }
        }
        return output.toByteArray()
    }
}
