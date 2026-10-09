package com.stickdeath.studio

import java.util.UUID

fun newID(): String = UUID.randomUUID().toString()
data class Point(val x: Float, val y: Float)
enum class Tool { Pencil, Eraser, Line, Rectangle, Ellipse, Triangle, Diamond, Star, Arrow, Eyedropper, Lasso, Move, Hand;
    val isClosedShape get() = this in listOf(Rectangle, Ellipse, Triangle, Diamond, Star, Arrow)
    val isShape get() = this == Line || isClosedShape
    val isDrawing get() = this == Pencil || this == Eraser || isShape
    val isSelectable get() = isDrawing && this != Eraser
}
data class Stroke(val id: String = newID(), val layerID: String, val points: List<Point>,
                  val color: Int, val width: Float, val tool: Tool, val filled: Boolean = false, val opacity: Float = 1f,
                  val brush: BrushFamily = BrushFamily.Round, val brushSeed: Int = id.hashCode(), val brushTransform: BrushTransform = BrushTransform(),
                  val nibAngle: Float = if (brush == BrushFamily.Hatch) -45f else 45f)
enum class LayerBlend(val label: String, val needsModernBlend: Boolean = false) {
    Normal("Normal"), Multiply("Multiply", true), Screen("Screen"), Overlay("Overlay"), Darken("Darken"), Lighten("Lighten"),
    ColorDodge("Color Dodge", true), ColorBurn("Color Burn", true), HardLight("Hard Light", true), SoftLight("Soft Light", true),
    Difference("Difference", true), Exclusion("Exclusion", true), Hue("Hue", true), Saturation("Saturation", true),
    Color("Color", true), Luminosity("Luminosity", true)
}
data class Layer(val id: String = newID(), val name: String, val visible: Boolean = true,
                 val locked: Boolean = false, val opacity: Float = 1f, val blend: LayerBlend = LayerBlend.Normal)
data class OnionSettings(val enabled: Boolean = false, val previous: Int = 1, val next: Int = 1,
                         val opacity: Float = 0.25f, val tinted: Boolean = true) {
    fun validate() {
        require(previous in 0..4 && next in 0..4 && opacity.isFinite() && opacity in 0f..1f)
    }
}
data class GridSettings(val enabled: Boolean = false, val spacing: Int = 32, val opacity: Float = 0.25f, val color: Int = 0xff777777.toInt()) {
    fun validate() { require(spacing in 8..256 && opacity.isFinite() && opacity in 0f..1f && color ushr 24 == 255) }
}
data class Frame(val id: String = newID(), val strokes: List<Stroke> = emptyList(), val hold: Int = 1)
/** Front-to-back layer ordering matches the native Swift document convention.
 * The storage envelope is Android-local v10 (reads v1–v9), not an advertised .sdi interchange codec. */
