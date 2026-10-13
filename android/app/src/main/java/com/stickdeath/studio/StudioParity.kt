package com.stickdeath.studio

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

// Pure-Kotlin counterparts of iOS Studio model rules (schema 35). No Android imports, so the
// JVM unit tests under app/src/test exercise exactly the code the app ships.

/** iOS `LayerLockMode` raw values. Full refuses every edit; Position allows new marks but no
 * transforms; Alpha allows only brush paint that keeps the layer's existing coverage. */
enum class LayerLockMode(val label: String, val swiftName: String) {
    Free("Unlocked", "free"), Full("Locked", "full"), Position("Position lock", "position"), Alpha("Alpha lock", "alpha");

    /** New pencil/shape/text marks and pasted artwork (iOS `commit`: free or position). */
    val allowsNewMarks get() = this == Free || this == Position
    /** Erasing, filling and importing images (iOS requires `free`). */
    val allowsErase get() = this == Free
    /** Move, resize, rotate, flip, nudge, align, reorder, layer transfer and appearance edits. */
    val allowsTransform get() = this == Free
    /** Explicit deletion of selected artwork (iOS: not full, not alpha). */
    val allowsDelete get() = this == Free || this == Position
    val isFull get() = this == Full

    companion object {
        fun fromSwift(stored: String): LayerLockMode? = entries.firstOrNull { it.swiftName.equals(stored, ignoreCase = true) }
        /** Local envelope reader: the iOS raw value or an Android enum name; anything else rejects. */
        fun fromStored(stored: String): LayerLockMode = fromSwift(stored) ?: entries.firstOrNull { it.name == stored }
            ?: throw IllegalArgumentException("Unsupported layer lock mode \"$stored\"; original preserved.")
    }
}

/** PhotoCraft layer label colours (StudioLayerLabelColor.swift), stored as the iOS `colorLabel` hex. */
enum class LayerLabel(val hex: String, val cellHex: String) {
    Red("#FC5D5B", "#9F2F30"), Orange("#F79744", "#934F0C"), Yellow("#DCD64B", "#99780C"), Green("#85DC6A", "#4E712E"),
    Seafoam("#1C8488", "#0B544F"), Blue("#78ADF6", "#415B87"), Indigo("#544BE7", "#36348E"), Magenta("#CC1A7E", "#981B51"),
    Fuchsia("#B014C0", "#710F74"), Violet("#9176D5", "#5D3F8E"), Gray("#9C9C9C", "#575757");

    val title get() = name
    val argb: Int get() = (0xff000000L or hex.substring(1).toLong(16)).toInt()
    val cellArgb: Int get() = (0xff000000L or cellHex.substring(1).toLong(16)).toInt()

    companion object {
        /** Case-insensitive match against the eleven PhotoCraft swatches; other hex strings stay null. */
        fun fromHex(hex: String?): LayerLabel? {
            val value = hex?.trim()?.uppercase() ?: return null
            return entries.firstOrNull { it.hex == value }
        }
    }
}

/** iOS `StudioImageCrop`: a normalized rectangle of the upright source, before quarter turns. */
data class ImageCrop(val x: Double, val y: Double, val width: Double, val height: Double) {
    val isFull get() = x == 0.0 && y == 0.0 && width == 1.0 && height == 1.0
    fun validate() {
        require(listOf(x, y, width, height).all { it.isFinite() } && x >= 0 && y >= 0 &&
            width >= MINIMUM && height >= MINIMUM && x + width <= 1 + 1e-9 && y + height <= 1 + 1e-9) {
            "Choose a crop inside the original image, at least 1% wide and high."
        }
    }
    companion object {
        const val MINIMUM = 0.01
        val full = ImageCrop(0.0, 0.0, 1.0, 1.0)
        /** Edge fractions (left, top, right, bottom in 0…1) as the sliders express them. */
        fun fromEdges(left: Double, top: Double, right: Double, bottom: Double) = ImageCrop(left, top, right - left, bottom - top)
    }
}

/** Mapping between the displayed image quad, its crop and clockwise quarter turns. All
 * coordinates are fractions; callers scale to source pixels or canvas points. */
