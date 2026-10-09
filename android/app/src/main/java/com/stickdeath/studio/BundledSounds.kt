package com.stickdeath.studio

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import android.util.JsonReader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.net.URI
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/** Metadata describes the licensed original; duration of decoded PCM is authoritative on insertion. */
data class BundledSound(
    val id: String, val title: String, val category: String, val tags: List<String>,
    val author: String, val sourceURL: String, val filename: String, val sha256: String,
    val byteCount: Int, val duration: Double
)

/** Local assets only. Oversized or unsupported sounds fail without truncation or substitution. */
object BundledSounds {
    private const val ROOT = ""
    private const val COUNT = 2127
    private const val MAX_CATALOGUE = 8 * 1024 * 1024
    private const val MAX_ENCODED = 4 * 1024 * 1024
    private val hashPattern = Regex("[0-9a-f]{64}")
    private val lock = Mutex()
    private var cached: List<BundledSound>? = null

    suspend fun load(context: Context): List<BundledSound> = withContext(Dispatchers.IO) {
        lock.withLock {
            cached?.let { return@withLock it }
            val bytes = readBounded(context, ROOT + "catalogue.json", MAX_CATALOGUE)
            val result = ArrayList<BundledSound>(COUNT)
            val ids = HashSet<String>()
            var schema: Int? = null
            var sawSounds = false
            JsonReader(bytes.inputStream().reader(Charsets.UTF_8)).use { reader ->
                reader.beginObject()
                val fields = HashSet<String>()
                while (reader.hasNext()) {
                    currentCoroutineContext().ensureActive()
                    val key = reader.nextName()
                    require(fields.add(key)) { "Duplicate sound catalogue field." }
                    when (key) {
                        "schemaVersion" -> schema = reader.nextInt()
                        "sounds" -> {
                            sawSounds = true
                            reader.beginArray()
                            while (reader.hasNext()) {
                                currentCoroutineContext().ensureActive()
                                require(result.size < COUNT) { "Sound catalogue has too many entries." }
                                val sound = readEntry(reader)
                                require(ids.add(sound.id)) { "Duplicate bundled sound." }
                                result.add(sound)
                            }
                            reader.endArray()
                        }
                        else -> error("Unsupported sound catalogue field: $key")
                    }
                }
                reader.endObject()
                require(reader.peek() == android.util.JsonToken.END_DOCUMENT) { "Trailing sound catalogue data." }
            }
            require(schema == 1 && sawSounds && result.size == COUNT) { "Unsupported or incomplete sound catalogue." }
            java.util.Collections.unmodifiableList(result).also { cached = it }
        }
    }

    suspend fun source(context: Context, sound: BundledSound): AudioSource = withContext(Dispatchers.IO) {
        require(load(context).any { it == sound }) { "Sound is not in the bundled catalogue." }
        val bytes = readBounded(context, ROOT + sound.filename, MAX_ENCODED)
        require(bytes.size == sound.byteCount) { "Bundled sound size does not match its catalogue." }
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        require(hash == sound.sha256) { "Bundled sound integrity check failed." }
        currentCoroutineContext().ensureActive()
        if (sound.filename.endsWith(".wav")) bytes.inputStream().use { AudioSource.read(it) }
        else decode(context, sound)
    }

    private suspend fun readBounded(context: Context, path: String, limit: Int): ByteArray {
        val output = ByteArrayOutputStream()
        context.assets.open(path).use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                currentCoroutineContext().ensureActive()
                val count = input.read(buffer)
                if (count < 0) break
                require(count > 0) { "Bundled asset read stalled." }
                require(count <= limit - output.size()) { "Bundled asset exceeds its size limit." }
                output.write(buffer, 0, count)
            }
        }
        return output.toByteArray()
    }

    private fun readEntry(reader: JsonReader): BundledSound {
        val strings = HashMap<String, String>()
        val seen = HashSet<String>()
        val tags = ArrayList<String>()
        var byteCount = 0
        var duration = Double.NaN
        var rate = 0
        var channels = 0
        reader.beginObject()
        while (reader.hasNext()) {
            val key = reader.nextName()
            require(seen.add(key)) { "Duplicate sound metadata field." }
            when (key) {
                "id", "title", "category", "author", "sourceURL", "license", "licenseURL",
                "originalSHA256", "filename", "sha256" -> {
                    require(reader.peek() == android.util.JsonToken.STRING) { "Sound metadata must be text." }
                    val value = reader.nextString()
                    require(value.isNotBlank() && value.length <= 512 && value.none { it.isISOControl() }) {
                        "Invalid sound metadata."
                    }
                    strings[key] = value
                }
                "byteCount" -> byteCount = reader.nextInt()
                "duration" -> duration = reader.nextDouble()
                "sampleRate" -> rate = reader.nextInt()
                "channels" -> channels = reader.nextInt()
                "tags" -> {
                    reader.beginArray()
                    while (reader.hasNext()) {
                        require(tags.size < 16) { "Too many sound tags." }
                        require(reader.peek() == android.util.JsonToken.STRING)
                        val tag = reader.nextString()
                        require(tag.isNotBlank() && tag.length <= 80 && tag.none { it.isISOControl() })
                        tags.add(tag)
                    }
                    reader.endArray()
                }
                "waveformPeaks" -> {
                    reader.beginArray()
                    var count = 0
                    while (reader.hasNext()) {
                        require(++count <= 256) { "Oversized catalogue waveform." }
                        val peak = reader.nextDouble()
                        require(peak.isFinite() && peak in 0.0..1.0) { "Invalid catalogue waveform." }
                    }
                    reader.endArray()
                    require(count == 256) { "Incomplete catalogue waveform." }
                }
                else -> error("Unsupported sound metadata field: $key")
            }
        }
        reader.endObject()
        require(seen.size == 16 && tags.isNotEmpty()) { "Incomplete sound metadata." }
        fun value(key: String) = requireNotNull(strings[key]) { "Missing sound $key." }
        val id = value("id")
        val hash = value("sha256")
        val filename = value("filename")
        require(hashPattern.matches(id) && hashPattern.matches(hash) && hashPattern.matches(value("originalSHA256")))
        require(hash == id && (filename == "$id.wav" || filename == "$id.m4a")) { "Unsafe bundled sound filename." }
        require(value("license") == "CC0-1.0" && value("licenseURL") == "https://creativecommons.org/publicdomain/zero/1.0/") {
            "Unsupported bundled sound license."
        }
        val uri = URI(value("sourceURL"))
        require(uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null) { "Invalid sound attribution URL." }
        require(byteCount in 1..MAX_ENCODED && duration.isFinite() && duration > 0 && duration <= 60 &&
            rate in 8000..48000 && channels in 1..2) { "Invalid sound format metadata." }
        require(value("title").length <= 80 && value("category").length <= 80 && value("author").length <= 160)
        return BundledSound(id, value("title"), value("category"), java.util.Collections.unmodifiableList(tags),
            value("author"), value("sourceURL"), filename, hash, byteCount, duration)
    }

    private suspend fun decode(context: Context, sound: BundledSound): AudioSource =
        AudioDecoder.decode(setOf("audio/mp4a-latm")) { extractor ->
            context.assets.openFd(ROOT + sound.filename).use { asset ->
                require(asset.length == sound.byteCount.toLong()) { "Bundled audio descriptor length mismatch." }
                extractor.setDataSource(asset.fileDescriptor, asset.startOffset, asset.length)
            }
        }
}