data class Document(val id: String, val name: String, val width: Int, val height: Int, val fps: Int,
    val frames: List<Frame>, val layers: List<Layer>, val activeFrameID: String,
    val activeLayerID: String, val revision: Long = 0, val modified: Long = System.currentTimeMillis(), val onion: OnionSettings = OnionSettings(), val backgroundColor: Int = -1, val grid: GridSettings = GridSettings()) {
    val frame get() = frames.first { it.id == activeFrameID }
    val layer get() = layers.first { it.id == activeLayerID }
    val pointCount get() = frames.sumOf { f -> f.strokes.sumOf { it.points.size } }
    fun validated(): Document {
        UUID.fromString(id)
        onion.validate(); grid.validate()
        require(backgroundColor ushr 24 == 255) { "Choose an opaque project background color." }
        require(name.isNotBlank() && name.length <= 120) { "Use a project name of 1–120 characters." }
        require(width in 16..4096 && height in 16..4096 && fps in 1..60)
        require(frames.size in 1..500 && layers.size in 1..32)
        require(frames.map { it.id }.toSet().size == frames.size)
        require(layers.map { it.id }.toSet().size == layers.size)
        require(frames.any { it.id == activeFrameID } && layers.any { it.id == activeLayerID })
        require(pointCount <= 100_000 && frames.sumOf { it.strokes.size } <= 10_000) { "Project drawing capacity reached." }
        layers.forEach { require(it.name.isNotBlank() && it.name.length <= 80 && it.opacity.isFinite() && it.opacity in 0f..1f) }
        frames.forEach { frame ->
            require(frame.hold in 1..600 && frame.strokes.map { it.id }.toSet().size == frame.strokes.size)
            var brushWork = 0
            frame.strokes.forEach { stroke ->
                require(layers.any { it.id == stroke.layerID })
                require(stroke.tool.isDrawing)
                require(stroke.tool == Tool.Pencil || stroke.brush == BrushFamily.Round)
                require(stroke.nibAngle.isFinite() && stroke.nibAngle in -180f..180f)
                stroke.brushTransform.validate()
                require(stroke.brush != BrushFamily.Round || stroke.brushTransform == BrushTransform())
                require(stroke.opacity.isFinite() && stroke.opacity in 0f..1f)
                require(!stroke.filled || stroke.tool.isClosedShape)
                if (stroke.tool == Tool.Line) require(stroke.points.size == 2)
                if (stroke.tool.isClosedShape) {
                    val expected = when (stroke.tool) {
                        Tool.Rectangle, Tool.Diamond -> 5
                        Tool.Ellipse -> 129
                        Tool.Triangle -> 4
                        Tool.Star -> 11
                        Tool.Arrow -> 8
                        else -> error("Invalid closed shape")
                    }
                    require(stroke.points.size == expected)
                    require(stroke.points.first() == stroke.points.last())
                }
                require(stroke.width.isFinite() && stroke.width in 1f..128f && stroke.points.size in 1..8192)
                require(stroke.points.all { it.x.isFinite() && it.y.isFinite() && it.x in 0f..width.toFloat() && it.y in 0f..height.toFloat() })
                brushWork += BrushRenderer.work(stroke)
                require(brushWork <= 200_000) { "Frame textured-brush capacity reached." }
            }
        }
        return this
    }
    companion object {
        fun create(name: String, width: Int, height: Int, fps: Int, backgroundColor: Int = -1): Document {
            val layer = Layer(name = "Layer 1"); val frame = Frame()
            return Document(newID(), name.trim(), width, height, fps, listOf(frame), listOf(layer), frame.id, layer.id, backgroundColor = backgroundColor).validated()
        }
    }
}

/** Shapes are editable canonical paths so rotation, clipboard and export share
 * the same geometry. A gesture previews only its start/end, not every sample. */
object ShapePath {
    fun points(tool: Tool, start: Point, end: Point, equalSides: Boolean): List<Point> {
        var dx = end.x - start.x; var dy = end.y - start.y
        if (equalSides && tool != Tool.Line) {
            val side = minOf(kotlin.math.abs(dx), kotlin.math.abs(dy))
            dx = if (dx < 0) -side else side; dy = if (dy < 0) -side else side
        }
        val finish = Point(start.x + dx, start.y + dy)
        if (tool == Tool.Line) return if (start == finish) emptyList() else listOf(start, finish)
        if (kotlin.math.abs(dx) < 0.1f || kotlin.math.abs(dy) < 0.1f) return emptyList()
        return when (tool) {
            Tool.Rectangle -> listOf(start, Point(finish.x, start.y), finish, Point(start.x, finish.y), start)
            Tool.Triangle -> listOf(Point(start.x + dx/2, start.y), finish, Point(start.x, finish.y), Point(start.x + dx/2, start.y))
            Tool.Diamond -> listOf(Point(start.x + dx/2, start.y), Point(finish.x, start.y + dy/2),
                Point(start.x + dx/2, finish.y), Point(start.x, start.y + dy/2), Point(start.x + dx/2, start.y))
            Tool.Arrow -> {
                val outline = listOf(Point(start.x, start.y + dy*0.3f), Point(start.x + dx*0.6f, start.y + dy*0.3f),
                    Point(start.x + dx*0.6f, start.y), Point(finish.x, start.y + dy/2),
                    Point(start.x + dx*0.6f, finish.y), Point(start.x + dx*0.6f, start.y + dy*0.7f),
                    Point(start.x, start.y + dy*0.7f))
                outline + outline.first()
            }
            Tool.Star -> {
                val cx = start.x + dx/2; val cy = start.y + dy/2
                val outline = (0 until 10).map { index ->
                    val angle = -Math.PI/2 + index*Math.PI/5
                    val radius = if (index % 2 == 0) 1.0 else 0.45
                    Point(cx + (dx/2 * kotlin.math.cos(angle) * radius).toFloat(),
                        cy + (dy/2 * kotlin.math.sin(angle) * radius).toFloat())
                }
                outline + outline.first()
            }
            Tool.Ellipse -> {
                val cx = (start.x + finish.x) / 2; val cy = (start.y + finish.y) / 2
                val rx = kotlin.math.abs(dx) / 2; val ry = kotlin.math.abs(dy) / 2
                val outline = (0 until 128).map { n ->
                    val angle = n * 2 * Math.PI / 128
                    Point(cx + rx * kotlin.math.cos(angle).toFloat(), cy + ry * kotlin.math.sin(angle).toFloat())
                }
                outline + outline.first()
            }
            else -> emptyList()
        }
    }
}

