package com.stickdeath.studio

import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.round

/** Peak envelopes are measured from every PCM sample, off the UI thread, and bounded by
 * AudioSource's 4 MiB limit. The LRU retains at most 16 source objects
 * (up to 16 MiB of source bytes) and 16 × 1024 amplitudes. */
private object AudioEnvelopes {
    private val cache = object : LinkedHashMap<AudioSource, FloatArray>(16, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<AudioSource, FloatArray>?) = size > 16
    }
    suspend fun get(source: AudioSource): FloatArray {
        synchronized(cache) { cache[source]?.let { return it } }
        val peaks = FloatArray(minOf(1024, source.frames))
        for (bin in peaks.indices) {
            coroutineContext.ensureActive()
            val first = (bin.toLong() * source.frames / peaks.size).toInt()
            val end = ((bin + 1L) * source.frames / peaks.size).toInt()
            var peak = 0
            for (frame in first until end) for (channel in 0 until source.channels) {
                peak = maxOf(peak, abs(source.sample(frame, channel)))
            }
            peaks[bin] = peak / 32768f
        }
        synchronized(cache) {
            cache[source] = peaks
            while (cache.keys.sumOf { it.byteCount.toLong() } > 16L * 1024 * 1024) {
                val oldest = cache.entries.iterator(); oldest.next(); oldest.remove()
            }
        }
        return peaks
    }
}

private enum class AudioDragMode { Move, TrimStart, TrimEnd }

private data class AudioDrag(val document: Document, val original: AudioClip,
    val mode: AudioDragMode, val origin: Offset, val preview: AudioClip, val viewportPointer: Offset)

