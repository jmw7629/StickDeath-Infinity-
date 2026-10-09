package com.stickdeath.studio

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlinx.coroutines.ensureActive

/** Deterministic 48 kHz stereo PCM16 mix, computed by absolute output frame.
 * Linear interpolation, mono duplication and final saturating sum; no full-song cache.
 * Track is a grouping label: all unmuted clips, including same-track overlaps, sum. */
class AudioMixer(document: Document) {
    private val clips = document.audioClips.sortedBy { it.id }.filter { !it.muted && it.volume > 0f }
    val frameCount = (document.frames.sumOf { it.hold.toLong() } * RATE + document.fps - 1) / document.fps
    init { document.validated(); require(frameCount in 1..RATE * 120L) }
    fun write(first: Long, count: Int, output: ByteBuffer, check: () -> Unit) {
        require(first >= 0 && count in 1..4096 && first + count <= frameCount && output.remaining() >= count * 4)
        output.order(ByteOrder.LITTLE_ENDIAN)
        repeat(count) { index ->
            if (index % 128 == 0) check()
            val time = (first + index).toDouble() / RATE
            var left = 0.0; var right = 0.0
            for (clip in clips) {
                val elapsed = time - clip.start
                if (elapsed < 0.0 || elapsed >= clip.duration) continue
                val position = (clip.sourceOffset + elapsed) * clip.source.rate
                val frame = floor(position).toInt()
                if (frame !in 0 until clip.source.frames) continue
                val lastTrimFrame = minOf(clip.source.frames - 1, kotlin.math.ceil((clip.sourceOffset + clip.duration) * clip.source.rate).toInt() - 1)
                val next = minOf(frame + 1, lastTrimFrame)
                val fraction = position - frame
                fun value(channel: Int): Double {
                    val a = clip.source.sample(frame, channel)
                    return (a + (clip.source.sample(next, channel) - a) * fraction) * clip.volume
                }
                left += value(0); right += value(1)
            }
            output.putShort(left.roundToInt().coerceIn(-32768, 32767).toShort())
            output.putShort(right.roundToInt().coerceIn(-32768, 32767).toShort())
        }
    }
    /** Stream only a bounded PCM block. The consumed sample counter, not a
     * separate UI timer, owns animation time while this soundtrack is playing. */
    suspend fun preview(first: Long, onConsumed: suspend (Long) -> Unit) {
        require(first in 0 until frameCount)
        val minimum = android.media.AudioTrack.getMinBufferSize(RATE,
            android.media.AudioFormat.CHANNEL_OUT_STEREO, android.media.AudioFormat.ENCODING_PCM_16BIT)
        require(minimum > 0) { "This device cannot preview the mixed soundtrack." }
        val track = android.media.AudioTrack.Builder()
            .setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(android.media.AudioFormat.Builder().setSampleRate(RATE)
                .setChannelMask(android.media.AudioFormat.CHANNEL_OUT_STEREO)
                .setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT).build())
            .setTransferMode(android.media.AudioTrack.MODE_STREAM).setBufferSizeInBytes(maxOf(minimum, 8192)).build()
        val context = kotlinx.coroutines.currentCoroutineContext()
        val check = { context.ensureActive() }
        try {
            require(track.state == android.media.AudioTrack.STATE_INITIALIZED) { "Mixed audio output could not initialize." }
            val block = ByteBuffer.allocate(4096)
            var submitted = first
            var last = -1L
            suspend fun displayClock() {
                val consumed = (track.playbackHeadPosition.toLong() and 0xffffffffL).coerceAtMost(frameCount-first-1)
                if (consumed != last) { last = consumed; onConsumed(consumed) }
            }
            onConsumed(0); track.play()
            while (submitted < frameCount) {
                check()
                val count = minOf(1024L, frameCount-submitted).toInt()
                block.clear(); write(submitted,count,block,check)
                var offset = 0
                while (offset < count*4) {
                    check()
                    val written = track.write(block.array(),offset,count*4-offset,android.media.AudioTrack.WRITE_NON_BLOCKING)
                    require(written >= 0) { "Mixed audio output failed ($written)." }
                    offset += written; displayClock()
                    if (written == 0) kotlinx.coroutines.delay(10)
                }
                submitted += count
            }
            while ((track.playbackHeadPosition.toLong() and 0xffffffffL) < frameCount-first) {
                check(); displayClock(); kotlinx.coroutines.delay(10)
            }
            displayClock()
        } finally { runCatching { track.pause(); track.flush() }; track.release() }
    }
    companion object { const val RATE = 48_000 }
}
