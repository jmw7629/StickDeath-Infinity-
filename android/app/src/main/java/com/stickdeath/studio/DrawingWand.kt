package com.stickdeath.studio

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock

/** Color selection returns original editable artwork IDs, with one owner per sampled pixel. */
object DrawingWand {
    private const val MAX_CANDIDATES = 128
    private const val MAX_ATTRIBUTION_PIXELS = 16_777_216
    private const val MAX_MILLIS = 5_000L

    fun select(document: Document, point: Point, tolerance: Int, contiguous: Boolean,
               checkCancellation: () -> Unit): Set<String> = try {
        val start = SystemClock.elapsedRealtime()
        fun checkpoint() {
            checkCancellation()
            require(SystemClock.elapsedRealtime() - start <= MAX_MILLIS) {
                "Wand exceeded its 5-second work limit. Try Contiguous or select simpler artwork."
            }
        }

        checkpoint()
        val active = document.layer
        val frame = document.frame
        require(active.isEditable && active.lockMode.allowsTransform) {
            "Choose a visible unlocked layer to select its artwork with Wand."
        }
        val higherLayers = document.layers.takeWhile { it.id != active.id }
            .filter { it.visible && it.opacity > 0f }.map { it.id }.toSet()
        require(frame.strokes.none { it.layerID in higherLayers }) {
            "Wand needs the top painted layer. Select it or hide the layers with artwork above this one."
        }
        val activeStrokes = frame.strokes.filter { it.layerID == active.id }
        require(active.blend == LayerBlend.Normal && activeStrokes.none { it.tool.isEraser || it.preservesLayerAlpha }) {
            "Wand needs a Normal layer without eraser or alpha-locked marks. Use Move or Lasso here."
        }
        val activeDocument = document.copy(layers = listOf(active))
        val eligible = ArtworkSelection.eligible(frame, activeDocument.layers)
        val topFirst = activeStrokes.asReversed().filter { it.id in eligible }
        require(topFirst.size <= MAX_CANDIDATES) {
            "Wand can inspect up to 128 marks on this layer. Use Move or Lasso for more complex artwork."
        }
        if (topFirst.isEmpty()) emptySet()
        else {
            val spans = BucketFill.paintedColorRegion(activeDocument, point, tolerance, contiguous, ::checkpoint)
            if (spans.isEmpty()) emptySet() else topmostOwners(activeDocument, spans, topFirst, ::checkpoint)
        }
    } catch (error: OutOfMemoryError) {
        throw IllegalArgumentException("Not enough memory to select with Wand. Try a smaller canvas.", error)
    }

    private fun topmostOwners(document: Document, spans: List<FillSpan>, topFirst: List<Stroke>,
                              checkpoint: () -> Unit): Set<String> {
        val left = spans.minOf { it.start }; val top = spans.first().y
        val width = spans.maxOf { it.end } - left; val height = spans.last().y - top + 1
        val area = width * height
        require(area <= MAX_ATTRIBUTION_PIXELS / topFirst.size) {
            "This Wand region is too large to inspect every mark. Try Contiguous or a lower tolerance."
        }
        checkpoint()
        val unclaimed = ByteArray(area)
        var remaining = 0
        for (span in spans) {
            checkpoint()
            val row = (span.y - top) * width
            unclaimed.fill(1, row + span.start - left, row + span.end - left)
            remaining += span.end - span.start
        }
        val owners = mutableSetOf<String>()
        val pixels = IntArray(width)
        // Layer opacity is applied after the strokes have composited. The
        // sampled region already includes it; ownership uses each source alpha.
        val coverageDocument = document.copy(layers = listOf(document.layer.copy(opacity = 1f)))
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.translate(-left.toFloat(), -top.toFloat())
            for (stroke in topFirst) {
                checkpoint()
                bitmap.eraseColor(0)
                FrameRenderer.draw(canvas, coverageDocument, document.frame.copy(strokes = listOf(stroke)),
                    background = false, checkCancellation = checkpoint)
                var ownsPixel = false
                for (y in 0 until height) {
                    checkpoint()
                    bitmap.getPixels(pixels, 0, width, 0, y, width, 1)
                    val row = y * width
                    for (x in 0 until width) {
                        val index = row + x
                        if (unclaimed[index].toInt() == 0 || pixels[x] ushr 24 == 0) continue
                        unclaimed[index] = 0
                        remaining--
                        ownsPixel = true
                    }
                }
                if (ownsPixel) owners.add(stroke.id)
                if (remaining == 0) break
            }
        } finally { bitmap.recycle() }
        checkpoint()
        return owners
    }
}
