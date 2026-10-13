package com.stickdeath.studio

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.SystemClock
import java.io.File
import java.nio.ByteBuffer
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.delay

/** AAC encoding and lossless remux of the already inspected canonical H.264 video.
 * Failures never return the silent intermediate as a successful soundtrack export. */
object AudioMovieMuxer {
    private const val MAX_FILE = 256L * 1024 * 1024
    private const val AAC_FRAME = 1024L
    // Four AAC-LC packets: an explicit bound, not a decoded alignment guarantee.
    private const val MAX_PADDING_FRAMES = AAC_FRAME * 4
    private const val PADDING_US = (MAX_PADDING_FRAMES * 1_000_000 + AudioMixer.RATE - 1) / AudioMixer.RATE
    private data class GaplessInfo(val delay: Int?, val padding: Int?)
    suspend fun add(context: Context, video: File, document: Document): File {
        val scope = currentCoroutineContext()
        val began = SystemClock.elapsedRealtime()
        val check = {
            scope.ensureActive()
            require(SystemClock.elapsedRealtime() - began < 180_000) { "Audio export exceeded its three-minute limit." }
        }
        val audio = File.createTempFile("studio-aac-", ".partial", context.cacheDir)
        var output: File? = null
        var complete = false
        try {
            val gapless = encode(audio, AudioMixer(document), check)
            check()
            val destination = File.createTempFile("studio-av-", ".partial", context.cacheDir); output = destination
            remux(video, audio, destination, document, gapless, check)
            inspect(destination, document, check)
            check(); complete = true
            return destination
        } finally { audio.delete(); if (!complete) output?.delete() }
    }
    private suspend fun encode(file: File, mixer: AudioMixer, check: () -> Unit): GaplessInfo {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, AudioMixer.RATE, 2).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4096)
        }
        val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            ?: error("This device has no compatible AAC encoder. No silent fallback was exported.")
        val encoder = MediaCodec.createByCodecName(name)
        var writer: MediaMuxer? = null
        var started = false
        var gapless = GaplessInfo(null, null)
        try {
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start(); started = true
            val muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4); writer = muxer
            var track = -1; var queued = 0L; var inputEnded = false; var ended = false
            var lastActivity = SystemClock.elapsedRealtime(); var origin: Long? = null
            var lastPTS = -1L; var packets = 0L; var payload = 0L
            val maxPackets = (mixer.frameCount + AAC_FRAME - 1) / AAC_FRAME + MAX_PADDING_FRAMES / AAC_FRAME
            val info = MediaCodec.BufferInfo()
            while (!ended) {
                check()
                var activity = false
                if (!inputEnded) {
                    val index = encoder.dequeueInputBuffer(0)
                    if (index >= 0) {
                        if (queued == mixer.frameCount) {
                            encoder.queueInputBuffer(index, 0, 0, queued * 1_000_000 / AudioMixer.RATE, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEnded = true
                        } else {
                            val buffer = encoder.getInputBuffer(index) ?: error("AAC input buffer unavailable.")
                            buffer.clear()
                            val count = minOf(1024L, mixer.frameCount - queued, (buffer.remaining()/4).toLong()).toInt()
                            require(count > 0) { "AAC encoder input buffer is too small." }
                            mixer.write(queued, count, buffer, check)
                            encoder.queueInputBuffer(index, 0, count * 4, queued * 1_000_000 / AudioMixer.RATE, 0)
                            queued += count
                        }
                        activity = true
                    }
                }
                val index = encoder.dequeueOutputBuffer(info, 0)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    require(track < 0) { "AAC format changed during encoding." }
                    val result = encoder.outputFormat
                    require(result.getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_AUDIO_AAC &&
                        result.getInteger(MediaFormat.KEY_SAMPLE_RATE) == AudioMixer.RATE && result.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == 2)
                    fun boundedMetadata(key: String): Int? = if (result.containsKey(key)) result.getInteger(key).also {
                        require(it in 0..MAX_PADDING_FRAMES.toInt()) { "AAC delay/padding exceeds four codec frames." }
                    } else null
                    gapless = GaplessInfo(boundedMetadata(MediaFormat.KEY_ENCODER_DELAY), boundedMetadata(MediaFormat.KEY_ENCODER_PADDING))
                    track = muxer.addTrack(result); muxer.start(); activity = true
                } else if (index >= 0) {
                    try {
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                        if (info.size > 0) {
                            require(track >= 0 && packets < maxPackets && info.size <= 64 * 1024) { "AAC output exceeds its packet bound." }
                            if (origin == null) {
                                require(info.presentationTimeUs in -PADDING_US..PADDING_US) { "AAC priming exceeds the supported timing tolerance." }
                                // Normalizing packet PTS may retain codec priming in decoded samples.
                                // This is intentionally NOT described as sample-exact A/V synchronization.
                                origin = info.presentationTimeUs
                            }
                            val time = info.presentationTimeUs - requireNotNull(origin)
                            val expected = packets * AAC_FRAME * 1_000_000 / AudioMixer.RATE
                            require(time > lastPTS && kotlin.math.abs(time - expected) <= 2000) { "AAC encoder produced unexpected timing." }
                            val buffer = encoder.getOutputBuffer(index) ?: error("AAC output buffer unavailable.")
                            buffer.position(info.offset); buffer.limit(info.offset + info.size)
                            info.presentationTimeUs = time
                            muxer.writeSampleData(track, buffer, info)
                            lastPTS = time; packets++; payload += info.size
                            require(payload <= 8L * 1024 * 1024 && file.length() <= 8L * 1024 * 1024) { "AAC output exceeds 8 MiB." }
                        }
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            require(inputEnded && queued == mixer.frameCount && packets > 0)
                            val end = lastPTS + AAC_FRAME * 1_000_000 / AudioMixer.RATE
                            val expectedEnd = mixer.frameCount * 1_000_000 / AudioMixer.RATE
                            require(end >= expectedEnd - 2000 && end <= expectedEnd + PADDING_US) { "AAC duration exceeds the supported padding tolerance." }
                            ended = true
                        }
                    } finally { encoder.releaseOutputBuffer(index, false) }
                    activity = true
                }
                if (activity) lastActivity = SystemClock.elapsedRealtime()
                require(SystemClock.elapsedRealtime() - lastActivity < 15_000) { "AAC encoder stalled." }
                if (!activity) delay(5)
            }
            muxer.stop(); muxer.release(); writer = null
            require(file.length() in 1..8L * 1024 * 1024) { "AAC output is empty or oversized." }
            return gapless
        } finally {
            if (started) runCatching { encoder.stop() }
            runCatching { encoder.release() }; runCatching { writer?.release() }
        }
    }
    private fun remux(video: File, audio: File, output: File, document: Document, gapless: GaplessInfo, check: () -> Unit) {
        val ve = MediaExtractor(); val ae = MediaExtractor(); var muxer: MediaMuxer? = null
        try {
            ve.setDataSource(video.absolutePath); ae.setDataSource(audio.absolutePath)
            require(ve.trackCount == 1 && ae.trackCount == 1)
            val writer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4); muxer = writer
            val audioFormat = ae.getTrackFormat(0)
            // Preserve codec-reported gapless hints even when the intermediate extractor omits them.
            // Android muxers/players may ignore these hints; they do not prove decoded alignment.
            gapless.delay?.let { audioFormat.setInteger(MediaFormat.KEY_ENCODER_DELAY, it) }
            gapless.padding?.let { audioFormat.setInteger(MediaFormat.KEY_ENCODER_PADDING, it) }
            val vt = writer.addTrack(ve.getTrackFormat(0)); val at = writer.addTrack(audioFormat)
            ve.selectTrack(0); ae.selectTrack(0); writer.start()
            val buffer = ByteBuffer.allocate(8 * 1024 * 1024)
            val info = MediaCodec.BufferInfo(); var bytes = 0L; var samples = 0
            while (ve.sampleTrackIndex >= 0 || ae.sampleTrackIndex >= 0) {
                check()
                require(samples++ < 14_000) { "Movie contains too many samples." }
                val isVideo = ve.sampleTrackIndex >= 0 && (ae.sampleTrackIndex < 0 || ve.sampleTime <= ae.sampleTime)
                val source = if (isVideo) ve else ae
                buffer.clear()
                val count = source.readSampleData(buffer, 0)
                require(count in 1..buffer.capacity()) { "Movie sample exceeds the 8 MiB buffer limit." }
                require(source.sampleFlags and (MediaExtractor.SAMPLE_FLAG_ENCRYPTED or MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME) == 0)
                val flags = if (source.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                info.set(0, count, source.sampleTime, flags)
                buffer.position(0); buffer.limit(count)
                writer.writeSampleData(if (isVideo) vt else at, buffer, info)
                bytes += count
                require(bytes <= 250L * 1024 * 1024 && output.length() <= MAX_FILE) { "Combined MP4 exceeds its size limit." }
                source.advance()
            }
            val duration = document.frames.sumOf { it.hold.toLong() } * 1_000_000 / document.fps
            info.set(0, 0, duration, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            writer.writeSampleData(vt, ByteBuffer.allocate(0), info)
            writer.stop(); writer.release(); muxer = null
            require(output.length() in 1..MAX_FILE)
        } finally { ve.release(); ae.release(); runCatching { muxer?.release() } }
    }
    private fun inspect(file: File, document: Document, check: () -> Unit) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            require(extractor.trackCount == 2) { "Soundtrack MP4 must contain exactly video and audio tracks." }
            val tracks = (0 until extractor.trackCount).associateBy { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) }
            val video = tracks[MediaFormat.MIMETYPE_VIDEO_AVC] ?: error("MP4 video track is missing.")
            val audio = tracks[MediaFormat.MIMETYPE_AUDIO_AAC] ?: error("MP4 AAC track is missing.")
            val vf = extractor.getTrackFormat(video); val af = extractor.getTrackFormat(audio)
            val total = document.frames.sumOf { it.hold }
            val duration = total.toLong() * 1_000_000 / document.fps
            require(vf.getInteger(MediaFormat.KEY_WIDTH) == document.width && vf.getInteger(MediaFormat.KEY_HEIGHT) == document.height)
            require(kotlin.math.abs(vf.getLong(MediaFormat.KEY_DURATION) - duration) <= 1000) { "Muxing changed video duration." }
            require(af.getInteger(MediaFormat.KEY_SAMPLE_RATE) == AudioMixer.RATE && af.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == 2)
            require(af.getLong(MediaFormat.KEY_DURATION) in (duration - 2000)..(duration + PADDING_US)) { "MP4 audio duration exceeds the supported AAC padding." }
            extractor.selectTrack(video)
            var count = 0; var previous = -1L
            while (extractor.sampleTrackIndex >= 0) {
                check()
                val time = extractor.sampleTime
                require(count < total && time > previous && kotlin.math.abs(time - count.toLong()*1_000_000/document.fps) <= 1000) { "Muxing changed animation frame timing." }
                require(extractor.sampleFlags and (MediaExtractor.SAMPLE_FLAG_ENCRYPTED or MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME) == 0)
                require(count != 0 || extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0)
                previous = time; count++
                if (!extractor.advance()) break
            }
            require(count == total) { "Muxing dropped animation frames." }
            // Use a fresh extractor so selecting audio starts at the beginning.
        } finally { extractor.release() }
        val audioExtractor = MediaExtractor()
        try {
            audioExtractor.setDataSource(file.absolutePath)
            val track = (0 until audioExtractor.trackCount).first { audioExtractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_AUDIO_AAC }
            audioExtractor.selectTrack(track)
            val duration = document.frames.sumOf { it.hold.toLong() } * 1_000_000 / document.fps
            val maximum = (duration * AudioMixer.RATE / 1_000_000 + AAC_FRAME - 1) / AAC_FRAME + MAX_PADDING_FRAMES / AAC_FRAME
            var count = 0L; var previous = -1L
            while (audioExtractor.sampleTrackIndex >= 0) {
                check()
                val time = audioExtractor.sampleTime
                require(count < maximum && time > previous && kotlin.math.abs(time - count*AAC_FRAME*1_000_000/AudioMixer.RATE) <= 2000) { "MP4 audio packets have unexpected timing." }
                require(audioExtractor.sampleFlags and (MediaExtractor.SAMPLE_FLAG_ENCRYPTED or MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME) == 0)
                previous = time; count++
                if (!audioExtractor.advance()) break
            }
            require(count > 0 && previous + AAC_FRAME*1_000_000/AudioMixer.RATE >= duration - 2000) { "MP4 soundtrack is incomplete." }
        } finally { audioExtractor.release() }
    }
}
