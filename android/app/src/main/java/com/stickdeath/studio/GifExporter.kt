package com.stickdeath.studio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import java.io.File
import java.io.OutputStream
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import com.stickdeath.studio.billing.ExportRendition

/** One canonical bitmap at a time; project validation guarantees an opaque background. */
object GifExporter {
    /** [rendition] is the output size (the canvas, or scaled down for the Free plan) and whether the
     * SDI watermark is burned in. */
    suspend fun prepare(context: Context, document: Document, progress: (Int, Int) -> Unit,
                        rendition: ExportRendition = ExportRendition(document.width, document.height, 1f, false)): ExportArtifact {
        val d = document.validated()
        val outW = rendition.width; val outH = rendition.height
        val totalTicks = d.frames.sumOf { it.hold.toLong() }
        require(d.width.toLong() * d.height <= 4_194_304 && totalTicks <= d.fps * 120L) {
            "GIF export supports up to 4 megapixels and 120 seconds. No frames were omitted or resized."
        }
        val scope = currentCoroutineContext()
        val began = SystemClock.elapsedRealtime()
        val check = {
            scope.ensureActive()
            require(SystemClock.elapsedRealtime() - began < 600_000) { "GIF encoding exceeded its ten-minute limit." }
        }
        check()
        val file = File.createTempFile("studio-gif-", ".partial", context.cacheDir)
        var complete = false
        try {
            file.outputStream().buffered(64 * 1024).use { raw ->
                val bounded = object : OutputStream() {
                    var written = 0L
                    override fun write(value: Int) {
                        check(); require(written < 256L * 1024 * 1024) { "GIF exceeds 256 MiB. Export fewer or smaller frames." }
                        raw.write(value); written++
                    }
                    override fun write(bytes: ByteArray, offset: Int, length: Int) {
                        check(); require(written + length <= 256L * 1024 * 1024) { "GIF exceeds 256 MiB. Export fewer or smaller frames." }
                        raw.write(bytes, offset, length); written += length
                    }
                    override fun flush() = raw.flush()
                }
                val encoder = GifEncoder(bounded, outW, outH, check)
                encoder.begin()
                // Centisecond boundaries shared with the GIF receipt manifest (GifTiming).
                val delays = GifTiming.delaysCentiseconds(d.frames.map { it.hold }, d.fps)
                d.frames.forEachIndexed { index, frame ->
                    check()
                    val bitmap = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
                    try {
                        ExportWatermark.renderFrame(Canvas(bitmap), d, frame, rendition, check)
                        encoder.frame(delays[index]) { y, row -> bitmap.getPixels(row, 0, outW, 0, y, outW, 1) }
                    } finally { bitmap.recycle() }
                    progress(index + 1, d.frames.size)
                }
                encoder.finish()
            }
            check()
            require(file.length() in 1..256L * 1024 * 1024) { "GIF output is empty or too large." }
            complete = true
            return ExportArtifact(file, ExportKind.GIF, "${ExportManifests.filenameBase(d)}.gif")
        } finally { if (!complete) file.delete() }
    }
}
