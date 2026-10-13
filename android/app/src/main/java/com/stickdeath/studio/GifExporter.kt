package com.stickdeath.studio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import java.io.File
import java.io.OutputStream
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** One canonical bitmap at a time; project validation guarantees an opaque background. */
object GifExporter {
    suspend fun prepare(context: Context, document: Document, progress: (Int, Int) -> Unit): ExportArtifact {
        val d = document.validated()
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
                val encoder = GifEncoder(bounded, d.width, d.height, check)
                encoder.begin()
                // Centisecond boundaries shared with the GIF receipt manifest (GifTiming).
                val delays = GifTiming.delaysCentiseconds(d.frames.map { it.hold }, d.fps)
                d.frames.forEachIndexed { index, frame ->
                    check()
                    val bitmap = Bitmap.createBitmap(d.width, d.height, Bitmap.Config.ARGB_8888)
                    try {
                        FrameRenderer.draw(Canvas(bitmap), d, frame, checkCancellation = check)
                        encoder.frame(delays[index]) { y, row -> bitmap.getPixels(row, 0, d.width, 0, y, d.width, 1) }
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
