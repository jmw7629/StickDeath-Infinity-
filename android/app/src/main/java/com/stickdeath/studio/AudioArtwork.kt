package com.stickdeath.studio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Base64
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.delay
import java.io.InputStream
import org.json.JSONObject

/** Private immutable WAV bytes. History shares this object; providers are never retained. */
class AudioSource private constructor(private val bytes: ByteArray, val rate: Int, val channels: Int,
                                      private val offset: Int, val frames: Int) {
    val byteCount get() = bytes.size
    val duration get() = frames.toDouble() / rate
    /** Signed PCM lookup without exposing or copying owned source storage. */
    internal fun sample(frame: Int, channel: Int): Int {
        require(frame in 0 until frames && channel in 0..1)
        val index = offset + (frame * channels + if (channels == 1) 0 else channel) * 2
        return ((bytes[index].toInt() and 255) or (bytes[index + 1].toInt() shl 8)).toShort().toInt()
    }
    fun encoded(): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun copyFrames(frame: Int, count: Int, target: ByteArray) =
        bytes.copyInto(target, 0, offset + frame * channels * 2, offset + (frame + count) * channels * 2)
    suspend fun preview(clip: AudioClip) {
        val mask = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minimum = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        require(minimum > 0) { "This device cannot preview this WAV format." }
        val track = AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setChannelMask(mask)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(maxOf(minimum, 8192)).build()
        try {
            require(track.state == AudioTrack.STATE_INITIALIZED) { "Audio output could not initialize." }
            track.setVolume(if (clip.muted) 0f else clip.volume)
            track.play()
            val first = kotlin.math.round(clip.sourceOffset * rate).toInt()
            val total = minOf(kotlin.math.round(clip.duration * rate).toInt(), frames - first)
            val buffer = ByteArray(8192)
            var sent = 0
            while (sent < total) {
                currentCoroutineContext().ensureActive()
                val count = minOf(total - sent, buffer.size / (channels * 2))
                copyFrames(first + sent, count, buffer)
                clip.fade?.let { envelope ->
                    repeat(count) { index ->
                        val gain = envelope.gain((first + sent + index).toDouble() / rate)
                        repeat(channels) { channel ->
                            val at = (index * channels + channel) * 2
                            val value = ((buffer[at].toInt() and 255) or (buffer[at + 1].toInt() shl 8)).toShort().toInt()
                            val scaled = kotlin.math.round(value * gain).toInt().coerceIn(-32768, 32767)
                            buffer[at] = scaled.toByte(); buffer[at + 1] = (scaled shr 8).toByte()
                        }
                    }
                }
                var written = 0
                val bytesToWrite = count * channels * 2
                while (written < bytesToWrite) {
                    currentCoroutineContext().ensureActive()
                    val n = track.write(buffer, written, bytesToWrite - written, AudioTrack.WRITE_NON_BLOCKING)
                    require(n >= 0) { "Audio output failed ($n)." }
                    written += n
                    if (n == 0) delay(10)
                }
                sent += count
            }
            track.primeShortPCMStream(total.toLong(), channels)
            while (track.playbackHeadPosition.toLong() < total) { currentCoroutineContext().ensureActive(); delay(10) }
        } finally { runCatching { track.pause(); track.flush() }; track.release() }
    }
    companion object {
        const val MAX_BYTES = 4 * 1024 * 1024
        suspend fun read(input: InputStream): AudioSource {
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                currentCoroutineContext().ensureActive()
                val n = input.read(buffer); if (n < 0) break
                require(output.size() + n <= MAX_BYTES) { "WAV must be at most 4 MiB." }
                output.write(buffer, 0, n)
            }
            return parse(output.toByteArray())
        }
        fun decode(value: String): AudioSource {
            require(value.length <= (MAX_BYTES + 2) / 3 * 4) { "Audio source exceeds 4 MiB." }
            return parse(Base64.decode(value, Base64.NO_WRAP))
        }
        private fun parse(bytes: ByteArray): AudioSource {
            require(bytes.size in 44..MAX_BYTES) { "Invalid or oversized WAV." }
            fun tag(at: Int) = String(bytes, at, 4, Charsets.US_ASCII)
            fun u16(at: Int) = (bytes[at].toInt() and 255) or ((bytes[at+1].toInt() and 255) shl 8)
            fun u32(at: Int) = (0..3).fold(0L) { v, i -> v or ((bytes[at+i].toLong() and 255) shl (i*8)) }
            require(tag(0) == "RIFF" && tag(8) == "WAVE" && u32(4) + 8 == bytes.size.toLong()) { "Use an ordinary RIFF WAV file." }
            var at = 12; var rate = 0; var channels = 0; var bits = 0; var offset = -1; var size = 0
            while (at + 8 <= bytes.size) {
                val kind = tag(at); val length = u32(at + 4)
                require(length <= bytes.size - at - 8) { "Truncated WAV chunk." }
                val body = at + 8
                if (kind == "fmt ") {
                    require(rate == 0 && length >= 16 && u16(body) == 1 && u16(body+14) in listOf(16, 24)) { "Use uncompressed 16-bit or 24-bit PCM WAV." }
                    bits = u16(body+14)
                    channels = u16(body+2); val rawRate = u32(body+4)
                    require(channels in 1..2 && rawRate in 8000L..48000L) { "Use mono/stereo WAV at 8–48 kHz." }
                    rate = rawRate.toInt()
                    require(u16(body+12) == channels*(bits/8) && u32(body+8) == rate.toLong()*channels*(bits/8))
                } else if (kind == "data") {
                    require(offset < 0) { "Multiple WAV data chunks are unsupported." }; offset = body; size = length.toInt()
                }
                at = body + length.toInt() + (length.toInt() and 1)
            }
            require(at == bytes.size && rate > 0 && offset >= 0 && size > 0 && size % (channels*(bits/8)) == 0) { "Invalid PCM WAV structure." }
            val frames = size / (channels*(bits/8))
            require(frames > 0 && frames.toDouble()/rate <= 60.0) { "Use nonempty audio up to 60 seconds." }
            if (bits == 24) {
                val pcmBytes = frames * channels * 2
                val output = java.nio.ByteBuffer.allocate(44 + pcmBytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                output.put("RIFF".toByteArray()).putInt(36 + pcmBytes).put("WAVEfmt ".toByteArray()).putInt(16)
                    .putShort(1).putShort(channels.toShort()).putInt(rate).putInt(rate * channels * 2)
                    .putShort((channels * 2).toShort()).putShort(16).put("data".toByteArray()).putInt(pcmBytes)
                repeat(frames * channels) { sample ->
                    val at = offset + sample * 3
                    // Downconvert signed PCM24 at the same sample rate and channel layout.
                    output.putShort(((bytes[at + 1].toInt() and 255) or (bytes[at + 2].toInt() shl 8)).toShort())
                }
                return parse(output.array())
            }
            return AudioSource(bytes, rate, channels, offset, frames)
        }
    }
}