object ImageGeometry {
    /** Display fraction (u right, v down) → crop-relative fraction (a, b) for [turns] clockwise content turns. */
    fun displayToCrop(u: Double, v: Double, turns: Int): Pair<Double, Double> = when (((turns % 4) + 4) % 4) {
        0 -> u to v
        1 -> v to 1 - u
        2 -> 1 - u to 1 - v
        else -> 1 - v to u
    }
    /** Inverse of [displayToCrop]. */
    fun cropToDisplay(a: Double, b: Double, turns: Int): Pair<Double, Double> = when (((turns % 4) + 4) % 4) {
        0 -> a to b
        1 -> 1 - b to a
        2 -> 1 - a to 1 - b
        else -> b to 1 - a
    }
    /** Source-pixel positions shown at the quad's top-left, top-right and bottom-left corners, as
     * six floats (x0,y0,x1,y1,x3,y3) for `Matrix.setPolyToPoly` against points 0, 1 and 3. */
    fun sourceTriangle(sourceWidth: Int, sourceHeight: Int, crop: ImageCrop, turns: Int): FloatArray {
        crop.validate()
        val result = FloatArray(6)
        listOf(0.0 to 0.0, 1.0 to 0.0, 0.0 to 1.0).forEachIndexed { index, (u, v) ->
            val (a, b) = displayToCrop(u, v, turns)
            result[index * 2] = ((crop.x + a * crop.width) * sourceWidth).toFloat()
            result[index * 2 + 1] = ((crop.y + b * crop.height) * sourceHeight).toFloat()
        }
        return result
    }
    /** The sub-quad of [quad] (four canvas corners, image TL/TR/BR/BL) that shows [next] when the
     * quad currently shows [current] with [turns]; content scale and rotation are unchanged. */
    fun recroppedQuad(quad: List<Point>, current: ImageCrop, next: ImageCrop, turns: Int): List<Point> {
        require(quad.size == 4)
        current.validate(); next.validate()
        val o = quad[0]; val rx = quad[1].x - o.x; val ry = quad[1].y - o.y; val dx = quad[3].x - o.x; val dy = quad[3].y - o.y
        return listOf(0.0 to 0.0, 1.0 to 0.0, 1.0 to 1.0, 0.0 to 1.0).map { (u2, v2) ->
            // Each corner of the new display quad shows this fraction of the new crop …
            val (a2, b2) = displayToCrop(u2, v2, turns)
            val sx = next.x + a2 * next.width; val sy = next.y + b2 * next.height
            // … which sits here inside the current crop, and therefore here on the current quad.
            val a = (sx - current.x) / current.width; val b = (sy - current.y) / current.height
            val (u, v) = cropToDisplay(a, b, turns)
            Point((o.x + u * rx + v * dx).toFloat(), (o.y + u * ry + v * dy).toFloat())
        }
    }
    /** An upright box centred like [quad] whose sides are swapped, for a 90° content turn. */
    fun turnedQuad(quad: List<Point>): List<Point> {
        require(quad.size == 4)
        val width = hypot(quad[1].x - quad[0].x, quad[1].y - quad[0].y)
        val height = hypot(quad[3].x - quad[0].x, quad[3].y - quad[0].y)
        val cx = (quad[0].x + quad[2].x) / 2; val cy = (quad[0].y + quad[2].y) / 2
        val halfW = height / 2; val halfH = width / 2
        return listOf(Point(cx - halfW, cy - halfH), Point(cx + halfW, cy - halfH), Point(cx + halfW, cy + halfH), Point(cx - halfW, cy + halfH))
    }
}

/** Soft eraser = four stacked destination-out passes with shrinking width, so the edge feathers
 * without a mask filter (identical on software export canvases and hardware previews). */
object SoftEraser {
    data class Pass(val widthFactor: Float, val alpha: Float)
    const val PASSES = 4
    /** Per-pass alpha so the fully covered centre removes exactly [strength] of the layer. */
    fun passAlpha(strength: Float): Float {
        require(strength.isFinite() && strength in 0f..1f)
        return (1.0 - (1.0 - strength).pow(1.0 / PASSES)).toFloat()
    }
    fun passes(strength: Float): List<Pass> {
        val alpha = passAlpha(strength)
        return (1..PASSES).map { Pass(0.25f + 0.75f * it / PASSES, alpha) }
    }
    /** Coverage removed where [passesCovering] of the four passes overlap (centre = 4, rim = 1). */
    fun removedFraction(strength: Float, passesCovering: Int): Double {
        require(passesCovering in 0..PASSES)
        return 1.0 - (1.0 - passAlpha(strength).toDouble()).pow(passesCovering)
    }
}

