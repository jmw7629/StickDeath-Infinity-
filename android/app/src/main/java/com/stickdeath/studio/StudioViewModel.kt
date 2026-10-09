package com.stickdeath.studio

import android.app.Application
import android.net.Uri
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class StudioViewModel(application: Application) : AndroidViewModel(application) {
    private val store = ProjectStore(application)
    var importingAudio by mutableStateOf(false); private set
    var previewingAudio by mutableStateOf(false); private set
    private var audioCapture: Document? = null
    private var audioImportJob: Job? = null
    private var audioPreviewJob: Job? = null
    private var sceneAudioJob: Job? = null
    private val audioPreviewMutex = Mutex()
    private val audioImportMutex = Mutex()
    private var audioGeneration = 0L
    fun beginAudioImport(): Boolean {
        val captured = document ?: return false
        if (closing || importingAudio) return false
        stopAudioPreview()
        audioCapture = captured; importingAudio = true
        return true
    }
    fun cancelAudioImport() {
        audioGeneration++; audioImportJob?.cancel(); audioImportJob = null
        audioCapture = null; importingAudio = false
    }
    fun importAudio(uri: Uri?) {
        val captured = audioCapture ?: return
        if (uri == null) { cancelAudioImport(); return }
        audioCapture = null
        loadAudioIntoProject(captured, "Audio ${captured.audioClips.size + 1}") {
            getApplication<Application>().contentResolver.openInputStream(uri)?.use { AudioSource.read(it) }
                ?: error("Files could not open this WAV.")
        }
    }
    fun addBundledSound(captured: Document, sound: BundledSound) {
        if (document != captured || !beginAudioImport()) return
        audioCapture = null
        loadAudioIntoProject(captured, sound.title, AssetCredit(sound.id, sound.title, sound.author, sound.sourceURL, sound.sha256)) { BundledSounds.source(getApplication<Application>(), sound) }
    }
    private fun loadAudioIntoProject(captured: Document, name: String, credit: AssetCredit? = null, load: suspend () -> AudioSource) {
        val generation = audioGeneration
        audioImportJob = viewModelScope.launch {
            try {
                val candidate = withContext(Dispatchers.IO) {
                    audioImportMutex.withLock {
                        val source = load()
                        val clip = AudioClip(name = name.take(80), source = source, assetCredit = credit)
                        val next = captured.copy(audioClips = captured.audioClips + clip)
                        // Combined image/audio Base64 must fit the complete backup,
                        // not merely each asset's independent byte allowance.
                        store.encode(next.copy(revision = captured.revision + 1, modified = System.currentTimeMillis()))
                        currentCoroutineContext().ensureActive()
                        next
                    }
                }
                ensureActive()
                if (generation != audioGeneration) return@launch
                // Finish this import before change() cancels all stale captured operations.
                audioImportJob = null; audioCapture = null; importingAudio = false
                if (change { current ->
                    require(current == captured) { "Project changed during import. Choose the WAV again." }
                    candidate
                }) message = "Sound copied into project. Select its clip to edit or preview. MP4 export mixes saved audio clips over the animation duration."
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { report(e.message ?: "Audio import failed; no clip added.") }
            finally { if (generation == audioGeneration) { audioCapture = null; importingAudio = false; audioImportJob = null } }
        }
    }
    fun editAudioTrack(captured: Document, index: Int, mix: AudioTrackMix): Boolean = change { current ->
        require(current == captured && index in 0..3) { "Timeline changed; reopen track controls." }
        mix.validate()
        current.copy(audioTracks = current.audioTracks.mapIndexed { n, old -> if (n == index) mix else old })
    }
    fun editAudio(captured: Document, clip: AudioClip): Boolean = change { current ->
        require(current == captured && current.audioClips.any { it.id == clip.id && it.source === clip.source }) { "Project changed. Reopen the audio clip." }
        current.copy(audioClips = current.audioClips.map { if (it.id == clip.id) clip else it })
    }
    /** Expansion preflights the complete portable backup off-main before one history edit. */
    fun expandAudio(captured: Document, id: String, splitAt: Double? = null) {
        if (closing || importingAudio || document != captured) return
        val clip = captured.audioClips.firstOrNull { it.id == id } ?: return
        stopAudioPreview()
        cancelAudioImport()
        val generation = audioGeneration
        importingAudio = true
        audioImportJob = viewModelScope.launch {
            try {
                val candidate = withContext(Dispatchers.IO) {
                    audioImportMutex.withLock {
                        val right = if (splitAt == null) {
                            clip.copy(id = newID(), start = clip.start + clip.duration)
                        } else {
                            require(splitAt.isFinite()) { "Enter a finite split time." }
                            // Source-sample alignment avoids a fractional-sample gap at the join.
                            val sourceBoundary = kotlin.math.round((clip.sourceOffset + splitAt - clip.start) * clip.source.rate) / clip.source.rate
                            val leftDuration = sourceBoundary - clip.sourceOffset
                            require(leftDuration + 1e-12 >= 1.0 / clip.source.rate && clip.duration - leftDuration + 1e-12 >= 1.0 / clip.source.rate) {
                                "Split must leave at least one source sample on each side."
                            }
                            clip.copy(id = newID(), start = clip.start + leftDuration,
                                sourceOffset = clip.sourceOffset + leftDuration, duration = clip.duration - leftDuration)
                        }
                        val left = if (splitAt == null) clip else clip.copy(duration = right.start - clip.start)
                        val clips = captured.audioClips.flatMap { if (it.id == clip.id) listOf(left, right) else listOf(it) }
                        val next = captured.copy(audioClips = clips).validated()
                        store.encode(next.copy(revision = captured.revision + 1, modified = System.currentTimeMillis()))
                        currentCoroutineContext().ensureActive()
                        next
                    }
                }
                ensureActive()
                if (generation != audioGeneration) return@launch
                audioImportJob = null; importingAudio = false
                if (change { current ->
                    require(current == captured) { "Project changed; select the clip again." }
                    candidate
                }) message = if (splitAt == null) "Clip duplicated after its end. Undo restores the original timeline."
                    else "Clip split at the nearest source sample. Undo joins both parts."
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { report(error.message ?: "Audio edit failed; timeline unchanged.") }
            finally { if (generation == audioGeneration) { audioImportJob = null; importingAudio = false } }
        }
    }
    fun deleteAudio(captured: Document, id: String): Boolean = change { current ->
        require(current == captured && current.audioClips.any { it.id == id }) { "Project changed. Select the clip again." }
        current.copy(audioClips = current.audioClips.filterNot { it.id == id })
    }
    var sceneStopGeneration by mutableStateOf(0L); private set
    fun stopScenePlayback() { sceneStopGeneration++; stopAudioPreview() }
    fun stopAudioPreview() { sceneAudioJob?.cancel(); sceneAudioJob = null; audioPreviewJob?.cancel(); audioPreviewJob = null; previewingAudio = false }
    suspend fun previewSceneAudio(captured: Document, onElapsedNanos: (Long) -> Unit) {
        require(document == captured && !closing) { "Project changed before playback." }
        val owner = currentCoroutineContext()[Job]
        sceneAudioJob = owner
        val manager = getApplication<Application>().getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager
        val focus = android.media.AudioFocusRequest.Builder(android.media.AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setOnAudioFocusChangeListener { state -> if (state < 0) owner?.cancel() }.build()
        try {
            require(manager.requestAudioFocus(focus) == android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED) { "Audio focus is unavailable; playback stopped." }
            val startTicks = captured.frames.takeWhile { it.id != captured.activeFrameID }.sumOf { it.hold.toLong() }
            val firstSample = startTicks * AudioMixer.RATE / captured.fps
            withContext(Dispatchers.IO) {
                audioPreviewMutex.withLock {
                    val mixer = AudioMixer(captured)
                    kotlinx.coroutines.withTimeout((mixer.frameCount-firstSample)*1000/AudioMixer.RATE + 5000) {
                        mixer.preview(firstSample) { consumed ->
                            withContext(Dispatchers.Main.immediate) {
                                require(document == captured && !closing) { "Project changed during playback." }
                                onElapsedNanos(consumed*1_000_000_000L/AudioMixer.RATE)
                            }
                        }
                    }
                }
            }
        } finally {
            manager.abandonAudioFocusRequest(focus)
            if (sceneAudioJob === owner) sceneAudioJob = null
        }
    }
    fun previewAudio(captured: Document, id: String) {
        if (closing || document != captured) return
        val clip = captured.audioClips.firstOrNull { it.id == id } ?: return
        previewAudioSource(captured) { clip.copy(
            volume = clip.volume * captured.audioTracks[clip.track - 1].volume,
            muted = clip.muted || captured.audioTracks[clip.track - 1].muted) }
    }
    fun previewBundledSound(captured: Document, sound: BundledSound) {
        if (closing || document != captured) return
        previewAudioSource(captured) { AudioClip(name = sound.title.take(80), source = BundledSounds.source(getApplication<Application>(), sound)) }
    }
    private fun previewAudioSource(captured: Document, load: suspend () -> AudioClip) {
        stopAudioPreview(); previewingAudio = true
        audioPreviewJob = viewModelScope.launch {
            val owner = currentCoroutineContext()[Job]
            val manager = getApplication<Application>().getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager
            val focus = android.media.AudioFocusRequest.Builder(android.media.AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setOnAudioFocusChangeListener { state -> if (state < 0) owner?.cancel() }.build()
            try {
                require(manager.requestAudioFocus(focus) == android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED) { "Audio focus is unavailable. Try preview again when other audio stops." }
                withContext(Dispatchers.IO) {
                    audioPreviewMutex.withLock {
                        val clip = kotlinx.coroutines.withTimeout(30_000) { load() }
                        withContext(Dispatchers.Main.immediate) {
                            require(document == captured && !closing) { "Project changed before sound preview." }
                        }
                        currentCoroutineContext().ensureActive()
                        kotlinx.coroutines.withTimeout((clip.duration * 1000).toLong() + 5000) { clip.source.preview(clip) }
                    }
                }
            } catch (e: kotlinx.coroutines.TimeoutCancellationException) { report("Audio output timed out. Preview stopped.") }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { report(e.message ?: "Audio preview failed.") }
            finally { manager.abandonAudioFocusRequest(focus); if (audioPreviewJob === owner) { previewingAudio = false; audioPreviewJob = null } }
        }
    }

    var document by mutableStateOf<Document?>(null); private set
    var library by mutableStateOf(Library(emptyList(), 0)); private set
    var message by mutableStateOf(""); private set
    var saving by mutableStateOf(false); private set
    var busy by mutableStateOf(false); private set
    var closing by mutableStateOf(false); private set
    var dirty by mutableStateOf(false); private set
    var tool by mutableStateOf(Tool.Pencil); private set
    private data class DrawingSettings(val width: Float, val opacity: Float, val filled: Boolean = false, val equalSides: Boolean = false, val smoothing: Float = 0f, val mirror: MirrorMode = MirrorMode.Off)
    var brushFamily by mutableStateOf(BrushFamily.Round); private set
    var nibAngle by mutableStateOf(45f)
    var selectionNudge by mutableStateOf(1f)
    private fun restoreNibAngle() {
        val fallback = if (brushFamily == BrushFamily.Hatch) -45f else 45f
        nibAngle = try { preferences.getFloat("brush.${brushFamily.name}.angle", fallback)
            .takeIf { it.isFinite() && it in -180f..180f } ?: fallback } catch (_: Exception) { fallback }
    }
    private data class BrushSettings(val width: Float, val opacity: Float, val smoothing: Float)
    private fun brushDefaults(family: BrushFamily) = when (family) {
        BrushFamily.Round -> BrushSettings(8f, 1f, 3f)
        BrushFamily.Stipple -> BrushSettings(24f, 1f, 1f)
        BrushFamily.Grain -> BrushSettings(24f, 0.65f, 2f)
        BrushFamily.RoughPen -> BrushSettings(6f, 1f, 2f)
        BrushFamily.Calligraphy -> BrushSettings(20f, 1f, 5f)
        BrushFamily.DipPen -> BrushSettings(12f, 1f, 4f)
        BrushFamily.Halftone -> BrushSettings(24f, 1f, 2f)
        BrushFamily.Hatch -> BrushSettings(18f, 0.8f, 2f)
    }
    private fun applyBrushSettings(value: BrushSettings) {
        width = value.width; strokeOpacity = value.opacity; smoothing = value.smoothing
    }
    private fun restoreBrushSettings(legacy: DrawingSettings? = null) {
        val defaults = legacy?.let { BrushSettings(it.width, it.opacity, it.smoothing) } ?: brushDefaults(brushFamily)
        val key = "brush.${brushFamily.name}"
        val value = try {
            BrushSettings(preferences.getFloat("$key.width", defaults.width),
                preferences.getFloat("$key.opacity", defaults.opacity),
                preferences.getFloat("$key.smoothing", defaults.smoothing)).also {
                require(it.width.isFinite() && it.width in 1f..128f &&
                    it.opacity.isFinite() && it.opacity in 0f..1f &&
                    it.smoothing.isFinite() && it.smoothing in 0f..10f)
            }
        } catch (_: Exception) { defaults }
        applyBrushSettings(value)
        restoreNibAngle()
    }
    fun chooseBrush(family: BrushFamily) {
        if (tool != Tool.Pencil || family == brushFamily) return
        persistToolSettings()
        brushFamily = family
        restoreBrushSettings()
        persistToolSettings()
    }
    fun resetSelectedBrush() {
        if (tool != Tool.Pencil) return
        applyBrushSettings(brushDefaults(brushFamily))
        nibAngle = if (brushFamily == BrushFamily.Hatch) -45f else 45f
        persistToolSettings()
    }
    private val drawingSettings = mutableMapOf<Tool, DrawingSettings>()
    private val preferences = application.getSharedPreferences("studio-tool-settings-v1", android.content.Context.MODE_PRIVATE)
    private fun defaultSettings(tool: Tool) = DrawingSettings(if (tool == Tool.Eraser) 24f else if (tool.isShape) 4f else 8f,
        1f, smoothing = if (tool == Tool.Pencil) 3f else 0f)
    fun persistToolSettings() {
        if (tool.isDrawing) drawingSettings[tool] = DrawingSettings(width, strokeOpacity, shapeFilled, shapeEqualSides, smoothing, mirrorMode)
        val edit = preferences.edit().putInt("fill.tolerance", fillTolerance).putBoolean("fill.contiguous", fillContiguous).putFloat("brush.${brushFamily.name}.angle", nibAngle).putInt("color", color).putFloat("selection.nudge", selectionNudge).putBoolean("selection.preserveAspect", selectionPreservesAspect).putString("pencil.brush", brushFamily.name)
        if (tool == Tool.Pencil) {
            val key = "brush.${brushFamily.name}"
            edit.putFloat("$key.width", width).putFloat("$key.opacity", strokeOpacity)
                .putFloat("$key.smoothing", smoothing)
        }
        drawingSettings.forEach { (tool, value) ->
            val key = tool.name
            edit.putFloat("$key.width", value.width).putFloat("$key.opacity", value.opacity)
                .putBoolean("$key.filled", value.filled).putBoolean("$key.equalSides", value.equalSides)
                .putFloat("$key.smoothing", value.smoothing).putString("$key.mirror", value.mirror.name)
        }
        edit.apply()
    }
    private fun restoreToolSettings() {
        try { fillTolerance = preferences.getInt("fill.tolerance", 24).coerceIn(0,255) } catch (_: Exception) { }
        try { fillContiguous = preferences.getBoolean("fill.contiguous", true) } catch (_: Exception) { }
        try { brushFamily = BrushFamily.valueOf(preferences.getString("pencil.brush", "Round") ?: "Round") } catch (_: Exception) { }
        restoreNibAngle()
        try { selectionNudge = preferences.getFloat("selection.nudge", 1f).takeIf { it in listOf(1f, 5f, 10f) } ?: 1f } catch (_: Exception) { }
        try { selectionPreservesAspect = preferences.getBoolean("selection.preserveAspect", true) } catch (_: Exception) { }
        Tool.entries.filter { it.isDrawing }.forEach { tool ->
            val defaults = defaultSettings(tool); val key = tool.name
            try {
                val value = DrawingSettings(preferences.getFloat("$key.width", defaults.width),
                    preferences.getFloat("$key.opacity", defaults.opacity), preferences.getBoolean("$key.filled", false),
                    preferences.getBoolean("$key.equalSides", false), preferences.getFloat("$key.smoothing", defaults.smoothing),
                    MirrorMode.valueOf(preferences.getString("$key.mirror", "Off") ?: "Off"))
                require(value.width.isFinite() && value.width in 1f..128f && value.opacity.isFinite() && value.opacity in 0f..1f && value.smoothing.isFinite() && value.smoothing in 0f..10f)
                drawingSettings[tool] = value
            } catch (_: Exception) { drawingSettings[tool] = defaults }
        }
        val initial = drawingSettings[Tool.Pencil] ?: defaultSettings(Tool.Pencil)
        width = initial.width; strokeOpacity = initial.opacity; shapeFilled = initial.filled
        shapeEqualSides = initial.equalSides; smoothing = initial.smoothing; mirrorMode = initial.mirror
        // Migrate only the previously active family's shared Pencil values.
        restoreBrushSettings(if (preferences.contains("Pencil.width")) initial else null)
        try { preferences.getInt("color", color).takeIf { it ushr 24 == 255 }?.let { color = it } } catch (_: Exception) { }
    }
    var fillTolerance by mutableIntStateOf(24); private set
    var fillContiguous by mutableStateOf(true); private set
    var filling by mutableStateOf(false); private set
    private var fillJob: Job? = null
    // Cancellation is cooperative during native raster calls. Keep one allocation
    // owner until that call unwinds before admitting the next requested fill.
    private val fillComputeMutex = Mutex()
    private var fillGeneration = 0L
    fun cancelFill() {
        if (filling) message = "Fill cancelled; no fill was added."
        fillGeneration++
        fillJob?.cancel(); fillJob = null; filling = false
    }
    fun configureFill(tolerance: Int = fillTolerance, contiguous: Boolean = fillContiguous) {
        require(tolerance in 0..255)
        cancelFill(); fillTolerance = tolerance; fillContiguous = contiguous
        persistToolSettings()
    }
    fun fillAt(captured: Document, point: Point) {
        if (document != captured || closing || tool != Tool.Fill) return
        cancelFill()
        if (captured.layer.locked || !captured.layer.visible || captured.layer.opacity <= 0f) {
            report("Choose a visible unlocked layer for Fill."); return
        }
        val generation = fillGeneration
        val tolerance = fillTolerance; val contiguous = fillContiguous; val fillColor = color
        filling = true; message = "Filling from merged visible layers…"
        fillJob = viewModelScope.launch {
            try {
                val spans = withContext(Dispatchers.Default) {
                    fillComputeMutex.withLock {
                        val context = currentCoroutineContext()
                        context.ensureActive()
                        BucketFill.compute(captured, point, tolerance, contiguous) { context.ensureActive() }
                    }
                }
                currentCoroutineContext().ensureActive()
                if (generation != fillGeneration || document != captured || closing || tool != Tool.Fill ||
                    fillColor != color || tolerance != fillTolerance || contiguous != fillContiguous) {
                    if (generation == fillGeneration) report("Fill cancelled because the canvas or settings changed.")
                    return@launch
                }
                // Detach before change() cancels obsolete work. One canonical
                // stroke enters the ordinary undo/autosave/export pipeline.
                fillJob = null
                if (change { d ->
                    require(d == captured && !d.layer.locked && d.layer.visible && d.layer.opacity > 0f)
                    val stroke = Stroke(layerID = d.activeLayerID, points = listOf(point),
                        color = fillColor or 0xff000000.toInt(), width = 1f, tool = Tool.Fill, fill = spans, fillGeometry = FillGeometry(d.width, d.height))
                    d.copy(frames = d.frames.map { if (it.id == d.activeFrameID) it.copy(strokes = it.strokes + stroke) else it })
                }) message = "Fill added to ${captured.layer.name}. Undo removes the fill; source drawings stay editable."
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                if (generation == fillGeneration) report(error.message ?: "Fill could not be completed; no fill was added.")
            } finally {
                if (generation == fillGeneration) { filling = false; fillJob = null }
            }
        }
    }
    var importingImage by mutableStateOf(false); private set
    private var imageCapture: Document? = null
    private var imageJob: Job? = null
    private var imageGeneration = 0L
    private val imageComputeMutex = Mutex()
    fun beginImageImport(): Boolean {
        val d = document ?: return false
        if (closing || importingImage) return false
        if (android.os.Build.VERSION.SDK_INT < 28) { report("Image import requires Android 9 or later."); return false }
        if (d.layer.locked || !d.layer.visible || d.layer.opacity <= 0f) { report("Choose a visible unlocked layer for the image."); return false }
        cancelImageImport()
        imageCapture = d; importingImage = true
        return true
    }
    fun cancelImageImport() {
        imageGeneration++; imageJob?.cancel(); imageJob = null; imageCapture = null
        if (importingImage) report("Image import cancelled; no image was added.")
        importingImage = false
    }
    fun importImage(uri: Uri?) {
        val captured = imageCapture ?: return
        imageCapture = null
        if (uri == null) { cancelImageImport(); return }
        loadImageIntoProject(captured) { checkpoint ->
            getApplication<Application>().contentResolver.openInputStream(uri)?.use { ImageArtwork.importImage(it, checkpoint) }
                ?: error("The file provider could not open this image.")
        }
    }
    fun addBundledImage(captured: Document, image: BundledImage) {
        if (document != captured || !beginImageImport()) return
        imageCapture = null
        loadImageIntoProject(captured, AssetCredit(image.id, image.title, image.author, image.sourceURL, image.sha256)) { checkpoint ->
            BundledImages.artwork(getApplication<Application>(), image, checkpoint)
        }
    }
    private fun loadImageIntoProject(captured: Document, credit: AssetCredit? = null, load: (() -> Unit) -> ImageArtwork) {
        val generation = imageGeneration
        imageJob = viewModelScope.launch {
            try {
                val id = newID()
                val candidate = withContext(Dispatchers.IO) {
                    imageComputeMutex.withLock {
                        val context = currentCoroutineContext()
                        val deadline = android.os.SystemClock.elapsedRealtime() + 30_000L
                        val checkpoint = {
                            context.ensureActive()
                            require(android.os.SystemClock.elapsedRealtime() <= deadline) { "Image import exceeded 30 seconds; no image was added." }
                        }
                        checkpoint()
                        val image = load(checkpoint)
                        val stroke = Stroke(id = id, layerID = captured.activeLayerID, points = image.corners(captured), color = -1, width = 1f, tool = Tool.Image, image = image, assetCredit = credit)
                        val next = captured.copy(frames = captured.frames.map { if (it.id == captured.activeFrameID) it.copy(strokes = it.strokes + stroke) else it })
                        store.encode(next.copy(revision = captured.revision + 1, modified = System.currentTimeMillis()))
                        checkpoint()
                        next
                    }
                }
                currentCoroutineContext().ensureActive()
                require(generation == imageGeneration && document == captured && !closing) { "Canvas changed while importing; no image was added." }
                // Detach from cancellation before the single ordinary history transaction.
                imageJob = null; importingImage = false
                if (change { d ->
                    require(d == captured && !d.layer.locked && d.layer.visible && d.layer.opacity > 0f) { "Choose a visible unlocked layer." }
                    candidate
                }) {
                    selectedStrokeIDs = setOf(id); chooseTool(Tool.Move)
                    report("Image added. Move or use selection settings to resize, rotate or flip. Undo removes it.")
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: OutOfMemoryError) { if (generation == imageGeneration) report("Not enough memory for this image; no image was added.") }
            catch (error: Exception) { if (generation == imageGeneration) report(error.message ?: "Image import failed; no image was added.") }
            finally { if (generation == imageGeneration) { imageJob = null; importingImage = false; imageCapture = null } }
        }
    }
    private var sampledColorTool = Tool.Pencil
    private var colorSampleJob: Job? = null
    fun chooseTool(next: Tool) {
        if (next == tool) return
        cancelFill()
        persistToolSettings()
        if (next == Tool.Eyedropper && (tool.isSelectable || tool == Tool.Fill)) sampledColorTool = tool
        if (next != Tool.Eyedropper) colorSampleJob?.cancel()
        tool = next
        if (next == Tool.Text) selectedText?.let {
            val source = requireNotNull(it.text)
            textContent = source.content; textFontSize = source.fontSize; color = it.color
        }
        if (next.isDrawing) {
            val settings = drawingSettings[next] ?: DrawingSettings(if (next == Tool.Eraser) 24f else if (next.isShape) 4f else 8f, 1f, smoothing = if (next == Tool.Pencil) 3f else 0f)
            width = settings.width; strokeOpacity = settings.opacity
            shapeFilled = settings.filled; shapeEqualSides = settings.equalSides; smoothing = settings.smoothing; mirrorMode = settings.mirror
            if (next == Tool.Pencil) restoreBrushSettings()
        }
    }
    fun sampleColor(captured: Document, point: Point) {
        if (document != captured || closing || tool != Tool.Eyedropper) return
        colorSampleJob?.cancel()
        colorSampleJob = viewModelScope.launch {
            try {
                val sampled = withContext(Dispatchers.Default) {
                    val context = currentCoroutineContext()
                    FrameRenderer.sampleColor(captured, point) { context.ensureActive() }
                }
                currentCoroutineContext().ensureActive()
                if (document != captured || closing || tool != Tool.Eyedropper) return@launch
                chooseTool(sampledColorTool); color = sampled
                message = "Canvas color sampled. Continue drawing with ${sampledColorTool.name}."
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                if (document == captured && tool == Tool.Eyedropper) message = "Color could not be sampled; the previous drawing color is preserved."
            }
        }
    }
    var shapeFilled by mutableStateOf(false)
    var shapeEqualSides by mutableStateOf(false)
    var viewportZoom by mutableStateOf(1f); private set
    var viewportX by mutableStateOf(0f); private set
    var viewportY by mutableStateOf(0f); private set
    fun viewport(zoom: Float, x: Float = viewportX, y: Float = viewportY) {
        if (!zoom.isFinite() || !x.isFinite() || !y.isFinite()) return
        viewportZoom = zoom.coerceIn(0.25f, 8f)
        viewportX = x.coerceIn(-100_000f, 100_000f); viewportY = y.coerceIn(-100_000f, 100_000f)
    }
    fun fitViewport() = viewport(1f, 0f, 0f)
    var selectionPreservesAspect by mutableStateOf(true); private set
    fun chooseSelectionAspectLock(enabled: Boolean) {
        selectionPreservesAspect = enabled
        preferences.edit().putBoolean("selection.preserveAspect", enabled).apply()
    }
    var selectionShape by mutableStateOf(SelectionShape.Freehand); private set
    fun chooseSelectionShape(shape: SelectionShape) {
        if (closing) return
        selectionShape = shape
        chooseTool(Tool.Lasso)
    }
    var selectionMode by mutableStateOf(SelectionMode.Replace); private set
    fun chooseSelectionMode(mode: SelectionMode) {
        if (closing) return
        selectionMode = mode
        chooseTool(Tool.Lasso)
    }
    var selectedStrokeIDs by mutableStateOf<Set<String>>(emptySet()); private set
    private fun reconcileSelection() {
        val d = document
        selectedStrokeIDs = if (d == null) emptySet() else selectedStrokeIDs.intersect(ArtworkSelection.eligible(d.frame, d.layers))
    }
    private var artworkClipboard by mutableStateOf<List<Stroke>>(emptyList())
    private data class FrameClipboard(val projectID: String, val width: Int, val height: Int, val frames: List<Frame>)
    private var frameClipboard by mutableStateOf<FrameClipboard?>(null)
    val canPasteFrame: Boolean get() {
        val d = document ?: return false
        val copy = frameClipboard ?: return false
        return !closing && copy.projectID == d.id && copy.width == d.width && copy.height == d.height && d.frames.size + copy.frames.size <= 500 &&
            copy.frames.flatMap { it.strokes }.all { s -> d.layers.any { it.id == s.layerID && !it.locked } }
    }
    val frameClipboardCount: Int get() = frameClipboard?.frames?.size ?: 0
    fun copyFrame(cut: Boolean = false) {
        val d = document ?: return
        copyFrameRange(d, d.frames.indexOfFirst { it.id == d.activeFrameID } + 1, 1, cut)
    }
    fun copyFrameRange(captured: Document, first: Int, count: Int, cut: Boolean = false): Boolean {
        val current = document ?: return false
        if (closing) return false
        return try {
            val range = checkedFrameRange(current, captured, first, count)
            val copy = FrameClipboard(current.id, current.width, current.height, current.frames.slice(range))
            // Publish the immutable clipboard only after a successful cut. A
            // rejected locked/stale/final-frame cut preserves the old clipboard.
            if (cut && !deleteFrameRange(captured, first, count)) return false
            frameClipboard = copy
            message = if (cut) "$count frames cut with their exposures. Undo restores the cut." else "$count frames and exposures copied."
            true
        } catch (e: Exception) {
            report(e.message ?: "Frames could not be copied."); false
        }
    }
    fun pasteFrame() {
        val copy = frameClipboard ?: return
        if (change { d ->
            require(d.id == copy.projectID && d.width == copy.width && d.height == copy.height) { "Copy the frames again after changing projects or canvas size." }
            require(copy.frames.isNotEmpty() && d.frames.size + copy.frames.size <= 500) { "Frame limit reached." }
            require(copy.frames.flatMap { it.strokes }.all { s -> d.layers.any { it.id == s.layerID && !it.locked } }) { "A copied layer is missing or locked. Restore/unlock it, or copy another frame." }
            val pasted = copy.frames.map { frame -> frame.copy(id = newID(), strokes = frame.strokes.map { it.copy(id = newID()) }) }
            val frames = d.frames.toMutableList().apply { addAll(indexOfFirst { it.id == d.activeFrameID } + 1, pasted) }
            d.copy(frames = frames, activeFrameID = pasted.first().id)
        }) message = "${copy.frames.size} frames pasted after the selected frame. Layer appearance uses the current project settings."
    }
    val canPasteArtwork get() = artworkClipboard.isNotEmpty() && document?.let { !it.layer.locked && it.layer.visible && it.layer.opacity > 0f } == true && !closing
    fun deselect() { selectedStrokeIDs = emptySet() }
    private fun selectedArtwork(d: Document): List<Stroke> {
        require(selectedStrokeIDs.isNotEmpty()) { "Select artwork first." }
        val selected = d.frame.strokes.filter { it.id in selectedStrokeIDs }
        require(selected.size == selectedStrokeIDs.size && selected.all { s ->
            s.tool.isSelectable && d.layers.any { it.id == s.layerID && !it.locked && it.visible && it.opacity > 0f }
        }) { "Select visible unlocked artwork again." }
        return selected
    }
    fun setArtworkOpacity(captured: Document, ids: Set<String>, opacity: Float) {
        if (closing) return
        if (change { current ->
            require(current == captured && ids == selectedStrokeIDs && ids.isNotEmpty()) { "Select the current artwork again before setting opacity." }
            require(opacity.isFinite() && opacity in 0f..1f) { "Opacity must be between 0% and 100%." }
            selectedArtwork(current) // Recheck visibility, layer locks and every selected identity.
            current.copy(frames = current.frames.map { frame ->
                if (frame.id != current.activeFrameID) frame else frame.copy(strokes = frame.strokes.map { stroke ->
                    if (stroke.id in ids) stroke.copy(opacity = opacity) else stroke
                })
            })
        }) message = if (opacity == 0f) "Selected artwork is invisible. Undo restores its previous opacity." else "Selected artwork opacity updated in one Undo step."
    }
    fun copyArtwork(cut: Boolean = false) {
        val d = document ?: return
        if (closing) return
        try {
            val staged = selectedArtwork(d).map { it.copy(points = it.points.toList()) }
            if (cut) {
                val ids = staged.map { it.id }.toSet()
                if (!change { current ->
                    require(current == d) { "The document changed. Select the artwork again." }
                    current.copy(frames = current.frames.map { f -> if (f.id == current.activeFrameID)
                        f.copy(strokes = f.strokes.filterNot { it.id in ids }) else f })
                }) return
            }
            artworkClipboard = staged
            message = if (cut) "Selected artwork cut. Paste places it on the active layer; Undo restores the cut." else "Selected artwork copied. Paste places it on the active layer."
        } catch (e: Exception) { report(e.message ?: "Artwork could not be copied.") }
    }
    private fun pasteArtwork(source: List<Stroke>) {
        val d = document ?: return
        if (closing || source.isEmpty()) return
        val created = source.map { it.copy(id = newID(), layerID = d.activeLayerID) }
        if (change { current ->
            require(current == d && !current.layer.locked && current.layer.visible && current.layer.opacity > 0f) {
                "Choose a visible unlocked destination layer."
            }
            current.copy(frames = current.frames.map { f -> if (f.id == current.activeFrameID) f.copy(strokes = f.strokes + created) else f })
        }) { selectedStrokeIDs = created.map { it.id }.toSet(); chooseTool(Tool.Move); message = "Artwork pasted in place. Drag its selection box to move it." }
    }
    fun pasteArtwork() = pasteArtwork(artworkClipboard)
    fun duplicateArtwork() {
        val d = document ?: return
        try { pasteArtwork(selectedArtwork(d)) }
        catch (e: Exception) { report(e.message ?: "Artwork could not be duplicated.") }
    }
    fun orderArtwork(order: ArtworkOrder) {
        val captured = document ?: return
        if (closing) return
        try {
            val ids = selectedArtwork(captured).map { it.id }.toSet()
            val reordered = captured.frame.strokes.toMutableList()
            captured.layers.forEach { layer ->
                val slots = reordered.indices.filter { reordered[it].layerID == layer.id }
                val marks = slots.map { reordered[it] }.toMutableList()
                when (order) {
                    ArtworkOrder.Front -> {
                        val sorted = marks.filterNot { it.id in ids } + marks.filter { it.id in ids }
                        marks.clear(); marks.addAll(sorted)
                    }
                    ArtworkOrder.Back -> {
                        val sorted = marks.filter { it.id in ids } + marks.filterNot { it.id in ids }
                        marks.clear(); marks.addAll(sorted)
                    }
                    ArtworkOrder.Forward -> for (index in marks.size - 2 downTo 0) {
                        if (marks[index].id in ids && marks[index + 1].id !in ids) {
                            val next = marks[index + 1]; marks[index + 1] = marks[index]; marks[index] = next
                        }
                    }
                    ArtworkOrder.Backward -> for (index in 1 until marks.size) {
                        if (marks[index].id in ids && marks[index - 1].id !in ids) {
                            val previous = marks[index - 1]; marks[index - 1] = marks[index]; marks[index] = previous
                        }
                    }
                }
                slots.forEachIndexed { index, slot -> reordered[slot] = marks[index] }
            }
            if (reordered == captured.frame.strokes) { message = "Selected artwork is already at this stacking boundary."; return }
            if (change { current ->
                require(current == captured && selectedStrokeIDs == ids) { "The selection changed. Select artwork again." }
                current.copy(frames = current.frames.map { frame ->
                    if (frame.id == current.activeFrameID) frame.copy(strokes = reordered.toList()) else frame
                })
            }) message = "Changed selected artwork stacking. Undo restores its previous order."
        } catch (e: Exception) { report(e.message ?: "Artwork order could not be changed.") }
    }
    fun moveArtworkToLayer(targetID: String) {
        val captured = document ?: return
        if (closing) return
        try {
            val selected = selectedArtwork(captured)
            val target = captured.layers.firstOrNull { it.id == targetID }
                ?: error("The destination layer is unavailable.")
            require(target.visible && !target.locked && target.opacity > 0f) { "Choose a visible, unlocked destination layer." }
            if (selected.all { it.layerID == targetID }) { message = "Selected artwork is already on this layer."; return }
            val ids = selected.map { it.id }.toSet()
            if (change { current ->
                require(current == captured && selectedStrokeIDs == ids) { "The selection changed. Select artwork again." }
                // Append together above the destination's existing marks. Keep
                // identities and geometry; layer appearance comes from target.
                val moved = selected.map { it.copy(layerID = targetID) }
                current.copy(activeLayerID = targetID, frames = current.frames.map { frame ->
                    if (frame.id != current.activeFrameID) frame else
                        frame.copy(strokes = frame.strokes.filterNot { it.id in ids } + moved)
                })
            }) {
                selectedStrokeIDs = ids; chooseTool(Tool.Move)
                message = "Moved ${ids.size} selected objects to ${target.name}. Undo restores their original layers."
            }
        } catch (e: Exception) { report(e.message ?: "Artwork could not be moved to this layer.") }
    }
    fun flipArtwork(horizontal: Boolean) {
        val d = document ?: return
        try {
            val ids = selectedArtwork(d).map { it.id }.toSet()
            val bounds = ArtworkSelection.bounds(d.frame, ids) ?: return
            change { current ->
                require(current == d) { "Select the artwork again." }
                current.copy(frames = current.frames.map { f -> if (f.id != current.activeFrameID) f else
                    f.copy(strokes = f.strokes.map { s -> if (s.id !in ids) s else if (s.tool == Tool.Fill) s.transformFill(
                        if (horizontal) -1f else 1f, 0f, 0f, if (horizontal) 1f else -1f,
                        if (horizontal) bounds.left+bounds.right else 0f, if (horizontal) 0f else bounds.top+bounds.bottom) else s.copy(
                        brushTransform = if (s.brush == BrushFamily.Round) s.brushTransform else s.brushTransform.then(if (horizontal) -1f else 1f,0f,0f,if (horizontal) 1f else -1f), points = s.points.map { p ->
                        if (horizontal) Point(bounds.left+bounds.right-p.x,p.y) else Point(p.x,bounds.top+bounds.bottom-p.y)
                    }) }) })
            }
        } catch (e: Exception) { report(e.message ?: "Artwork could not be flipped.") }
    }
    private fun finishSelection(freeResize: Boolean = false) {
        if (selectedStrokeIDs.isNotEmpty()) {
            selectionMode = SelectionMode.Replace
            chooseTool(Tool.Move)
            // A completed lasso is immediately reshappable, matching native Studio.
            // This is transient; selecting a region does not write document history.
            if (freeResize) selectionPreservesAspect = false
            message = "Drag the selection to move; use corners to resize or the top handle to rotate."
        } else message = "No artwork selected. Enclose whole visible, unlocked drawings."
    }
    fun selectVisibleArtwork(invert: Boolean = false) {
        val d = document ?: return
        if (closing) return
        val eligible = ArtworkSelection.eligible(d.frame, d.layers)
        selectedStrokeIDs = if (invert) eligible - selectedStrokeIDs else eligible
        finishSelection()
    }
    fun selectArea(captured: Document, points: List<Point>, mode: SelectionMode, prior: Set<String>, shape: SelectionShape) {
        if (document != captured || closing || tool != Tool.Lasso || mode != selectionMode || prior != selectedStrokeIDs || shape != selectionShape) return
        try {
            val found = ArtworkSelection.enclosed(captured.frame, captured.layers, points, shape)
            val eligible = ArtworkSelection.eligible(captured.frame, captured.layers)
            selectedStrokeIDs = when (mode) {
                SelectionMode.Replace -> found
                SelectionMode.Add -> prior + found
                SelectionMode.Subtract -> prior - found
            }.intersect(eligible)
            finishSelection(freeResize = true)
        } catch (e: Exception) { report(e.message ?: "Selection unavailable.") }
    }
    fun positionSelection(dx: Float = 0f, dy: Float = 0f, alignment: ArtworkAlignment? = null) {
        val captured = document ?: return
        if (closing) return
        try {
            val ids = selectedArtwork(captured).map { it.id }.toSet()
            val bounds = ArtworkSelection.bounds(captured.frame, ids) ?: return
            require(dx.isFinite() && dy.isFinite()) { "Invalid movement." }
            var x = dx; var y = dy
            when (alignment) {
                ArtworkAlignment.Left -> x = -bounds.left
                ArtworkAlignment.CenterX -> x = captured.width / 2f - bounds.center.x
                ArtworkAlignment.Right -> x = captured.width - bounds.right
                ArtworkAlignment.Top -> y = -bounds.top
                ArtworkAlignment.CenterY -> y = captured.height / 2f - bounds.center.y
                ArtworkAlignment.Bottom -> y = captured.height - bounds.bottom
                null -> Unit
            }
            if (x == 0f && y == 0f) return
            transformSelection(captured, ids, ArtworkTransform(dx = x, dy = y))
        } catch (e: Exception) { report(e.message ?: "Selection could not be positioned.") }
    }
    fun transformSelection(captured: Document, ids: Set<String>, transform: ArtworkTransform) {
        if (document != captured || ids != selectedStrokeIDs || ids.isEmpty() || closing) return
        val bounds = ArtworkSelection.bounds(captured.frame, ids) ?: return
        change { d ->
            require(d.frame.strokes.filter { it.id in ids }.all { s -> d.layers.any { it.id == s.layerID && it.visible && !it.locked && it.opacity > 0f } })
            val transformed = transform.apply(d.frame, ids, bounds)
            require(transformed.strokes.filter { it.id in ids }.all { s ->
                if (s.tool == Tool.Fill) s.fillBounds().let { it.left >= 0f && it.top >= 0f && it.right <= d.width && it.bottom <= d.height }
                else s.points.all { it.x in 0f..d.width.toFloat() && it.y in 0f..d.height.toFloat() }
            }) {
                "Keep the selected drawing inside the canvas. The transform was not applied."
            }
            d.copy(frames = d.frames.map { if (it.id == d.activeFrameID) transformed else it })
        }
    }
    fun deleteSelection() {
        if (selectedStrokeIDs.isEmpty()) return
        val ids = selectedStrokeIDs
        change { d ->
            require(d.frame.strokes.filter { it.id in ids }.all { s -> d.layers.any { it.id == s.layerID && it.visible && !it.locked && it.opacity > 0f } })
            d.copy(frames = d.frames.map { if (it.id == d.activeFrameID) it.copy(strokes = it.strokes.filterNot { s -> s.id in ids }) else it })
        }
        reconcileSelection()
    }
    var width by mutableFloatStateOf(8f)
    var strokeOpacity by mutableFloatStateOf(1f)
    var mirrorMode by mutableStateOf(MirrorMode.Off)
    var smoothing by mutableFloatStateOf(3f)
    var color by mutableIntStateOf(0xffe52b38.toInt())
    var exporting by mutableStateOf(false); private set
    var exportArtifact by mutableStateOf<ExportArtifact?>(null); private set
    var exportPickerRequested by mutableStateOf(false); private set
    data class ExportProgress(val stage: String, val percent: Int? = null)
    // Exporters report from IO. StateFlow safely conflates updates without
    // launching one Main coroutine per video frame or output buffer.
    private val mutableExportProgress = MutableStateFlow<ExportProgress?>(null)
    val exportProgress = mutableExportProgress.asStateFlow()
    private var exportJob: Job? = null
    fun prepareExport(kind: ExportKind) {
        val snapshot = document ?: return
        if (exporting || exportArtifact != null || closing) return
        exporting = true; message = "Preparing export of revision ${snapshot.revision}…"
        mutableExportProgress.value = ExportProgress("Preparing export")
        exportJob = viewModelScope.launch {
            var owned: ExportArtifact? = null
            var delivered = false
            try {
                withContext(Dispatchers.IO) {
                    owned = ProjectExporter.prepare(getApplication(), snapshot, kind) { completed, total ->
                        if (total > 0) {
                            mutableExportProgress.value = if (completed >= total) ExportProgress("Finalizing export")
                            else ExportProgress("Rendering export", (completed.toLong() * 100 / total).toInt().coerceIn(0, 99))
                        }
                    }
                }
                exportArtifact = owned; exportPickerRequested = false; delivered = true
                message = "Choose where to save the export."
            } catch (_: CancellationException) { message = "Export cancelled." }
            catch (e: Exception) { message = e.message ?: "Could not prepare export." }
            finally { if (!delivered) owned?.file?.delete(); mutableExportProgress.value = null; exporting = false; exportJob = null }
        }
    }
    fun markExportPickerRequested() { exportPickerRequested = true }
    fun cancelExport() {
        if (exporting) exportJob?.cancel()
        else { exportArtifact?.file?.delete(); exportArtifact = null; exportPickerRequested = false; message = "Export cancelled." }
    }
    fun finishExport(uri: Uri?) {
        val artifact = exportArtifact ?: return
        if (exporting) return
        if (uri == null) { cancelExport(); return }
        exporting = true; exportArtifact = null; message = "Writing export…"
        mutableExportProgress.value = ExportProgress("Writing to Files", 0)
        exportJob = viewModelScope.launch {
            var destinationOpened = false
            try {
                withContext(Dispatchers.IO) {
                    val scope = currentCoroutineContext()
                    scope.ensureActive()
                    val output = getApplication<Application>().contentResolver.openOutputStream(uri, "wt")
                        ?: error("Document provider did not open the destination.")
                    destinationOpened = true
                    output.use { target -> artifact.file.inputStream().use { source ->
                        val bytes = ByteArray(64 * 1024)
                        val totalBytes = artifact.file.length()
                        var written = 0L
                        while (true) {
                            scope.ensureActive()
                            val count = source.read(bytes); if (count < 0) break
                            target.write(bytes, 0, count)
                            written += count
                            mutableExportProgress.value = ExportProgress("Writing to Files",
                                if (totalBytes > 0) (written * 100 / totalBytes).toInt().coerceIn(0, 99) else null)
                        }
                        mutableExportProgress.value = ExportProgress("Finishing file")
                        scope.ensureActive(); target.flush()
                    } }
                }
                message = when (artifact.kind) {
                    ExportKind.CREDITS -> "Project asset credits exported; unknown sources remain identified."
                    ExportKind.PROJECT -> "Editable Android project backup exported."
                    ExportKind.MP4 -> "MP4 video exported from the captured project revision."
                    ExportKind.GIF -> "Looping GIF exported with 256-color palette and centisecond timing."
                    ExportKind.PNG -> "PNG exported."
                    ExportKind.SEQUENCE -> "PNG sequence and timing manifest exported."
                    ExportKind.SPRITESHEET -> "Spritesheet and frame/timing manifest exported."
                }
            } catch (_: CancellationException) {
                message = if (destinationOpened) "Export cancelled. The selected destination may contain a partial file; remove it in Files." else "Export cancelled."
            } catch (e: Exception) {
                message = "Export failed: ${e.message ?: "document provider error"}" +
                    if (destinationOpened) ". The destination may be partial; check it in Files." else ""
            } finally {
                // Only our staging file is owned. Never delete an arbitrary provider URI:
                // the user may have chosen to replace an existing document.
                artifact.file.delete(); mutableExportProgress.value = null; exporting = false; exportPickerRequested = false; exportJob = null
            }
        }
    }
    override fun onCleared() {
        cancelAudioImport(); stopAudioPreview()
        imageJob?.cancel(); colorSampleJob?.cancel(); exportJob?.cancel(); exportArtifact?.file?.delete(); super.onCleared()
    }
    private val undo = mutableStateListOf<Document>()
    private val redo = mutableStateListOf<Document>()
    val canUndo get() = undo.isNotEmpty() && !closing
    val canRedo get() = redo.isNotEmpty() && !closing
    init { restoreToolSettings(); refresh() }
    fun report(text: String) { message = text }
    fun refresh() { viewModelScope.launch {
        try { library = withContext(Dispatchers.IO) { store.list() } }
        catch (e: Exception) { message = e.message ?: "Could not read local projects." }
    } }
    fun updateProject(captured: Document, name: String, width: Int, height: Int, fps: Int, fitArtwork: Boolean, backgroundColor: Int = captured.backgroundColor): Boolean = change { d ->
        require(d == captured) { "Project changed. Reopen settings before applying." }
        require(width in 16..4096 && height in 16..4096 && fps in 1..60)
        val resizing = width != d.width || height != d.height
        val frames = if (resizing && fitArtwork) {
            require(d.frames.all { f -> f.strokes.none { s -> d.layers.any { it.id == s.layerID && it.locked } } }) {
                "Unlock artwork layers before fitting their contents to a new canvas."
            }
            val factor = minOf(width.toFloat() / d.width, height.toFloat() / d.height)
            val offsetX = (width - d.width * factor) / 2f
            val offsetY = (height - d.height * factor) / 2f
            d.frames.map { f -> f.copy(strokes = f.strokes.map { s ->
                if (s.tool == Tool.Fill) s.transformFill(factor,0f,0f,factor,offsetX,offsetY) else {
                val strokeWidth = if (s.brush == BrushFamily.Round) s.width else s.width * factor
                require(strokeWidth in 1f..128f) { "Fitting would exceed the supported textured brush width." }
                s.copy(width = strokeWidth, brushTransform = if (s.brush == BrushFamily.Round) s.brushTransform else s.brushTransform.then(factor,0f,0f,factor), points = s.points.map { p ->
                Point((p.x * factor + offsetX).coerceIn(0f, width.toFloat()),
                    (p.y * factor + offsetY).coerceIn(0f, height.toFloat()))
            }) } }) }
        } else {
            require(d.frames.all { f -> f.strokes.all { s ->
                if (s.tool == Tool.Fill) s.fillBounds().let { it.left >= 0f && it.top >= 0f && it.right <= width && it.bottom <= height }
                else s.points.all { it.x <= width && it.y <= height }
            } }) {
                "Artwork would fall outside this canvas. Choose Fit artwork or a larger size."
            }
            d.frames
        }
        d.copy(name = name.trim(), width = width, height = height, fps = fps, frames = frames, backgroundColor = backgroundColor)
    }
    fun create(name: String, width: Int, height: Int, fps: Int, backgroundColor: Int = -1) {
        if (busy || document != null) return
        val created = try { Document.create(name, width, height, fps, backgroundColor) }
        catch (e: Exception) { report(e.message ?: "Invalid project settings."); return }
        busy = true
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { store.save(created) }
                document = created; frameClipboard = null; dirty = false; undo.clear(); redo.clear(); message = "Saved locally"
            } catch (e: Exception) { report(e.message ?: "Could not create project.") }
            finally { busy = false }
        }
    }
    fun duplicateProject(entry: ProjectEntry) {
        if (busy || document != null) return
        busy = true
        viewModelScope.launch {
            try {
                val copy = withContext(Dispatchers.IO) { store.duplicate(entry) }
                library = withContext(Dispatchers.IO) { store.list() }
                message = "Saved ${copy.name} as an independent project. Original preserved."
            } catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (e: Exception) { report(e.message ?: "Could not duplicate project; original preserved.") }
            finally { busy = false }
        }
    }
    fun importProject(uri: Uri?) {
        if (uri == null || busy || document != null) return
        busy = true
        viewModelScope.launch {
            try {
                val restored = withContext(Dispatchers.IO) {
                    getApplication<Application>().contentResolver.openInputStream(uri)?.use { store.importProject(it) }
                        ?: error("The file provider could not open the project.")
                }
                library = withContext(Dispatchers.IO) { store.list() }
                message = "Restored ${restored.name} as a separate project. Existing projects preserved."
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { report(e.message ?: "Could not restore this Android project backup.") }
            finally { busy = false }
        }
    }
    fun open(id: String) {
        if (busy || document != null) return
        busy = true
        viewModelScope.launch {
            try {
                document = withContext(Dispatchers.IO) { store.load(id) }
                frameClipboard = null
                dirty = false; undo.clear(); redo.clear(); message = "Opened local project"
            } catch (e: Exception) { report(e.message ?: "Could not open project; original preserved.") }
            finally { busy = false }
        }
    }
    /** Exactly one writer. Changes made during an IO write are saved by the next iteration.
     * Closing waits for the latest revision; failure leaves the editor and history intact. */
    fun save(close: Boolean = false) {
        if (document == null) return
        if (close) { cancelImageImport(); cancelFill(); cancelAudioImport(); stopAudioPreview(); closing = true }
        if (saving) return
        saving = true
        viewModelScope.launch {
            try {
                while (true) {
                    val snapshot = document ?: break
                    withContext(Dispatchers.IO) { store.save(snapshot) }
                    if (document?.id != snapshot.id) break
                    if (document?.revision != snapshot.revision) continue
                    dirty = false; message = "Saved locally"
                    if (closing) { document = null; selectedStrokeIDs = emptySet(); artworkClipboard = emptyList(); frameClipboard = null; undo.clear(); redo.clear(); refresh() }
                    break
                }
            } catch (e: Exception) { report(e.message ?: "Save failed. Your open project is retained.") }
            finally { saving = false; closing = false }
        }
    }
    private fun boundedPush(list: MutableList<Document>, value: Document) {
        list.add(value)
        while (list.size > 1 && (list.size > 32 || list.sumOf { it.pointCount.toLong() } > 200_000 || list.sumOf { it.audioBytes } > 16L * 1024 * 1024 || list.sumOf { it.imageBytes } > 8L * 1024 * 1024 || list.sumOf { it.imagePixels } > 8_388_608L)) list.removeAt(0)
    }
    private fun change(transform: (Document) -> Document): Boolean {
        val before = document ?: return false
        if (closing) return false
        try {
            val proposed = transform(before)
            if (proposed == before) return false
            val next = proposed.copy(revision = before.revision + 1, modified = System.currentTimeMillis()).validated()
            cancelImageImport(); cancelFill(); cancelAudioImport(); stopAudioPreview()
            boundedPush(undo, before); redo.clear(); document = next; reconcileSelection(); dirty = true; save()
            return true
        } catch (e: Exception) { report(e.message ?: "This change is unavailable."); return false }
    }
    fun undo() {
        val before = document ?: return
        if (!canUndo) return
        cancelImageImport(); cancelFill(); cancelAudioImport(); stopAudioPreview()
        boundedPush(redo, before)
        document = undo.removeAt(undo.lastIndex).copy(revision = before.revision + 1, modified = System.currentTimeMillis())
        reconcileSelection(); dirty = true; save()
    }
    fun redo() {
        val before = document ?: return
        if (!canRedo) return
        cancelImageImport(); cancelFill(); cancelAudioImport(); stopAudioPreview()
        boundedPush(undo, before)
        document = redo.removeAt(redo.lastIndex).copy(revision = before.revision + 1, modified = System.currentTimeMillis())
        reconcileSelection(); dirty = true; save()
    }
    var textContent by mutableStateOf("Text")
    var textFontSize by mutableFloatStateOf(32f)
    val selectedText: Stroke? get() = document?.frame?.strokes?.singleOrNull { it.id in selectedStrokeIDs }
        ?.takeIf { selectedStrokeIDs.size == 1 && it.tool == Tool.Text }
    fun addText(captured: Document, origin: Point) {
        val id = newID()
        if (change { d ->
            require(d == captured) { "The document changed. Add text again." }
            require(!d.layer.locked && d.layer.visible && d.layer.opacity > 0f) { "Choose a visible unlocked layer." }
            val source = EditableText(textContent, textFontSize).also { it.validate() }
            val stroke = Stroke(id = id, layerID = d.activeLayerID, points = TextArtwork.corners(source, origin),
                color = color or 0xff000000.toInt(), width = 1f, tool = Tool.Text, text = source)
            require(stroke.points.all { it.x in 0f..d.width.toFloat() && it.y in 0f..d.height.toFloat() }) {
                "Text does not fit here. Use fewer characters, a smaller size, or tap nearer the top left."
            }
            d.copy(frames = d.frames.map { if (it.id == d.activeFrameID) it.copy(strokes = it.strokes + stroke) else it })
        }) { selectedStrokeIDs = setOf(id); chooseTool(Tool.Move); message = "Text added. Move, resize or rotate the selection; use Edit text to change its words." }
    }
    fun editText(captured: Document) {
        val id = selectedText?.id ?: return
        change { d ->
            require(d == captured) { "The document changed. Reopen text settings." }
            val original = selectedArtwork(d).single().also { require(it.id == id && it.tool == Tool.Text) }
            val updated = TextArtwork.replace(original, EditableText(textContent, textFontSize)).copy(color = color or 0xff000000.toInt())
            require(updated.points.all { it.x in 0f..d.width.toFloat() && it.y in 0f..d.height.toFloat() }) { "Edited text does not fit. Shorten it, reduce its size or move it first." }
            d.copy(frames = d.frames.map { if (it.id == d.activeFrameID) it.copy(strokes = it.strokes.map { s -> if (s.id == id) updated else s }) else it })
        }
    }
    fun commitStroke(captured: Document, points: List<Point>, strokeTool: Tool, strokeWidth: Float, strokeColor: Int, filled: Boolean = false, opacity: Float = 1f, mirror: MirrorMode = MirrorMode.Off, brush: BrushFamily = BrushFamily.Round, brushSeed: Int = newID().hashCode(), nibAngle: Float = if (brush == BrushFamily.Hatch) -45f else 45f) {
        val now = document ?: return
        if (!strokeTool.isDrawing) return
        if (now.id != captured.id || now.revision != captured.revision || closing) return
        if (now.layer.locked || !now.layer.visible || now.layer.opacity == 0f || points.isEmpty() || opacity == 0f) return
        change { d -> d.copy(frames = d.frames.map { f -> if (f.id != d.activeFrameID) f else
            f.copy(strokes = f.strokes + Stroke(layerID = d.activeLayerID, points = points.toList(), color = strokeColor, width = strokeWidth, tool = strokeTool, filled = filled, opacity = opacity, brush = if (strokeTool == Tool.Pencil) brush else BrushFamily.Round, brushSeed = brushSeed, nibAngle = nibAngle).mirrored(d.width, d.height, mirror)) }) }
    }
    fun updateGrid(settings: GridSettings) = change { d -> settings.validate(); d.copy(grid = settings) }
    fun updateOnion(settings: OnionSettings) = change { d ->
        settings.validate()
        d.copy(onion = settings)
    }
    fun seekAudioFrame(captured: Document, seconds: Double): Boolean = change { current ->
        require(current == captured && seconds.isFinite() && seconds >= 0) { "Timeline changed; choose a frame again." }
        val tick = kotlin.math.floor(seconds * current.fps).toLong()
        var end = 0L
        val frame = current.frames.firstOrNull { end += it.hold; tick < end } ?: current.frames.last()
        current.copy(activeFrameID = frame.id)
    }
    fun selectFrame(id: String) = change { d -> require(d.frames.any { it.id == id }); d.copy(activeFrameID = id) }
    fun addFrame(duplicate: Boolean) = change { d ->
        require(d.frames.size < 500) { "Frame limit reached." }
        val next = if (duplicate) d.frame.copy(id = newID(), strokes = d.frame.strokes.map { it.copy(id = newID()) }) else Frame()
        val frames = d.frames.toMutableList().apply { add(indexOfFirst { it.id == d.activeFrameID } + 1, next) }
        d.copy(frames = frames, activeFrameID = next.id)
    }
    fun deleteFrame() = change { d ->
        require(d.frames.size > 1) { "Keep at least one frame." }
        require(d.frame.strokes.none { s -> d.layers.first { it.id == s.layerID }.locked }) { "Unlock this frame’s drawing layers first." }
        val index = d.frames.indexOf(d.frame)
        val remaining = d.frames.filterNot { it.id == d.activeFrameID }
        d.copy(frames = remaining, activeFrameID = remaining[index.coerceAtMost(remaining.lastIndex)].id)
    }
    /** One history/save transaction over a captured contiguous range. */
    fun editFrameRange(captured: Document, first: Int, count: Int, ticks: Int?, reverse: Boolean): Boolean = change { current ->
        require(current == captured) { "Project changed. Reopen Frame range before applying." }
        require(first >= 1 && count in 1..96 && first <= current.frames.size && count <= current.frames.size - first + 1) { "Choose up to 96 existing consecutive frames." }
        require((reverse && ticks == null && count >= 2) || (!reverse && ticks != null && ticks in 1..600)) { "Choose a valid exposure or at least two frames to reverse." }
        val start = first - 1
        val original = current.frames.subList(start, start + count)
        val replacement = if (reverse) original.reversed() else original.map { it.copy(hold = requireNotNull(ticks)) }
        val frames = current.frames.toMutableList()
        replacement.forEachIndexed { offset, frame -> frames[start + offset] = frame }
        current.copy(frames = frames)
    }
    private fun checkedFrameRange(current: Document, captured: Document, first: Int, count: Int): IntRange {
        require(current == captured) { "Project changed. Reopen Frame range before applying." }
        require(first >= 1 && count in 1..96 && first <= current.frames.size && count <= current.frames.size - first + 1) {
            "Choose up to 96 existing consecutive frames."
        }
        return (first - 1) until (first - 1 + count)
    }
    fun moveFrameRange(captured: Document, first: Int, count: Int, earlier: Boolean): Boolean = change { current ->
        val range = checkedFrameRange(current, captured, first, count)
        val destination = range.first + if (earlier) -1 else 1
        require(destination >= 0 && destination + count <= current.frames.size) { "The range is already at the timeline edge." }
        val selected = current.frames.slice(range)
        val frames = current.frames.toMutableList()
        repeat(count) { frames.removeAt(range.first) }
        frames.addAll(destination, selected)
        current.copy(frames = frames)
    }
    fun duplicateFrameRange(captured: Document, first: Int, count: Int): Boolean = change { current ->
        val range = checkedFrameRange(current, captured, first, count)
        require(current.frames.size + count <= 500) { "Frame limit reached." }
        val copies = current.frames.slice(range).map { frame ->
            frame.copy(id = newID(), strokes = frame.strokes.map { it.copy(id = newID()) })
        }
        val frames = current.frames.toMutableList().apply { addAll(range.last + 1, copies) }
        current.copy(frames = frames, activeFrameID = copies.first().id)
    }
    fun deleteFrameRange(captured: Document, first: Int, count: Int): Boolean = change { current ->
        val range = checkedFrameRange(current, captured, first, count)
        require(count < current.frames.size) { "Keep at least one frame." }
        val removed = current.frames.slice(range)
        val locked = current.layers.filter { it.locked }.map { it.id }.toSet()
        require(removed.none { frame -> frame.strokes.any { it.layerID in locked } }) { "Unlock the selected frames' drawing layers first." }
        val removedIDs = removed.map { it.id }.toSet()
        val frames = current.frames.filterNot { it.id in removedIDs }
        current.copy(frames = frames, activeFrameID = if (current.activeFrameID in removedIDs)
            frames[range.first.coerceAtMost(frames.lastIndex)].id else current.activeFrameID)
    }
    fun setHold(value: Int) = change { d -> d.copy(frames = d.frames.map { if (it.id == d.activeFrameID) it.copy(hold = value) else it }) }
    fun selectLayer(id: String) = change { d -> require(d.layers.any { it.id == id }); d.copy(activeLayerID = id) }
    fun addLayer() = change { d ->
        require(d.layers.size < 32) { "Layer limit reached." }
        val layer = Layer(name = "Layer ${d.layers.size + 1}")
        d.copy(layers = listOf(layer) + d.layers, activeLayerID = layer.id)
    }
    fun updateLayer(id: String, visible: Boolean? = null, locked: Boolean? = null, opacity: Float? = null, blend: LayerBlend? = null) = change { d ->
        require(d.layers.any { it.id == id }) { "The layer is unavailable." }
        require(blend == null || FrameRenderer.supports(blend)) { "${blend?.label ?: "This blend"} requires Android 10 or later." }
        d.copy(layers = d.layers.map { if (it.id != id) it else {
            require(!it.locked || (visible == null && opacity == null && blend == null)) { "Unlock the layer before changing its appearance." }
            it.copy(visible = visible ?: it.visible, locked = locked ?: it.locked, opacity = opacity ?: it.opacity, blend = blend ?: it.blend)
        } })
    }
    fun moveLayer(up: Boolean) = change { d ->
        require(!d.layer.locked) { "Unlock the layer first." }
        val index = d.layers.indexOf(d.layer); val target = index + if (up) -1 else 1
        require(target in d.layers.indices) { "Already at the edge of the layer stack." }
        val layers = d.layers.toMutableList(); layers.add(target, layers.removeAt(index)); d.copy(layers = layers)
    }
    fun renameLayer(id: String, name: String) = change { d ->
        val title = name.trim()
        require(title.isNotEmpty() && title.length <= 80) { "Use a layer name of 1–80 characters." }
        require(d.layers.any { it.id == id }) { "The selected layer changed." }
        d.copy(layers = d.layers.map { if (it.id == id) it.copy(name = title) else it })
    }
    fun duplicateLayer(id: String) = change { d ->
        require(d.layers.size < 32) { "Layer limit reached." }
        val index = d.layers.indexOfFirst { it.id == id }
        require(index >= 0) { "The selected layer changed." }
        val source = d.layers[index]
        val copy = source.copy(id = newID(), name = (source.name.take(73) + " copy").take(80), locked = false)
        val layers = d.layers.toMutableList().apply { add(index, copy) }
        // One atomic document revision copies the layer through every frame.
        val frames = d.frames.map { f -> f.copy(strokes = f.strokes + f.strokes.filter { it.layerID == id }
            .map { it.copy(id = newID(), layerID = copy.id) }) }
        d.copy(layers = layers, frames = frames, activeLayerID = copy.id)
    }
    fun deleteLayer(id: String) = change { d ->
        require(d.layers.size > 1) { "Keep at least one layer." }
        val source = d.layers.firstOrNull { it.id == id } ?: error("The selected layer changed.")
        require(!source.locked) { "Unlock this layer before deleting it." }
        val index = d.layers.indexOf(source)
        val remaining = d.layers.filterNot { it.id == id }
        d.copy(layers = remaining,
            frames = d.frames.map { f -> f.copy(strokes = f.strokes.filterNot { it.layerID == id }) },
            activeLayerID = if (d.activeLayerID == id) remaining[index.coerceAtMost(remaining.lastIndex)].id else d.activeLayerID)
    }
    fun moveFrame(id: String, earlier: Boolean) = change { d ->
        val index = d.frames.indexOfFirst { it.id == id }
        require(index >= 0) { "The selected frame changed." }
        val target = index + if (earlier) -1 else 1
        require(target in d.frames.indices) { "Already at the edge of the timeline." }
        require(d.frames[index].strokes.none { s -> d.layers.first { it.id == s.layerID }.locked }) {
            "Unlock the frame’s drawing layers before changing its timing."
        }
        val frames = d.frames.toMutableList().apply { add(target, removeAt(index)) }
        d.copy(frames = frames)
    }

}
