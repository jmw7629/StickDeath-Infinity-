package com.stickdeath.studio

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Bounded device decoder shared by approved bundles and user-selected audio. */
object AudioDecoder {
    suspend fun decode(allowedMimes: Set<String>, progress: suspend (String) -> Unit = {}, configure: (MediaExtractor) -> Unit): AudioSource {
        val coroutine = currentCoroutineContext()
        val started = SystemClock.elapsedRealtime()
        var lastProgress = started
        fun check() {
            coroutine.ensureActive()
            val now = SystemClock.elapsedRealtime()
            require(now - started < 30_000) { "Audio decoding exceeded 30 seconds." }
            require(now - lastProgress < 5_000) { "Audio decoder stalled." }
        }
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var running = false
        try {
            progress("Opening audio decoder…")
            configure(extractor)
            check()
            require(extractor.trackCount == 1) { "Choose a file containing exactly one audio track." }
            val format = extractor.getTrackFormat(0)
            val mime = requireNotNull(format.getString(MediaFormat.KEY_MIME))
            require(mime in allowedMimes) { "This audio codec is not supported for import." }
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
            var lastReport = started
            progress("Decoding audio into project-owned PCM…")
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
                                val now = SystemClock.elapsedRealtime()
                                if (now - lastReport >= 500) {
                                    lastReport = now
                                    progress("Decoded %.1f seconds of audio…".format(pcm.size().toDouble() / (rate * channels * 2)))
                                }
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
            progress("Validating decoded audio…")
            return wav.array().inputStream().use { AudioSource.read(it) }
        } finally {
            codec?.let { if (running) runCatching { it.stop() }; runCatching { it.release() } }
            extractor.release()
        }
    }
}