/** Ruler tool: constrain a drawing gesture to a straight line through its first point. */
enum class RulerMode(val label: String) {
    Off("Off"), Horizontal("Horizontal"), Vertical("Vertical"), Diagonal("45°"), FirstDirection("Lock first direction")
}
class RulerConstraint(private val anchor: Point, private val mode: RulerMode) {
    private var lockedAngle: Double? = when (mode) {
        RulerMode.Horizontal -> 0.0
        RulerMode.Vertical -> Math.PI / 2
        else -> null
    }
    /** For [RulerMode.FirstDirection], the angle locks once the pointer moves at least this far. */
    private val lockDistance = 6f
    fun constrain(point: Point): Point {
        require(point.x.isFinite() && point.y.isFinite())
        if (mode == RulerMode.Off) return point
        val dx = point.x - anchor.x; val dy = point.y - anchor.y
        val angle = lockedAngle ?: when (mode) {
            RulerMode.Diagonal -> {
                // Nearest of the four 45° diagonals, re-evaluated until the gesture commits to one.
                val a = Math.atan2(dy.toDouble(), dx.toDouble())
                val snapped = Math.round((a - Math.PI / 4) / (Math.PI / 2)) * (Math.PI / 2) + Math.PI / 4
                if (hypot(dx, dy) >= lockDistance) lockedAngle = snapped
                snapped
            }
            RulerMode.FirstDirection -> {
                if (hypot(dx, dy) < lockDistance) return anchor
                // Snap the first clear direction to 15° steps so near-horizontal lines are level.
                val a = Math.atan2(dy.toDouble(), dx.toDouble())
                val snapped = Math.round(a / (Math.PI / 12)) * (Math.PI / 12)
                lockedAngle = snapped
                snapped
            }
            else -> 0.0
        }
        val ux = cos(angle); val uy = sin(angle)
        val along = dx * ux + dy * uy
        return Point((anchor.x + along * ux).toFloat(), (anchor.y + along * uy).toFloat())
    }
}

/** Audio bounds shared with iOS `StudioDocument.validate()`: clips and source trims are capped at
 * 300 s. Android's byte caps (4 MiB per embedded source, 8 MiB per project, 24 MiB file) still
 * apply, so long clips must be short in sample rate/channels or they are rejected by size. */
object AudioLimits {
    const val MAX_CLIP_SECONDS = 300.0
    const val MAX_TIMELINE_START_SECONDS = 3600.0
    const val MAX_SOURCE_BYTES = 4 * 1024 * 1024
    const val MAX_PROJECT_AUDIO_BYTES = 8L * 1024 * 1024
    /** Longest PCM16 clip that fits the per-source byte cap at [rate] Hz with [channels]. */
    fun secondsFittingSource(rate: Int, channels: Int): Double {
        require(rate > 0 && channels in 1..2)
        return minOf(MAX_CLIP_SECONDS, (MAX_SOURCE_BYTES - 44).toDouble() / (rate * channels * 2))
    }
    fun durationMessage(): String = "Use nonempty audio up to ${MAX_CLIP_SECONDS.toInt()} seconds (and at most 4 MiB of PCM; long clips need a low sample rate or mono)."
}

/** GIF frame delays: each cumulative boundary rounds to the nearest centisecond (ties upward) so the
 * total drifts by at most 5 ms. Shared by the encoder and the receipt manifest. */
object GifTiming {
    fun delaysCentiseconds(holds: List<Int>, fps: Int): List<Int> {
        require(fps in 1..60 && holds.isNotEmpty() && holds.all { it in 1..600 })
        var ticks = 0L; var previousEnd = 0L
        return holds.map { hold ->
            ticks += hold
            val end = (ticks * 100 + fps / 2) / fps
            (end - previousEnd).toInt().also { previousEnd = end }
        }
    }
}

/** Port of iOS `StudioExportFilename` (#185): ASCII letters, digits, '-' and '_' are kept; any other
 * run collapses to one '-'; trimmed to 40 characters; empty falls back to "animation". */
object StudioExportFilename {
    const val FALLBACK = "animation"
    const val MAXIMUM_LENGTH = 40
    private fun allowed(c: Char) = c in '0'..'9' || c in 'A'..'Z' || c in 'a'..'z' || c == '_' || c == '-'
    fun base(projectName: String?): String {
        if (projectName == null) return FALLBACK
        val result = StringBuilder(); var separatorPending = false
        for (c in projectName) {
            if (allowed(c)) {
                if (separatorPending && result.isNotEmpty()) result.append('-')
                separatorPending = false
                result.append(c)
            } else separatorPending = true
            if (result.length >= MAXIMUM_LENGTH) break
        }
        var text = result.toString()
        if (text.length > MAXIMUM_LENGTH) text = text.substring(0, MAXIMUM_LENGTH)
        text = text.trimEnd('-').trimStart('-')
        return text.ifEmpty { FALLBACK }
    }
    fun isValid(base: String) = base.isNotEmpty() && base.length <= MAXIMUM_LENGTH && !base.startsWith("-") &&
        !base.endsWith("-") && base.all(::allowed)
}

/** Swift `Date` encodes as seconds since 2001-01-01T00:00:00Z. */
object SwiftDates {
    const val REFERENCE_EPOCH_MILLIS = 978_307_200_000L
    fun fromEpochMillis(millis: Long): Double = (millis - REFERENCE_EPOCH_MILLIS) / 1000.0
    fun toEpochMillis(seconds: Double): Long {
        require(seconds.isFinite() && abs(seconds) < 1e13)
        return Math.round(seconds * 1000) + REFERENCE_EPOCH_MILLIS
    }
}

/** Percent label helper shared by UI and Spatter receipts. */
internal fun Float.percentLabel(): String = "${(this * 100).roundToInt()}%"
