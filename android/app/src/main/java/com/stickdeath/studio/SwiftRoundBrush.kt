package com.stickdeath.studio

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.hypot
import kotlin.math.max

/** The Swift round brush's saved samples/settings, not Android's similarly named polyline. */
data class SwiftRoundBrush(val descriptor: String, val pressures: List<Double>) {
    private val settings get() = JSONObject(descriptor)
    val smoothing get() = settings.getDouble("smoothing")
    val pressureEnabled get() = settings.getBoolean("pressureEnabled")
    fun validate(count: Int) {
        require(count in 1..8192)
        require(pressures.size == count && pressures.all { it.isFinite() && it in 0.0..1.0 })
        val d = settings
        val keys = setOf("version", "family", "seed", "smoothing", "pressureEnabled", "tipAngleDegrees", "texture", "grain", "gradientEndColor", "tiltEnabled")
        require(d.keys().asSequence().all { it in keys || d.isNull(it) })
        require(d.getInt("version") in 1..2 && d.getString("family") == "round")
        // Round geometry never consumes the random seed. JSONObject may represent
        // unsigned Swift UInt64 values above Long.MAX_VALUE as Double.
        val seed = d.getDouble("seed")
        require(seed.isFinite() && seed >= 0 && seed <= 18446744073709551616.0 && seed == kotlin.math.floor(seed))
        require(smoothing.isFinite() && smoothing in 0.0..10.0)
        require(!d.optBoolean("tiltEnabled") && d.isNull("gradientEndColor"))
        val angle = d.getDouble("tipAngleDegrees")
        require(angle.isFinite() && angle >= 0 && angle < 180)
        for (key in listOf("texture", "grain")) require(d.getDouble(key).let { it.isFinite() && it in 0.0..1.0 })
    }
    fun json() = JSONObject().put("descriptor", settings).put("pressures", JSONArray(pressures))
    companion object {
        fun decode(j: JSONObject): SwiftRoundBrush {
            val p = j.getJSONArray("pressures")
            require(p.length() in 1..8192)
            return SwiftRoundBrush(j.getJSONObject("descriptor").toString(), (0 until p.length()).map { p.getDouble(it) })
                .also { it.validate(p.length()) }
        }
    }
    data class Dab(val x: Double, val y: Double, val pressure: Double)
    /** Direct counterpart of StudioBrushRenderer.geometry's round-family sampling. */
    fun dabs(stroke: Stroke, check: () -> Unit = {}): List<Dab> {
        validate(stroke.points.size)
        require(stroke.points.all { it.x.isFinite() && it.y.isFinite() })
        val t = stroke.brushTransform
        t.validate()
        val origin = stroke.points.first()
        val size = stroke.width.toDouble() / t.meanScale
        require(size.isFinite() && size in 0.25..512.0)
        val points = stroke.points.map { t.inverse(Point(it.x - origin.x, it.y - origin.y)) }
        val spacing = max(0.25, size * 0.15)
        val factor = 1 / (1 + smoothing * 0.4)
        val filtered = mutableListOf<Dab>()
        var x = points[0].x.toDouble(); var y = points[0].y.toDouble()
        points.forEachIndexed { index, p ->
            if (index % 256 == 0) check()
            if (index > 0) { x += (p.x - x) * factor; y += (p.y - y) * factor }
            filtered.add(Dab(x, y, pressures[index]))
        }
        val end = points.last()
        if (x != end.x.toDouble() || y != end.y.toDouble()) filtered.add(Dab(end.x.toDouble(), end.y.toDouble(), pressures.last()))
        val dabs = mutableListOf(filtered.first())
        var distance = 0.0; var nextDistance = spacing
        for (i in 1 until filtered.size) {
            check()
            val a = filtered[i - 1]; val b = filtered[i]
            val length = hypot(b.x - a.x, b.y - a.y)
            require(distance + length <= 8191 * spacing) { "Swift round stroke exceeds the 8,192-dab capacity." }
            if (length == 0.0 && pressureEnabled && a.pressure != b.pressure) {
                require(dabs.size < 8192); dabs.add(b)
            }
            while (length > 0 && nextDistance <= distance + length) {
                require(dabs.size < 8192)
                val fraction = (nextDistance - distance) / length
                dabs.add(Dab(a.x + (b.x - a.x) * fraction, a.y + (b.y - a.y) * fraction,
                    a.pressure + (b.pressure - a.pressure) * fraction))
                nextDistance += spacing
            }
            distance += length
        }
        val last = filtered.last(); val dab = dabs.last()
        if (hypot(last.x - dab.x, last.y - dab.y) > 0.000001 || (pressureEnabled && last.pressure != dab.pressure)) {
            require(dabs.size < 8192); dabs.add(last)
        }
        return dabs
    }
    fun draw(canvas: Canvas, stroke: Stroke, paint: Paint, check: () -> Unit) {
        val dabs = dabs(stroke, check)
        val checkpoint = canvas.save()
        try {
            val origin = stroke.points.first(); val t = stroke.brushTransform
            canvas.translate(origin.x, origin.y)
            canvas.concat(Matrix().apply { setValues(floatArrayOf(t.a,t.c,0f,t.b,t.d,0f,0f,0f,1f)) })
            val path = Path()
            val size = stroke.width / t.meanScale
            dabs.forEachIndexed { index, dab ->
                if (index % 128 == 0) check()
                val pressure = if (pressureEnabled) 0.15 + 0.85 * dab.pressure else 1.0
                path.addCircle(dab.x.toFloat(), dab.y.toFloat(), (size * pressure / 2).toFloat(), Path.Direction.CW)
            }
            paint.style = Paint.Style.FILL
            canvas.drawPath(path, paint) // one opacity application across the union of opaque round marks
        } finally { canvas.restoreToCount(checkpoint) }
    }
}
