package com.stickdeath.studio

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import com.stickdeath.studio.billing.ExportRendition
import com.stickdeath.studio.billing.ExportWatermarkLayout

/** Renders one MP4/GIF frame at the rendition size and, on the Free plan, burns in the small SDI mark
 * at the bottom right ([ExportWatermarkLayout]). The editable project is never changed. */
object ExportWatermark {
    fun renderFrame(canvas: Canvas, document: Document, frame: Frame, rendition: ExportRendition, check: () -> Unit) {
        val checkpoint = canvas.save()
        try {
            if (rendition.resized) canvas.scale(rendition.width.toFloat() / document.width, rendition.height.toFloat() / document.height)
            FrameRenderer.draw(canvas, document, frame, checkCancellation = check)
        } finally { canvas.restoreToCount(checkpoint) }
        if (rendition.watermark) draw(canvas, rendition.width, rendition.height)
    }

    fun draw(canvas: Canvas, width: Int, height: Int) {
        val r = ExportWatermarkLayout.rect(width, height)
        val box = RectF(r.left.toFloat(), r.top.toFloat(), r.right.toFloat(), r.bottom.toFloat())
        val radius = r.height * 0.3f
        canvas.drawRoundRect(box, radius, radius, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(150, 0, 0, 0) })
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(235, 255, 255, 255)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textAlign = Paint.Align.CENTER
            textSize = r.height * 0.62f
        }
        val baseline = box.centerY() - (text.descent() + text.ascent()) / 2f
        canvas.drawText(ExportWatermarkLayout.TEXT, box.centerX(), baseline, text)
    }
}