/** Source-time envelope: trim and split retain the original fade phase. */
data class AudioFade(val start: Double, val end: Double, val fadeIn: Double, val fadeOut: Double) {
    fun validate(sourceDuration: Double) {
        require(listOf(start, end, fadeIn, fadeOut).all { it.isFinite() } && start >= 0 &&
            end > start && end <= sourceDuration + 0.000001 && fadeIn >= 0 && fadeOut >= 0 &&
            fadeIn + fadeOut <= end - start + 0.000001) { "Fade lengths must fit their source-time span without overlapping." }
    }
    fun gain(sourceTime: Double): Double {
        val incoming = if (fadeIn == 0.0) 1.0 else ((sourceTime - start) / fadeIn).coerceIn(0.0, 1.0)
        val outgoing = if (fadeOut == 0.0) 1.0 else ((end - sourceTime) / fadeOut).coerceIn(0.0, 1.0)
        return minOf(incoming, outgoing)
    }
    fun json() = JSONObject().put("start", start).put("end", end).put("in", fadeIn).put("out", fadeOut)
    companion object {
        fun decode(j: JSONObject) = AudioFade(j.getDouble("start"), j.getDouble("end"), j.getDouble("in"), j.getDouble("out"))
    }
}

data class AudioClip(val id: String = newID(), val name: String, val source: AudioSource,
    val start: Double = 0.0, val sourceOffset: Double = 0.0, val duration: Double = source.duration,
    val volume: Float = 1f, val muted: Boolean = false, val track: Int = 1, val fade: AudioFade? = null, val assetCredit: AssetCredit? = null) {
    fun validate() {
        java.util.UUID.fromString(id)
        require(name.isNotBlank() && name.length <= 80 && track in 1..4)
        require(start.isFinite() && start in 0.0..3600.0 && sourceOffset.isFinite() && sourceOffset >= 0 &&
            duration.isFinite() && duration + 1e-12 >= 1.0 / source.rate && sourceOffset + duration <= source.duration + 0.000001) { "Trim must remain inside the source (minimum one source sample)." }
        require(volume.isFinite() && volume in 0f..1f)
        assetCredit?.validate()
        fade?.validate(source.duration)
    }
    fun json() = JSONObject().put("id",id).put("name",name).put("wav",source.encoded()).put("start",start)
        .put("sourceOffset",sourceOffset).put("duration",duration).put("volume",volume).put("muted",muted).put("track",track).apply { fade?.let { put("fade", it.json()) }; assetCredit?.let { put("assetCredit", it.json()) } }
    companion object {
        fun decode(j: JSONObject, source: AudioSource? = null) = AudioClip(j.getString("id"),j.getString("name"),source ?: AudioSource.decode(j.getString("wav")),
            j.getDouble("start"),j.getDouble("sourceOffset"),j.getDouble("duration"),j.getDouble("volume").toFloat(),j.getBoolean("muted"),j.getInt("track"), if (j.has("fade")) AudioFade.decode(j.getJSONObject("fade")) else null, if (j.has("assetCredit")) AssetCredit.decode(j.getJSONObject("assetCredit")) else null)
    }
}

/** Track gain is independent of clip gain and drawing-layer controls. */
data class AudioTrackMix(val volume: Float = 1f, val muted: Boolean = false) {
    fun validate() { require(volume.isFinite() && volume in 0f..1f) { "Track volume must be between 0 and 100 percent." } }
    fun json() = JSONObject().put("volume", volume).put("muted", muted)
    companion object { fun decode(j: JSONObject) = AudioTrackMix(j.getDouble("volume").toFloat(), j.getBoolean("muted")) }
}

/** A streaming AudioTrack starts only after its device buffer threshold is met.
 * Append bounded silence for short effects, but retain the caller's logical end. */
internal suspend fun AudioTrack.primeShortPCMStream(logicalFrames: Long, channels: Int) {
    require(logicalFrames > 0 && channels in 1..2)
    var bytesRemaining = (bufferSizeInFrames.toLong() - logicalFrames).coerceAtLeast(0) * channels * 2
    val silence = ByteArray(8192)
    while (bytesRemaining > 0) {
        currentCoroutineContext().ensureActive()
        val count = minOf(bytesRemaining, silence.size.toLong()).toInt()
        val written = write(silence, 0, count, AudioTrack.WRITE_NON_BLOCKING)
        require(written >= 0) { "Audio startup failed ($written)." }
        bytesRemaining -= written
        if (written == 0) delay(10)
    }
}
