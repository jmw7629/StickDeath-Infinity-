package com.stickdeath.studio

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import kotlin.math.*

enum class BrushFamily { Round, Stipple, Grain, RoughPen, Calligraphy, DipPen, Halftone, Hatch }

/** Linear nib transform; translation follows the stroke's first point. */
data class BrushTransform(val a: Float = 1f, val b: Float = 0f, val c: Float = 0f, val d: Float = 1f) {
    val determinant get() = a*d-b*c
    val meanScale get() = sqrt(abs(determinant))
    fun validate() {
        require(listOf(a,b,c,d).all { it.isFinite() && abs(it) <= 64f } && abs(determinant) in 0.0001f..4096f) {
            "Brush transform capacity reached. Undo or use a smaller transform."
        }
    }
    fun then(aa: Float, bb: Float, cc: Float, dd: Float) =
        BrushTransform(aa*a+cc*b, bb*a+dd*b, aa*c+cc*d, bb*c+dd*d).also { it.validate() }
    fun inverse(point: Point): Point = Point((d*point.x-c*point.y)/determinant, (-b*point.x+a*point.y)/determinant)
}
fun Stroke.textureRadius(): Float = if (brush == BrushFamily.Round) width/2 else
    width/(2*brushTransform.meanScale)*max(hypot(brushTransform.a,brushTransform.c),hypot(brushTransform.b,brushTransform.d))

/** Original procedural marks. A saved seed and arc-length sampling make redraw/export repeatable. */
object BrushRenderer {
    private fun spacing(stroke: Stroke): Float = max(0.75f, stroke.width * when (stroke.brush) {
        BrushFamily.Stipple -> 0.35f
        BrushFamily.Halftone -> 0.7f
        BrushFamily.Hatch -> 0.5f
        else -> 0.14f
    })
    private fun original(stroke: Stroke): Stroke {
        stroke.brushTransform.validate()
        val origin = stroke.points.first()
        val width = stroke.width / stroke.brushTransform.meanScale
        require(width.isFinite() && width in 0.99f..128.01f) { "Invalid original brush width." }
        return stroke.copy(width = width, points = stroke.points.map {
            stroke.brushTransform.inverse(Point(it.x-origin.x,it.y-origin.y))
        }, brushTransform = BrushTransform())
    }
    fun work(stroke: Stroke): Int {
        if (stroke.brush == BrushFamily.Round || stroke.tool != Tool.Pencil) return 0
        return originalWork(original(stroke))
    }
    private fun originalWork(stroke: Stroke): Int {
        var length = 0.0
        stroke.points.zipWithNext().forEach { (a,b) -> length += hypot((b.x-a.x).toDouble(), (b.y-a.y).toDouble()) }
        require(length.isFinite())
        val stamps = ceil(length / spacing(stroke)) + 1
        require(stamps <= 16_384) { "This textured stroke is too long. Use a larger brush or shorter strokes." }
        return stamps.toInt() * if (stroke.brush == BrushFamily.Grain) 8 else 3
    }
    fun draw(canvas: Canvas, stroke: Stroke, paint: Paint, checkCancellation: () -> Unit) {
        val source = original(stroke)
        originalWork(source)
        val checkpoint = canvas.save()
        try {
            canvas.translate(stroke.points.first().x,stroke.points.first().y)
            val t = stroke.brushTransform
            val matrix = android.graphics.Matrix().apply { setValues(floatArrayOf(t.a,t.c,0f,t.b,t.d,0f,0f,0f,1f)) }
            canvas.concat(matrix)
            drawOriginal(canvas,source,paint,checkCancellation)
        } finally { canvas.restoreToCount(checkpoint) }
    }
    private fun drawOriginal(canvas: Canvas, stroke: Stroke, paint: Paint, checkCancellation: () -> Unit) {
        val path = Path()
        var random = stroke.brushSeed.takeIf { it != 0 } ?: 0x13579bdf
        fun unit(): Float {
            random = random xor (random shl 13); random = random xor (random ushr 17); random = random xor (random shl 5)
            return (random ushr 8) / 16777216f
        }
        var count = 0
        fun stamp(x: Float, y: Float, direction: Float) {
            if (count++ % 128 == 0) checkCancellation()
            val r = stroke.width / 2
            fun dot(dx: Float, dy: Float, radius: Float) = path.addCircle(x+dx, y+dy, max(0.15f,radius), Path.Direction.CW)
            fun nib(length: Float, thickness: Float, angle: Float) {
                val ux = cos(angle)*length/2; val uy = sin(angle)*length/2
                val vx = -sin(angle)*thickness/2; val vy = cos(angle)*thickness/2
                path.moveTo(x-ux-vx,y-uy-vy); path.lineTo(x+ux-vx,y+uy-vy)
                path.lineTo(x+ux+vx,y+uy+vy); path.lineTo(x-ux+vx,y-uy+vy); path.close()
            }
            val nibAngle = stroke.nibAngle * PI.toFloat() / 180f
            when (stroke.brush) {
                BrushFamily.Stipple, BrushFamily.Grain -> repeat(if (stroke.brush == BrushFamily.Grain) 8 else 3) {
                    val angle = unit()*2*PI.toFloat(); val distance = sqrt(unit())*r*0.8f
                    dot(cos(angle)*distance,sin(angle)*distance,r * if (stroke.brush == BrushFamily.Grain) 0.07f else 0.2f)
                }
                BrushFamily.RoughPen -> dot((unit()-0.5f)*r*0.18f,(unit()-0.5f)*r*0.18f,r*(0.72f+unit()*0.22f))
                BrushFamily.Calligraphy -> nib(stroke.width,stroke.width*0.18f,nibAngle)
                BrushFamily.DipPen -> dot(0f,0f,r*(0.25f+0.75f*abs(sin(direction-nibAngle))))
                BrushFamily.Halftone -> dot(0f,0f,r*0.48f)
                BrushFamily.Hatch -> nib(stroke.width, max(0.5f,stroke.width*0.08f),nibAngle)
                BrushFamily.Round -> dot(0f,0f,r)
            }
        }
        val first = stroke.points.first()
        val initial = stroke.points.drop(1).firstOrNull { it != first }
        stamp(first.x, first.y, initial?.let { atan2(it.y-first.y,it.x-first.x) } ?: 0f)
        val step = spacing(stroke); var remaining = step
        stroke.points.zipWithNext().forEach { (a,b) ->
            checkCancellation()
            val dx=b.x-a.x; val dy=b.y-a.y; val length=hypot(dx,dy)
            if (length > 0) {
                var at = remaining
                while (at <= length) { stamp(a.x+dx*at/length,a.y+dy*at/length,atan2(dy,dx)); at += step }
                remaining = at-length
            }
        }
        paint.style = Paint.Style.FILL
        // One path applies stroke opacity once across overlapping marks.
        canvas.drawPath(path,paint)
    }
}
