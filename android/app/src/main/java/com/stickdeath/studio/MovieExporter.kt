package com.stickdeath.studio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.Image
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

/** Canonical H.264, with bounded AAC soundtrack mixing when the project owns audio clips. */
object MovieExporter {
    suspend fun prepare(context: Context, document: Document, progress: (Int, Int) -> Unit): ExportArtifact {
        val d = document.validated()
        val total = d.frames.sumOf { it.hold }
        require(d.width % 2 == 0 && d.height % 2 == 0) { "MP4 requires even canvas dimensions. Change project dimensions or use PNG sequence; no resizing was performed." }
        require(d.width.toLong()*d.height <= 4_194_304 && total <= d.fps*120) { "MP4 export supports up to 4 megapixels and 120 seconds." }
        val scope = currentCoroutineContext()
        val began = SystemClock.elapsedRealtime()
        val check = {
            scope.ensureActive()
            require(SystemClock.elapsedRealtime()-began < 600_000) { "MP4 encoding exceeded its ten-minute limit." }
        }
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, d.width, d.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, (d.width.toLong()*d.height*d.fps/5).coerceIn(1_000_000,20_000_000).toInt())
            setInteger(MediaFormat.KEY_FRAME_RATE, d.fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT601_NTSC)
            setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
            setInteger("max-bframes", 0)
        }
        val encoderName = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            ?: error("This device has no compatible H.264 encoder for these canvas dimensions and frame rate.")
        val file = File.createTempFile("studio-movie-", ".partial", context.cacheDir)
        var codec: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var started = false
        var complete = false
        try {
            val encoder = MediaCodec.createByCodecName(encoderName); codec = encoder
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start(); started = true
            val writer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4); muxer = writer
            var track = -1
            var muxing = false
            var ended = false
            var written = 0L
            var samples = 0
            var lastPTS = -1L
            var lastActivity = SystemClock.elapsedRealtime()
            val info = MediaCodec.BufferInfo()
            val durationUS = total.toLong()*1_000_000/d.fps
            fun drain() {
                while (true) {
                    check()
                    val index = encoder.dequeueOutputBuffer(info, 0)
                    if (index == MediaCodec.INFO_TRY_AGAIN_LATER) return
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        require(!muxing) { "Encoder changed format after MP4 started." }
                        track = writer.addTrack(encoder.outputFormat); writer.start(); muxing = true
                        lastActivity = SystemClock.elapsedRealtime()
                    } else if (index >= 0) {
                        try {
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                            if (info.size > 0) {
                                require(muxing && info.presentationTimeUs > lastPTS) { "Encoder produced invalid frame timing." }
                                require(written + info.size <= 250L*1024*1024) { "MP4 exceeds its output size limit." }
                                val buffer = encoder.getOutputBuffer(index) ?: error("Encoded frame is unavailable.")
                                buffer.position(info.offset); buffer.limit(info.offset+info.size)
                                writer.writeSampleData(track, buffer, info)
                                written += info.size; samples++; lastPTS = info.presentationTimeUs
                            }
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                require(muxing && samples == total) { "Encoder did not produce every animation tick." }
                                val end = MediaCodec.BufferInfo().apply { set(0,0,durationUS,MediaCodec.BUFFER_FLAG_END_OF_STREAM) }
                                writer.writeSampleData(track, ByteBuffer.allocate(0), end)
                                ended = true
                            }
                        } finally { encoder.releaseOutputBuffer(index, false) }
                        lastActivity = SystemClock.elapsedRealtime()
                        require(file.length() <= 256L*1024*1024) { "MP4 exceeds 256 MiB." }
                    }
                }
            }
            fun inputIndex(): Int {
                while (true) {
                    check(); drain()
                    val index = encoder.dequeueInputBuffer(10_000)
                    if (index >= 0) return index
                    require(SystemClock.elapsedRealtime()-lastActivity < 15_000) { "Video encoder stopped accepting frames." }
                }
            }
            var tick = 0
            for (frame in d.frames) {
                check()
                val bitmap = Bitmap.createBitmap(d.width,d.height,Bitmap.Config.ARGB_8888)
                val yuv = try {
                    FrameRenderer.draw(Canvas(bitmap),d,frame,checkCancellation=check)
                    convert(bitmap, check)
                } finally { bitmap.recycle() }
                repeat(frame.hold) {
                    check()
                    val index = inputIndex()
                    val image = encoder.getInputImage(index) ?: error("Encoder does not expose writable YUV image planes on this device.")
                    image.use { writePlanes(it,yuv,d.width,d.height,check) }
                    encoder.queueInputBuffer(index,0,yuv.size,tick.toLong()*1_000_000/d.fps,0)
                    lastActivity = SystemClock.elapsedRealtime()
                    tick++; progress(tick,total); drain()
                }
            }
            val index = inputIndex()
            encoder.queueInputBuffer(index,0,0,durationUS,MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            while (!ended) {
                check(); drain()
                require(SystemClock.elapsedRealtime()-lastActivity < 15_000) { "Video encoder did not finish." }
                if (!ended) kotlinx.coroutines.delay(5)
            }
            writer.stop(); writer.release(); muxer = null
            encoder.stop(); started = false; encoder.release(); codec = null
            check()
            require(file.length() in 1..256L*1024*1024) { "MP4 output is empty or too large." }
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(file.absolutePath)
                require(extractor.trackCount == 1) { "MP4 track is missing." }
                val result = extractor.getTrackFormat(0)
                require(result.getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_VIDEO_AVC &&
                    result.getInteger(MediaFormat.KEY_WIDTH) == d.width && result.getInteger(MediaFormat.KEY_HEIGHT) == d.height) { "MP4 dimensions or codec changed." }
                // Inspect the completed container, not only encoder callbacks.
                // MP4 timescale conversion may round timestamps by up to 1 ms.
                val toleranceUS = 1_000L
                require(result.containsKey(MediaFormat.KEY_DURATION)) { "MP4 duration is missing." }
                val actualDuration = result.getLong(MediaFormat.KEY_DURATION)
                require(actualDuration in (durationUS-toleranceUS)..(durationUS+toleranceUS)) {
                    "MP4 duration does not match the animation. No file was offered for saving."
                }
                extractor.selectTrack(0)
                var extracted = 0
                var previousTime = -1L
                while (extractor.sampleTrackIndex >= 0) {
                    check()
                    require(extracted < total && extractor.sampleTrackIndex == 0) { "MP4 contains unexpected frames." }
                    val timestamp = extractor.sampleTime
                    val expected = extracted.toLong()*1_000_000/d.fps
                    require(timestamp > previousTime && timestamp in (expected-toleranceUS)..(expected+toleranceUS)) {
                        "MP4 frame timing does not match the animation."
                    }
                    val flags = extractor.sampleFlags
                    require(flags and (MediaExtractor.SAMPLE_FLAG_ENCRYPTED or MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME) == 0) {
                        "MP4 contains an incomplete or encrypted frame."
                    }
                    require(extracted != 0 || flags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                        "MP4 does not begin with a playable keyframe."
                    }
                    previousTime = timestamp
                    extracted++
                    if (!extractor.advance()) break
                }
                require(extracted == total) { "MP4 is missing animation frames. No file was offered for saving." }
                check()
            } finally { extractor.release() }
            val stem = d.name.replace(Regex("[^A-Za-z0-9 _-]"),"_").take(80).ifBlank { "animation" }
            val result = if (d.audioClips.isEmpty()) file else AudioMovieMuxer.add(context, file, d)
            if (result !== file) file.delete()
            complete = true
            return ExportArtifact(result,ExportKind.MP4,"$stem.mp4")
        } finally {
            if (started) runCatching { codec?.stop() }
            runCatching { codec?.release() }; runCatching { muxer?.release() }
            if (!complete) file.delete()
        }
    }
    private fun convert(bitmap: Bitmap, check: () -> Unit): ByteArray {
        val width = bitmap.width; val height = bitmap.height; val count = width*height
        val pixels = IntArray(count); bitmap.getPixels(pixels,0,width,0,0,width,height)
        val out = ByteArray(count*3/2)
        fun component(color: Int, shift: Int) = color shr shift and 255
        for (y in 0 until height) {
            check()
            for (x in 0 until width) {
                val color = pixels[y*width+x]
                val r=component(color,16); val g=component(color,8); val b=component(color,0)
                out[y*width+x] = (((66*r+129*g+25*b+128) shr 8)+16).coerceIn(16,235).toByte()
                if (x%2 == 0 && y%2 == 0) {
                    var red=0; var green=0; var blue=0
                    for (dy in 0..1) for (dx in 0..1) {
                        val c=pixels[(y+dy)*width+x+dx]
                        red+=component(c,16); green+=component(c,8); blue+=component(c,0)
                    }
                    red/=4; green/=4; blue/=4
                    val chroma=(y/2)*(width/2)+x/2
                    out[count+chroma]=((((-38*red-74*green+112*blue+128) shr 8)+128).coerceIn(16,240)).toByte()
                    out[count+count/4+chroma]=((((112*red-94*green-18*blue+128) shr 8)+128).coerceIn(16,240)).toByte()
                }
            }
        }
        return out
    }
    private fun writePlanes(image: Image, source: ByteArray, width: Int, height: Int, check: () -> Unit) {
        require(image.width == width && image.height == height && image.planes.size == 3) { "Encoder returned an incompatible image layout." }
        for (planeIndex in 0..2) {
            val plane=image.planes[planeIndex]; val buffer=plane.buffer
            val w=if (planeIndex==0) width else width/2; val h=if (planeIndex==0) height else height/2
            val sourceOffset=when(planeIndex) { 0 -> 0; 1 -> width*height; else -> width*height*5/4 }
            val base=buffer.position()
            for (y in 0 until h) {
                check()
                for (x in 0 until w) buffer.put(base+y*plane.rowStride+x*plane.pixelStride,source[sourceOffset+y*w+x])
            }
        }
    }
}
