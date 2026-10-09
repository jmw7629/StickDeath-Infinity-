package com.stickdeath.studio

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Typeface
import kotlin.math.abs
import kotlin.math.hypot

/** Source text plus a bounded font size. Four editable corners encode its affine placement. */
data class EditableText(val content: String, val fontSize: Float = 32f) {
    fun validate() {
        require(content.isNotBlank() && content.length <= 512 && content.count { it == '\n' } < 8) { "Use 1–512 characters and at most 8 lines." }
        require(content.none { it.isISOControl() && it != '\n' }) { "Text contains unsupported control characters." }
        require(fontSize.isFinite() && fontSize in 8f..128f) { "Text size must be 8–128 pixels." }
    }
}
object TextArtwork {
    private fun paint(text: EditableText) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.DEFAULT; textSize = text.fontSize; style = Paint.Style.FILL
    }
    private fun size(text: EditableText): Point {
        text.validate()
        val p = paint(text); val fm = p.fontMetrics
        return Point(text.content.split('\n').maxOf { p.measureText(it) }.coerceAtLeast(1f) + 4f,
            (fm.bottom - fm.top) * text.content.split('\n').size + 4f)
    }
    fun corners(text: EditableText, origin: Point): List<Point> {
        val size = size(text)
        return listOf(origin, Point(origin.x + size.x, origin.y), Point(origin.x + size.x, origin.y + size.y), Point(origin.x, origin.y + size.y))
    }
    fun replace(stroke: Stroke, text: EditableText): Stroke {
        val old = size(requireNotNull(stroke.text)); val next = size(text)
        val o = stroke.points[0]; val x = stroke.points[1]; val y = stroke.points[3]
        val right = Point(o.x + (x.x-o.x)*next.x/old.x, o.y + (x.y-o.y)*next.x/old.x)
        val bottom = Point(o.x + (y.x-o.x)*next.y/old.y, o.y + (y.y-o.y)*next.y/old.y)
        return stroke.copy(text = text, points = listOf(o, right, Point(right.x+bottom.x-o.x,right.y+bottom.y-o.y), bottom))
    }
    fun validateGeometry(stroke: Stroke) {
        val p = stroke.points; val natural = size(requireNotNull(stroke.text))
        val a = (p[1].x-p[0].x)/natural.x; val b = (p[1].y-p[0].y)/natural.x
        val c = (p[3].x-p[0].x)/natural.y; val d = (p[3].y-p[0].y)/natural.y
        require(listOf(a,b,c,d).all { it.isFinite() && abs(it) <= 64f } && abs(a*d-b*c) in 0.0001f..4096f) { "Text transform is outside supported limits." }
        require(hypot(p[2].x-(p[1].x+p[3].x-p[0].x),p[2].y-(p[1].y+p[3].y-p[0].y)) < 0.05f) { "Invalid text geometry." }
    }
    fun draw(canvas: Canvas, stroke: Stroke, appearance: Paint) {
        val text = requireNotNull(stroke.text); val size = size(text)
        val p = paint(text).apply { color = appearance.color; alpha = appearance.alpha }
        val points = stroke.points
        val matrix = Matrix()
        check(matrix.setPolyToPoly(floatArrayOf(0f,0f,size.x,0f,0f,size.y),0,
            floatArrayOf(points[0].x,points[0].y,points[1].x,points[1].y,points[3].x,points[3].y),0,3))
        val checkpoint = canvas.save()
        try {
            canvas.concat(matrix)
            val fm = p.fontMetrics
            text.content.split('\n').forEachIndexed { i, line -> canvas.drawText(line,2f,2f-fm.top+i*(fm.bottom-fm.top),p) }
        } finally { canvas.restoreToCount(checkpoint) }
    }
}
