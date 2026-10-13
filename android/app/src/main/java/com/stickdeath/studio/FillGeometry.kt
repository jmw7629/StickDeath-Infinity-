package com.stickdeath.studio

import android.graphics.Matrix
import kotlin.math.abs

/** Immutable source pixels plus a source-to-canvas affine map. Transforms never
 * resample or expand the mask; source extent remains independent of canvas size. */
data class FillGeometry(val sourceWidth: Int, val sourceHeight: Int,
    val a: Float = 1f, val b: Float = 0f, val c: Float = 0f, val d: Float = 1f,
    val tx: Float = 0f, val ty: Float = 0f) {
    fun point(x: Float, y: Float) = Point(a*x+c*y+tx, b*x+d*y+ty)
    fun then(aa: Float, bb: Float, cc: Float, dd: Float, x: Float, y: Float) = copy(
        a = aa*a+cc*b, b = bb*a+dd*b, c = aa*c+cc*d, d = bb*c+dd*d,
        tx = aa*tx+cc*ty+x, ty = bb*tx+dd*ty+y)
    fun matrix() = Matrix().apply { setValues(floatArrayOf(a,c,tx,b,d,ty,0f,0f,1f)) }
    fun validate() {
        require(sourceWidth in 1..4096 && sourceHeight in 1..4096 &&
            sourceWidth.toLong()*sourceHeight <= BucketFill.MAX_PIXELS)
        require(listOf(a,b,c,d,tx,ty).all { it.isFinite() }) { "Invalid fill transform." }
        val determinant = a.toDouble()*d-b.toDouble()*c
        require(abs(determinant) in 1e-10..1e10) { "Fill transform is too small or too large." }
    }
}

/** Nullable only for older in-memory callers. Persistence upgrades v13 using its
 * canvas extent; other callers infer the smallest valid immutable source extent. */
fun Stroke.fillGeometryOrIdentity(): FillGeometry = fillGeometry ?: requireNotNull(fill).let { spans ->
    FillGeometry(spans.maxOf { it.end }, spans.maxOf { it.y }+1)
}
fun Stroke.fillBounds(): ArtworkBounds {
    val mapping = fillGeometryOrIdentity()
    var left = Float.POSITIVE_INFINITY; var top = Float.POSITIVE_INFINITY
    var right = Float.NEGATIVE_INFINITY; var bottom = Float.NEGATIVE_INFINITY
    fun include(x: Float, y: Float) {
        val px = mapping.a*x+mapping.c*y+mapping.tx
        val py = mapping.b*x+mapping.d*y+mapping.ty
        left = minOf(left,px); top = minOf(top,py)
        right = maxOf(right,px); bottom = maxOf(bottom,py)
    }
    requireNotNull(fill).forEach { span ->
        // Pixel edges, including the exclusive right/bottom, are authoritative.
        // No per-pixel expansion or corner collections during gesture previews.
        include(span.start.toFloat(),span.y.toFloat())
        include(span.end.toFloat(),span.y.toFloat())
        include(span.start.toFloat(),(span.y+1).toFloat())
        include(span.end.toFloat(),(span.y+1).toFloat())
    }
    return ArtworkBounds(left,top,right,bottom)
}
fun Stroke.transformFill(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float): Stroke {
    require(tool == Tool.Fill)
    val transformed = copy(fillGeometry = fillGeometryOrIdentity().then(a,b,c,d,tx,ty))
    // Fill's legacy seed is metadata, not its selection geometry. Keep the
    // required point inside the resulting object even for disconnected masks.
    return transformed.copy(points = listOf(transformed.fillBounds().center))
}
