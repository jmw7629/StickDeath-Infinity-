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

    private suspend fun decode(context: Context, sound: BundledSound): AudioSource {
        val coroutine = currentCoroutineContext()
        val started = SystemClock.elapsedRealtime()
        var lastProgress = started
        fun check() {
            coroutine.ensureActive()
            val now = SystemClock.elapsedRealtime()
            require(now - started < 30_000) { "Bundled sound decoding exceeded 30 seconds." }
            require(now - lastProgress < 5_000) { "Bundled sound decoder stalled." }
        }
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var running = false
        try {
            context.assets.openFd(ROOT + sound.filename).use { asset ->
                require(asset.length == sound.byteCount.toLong()) { "Bundled audio descriptor length mismatch." }
                extractor.setDataSource(asset.fileDescriptor, asset.startOffset, asset.length)
            }
            check()
            require(extractor.trackCount == 1) { "Bundled sound must contain one audio track." }
            val format = extractor.getTrackFormat(0)
            val mime = requireNotNull(format.getString(MediaFormat.KEY_MIME))
            require(mime == "audio/mp4a-latm") { "Unsupported bundled M4A codec." }
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            require(rate in 8000..48000 && channels in 1..2) { "Use mono/stereo audio at 8–48 kHz." }
            format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            extractor.selectTrack(0)
            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            running = true
            var inputEnded = false
            var outputEnded = false
            var sawOutputFormat = false
            val pcm = ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            while (!outputEnded) {
                check()
                if (!inputEnded) {
                    val index = decoder.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val input = requireNotNull(decoder.getInputBuffer(index))
                        input.clear()
                        val count = extractor.readSampleData(input, 0)
                        if (count < 0) {
                            decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEnded = true
                        } else {
                            require(count > 0 && count <= input.capacity()) { "Invalid encoded sound packet." }
                            require(extractor.sampleTime >= 0 && extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED == 0) {
                                "Invalid or encrypted sound packet."
                            }
                            decoder.queueInputBuffer(index, 0, count, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                        lastProgress = SystemClock.elapsedRealtime()
                    }
                }
                when (val index = decoder.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val output = decoder.outputFormat
                        val nextRate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        val nextChannels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        val encoding = if (output.containsKey(MediaFormat.KEY_PCM_ENCODING)) output.getInteger(MediaFormat.KEY_PCM_ENCODING)
                            else AudioFormat.ENCODING_PCM_16BIT
                        require(nextRate in 8000..48000 && nextChannels in 1..2 && encoding == AudioFormat.ENCODING_PCM_16BIT) {
                            "Decoder did not produce supported 16-bit PCM."
                        }
                        require(pcm.size() == 0 || (rate == nextRate && channels == nextChannels)) { "Audio format changed midstream." }
                        rate = nextRate
                        channels = nextChannels
                        sawOutputFormat = true
                        lastProgress = SystemClock.elapsedRealtime()
                    }
                    MediaCodec.INFO_TRY_AGAIN_LATER, MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                    else -> {
                        require(index >= 0) { "Unexpected decoder output." }
                        try {
                            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                require(sawOutputFormat) { "Decoder omitted PCM format information." }
                                require(info.size <= AudioSource.MAX_BYTES - 44 - pcm.size()) {
                                    "Decoded sound exceeds the 4 MiB audio source limit."
                                }
                                val buffer = requireNotNull(decoder.getOutputBuffer(index))
                                require(info.offset >= 0 && info.size <= buffer.capacity() - info.offset)
                                buffer.limit(info.offset + info.size)
                                buffer.position(info.offset)
                                val data = ByteArray(info.size)
                                buffer.get(data)
                                pcm.write(data)
                            }
                            outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            lastProgress = SystemClock.elapsedRealtime()
                        } finally { decoder.releaseOutputBuffer(index, false) }
                    }
                }
            }
            check()
            require(pcm.size() > 0 && pcm.size() % (channels * 2) == 0) { "Decoder produced incomplete PCM frames." }
            val duration = pcm.size().toDouble() / (rate * channels * 2)
            require(duration > 0 && duration <= 60.0) { "Use nonempty audio up to 60 seconds." }
            val wav = ByteBuffer.allocate(44 + pcm.size()).order(ByteOrder.LITTLE_ENDIAN)
            wav.put("RIFF".toByteArray(Charsets.US_ASCII)).putInt(36 + pcm.size())
                .put("WAVEfmt ".toByteArray(Charsets.US_ASCII)).putInt(16).putShort(1)
                .putShort(channels.toShort()).putInt(rate).putInt(rate * channels * 2)
                .putShort((channels * 2).toShort()).putShort(16)
                .put("data".toByteArray(Charsets.US_ASCII)).putInt(pcm.size()).put(pcm.toByteArray())
            return wav.array().inputStream().use { AudioSource.read(it) }
        } finally {
            codec?.let { if (running) runCatching { it.stop() }; runCatching { it.release() } }
            extractor.release()
        }
    }
}
