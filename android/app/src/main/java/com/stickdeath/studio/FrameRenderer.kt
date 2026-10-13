package com.stickdeath.studio

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF

/** Shared viewport/export drawing path. Erasers remove alpha from a layer, never the white background. */
object FrameRenderer {
    /** Linear Burn (max(0, cb + cs - 1)) has no native BlendMode/PorterDuff equivalent and this
     * renderer cannot read its backdrop for a software pass, so it is refused on every API level
     * rather than drawn as Normal. */
    fun supports(blend: LayerBlend): Boolean =
        blend != LayerBlend.LinearBurn && (!blend.needsModernBlend || android.os.Build.VERSION.SDK_INT >= 29)
    /** Honest user-facing reason a blend cannot be drawn here, or null when it can. */
    fun unavailableReason(blend: LayerBlend): String? = when {
        blend == LayerBlend.LinearBurn -> "Linear Burn layers have no exact Android compositing mode yet. The original project is preserved."
        !supports(blend) -> "${blend.label} layers require Android 10 or later. The original project is preserved."
        else -> null
    }
    private fun layerPaint(layer: Layer): Paint = Paint().apply {
        alpha = (layer.opacity * 255).toInt()
        require(supports(layer.blend)) { unavailableReason(layer.blend) ?: "Unsupported blend: ${layer.blend.label}" }
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
                // PLUS sums premultiplied source and destination and saturates: min(1, cb + cs).
                LayerBlend.LinearDodge -> android.graphics.BlendMode.PLUS
                LayerBlend.LinearBurn -> error("Linear Burn has no exact Android compositing mode.")
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
                            this.alpha = ((if (stroke.tool.isEraser) 255 else android.graphics.Color.alpha(stroke.color)) * stroke.opacity).toInt().coerceIn(0, 255)
                            strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
                            if (stroke.tool.isEraser) xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
                            // Alpha lock: paint only where this layer already has coverage (iOS preservesLayerAlpha).
                            else if (stroke.preservesLayerAlpha) xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_ATOP)
                        }
                        if (stroke.tool == Tool.SoftEraser) {
                            // Feathered edge from stacked destination-out passes; see SoftEraser.
                            val fullAlpha = paint.alpha
                            SoftEraser.passes(stroke.opacity).forEach { pass ->
                                paint.strokeWidth = stroke.width * pass.widthFactor
                                paint.alpha = (pass.alpha * 255).toInt().coerceIn(0, 255)
                                drawPolyline(canvas, stroke, paint)
                            }
                            paint.alpha = fullAlpha
                        } else if (stroke.tool == Tool.Fill) {
                            paint.isAntiAlias = false
                            val fillCheckpoint = canvas.save()
                            try {
                                canvas.concat(stroke.fillGeometryOrIdentity().matrix())
                                requireNotNull(stroke.fill).forEachIndexed { index, span ->
                                    if (index % 256 == 0) checkCancellation()
                                    canvas.drawRect(span.start.toFloat(), span.y.toFloat(), span.end.toFloat(), (span.y + 1).toFloat(), paint)
                                }
                            } finally { canvas.restoreToCount(fillCheckpoint) }
                        } else if (stroke.tool == Tool.Image) {
                            requireNotNull(stroke.image).draw(canvas, stroke, paint)
                        } else if (stroke.tool == Tool.Text) {
                            TextArtwork.draw(canvas, stroke, paint)
                        } else if (stroke.swiftRoundBrush != null) {
                            stroke.swiftRoundBrush.draw(canvas, stroke, paint, checkCancellation)
                        } else if (stroke.tool == Tool.Pencil && stroke.brush != BrushFamily.Round) {
                            BrushRenderer.draw(canvas,stroke,paint,checkCancellation)
                        } else if (stroke.swiftLegacyPath) {
                            // Historical Swift pencil uses a butt cap; pen/brush use round caps.
                            paint.strokeCap = if (stroke.swiftLegacyButtCap) Paint.Cap.BUTT else Paint.Cap.ROUND
                            // Exact historical Swift path construction, not Android's polyline.
                            if (stroke.points.size == 1) {
                                canvas.drawCircle(stroke.points[0].x, stroke.points[0].y, maxOf(0.5f, stroke.width / 2), paint)
                            } else {
                                paint.style = Paint.Style.STROKE
                                val path = Path().apply {
                                    moveTo(stroke.points[0].x, stroke.points[0].y)
                                    if (stroke.points.size > 2) for (i in 1 until stroke.points.size) {
                                        val previous = stroke.points[i - 1]; val next = stroke.points[i]
                                        quadTo(previous.x, previous.y, (previous.x + next.x) / 2, (previous.y + next.y) / 2)
                                    }
                                    lineTo(stroke.points.last().x, stroke.points.last().y)
                                }
                                canvas.drawPath(path, paint)
                            }
                        } else drawPolyline(canvas, stroke, paint)
                    }
                } finally { canvas.restoreToCount(checkpoint) }
            }
        } finally { canvas.restoreToCount(outer) }
    }
    /** Android's native round-capped polyline (or filled closed shape); a lone point is a dot. */
    private fun drawPolyline(canvas: Canvas, stroke: Stroke, paint: Paint) {
        if (stroke.points.size == 1 || stroke.points.all { it == stroke.points.first() }) {
            paint.style = Paint.Style.FILL
            canvas.drawCircle(stroke.points.first().x, stroke.points.first().y, paint.strokeWidth / 2, paint)
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