/** Gesture-only stabilizer. Output points become the saved canonical stroke;
 * rendering/export never apply a second smoothing pass. Zero follows input. */
class StrokeSmoother(start: Point, amount: Float) {
    private val weight: Float
    private var previous = start
    init {
        require(amount.isFinite() && amount in 0f..10f)
        weight = 1f / (1f + amount)
    }
    fun next(point: Point): Point {
        require(point.x.isFinite() && point.y.isFinite())
        previous = Point(previous.x + (point.x - previous.x) * weight,
            previous.y + (point.y - previous.y) * weight)
        return previous
    }
}

/** Monotonic playback lookup; never expands held frames or accumulates delays. */
class FramePlaybackClock(document: Document) {
    private val starts = LongArray(document.frames.size)
    val totalTicks: Long
    private val fps = document.fps
    private val startTick: Long
    init {
        require(document.frames.isNotEmpty() && fps in 1..60)
        var sum = 0L
        document.frames.forEachIndexed { index, frame ->
            require(frame.hold in 1..600)
            starts[index] = sum; sum += frame.hold
        }
        totalTicks = sum
        startTick = starts[document.frames.indexOfFirst { it.id == document.activeFrameID }.also { require(it >= 0) }]
    }
    fun tickAt(elapsedNanos: Long): Long {
        val elapsed = elapsedNanos.coerceAtLeast(0)
        // Reduce whole seconds before multiplication to avoid uptime overflow.
        val ticks = ((elapsed / 1_000_000_000L) % totalTicks) * fps +
            (elapsed % 1_000_000_000L) * fps / 1_000_000_000L
        return (startTick + ticks) % totalTicks
    }
    fun frameAt(elapsedNanos: Long): Int {
        val tick = tickAt(elapsedNanos)
        var low = 0; var high = starts.lastIndex
        while (low < high) {
            val middle = (low + high + 1) / 2
            if (starts[middle] <= tick) low = middle else high = middle - 1
        }
        return low
    }
}


enum class MirrorMode { Off, Vertical, Horizontal, Both }
/** Baked editable marks share the ordinary renderer, selection, history and export path. */
fun Stroke.mirrored(canvasWidth: Int, canvasHeight: Int, mode: MirrorMode): List<Stroke> {
    if (mode == MirrorMode.Off || tool == Tool.Eraser) return listOf(this)
    val result = mutableListOf(this)
    fun reflect(horizontal: Boolean, vertical: Boolean) {
        val reflected = points.map { Point(if (horizontal) canvasWidth - it.x else it.x, if (vertical) canvasHeight - it.y else it.y) }
        // Avoid double opacity for artwork lying exactly on a mirror axis.
        if (result.none { it.points == reflected || it.points == reflected.asReversed() }) result += copy(id = newID(), points = reflected, brushTransform = if (brush == BrushFamily.Round) brushTransform else brushTransform.then(if (horizontal) -1f else 1f,0f,0f,if (vertical) -1f else 1f))
    }
    if (mode == MirrorMode.Vertical || mode == MirrorMode.Both) reflect(true, false)
    if (mode == MirrorMode.Horizontal || mode == MirrorMode.Both) reflect(false, true)
    if (mode == MirrorMode.Both) reflect(true, true)
    return result
}