/** Gesture drafts remain local; only a completed gesture produces a history command. */
@Composable
fun AudioTimeline(vm: StudioViewModel, doc: Document, enabled: Boolean,
                  selected: String?, playbackSeconds: Double? = null, onSelect: (String) -> Unit) {
    var snap by remember(doc.id) { mutableStateOf(true) }
    var drag by remember(doc.id, doc.revision, enabled) { mutableStateOf<AudioDrag?>(null) }
    val currentSelection by rememberUpdatedState(selected)
    val select by rememberUpdatedState(onSelect)
    val active by rememberUpdatedState(enabled)
    val sources = remember(doc.audioClips) { doc.audioClips.map { it.source }.distinct() }
    val envelopes by produceState<Map<AudioSource, FloatArray>>(emptyMap(), sources) {
        value = withContext(Dispatchers.Default) { sources.associateWith { AudioEnvelopes.get(it) } }
    }
    val seconds = maxOf(10.0, doc.frames.sumOf { it.hold }.toDouble() / doc.fps,
        (doc.audioClips.maxOfOrNull { it.start + it.duration } ?: 0.0) + 5.0)
    // Bound layout dimensions even for a clip near the maximum one-hour start time.
    val unitsPerSecond = minOf(72.0, 24000.0 / seconds).toFloat()
    val density = LocalDensity.current
    val scale = with(density) { unitsPerSecond.dp.toPx() }
    val rowHeight = with(density) { 64.dp.toPx() }
    val ruler = with(density) { 28.dp.toPx() }
    val handle = with(density) { 14.dp.toPx() }
    val scroll = rememberScrollState()
    var viewport by remember { mutableIntStateOf(0) }
    LaunchedEffect(doc.id) { scroll.scrollTo(0) }
    LaunchedEffect(playbackSeconds, scale, viewport) {
        val time = playbackSeconds
        if (time != null && time.isFinite() && viewport > 0) {
            val cursor = (time * scale).toInt()
            if (cursor < scroll.value || cursor > scroll.value + viewport - 24)
                scroll.scrollTo((cursor - viewport / 3).coerceIn(0, scroll.maxValue))
        }
    }
    fun preview(state: AudioDrag): AudioDrag {
        val pointer = Offset(state.viewportPointer.x + scroll.value, state.viewportPointer.y)
        val delta = (pointer.x - state.origin.x) / scale
        fun quantize(value: Double) = if (snap) round(value * doc.fps) / doc.fps else value
        val original = state.original
        val minimum = 1.0 / original.source.rate
        val clip = when (state.mode) {
            AudioDragMode.TrimStart -> {
                // Keep the right edge and source alignment fixed. Extending left
                // reveals only real source samples; it never invents leading audio.
                val earliest = maxOf(0.0, original.start - original.sourceOffset)
                val latest = minOf(3600.0, original.start + original.duration - minimum).coerceAtLeast(earliest)
                val start = quantize(original.start + delta).coerceIn(earliest, latest)
                val shift = start - original.start
                original.copy(start = start, sourceOffset = maxOf(0.0, original.sourceOffset + shift),
                    duration = original.duration - shift)
            }
            AudioDragMode.TrimEnd -> {
                val end = quantize(original.start + original.duration + delta)
                original.copy(duration = (end - original.start).coerceIn(minimum,
                    maxOf(minimum, original.source.duration - original.sourceOffset)))
            }
            AudioDragMode.Move -> original.copy(start = quantize(original.start + delta).coerceIn(0.0, 3600.0),
                track = (floor((pointer.y - ruler) / rowHeight).toInt() + 1).coerceIn(1, 4))
        }
        return state.copy(preview = clip)
    }
    val edgeWidth = with(density) { 40.dp.toPx() }
    val scrollSpeed = with(density) { 240.dp.toPx() }
    LaunchedEffect(drag?.original?.id, doc.id, doc.revision, enabled, snap, viewport) {
        if (!enabled || viewport <= 0) return@LaunchedEffect
        var previous = withFrameNanos { it }
        while (drag != null) {
            val now = withFrameNanos { it }
            val secondsElapsed = ((now - previous) / 1_000_000_000f).coerceIn(0f, 0.05f)
            previous = now
            val state = drag ?: break
            val edge = minOf(edgeWidth, viewport / 3f)
            val x = state.viewportPointer.x
            val direction = when {
                x < edge -> -((edge - x) / edge).coerceIn(0f, 1f)
                x > viewport - edge -> ((x - viewport + edge) / edge).coerceIn(0f, 1f)
                else -> 0f
            }
            if (direction != 0f) {
                scroll.scrollBy(direction * scrollSpeed * secondsElapsed)
                // A pointer-up/cancel while scrolling must never recreate its draft.
                val current = drag ?: break
                drag = preview(current)
            }
        }
    }
    val paint = remember { Paint(Paint.ANTI_ALIAS_FLAG) }
    val textSize = with(density) { 11.dp.toPx() }
    fun hit(point: Offset): AudioClip? {
        val track = floor((point.y - ruler) / rowHeight).toInt() + 1
        if (point.y < ruler || track !in 1..4) return null
        val candidates = doc.audioClips.filter { it.track == track &&
            point.x >= it.start * scale - handle / 2 &&
            point.x <= (it.start + it.duration) * scale + handle / 2 }
        return candidates.firstOrNull { it.id == currentSelection } ?: candidates.lastOrNull()
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(snap, { snap = !snap }, { Text("Snap to frames (${doc.fps} fps)") }, enabled = enabled)
    }
    Text("Tracks 1–4 · tap the ruler to select an animation frame; scroll horizontally. Tap a clip to select; hold then drag to move across time or tracks. Hold either selected edge to trim; the left edge adjusts its source offset and keeps its end fixed. Hold near either viewport edge to scroll while dragging. Use the fields below for precise timing or overlapping clips.")
    Text("${if (playbackSeconds == null) "Red marker is the selected animation frame." else "Red marker follows playback: %.2fs.".format(playbackSeconds)} Waveforms show measured source peaks before volume/mute/fades; ${if (envelopes.size < sources.size) "loading…" else "ready"}.")
    Row(Modifier.fillMaxWidth()) {
        Column(Modifier.width(30.dp).padding(top = 28.dp)) {
            for (track in 1..4) Box(Modifier.height(64.dp)) { Text("$track") }
        }
        Box(Modifier.weight(1f).onSizeChanged { viewport = it.width }.horizontalScroll(scroll)) {
            Canvas(Modifier.width((seconds * unitsPerSecond).toFloat().dp).height(284.dp)
                .background(Color(0xff19191e))
                .semantics { contentDescription = "Four-track audio timeline. Select and edit clips using the labeled controls below." }
                .pointerInput(doc.id, doc.revision, enabled, scale) {
                    if (enabled) detectTapGestures { point ->
                        if (point.y < ruler) vm.seekAudioFrame(doc, (point.x / scale).toDouble().coerceAtLeast(0.0))
                        else hit(point)?.let { select(it.id) }
                    }
                }
                .pointerInput(doc.id, doc.revision, enabled, snap, scale) {
                    if (enabled) detectDragGesturesAfterLongPress(
                        onDragStart = { point ->
                            hit(point)?.let { clip ->
                                val leftDistance = abs(point.x - (clip.start * scale).toFloat())
                                val rightDistance = abs(point.x - ((clip.start + clip.duration) * scale).toFloat())
                                val mode = if (currentSelection != clip.id) AudioDragMode.Move
                                    else if (leftDistance <= handle && leftDistance < rightDistance) AudioDragMode.TrimStart
                                    else if (rightDistance <= handle) AudioDragMode.TrimEnd
                                    else AudioDragMode.Move
                                select(clip.id)
                                drag = AudioDrag(doc, clip, mode, point, clip, Offset(point.x - scroll.value, point.y))
                            }
                        },
                        onDrag = { change, _ ->
                            drag?.let { state ->
                                change.consume()
                                drag = preview(state.copy(viewportPointer = Offset(change.position.x - scroll.value, change.position.y)))
                            }
                        },
                        onDragEnd = {
                            val completed = drag
                            drag = null
                            if (active && completed != null && completed.preview != completed.original)
                                vm.editAudio(completed.document, completed.preview)
                        },
                        onDragCancel = { drag = null }
                    )
                }) {
                paint.textSize = textSize
                paint.color = android.graphics.Color.LTGRAY
                val tickSeconds = maxOf(1, kotlin.math.ceil(55f / unitsPerSecond).toInt())
                for (second in 0..seconds.toInt() step tickSeconds) {
                    val x = second * scale
                    drawLine(Color(0xff34343c), Offset(x, ruler), Offset(x, size.height))
                    drawContext.canvas.nativeCanvas.drawText("${second}s", x + 3, ruler - 7, paint)
                }
                for (track in 0..4) drawLine(Color(0xff55555d), Offset(0f, ruler + track * rowHeight), Offset(size.width, ruler + track * rowHeight))
                val frameStart = doc.frames.takeWhile { it.id != doc.activeFrameID }.sumOf { it.hold.toLong() }.toDouble() / doc.fps
                val frameX = ((playbackSeconds ?: frameStart) * scale).toFloat()
                // Selected clip draws last so its trim handle remains reachable among overlaps.
                val clips = doc.audioClips.sortedBy { if (it.id == selected) 1 else 0 }
                for (saved in clips) {
                    val clip = drag?.takeIf { it.original.id == saved.id }?.preview ?: saved
                    val left = (clip.start * scale).toFloat()
                    val width = (clip.duration * scale).toFloat()
                    val top = ruler + (clip.track - 1) * rowHeight + 4
                    val height = rowHeight - 8
                    val chosen = clip.id == selected
                    drawRect(if (chosen) Color(0xff9a2638) else Color(0xff40303b), Offset(left, top), Size(width, height))
                    clipRect(left, top, left + width, top + height) {
                        val peaks = envelopes[clip.source]
                        if (peaks != null) {
                            val first = floor(clip.sourceOffset / clip.source.duration * peaks.size).toInt().coerceIn(0, peaks.lastIndex)
                            val last = kotlin.math.ceil((clip.sourceOffset + clip.duration) / clip.source.duration * peaks.size).toInt().coerceAtMost(peaks.size)
                            for (bin in first until last) {
                                val x = left + ((bin + .5) * clip.source.duration / peaks.size - clip.sourceOffset).toFloat() * scale
                                val amplitude = peaks[bin] * (height - 20) / 2
                                drawLine(if (clip.muted || doc.audioTracks[clip.track - 1].muted) Color.Gray else Color(0xffff9aa4), Offset(x, top + height / 2 - amplitude), Offset(x, top + height / 2 + amplitude), maxOf(1f, (clip.source.duration / peaks.size * scale).toFloat()))
                            }
                        }
                        paint.color = android.graphics.Color.WHITE
                        drawContext.canvas.nativeCanvas.drawText(clip.name + if (clip.muted || doc.audioTracks[clip.track - 1].muted) " (muted)" else "", left + 4, top + textSize, paint)
                    }
                    if (chosen) {
                        drawLine(Color(0xffff343f), Offset(left, top), Offset(left, top + height), 4.dp.toPx())
                        drawLine(Color(0xffff343f), Offset(left + width, top), Offset(left + width, top + height), 4.dp.toPx())
                    }
                }
                drawLine(Color(0xffff343f), Offset(frameX, 0f), Offset(frameX, size.height), 2.dp.toPx())
            }
        }
    }
    drag?.let { Text("${when (it.mode) { AudioDragMode.Move -> "Move"; AudioDragMode.TrimStart -> "Trim start"; AudioDragMode.TrimEnd -> "Trim end" }}: track ${it.preview.track}, start ${"%.3f".format(it.preview.start)}s, duration ${"%.3f".format(it.preview.duration)}s · release to apply") }
}
