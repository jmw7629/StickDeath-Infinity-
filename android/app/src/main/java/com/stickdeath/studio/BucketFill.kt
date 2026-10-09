package com.stickdeath.studio

import android.graphics.Bitmap
import android.graphics.Canvas
import kotlin.math.abs

/** Canonical half-open pixel runs. Stored on their owning layer in stroke order;
 * source artwork remains editable and the mask is never recomputed on reopen. */
data class FillSpan(val y: Int, val start: Int, val end: Int)

object BucketFill {
    const val MAX_PIXELS = 4_194_304
    const val MAX_SPANS = 20_000
    private const val MAX_MILLIS = 5_000L

    /** Samples the actual merged visible frame at document resolution, including
     * background and layer blends. Editor overlays are deliberately excluded.
     * Contiguous mode uses four-connected pixels; tolerance is maximum RGB channel
     * distance from the tapped pixel (0 = exact, 255 = every color).
     * At the pixel limit, readback holds a 16 MiB bitmap and 16 MiB pixel array;
     * classification holds 36 MiB of arrays (20 MiB for global mode), after bitmap
     * recycling. Renderer/native buffers, object overhead and result runs are extra.
     * The time limit is cooperative: a native allocation/draw/copy must return
     * before its following cancellation/time checkpoint can run. */
    fun compute(document: Document, point: Point, tolerance: Int, contiguous: Boolean,
                checkCancellation: () -> Unit): List<FillSpan> = try {
        computeBounded(document, point, tolerance, contiguous, checkCancellation)
    } catch (error: OutOfMemoryError) {
        // computeBounded's bitmap finally has already run. Surface allocation
        // failure through the editor's existing error path without adding artwork.
        throw IllegalArgumentException("Not enough memory to fill this canvas; no fill was added. Try a smaller canvas or simpler frame.", error)
    }

    private fun computeBounded(document: Document, point: Point, tolerance: Int, contiguous: Boolean,
                checkCancellation: () -> Unit): List<FillSpan> {
        require(tolerance in 0..255)
        require(point.x.isFinite() && point.y.isFinite() && point.x in 0f..document.width.toFloat() && point.y in 0f..document.height.toFloat())
        require(document.width in 16..4096 && document.height in 16..4096 &&
            document.width.toLong() * document.height <= MAX_PIXELS) {
            "Fill supports canvases up to 4,194,304 pixels, with each edge from 16 to 4096 pixels; no fill was added."
        }
        val started = android.os.SystemClock.elapsedRealtime()
        fun checkpoint() {
            checkCancellation()
            require(android.os.SystemClock.elapsedRealtime() - started <= MAX_MILLIS) {
                "Fill exceeded its 5-second work limit; no fill was added. Simplify the frame."
            }
        }
        checkpoint()
        val width = document.width; val height = document.height; val count = width * height
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val pixels = try {
            checkpoint()
            FrameRenderer.draw(Canvas(bitmap), document, document.frame, checkCancellation = ::checkpoint)
            checkpoint()
            // Allocate readback only after rendering has released its saved layers.
            // Copy bounded strips so cancellation need not wait for full readback.
            val sampled = IntArray(count)
            for (y in 0 until height step 32) {
                checkpoint()
                bitmap.getPixels(sampled, y * width, width, 0, y, width, minOf(32, height - y))
            }
            checkpoint()
            sampled
        } finally { bitmap.recycle() }
        val seed = point.y.toInt().coerceIn(0, height - 1) * width + point.x.toInt().coerceIn(0, width - 1)
        val target = pixels[seed]
        fun matches(index: Int): Boolean {
            val value = pixels[index]
            return abs((value ushr 16 and 255) - (target ushr 16 and 255)) <= tolerance &&
                abs((value ushr 8 and 255) - (target ushr 8 and 255)) <= tolerance &&
                abs((value and 255) - (target and 255)) <= tolerance
        }
        // Each pixel is classified once and enqueued at most once. The queue has
        // a hard pixel-count bound, so checkerboards cannot exhaust a boxed stack.
        checkpoint()
        val state = ByteArray(count)
        checkpoint()
        if (contiguous) {
            val queue = IntArray(count)
            checkpoint()
            var head = 0; var tail = 0
            fun visit(index: Int) {
                if (state[index].toInt() != 0) return
                state[index] = 1
                if (matches(index)) { state[index] = 2; queue[tail++] = index }
            }
            visit(seed)
            while (head < tail) {
                if (head % 4096 == 0) checkpoint()
                val index = queue[head++]; val x = index % width
                if (x > 0) visit(index - 1)
                if (x + 1 < width) visit(index + 1)
                if (index >= width) visit(index - width)
                if (index + width < count) visit(index + width)
            }
        } else {
            for (index in pixels.indices) {
                if (index % 4096 == 0) checkpoint()
                if (matches(index)) state[index] = 2
            }
        }
        val existingPoints = document.pointCount
        val spans = ArrayList<FillSpan>()
        for (y in 0 until height) {
            checkpoint()
            var x = 0
            while (x < width) {
                if (state[y * width + x].toInt() != 2) { x++; continue }
                val start = x++
                while (x < width && state[y * width + x].toInt() == 2) x++
                require(spans.size < MAX_SPANS && existingPoints + (spans.size + 1) * 3 + 1 <= 100_000) {
                    "Fill is too complex or project capacity is reached (20,000 runs per fill); no fill was added."
                }
                spans.add(FillSpan(y, start, x))
            }
        }
        checkpoint()
        return spans
    }
}
