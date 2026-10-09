package com.stickdeath.studio

import kotlin.math.*

/** Transient object selection; originals remain editable strokes, never screenshots. */
data class ArtworkBounds(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    val center get() = Point((left + right) / 2, (top + bottom) / 2)
    val width get() = right - left
    val height get() = bottom - top
    fun contains(p: Point) = p.x in left..right && p.y in top..bottom
    fun union(b: ArtworkBounds) = ArtworkBounds(min(left,b.left), min(top,b.top), max(right,b.right), max(bottom,b.bottom))
    companion object {
        fun of(stroke: Stroke): ArtworkBounds {
            if (stroke.tool == Tool.Fill) return stroke.fillBounds()
            val radius = if (stroke.tool == Tool.Text || stroke.tool == Tool.Image) 0f else stroke.textureRadius()
            return ArtworkBounds(stroke.points.minOf { it.x } - radius, stroke.points.minOf { it.y } - radius,
                stroke.points.maxOf { it.x } + radius, stroke.points.maxOf { it.y } + radius)
        }
    }
}

data class ArtworkTransform(val dx: Float = 0f, val dy: Float = 0f, val scale: Float = 1f, val angle: Float = 0f, val heightScale: Float = scale) {
    fun apply(frame: Frame, ids: Set<String>, bounds: ArtworkBounds): Frame {
        require(listOf(dx,dy,scale,heightScale,angle).all { it.isFinite() } && scale in 0.25f..4f && heightScale in 0.25f..4f && angle in -360f..360f)
        val a = angle * PI / 180
        // Exact quarter turns must not spill a boundary-touching selection
        // outside the canvas because cos(90 degrees) is a tiny nonzero float.
        val turn = ((angle % 360f) + 360f) % 360f
        val (c, s) = when (turn) {
            0f -> 1f to 0f
            90f -> 0f to 1f
            180f -> -1f to 0f
            270f -> 0f to -1f
            else -> cos(a).toFloat() to sin(a).toFloat()
        }
        val center = bounds.center
        return frame.copy(strokes = frame.strokes.map { stroke ->
            if (stroke.id !in ids) stroke else if (stroke.tool == Tool.Fill) {
                stroke.transformFill(c*scale,s*scale,-s*heightScale,c*heightScale,
                    center.x-c*scale*center.x+s*heightScale*center.y+dx,
                    center.y-s*scale*center.x-c*heightScale*center.y+dy)
            } else {
                val width = stroke.width * sqrt(scale * heightScale)
                if (stroke.brush != BrushFamily.Round) require(width in 1f..128f) { "Transformed brush width must remain 1–128 pixels." }
                stroke.copy(width = width.coerceIn(1f,128f),
                    brushTransform = if (stroke.brush == BrushFamily.Round) stroke.brushTransform else stroke.brushTransform.then(c*scale,s*scale,-s*heightScale,c*heightScale), points = stroke.points.map {
                val x = (it.x-center.x)*scale; val y = (it.y-center.y)*heightScale
                Point(center.x + x*c-y*s+dx, center.y + x*s+y*c+dy)
            })
            }
        })
    }
}

enum class ArtworkAlignment(val label: String) { Left("Left"), CenterX("Center horizontally"), Right("Right"), Top("Top"), CenterY("Center vertically"), Bottom("Bottom") }

