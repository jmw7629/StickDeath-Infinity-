package com.stickdeath.studio

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF

/** Shared viewport/export drawing path. Erasers remove alpha from a layer, never the white background. */
object FrameRenderer {
    fun supports(blend: LayerBlend): Boolean = !blend.needsModernBlend || android.os.Build.VERSION.SDK_INT >= 29
    private fun layerPaint(layer: Layer): Paint = Paint().apply {
        alpha = (layer.opacity * 255).toInt()
        require(supports(layer.blend)) { "${layer.blend.label} layers require Android 10 or later. The original project is preserved." }
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            blendMode = when (layer.blend) {
                LayerBlend.Normal -> android.graphics.BlendMode.SRC_OVER
                LayerBlend.Multiply -> android.graphics.BlendMode.MULTIPLY
                LayerBlend.Screen -> android.graphics.BlendMode.SCREEN
                LayerBlend.Overlay -> android.graphics.BlendMode.OVERLAY
                LayerBlend.Darken -> android.graphics.BlendMode.DARKEN
                LayerBlend.Lighten -> android.graphics.BlendMode.LIGHTEN
                LayerBlend.ColorDodge -> android.graphics.BlendMode.COLOR_DODGE
                LayerBlend.ColorBurn -> android.graphics.BlendMode.COLOR_BURN
                LayerBlend.HardLight -> android.graphics.BlendMode.HARD_LIGHT
                LayerBlend.SoftLight -> android.graphics.BlendMode.SOFT_LIGHT
                LayerBlend.Difference -> android.graphics.BlendMode.DIFFERENCE
                LayerBlend.Exclusion -> android.graphics.BlendMode.EXCLUSION
                LayerBlend.Hue -> android.graphics.BlendMode.HUE
                LayerBlend.Saturation -> android.graphics.BlendMode.SATURATION
                LayerBlend.Color -> android.graphics.BlendMode.COLOR
                LayerBlend.Luminosity -> android.graphics.BlendMode.LUMINOSITY
            }
        } else {
            // Legacy MULTIPLY modulates alpha and is not equivalent to the
            // source-over Multiply used by Studio; never substitute it silently.
            xfermode = PorterDuffXfermode(when (layer.blend) {
                LayerBlend.Normal -> PorterDuff.Mode.SRC_OVER
                LayerBlend.Screen -> PorterDuff.Mode.SCREEN
                LayerBlend.Overlay -> PorterDuff.Mode.OVERLAY
                LayerBlend.Darken -> PorterDuff.Mode.DARKEN
                LayerBlend.Lighten -> PorterDuff.Mode.LIGHTEN
                else -> error("Unsupported blend: ${layer.blend.label}")
            })
        }
    }
    fun sampleColor(document: Document, point: Point, checkCancellation: () -> Unit): Int {
        require(point.x.isFinite() && point.y.isFinite() && point.x in 0f..document.width.toFloat() && point.y in 0f..document.height.toFloat())
        checkCancellation()
        // Render the canonical composite into a one-pixel target. No screenshot,
        // onion skin, selection overlay or full-resolution bitmap is sampled.
        val pixel = android.graphics.Bitmap.createBitmap(1, 1, android.graphics.Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(pixel)
            canvas.translate(-point.x.toInt().coerceIn(0, document.width - 1).toFloat(),
                -point.y.toInt().coerceIn(0, document.height - 1).toFloat())
            draw(canvas, document, document.frame, checkCancellation = checkCancellation)
            checkCancellation()
            return pixel.getPixel(0, 0)
        } finally { pixel.recycle() }
    }
    fun draw(canvas: Canvas, document: Document, frame: Frame, pending: Stroke? = null,
             background: Boolean = true, checkCancellation: () -> Unit = {}) {
        val outer = canvas.save()
        try {
            canvas.clipRect(0f, 0f, document.width.toFloat(), document.height.toFloat())
            if (background) canvas.drawColor(document.backgroundColor)
            document.layers.asReversed().filter { it.visible && it.opacity > 0 }.forEach { layer ->
                checkCancellation()
                val alpha = layerPaint(layer)
                val checkpoint = canvas.saveLayer(RectF(0f, 0f, document.width.toFloat(), document.height.toFloat()), alpha)
                try {
                    val strokes = frame.strokes.filter { it.layerID == layer.id } +
                        (pending?.takeIf { it.layerID == layer.id }?.let { listOf(it) } ?: emptyList())
                    strokes.forEach { stroke ->
                        checkCancellation()
                        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                            color = stroke.color; strokeWidth = stroke.width
                            this.alpha = ((if (stroke.tool == Tool.Eraser) 255 else android.graphics.Color.alpha(stroke.color)) * stroke.opacity).toInt().coerceIn(0, 255)
                            strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
                            if (stroke.tool == Tool.Eraser) xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
                        }
                        if (stroke.tool == Tool.Fill) {
                            paint.isAntiAlias = false
                            requireNotNull(stroke.fill).forEachIndexed { index, span ->
                                if (index % 256 == 0) checkCancellation()
                                canvas.drawRect(span.start.toFloat(), span.y.toFloat(), span.end.toFloat(), (span.y + 1).toFloat(), paint)
                            }
                        } else if (stroke.tool == Tool.Text) {
                            TextArtwork.draw(canvas, stroke, paint)
                        } else if (stroke.tool == Tool.Pencil && stroke.brush != BrushFamily.Round) {
                            BrushRenderer.draw(canvas,stroke,paint,checkCancellation)
                        } else if (stroke.points.size == 1 || stroke.points.all { it == stroke.points.first() }) {
                            canvas.drawCircle(stroke.points.first().x, stroke.points.first().y, stroke.width / 2, paint)
                        } else {
                            paint.style = if (stroke.filled) Paint.Style.FILL else Paint.Style.STROKE
                            val path = Path().apply {
                                moveTo(stroke.points.first().x, stroke.points.first().y)
                                stroke.points.drop(1).forEach { lineTo(it.x, it.y) }
                                if (stroke.tool.isClosedShape) close()
                            }
                            canvas.drawPath(path, paint)
                        }
                    }
                } finally { canvas.restoreToCount(checkpoint) }
            }
        } finally { canvas.restoreToCount(outer) }
    }
    /** Ghosts are an editor overlay only; exports call draw directly. Each ghost
     * has its own composite layer so an eraser cannot cut into another frame. */
    fun drawOnion(canvas: Canvas, document: Document, frame: Frame, pending: Stroke? = null) {
        canvas.drawColor(document.backgroundColor)
        val index = document.frames.indexOfFirst { it.id == frame.id }
        val settings = document.onion
        fun ghost(neighbor: Frame, tint: Int, distance: Int) {
            val paint = Paint().apply {
                alpha = (settings.opacity * 255 / distance).toInt().coerceIn(0, 255)
                if (settings.tinted) colorFilter = android.graphics.PorterDuffColorFilter(tint, PorterDuff.Mode.SRC_IN)
            }
            val checkpoint = canvas.saveLayer(RectF(0f, 0f, document.width.toFloat(), document.height.toFloat()), paint)
            try { draw(canvas, document, neighbor, background = false) }
            finally { canvas.restoreToCount(checkpoint) }
        }
        if (settings.enabled && index >= 0 && settings.opacity > 0f) {
            for (distance in maxOf(settings.previous, settings.next) downTo 1) {
                if (distance <= settings.previous && index - distance >= 0)
                    ghost(document.frames[index - distance], 0xffe52b38.toInt(), distance)
                if (distance <= settings.next && index + distance <= document.frames.lastIndex)
                    ghost(document.frames[index + distance], 0xff246bfe.toInt(), distance)
            }
        }
        draw(canvas, document, frame, pending, background = false)
    }

}