enum class ArtworkOrder { Forward, Backward, Front, Back }
enum class SelectionShape { Freehand, Rectangle }
enum class SelectionMode { Replace, Add, Subtract }
object ArtworkSelection {
    fun eligible(frame: Frame, layers: List<Layer>): Set<String> {
        val editable = layers.filter { it.visible && !it.locked && it.opacity > 0f }.map { it.id }.toSet()
        return frame.strokes.filter { it.layerID in editable && it.tool.isSelectable && it.opacity > 0f && (it.color ushr 24) > 0 }
            .map { it.id }.toSet()
    }
    fun bounds(frame: Frame, ids: Set<String>): ArtworkBounds? = frame.strokes.filter { it.id in ids }
        .map { ArtworkBounds.of(it) }.reduceOrNull { a,b -> a.union(b) }
    fun enclosed(frame: Frame, layers: List<Layer>, polygon: List<Point>,
                 shape: SelectionShape = SelectionShape.Freehand): Set<String> {
        require(polygon.size in 3..1024) { "Use a simpler closed outline (up to 1,024 points)." }
        require(polygon.all { it.x.isFinite() && it.y.isFinite() })
        val eligible = eligible(frame, layers)
        var remainingWork = 2_000_000
        fun spend() {
            require(remainingWork >= polygon.size) { "This selection is too complex. Use Rectangle or select fewer strokes." }
            remainingWork -= polygon.size
        }
        fun inside(p: Point): Boolean {
            spend()
            var result = false; var previous = polygon.last()
            polygon.forEach { next ->
                val dx = next.x - previous.x; val dy = next.y - previous.y
                val lengthSquared = dx*dx + dy*dy
                val projection = (p.x-previous.x)*dx + (p.y-previous.y)*dy
                if (lengthSquared > 0f && projection in 0f..lengthSquared &&
                    abs((p.x-previous.x)*dy - (p.y-previous.y)*dx) <= 0.0001f * kotlin.math.sqrt(lengthSquared)) return true
                if ((next.y > p.y) != (previous.y > p.y) &&
                    p.x < (previous.x-next.x)*(p.y-next.y)/(previous.y-next.y)+next.x) result = !result
                previous = next
            }
            return result
        }
        fun enclosesStroke(stroke: Stroke): Boolean {
            if (shape != SelectionShape.Freehand || stroke.tool !in listOf(Tool.Pencil, Tool.Line)) return false
            if (!stroke.points.all(::inside)) return false
            return stroke.points.zipWithNext().all { (a, b) ->
                spend()
                val dx = b.x-a.x; val dy = b.y-a.y
                val cuts = mutableListOf(0f, 1f)
                polygon.indices.forEach { index ->
                    val c = polygon[index]; val d = polygon[(index+1)%polygon.size]
                    val ex = d.x-c.x; val ey = d.y-c.y
                    val determinant = dx*ey-dy*ex
                    if (abs(determinant) > 0.0000001f) {
                        val cx = c.x-a.x; val cy = c.y-a.y
                        val t = (cx*ey-cy*ex)/determinant
                        val u = (cx*dy-cy*dx)/determinant
                        if (t > 0f && t < 1f && u in 0f..1f) cuts.add(t)
                    }
                }
                cuts.sort()
                cuts.zipWithNext().all { (low, high) ->
                    val t = (low+high)/2
                    inside(Point(a.x+dx*t,a.y+dy*t))
                }
            }
        }
        return frame.strokes.filter { stroke ->
            if (stroke.id !in eligible) false else {
                val b = ArtworkBounds.of(stroke)
                // Whole-object enclosure also rejects narrow concave slits whose
                // edges cross the bounds while every corner remains inside.
                fun crossesInterior(a: Point, end: Point): Boolean {
                    var lower = 0f; var upper = 1f
                    fun axis(start: Float, delta: Float, low: Float, high: Float): Boolean {
                        if (abs(delta) < 0.000001f) return start > low && start < high
                        val t1 = (low-start)/delta; val t2 = (high-start)/delta
                        lower = max(lower,min(t1,t2)); upper = min(upper,max(t1,t2))
                        return lower < upper
                    }
                    return axis(a.x,end.x-a.x,b.left+0.0001f,b.right-0.0001f) &&
                        axis(a.y,end.y-a.y,b.top+0.0001f,b.bottom-0.0001f) && lower < upper
                }
                spend()
                val enclosesBounds = listOf(Point(b.left,b.top),Point(b.right,b.top),Point(b.right,b.bottom),Point(b.left,b.bottom)).all(::inside) &&
                    polygon.indices.none { crossesInterior(polygon[it],polygon[(it+1)%polygon.size]) }
                enclosesBounds || enclosesStroke(stroke)
            }
        }.map { it.id }.toSet()
    }
}
