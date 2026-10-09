package com.stickdeath.studio

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp

class MainActivity : ComponentActivity() {
    private val studio: StudioViewModel by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Color(0xffff343f)), typography = studioTypography) {
                Surface(Modifier.fillMaxSize()) { StudioApp(studio) }
            }
        }
    }
    override fun onStop() { studio.save(); super.onStop() }
}

@Composable private fun StudioApp(vm: StudioViewModel) {
    val moviePicker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("video/mp4")) { vm.finishExport(it) }
    val gifPicker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/gif")) { vm.finishExport(it) }
    val pngPicker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/png")) { vm.finishExport(it) }
    val projectPicker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { vm.finishExport(it) }
    val zipPicker = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { vm.finishExport(it) }
    val artifact = vm.exportArtifact
    LaunchedEffect(artifact, vm.exportPickerRequested) {
        if (artifact != null && !vm.exportPickerRequested) {
            vm.markExportPickerRequested()
            try {
                when (artifact.kind) {
                    ExportKind.MP4 -> moviePicker.launch(artifact.name)
                    ExportKind.GIF -> gifPicker.launch(artifact.name)
                    ExportKind.PNG -> pngPicker.launch(artifact.name)
                    ExportKind.PROJECT -> projectPicker.launch(artifact.name)
                    else -> zipPicker.launch(artifact.name)
                }
            } catch (e: Exception) { vm.cancelExport(); vm.report(e.message ?: "No document picker is available.") }
        }
    }
    val document = vm.document
    if (document == null) ProjectLibrary(vm) else Editor(vm, document)
}

private data class CanvasPreset(val name: String, val width: Int, val height: Int)
private val canvasPresets = listOf(CanvasPreset("Portrait",1080,1920), CanvasPreset("Landscape",1920,1080),
    CanvasPreset("Square",1080,1080), CanvasPreset("TikTok",1080,1920), CanvasPreset("YouTube",1920,1080),
    CanvasPreset("Instagram",1080,1350), CanvasPreset("SD",640,480), CanvasPreset("HD",1280,720))
private data class ProjectDraft(val name: String = "", val width: Int = 1080, val height: Int = 1920,
    val fps: Int = 12, val preset: String = "Portrait", val backgroundColor: Int = -1) {
    val valid get() = name.trim().length in 1..120 && width in 16..4096 && height in 16..4096 && fps in 1..60
    companion object {
        fun from(document: Document) = ProjectDraft(document.name, document.width, document.height, document.fps,
            canvasPresets.firstOrNull { it.width == document.width && it.height == document.height }?.name ?: "Custom", document.backgroundColor)
        val saver = androidx.compose.runtime.saveable.listSaver<ProjectDraft, Any>(
            save = { listOf(it.name,it.width,it.height,it.fps,it.preset,it.backgroundColor) },
            restore = { ProjectDraft(it[0] as String,it[1] as Int,it[2] as Int,it[3] as Int,it[4] as String, it.getOrNull(5) as? Int ?: -1) })
    }
}
/** Opaque RGB picker; stroke opacity is independently captured by each gesture. */
@Composable private fun StudioColorPicker(label: String, color: Int, update: (Int) -> Unit) {
    var expanded by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    val hex = String.format(java.util.Locale.ROOT, "%06X", color and 0x00ffffff)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(28.dp).background(Color(color)))
        Text("$label #$hex")
        TextButton({ expanded = !expanded }) { Text(if (expanded) "Close colors" else "Custom color") }
    }
    if (expanded) {
        var input by remember(color) { mutableStateOf(hex) }
        val digits = input.removePrefix("#")
        val valid = digits.length == 6 && digits.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
        OutlinedTextField(input, { input = it.take(7) }, label = { Text("Hex color (RRGGBB)") },
            singleLine = true, isError = !valid, modifier = Modifier.fillMaxWidth())
        if (!valid) Text("Enter six hexadecimal digits, for example E52B38. The current color is unchanged.")
        TextButton({ if (valid) update(0xff000000.toInt() or digits.toInt(16)) }, enabled = valid) { Text("Apply hex color") }
        listOf("Red" to 16, "Green" to 8, "Blue" to 0).forEach { (channel, shift) ->
            val value = (color ushr shift) and 255
            Text("$channel: $value")
            Slider(value.toFloat(), { amount ->
                val component = amount.toInt().coerceIn(0, 255)
                update(0xff000000.toInt() or ((color and (255 shl shift).inv()) or (component shl shift)))
            }, valueRange = 0f..255f, steps = 254)
        }
    }
}

/** Zero represents a cleared/invalid draft, never a silently restored old value. */
@Composable private fun ProjectNumber(label: String, value: Int, range: IntRange, update: (Int) -> Unit) {
    OutlinedTextField(if (value == 0) "" else value.toString(), { raw ->
        if (raw.length <= 4 && raw.all { it in '0'..'9' }) update(raw.toIntOrNull() ?: 0)
    }, label = { Text(label) }, singleLine = true, isError = value !in range,
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number),
        modifier = Modifier.fillMaxWidth())
    if (value !in range) Text("Enter ${range.first}–${range.last}.")
}

@Composable private fun ProjectConfiguration(draft: ProjectDraft, update: (ProjectDraft) -> Unit) {
    OutlinedTextField(draft.name, { update(draft.copy(name = it.take(120))) }, label = { Text("Project name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    Text("Canvas size · ${draft.width} × ${draft.height}")
    canvasPresets.chunked(2).forEach { pair ->
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            pair.forEach { preset ->
                FilterChip(draft.preset == preset.name, { update(draft.copy(width=preset.width,height=preset.height,preset=preset.name)) },
                    { Text("${preset.name} (${preset.width}×${preset.height})") }, Modifier.weight(1f))
            }
        }
    }
    var customSize by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(draft.preset == "Custom") }
    TextButton({ customSize = !customSize }) { Text(if (customSize) "Hide custom size" else "Custom canvas size") }
    if (customSize) {
        ProjectNumber("Width in pixels", draft.width, 16..4096) { update(draft.copy(width = it, preset = "Custom")) }
        ProjectNumber("Height in pixels", draft.height, 16..4096) { update(draft.copy(height = it, preset = "Custom")) }
        TextButton({ update(draft.copy(width = draft.height, height = draft.width, preset = "Custom")) },
            enabled = draft.width in 16..4096 && draft.height in 16..4096) { Text("Swap width and height") }
    }
    Text("Background")
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        listOf("White" to 0xffffffff, "Black" to 0xff000000, "Gray" to 0xff808080,
            "Red" to 0xffe52b38, "Blue" to 0xff246bfe, "Green" to 0xff22aa55).forEach { (name, value) ->
            FilterChip(draft.backgroundColor == value.toInt(), { update(draft.copy(backgroundColor = value.toInt())) },
                { Text(name) }, Modifier.padding(end = 6.dp))
        }
    }
    StudioColorPicker("Background", draft.backgroundColor) { update(draft.copy(backgroundColor = it)) }
    Text("Frame rate · ${draft.fps} FPS")
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        listOf(6,8,10,12,15,24,30).forEach { value ->
            FilterChip(draft.fps == value, { update(draft.copy(fps=value)) }, { Text("$value") }, Modifier.padding(end=6.dp))
        }
    }
    var customFPS by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(draft.fps !in listOf(6,8,10,12,15,24,30)) }
    TextButton({ customFPS = !customFPS }) { Text(if (customFPS) "Hide custom frame rate" else "Custom frame rate") }
    if (customFPS) ProjectNumber("Frames per second", draft.fps, 1..60) { update(draft.copy(fps = it)) }
    if (!draft.valid) Text("Enter a project name, dimensions from 16 to 4096 pixels and a frame rate from 1 to 60 FPS.")
}

@Composable private fun ProjectLibrary(vm: StudioViewModel) {
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { vm.importProject(it) }
    var draft by androidx.compose.runtime.saveable.rememberSaveable(stateSaver = ProjectDraft.saver) { mutableStateOf(ProjectDraft()) }
    var query by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf("") }
    var alphabetical by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    val projects = remember(vm.library.entries, query, alphabetical) {
        val filtered = vm.library.entries.filter { it.name.contains(query.trim(), ignoreCase = true) }
        if (alphabetical) filtered.sortedWith(compareBy<ProjectEntry> { it.name.lowercase(java.util.Locale.ROOT) }.thenBy { it.id })
        else filtered.sortedWith(compareByDescending<ProjectEntry> { it.modified }.thenBy { it.id })
    }
    LazyColumn(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("StickDeath Studio", style = MaterialTheme.typography.headlineMedium) }
        item {
            Text("Local projects", style = MaterialTheme.typography.titleLarge)
            TextButton({ importer.launch(arrayOf("application/json", "application/octet-stream")) }, enabled = !vm.busy) { Text("Restore Android project backup") }
        }
        item {
            Card { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("New animation")
                ProjectConfiguration(draft) { draft = it }
                Button({ vm.create(draft.name, draft.width, draft.height, draft.fps, draft.backgroundColor) }, enabled = draft.valid && !vm.busy) { Text("Create project") }
            } }
        }
        item { if (vm.library.unreadable > 0) Text("${vm.library.unreadable} unreadable project(s). Original files are preserved.") }
        item { if (vm.message.isNotEmpty()) Text(vm.message) }
        item {
            OutlinedTextField(query, { query = it.take(120) }, label = { Text("Search your projects") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row {
                FilterChip(!alphabetical, { alphabetical = false }, { Text("Recent") })
                FilterChip(alphabetical, { alphabetical = true }, { Text("Name") })
                TextButton({ vm.refresh() }, enabled = !vm.busy) { Text("Refresh") }
            }
            Text("${projects.size} of ${vm.library.entries.size} projects")
            if (projects.isEmpty()) Text(if (query.isBlank()) "Create your first animation above." else "No projects match this search.")
        }
        items(projects, key = { it.id }) { project ->
            Card(Modifier.fillMaxWidth().clickable(enabled = !vm.busy) { vm.open(project.id) }) {
                Column(Modifier.padding(16.dp)) {
                    Text(project.name)
                    Text("${project.width} × ${project.height} · ${project.fps} FPS · ${project.frames} frames")
                    Text("${String.format(java.util.Locale.getDefault(), "%.1f", project.ticks.toDouble() / project.fps)} sec · stored on this device")
                    TextButton({ vm.duplicateProject(project) }, enabled = !vm.busy) { Text("Duplicate project") }
                }
            }
        }
        item { Spacer(Modifier.height(32.dp)) }
    }
}

@Composable private fun Editor(vm: StudioViewModel, doc: Document) {
    // Coalesce slider changes, and flush the final choices when leaving Studio.
    LaunchedEffect(vm.tool, vm.width, vm.strokeOpacity, vm.shapeFilled, vm.shapeEqualSides, vm.smoothing, vm.mirrorMode, vm.color, vm.brushFamily, vm.nibAngle) {
        kotlinx.coroutines.delay(250)
        vm.persistToolSettings()
    }
    DisposableEffect(vm) { onDispose { vm.cancelFill(); vm.persistToolSettings() } }
    val exportProgress by vm.exportProgress.collectAsState()
    var panel by remember { mutableStateOf<String?>(null) }
    var settingsCapture by remember(doc.id) { mutableStateOf(doc) }
    var settingsDraft by remember(doc.id) { mutableStateOf(ProjectDraft.from(doc)) }
    var fitArtwork by remember(doc.id) { mutableStateOf(true) }
    var playing by remember { mutableStateOf(false) }
    var selectedLayerAction by remember(doc.id) { mutableStateOf<String?>(null) }
    var layerName by remember(doc.id) { mutableStateOf("") }
    var previewIndex by remember(doc.id) { mutableIntStateOf(0) }
    BackHandler { if (playing) playing = false else vm.save(close = true) }
    val timelineState = androidx.compose.foundation.lazy.rememberLazyListState()
    LaunchedEffect(playing, doc.id, doc.revision) {
        if (playing) {
            vm.cancelFill()
            val clock = FramePlaybackClock(doc)
            previewIndex = clock.frameAt(0)
            val started = withFrameNanos { it }
            while (playing) {
                withFrameNanos { now -> previewIndex = clock.frameAt(now - started) }
            }
        }
    }
    LaunchedEffect(playing, previewIndex, doc.activeFrameID) {
        val target = if (playing) previewIndex else doc.frames.indexOfFirst { it.id == doc.activeFrameID }
        if (target >= 0 && timelineState.layoutInfo.visibleItemsInfo.none { it.index == target }) timelineState.scrollToItem(target)
    }
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically) {
            TextButton({ playing = false; vm.save(close = true) }, enabled = !vm.closing) { Text("Projects") }
            Text(doc.name, Modifier.padding(horizontal = 8.dp))
            TextButton({ playing = false; settingsCapture = doc; settingsDraft = ProjectDraft.from(doc); panel = "project" }, enabled = !vm.closing) { Text("Project settings") }
            TextButton({ vm.save() }, enabled = !vm.saving) { Text(if (vm.saving) "Saving…" else if (vm.dirty) "Save" else "Saved") }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically) {
            Tool.entries.forEach { tool -> FilterChip(vm.tool == tool, { vm.chooseTool(tool) }, { Text(tool.name) }, enabled = !playing && !vm.closing, modifier = Modifier.padding(horizontal = 4.dp)) }
            TextButton({ panel = "brush" }, enabled = !playing && !vm.closing) { Text("Settings") }
            TextButton({ panel = "export" }, enabled = !playing && !vm.closing && !vm.exporting && vm.exportArtifact == null) { Text("Export") }
            if (vm.exporting) TextButton({ vm.cancelExport() }) { Text("Cancel export") }
            TextButton({ panel = "grid" }, enabled = !playing && !vm.closing) { Text("Grid") }
            TextButton({ panel = "layers" }, enabled = !playing && !vm.closing) { Text("Layers") }
            TextButton({ vm.undo() }, enabled = vm.canUndo && !playing) { Text("Undo") }
            TextButton({ vm.redo() }, enabled = vm.canRedo && !playing) { Text("Redo") }
            TextButton({ playing = !playing }, enabled = !vm.closing) { Text(if (playing) "Stop" else "Play") }
            FilterChip(doc.onion.enabled, { vm.updateOnion(doc.onion.copy(enabled = !doc.onion.enabled)) }, { Text("Onion skin") }, enabled = !playing && !vm.closing)
        }
        Box(Modifier.weight(1f).fillMaxWidth().background(Color(0xff303034)).padding(12.dp), contentAlignment = Alignment.Center) {
            DrawingSurface(vm, doc, if (playing) doc.frames[previewIndex.coerceIn(doc.frames.indices)] else doc.frame, playing, doc.onion.enabled)
        }
        exportProgress?.let { progress ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(progress.stage + (progress.percent?.let { " · $it%" } ?: "…"), Modifier.weight(1f),
                    style = MaterialTheme.typography.bodySmall)
                TextButton({ vm.cancelExport() }) { Text("Cancel export") }
            }
        }
        Text("${doc.fps} FPS · ${doc.layer.name} · ${vm.message}", Modifier.padding(8.dp), style = MaterialTheme.typography.bodySmall)
        LazyRow(Modifier.fillMaxWidth(), state = timelineState, horizontalArrangement = Arrangement.spacedBy(6.dp), contentPadding = PaddingValues(horizontal = 8.dp)) {
            items(doc.frames, key = { it.id }) { frame ->
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Canvas(Modifier.size(80.dp, 60.dp).clipToBounds().clickable(enabled = !playing && !vm.closing) { vm.selectFrame(frame.id) }) {
                        val canvas = drawContext.canvas.nativeCanvas
                        val checkpoint = canvas.save()
                        try {
                            val factor = minOf(size.width / doc.width, size.height / doc.height)
                            canvas.translate((size.width - doc.width * factor) / 2, (size.height - doc.height * factor) / 2)
                            canvas.scale(factor, factor)
                            FrameRenderer.draw(canvas, doc, frame)
                        } finally { canvas.restoreToCount(checkpoint) }
                    }
                    FilterChip(frame.id == (if (playing) doc.frames[previewIndex.coerceIn(doc.frames.indices)].id else doc.activeFrameID), { vm.selectFrame(frame.id) },
                        { Text("${doc.frames.indexOf(frame) + 1} · ${frame.hold} ticks") }, enabled = !playing && !vm.closing)
                }
            }
        }
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            TextButton({ vm.addFrame(false) }, enabled = !playing && !vm.closing) { Text("Add frame") }
            TextButton({ vm.addFrame(true) }, enabled = !playing && !vm.closing) { Text("Duplicate") }
            TextButton({ vm.copyFrame() }, enabled = !playing && !vm.closing) { Text("Copy frame") }
            TextButton({ vm.copyFrame(cut = true) }, enabled = !playing && !vm.closing && doc.frames.size > 1) { Text("Cut frame") }
            TextButton({ vm.pasteFrame() }, enabled = !playing && vm.canPasteFrame) { Text(if (vm.frameClipboardCount > 1) "Paste ${vm.frameClipboardCount} frames" else "Paste frame") }
            TextButton({ panel = "delete" }, enabled = !playing && !vm.closing && doc.frames.size > 1) { Text("Delete frame") }
            TextButton({ panel = "onion" }, enabled = !playing && !vm.closing) { Text("Onion settings") }
            TextButton({ panel = "hold" }, enabled = !playing && !vm.closing) { Text("Frame range") }
            TextButton({ vm.moveFrame(doc.activeFrameID, true) }, enabled = !playing && !vm.closing && doc.frames.first().id != doc.activeFrameID) { Text("Earlier") }
            TextButton({ vm.moveFrame(doc.activeFrameID, false) }, enabled = !playing && !vm.closing && doc.frames.last().id != doc.activeFrameID) { Text("Later") }
        }
    }
    if (panel != null) AlertDialog(onDismissRequest = { panel = null }, title = { Text(when(panel) { "project" -> "Project settings"; "export" -> "Export"; "layers" -> "Layers"; "hold" -> "Frame range & timing"; "onion" -> "Onion skin"; "grid" -> "Canvas grid"; "delete" -> "Delete this frame?"; "renameLayer" -> "Rename layer"; "deleteLayer" -> "Delete layer in every frame?"; "deleteSelection" -> "Delete selected artwork?"; else -> "Tool settings" }) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                when (panel) {
                    "project" -> {
                        ProjectConfiguration(settingsDraft) { settingsDraft = it }
                        FilterChip(fitArtwork, { fitArtwork = !fitArtwork }, { Text("Fit artwork proportionally") })
                        Text("Fit centers artwork on every frame and preserves stroke widths. Without Fit, artwork keeps its coordinates; a canvas that would exclude points is rejected. Locked artwork cannot be fitted. FPS changes duration; exposure ticks stay unchanged. Undo restores the whole change.")
                        if (vm.message.isNotEmpty()) Text(vm.message)
                    }
                    "export" -> {
                        Text("Export the current saved-or-unsaved project snapshot with its project background. ZIP stores each frame once with FPS and exposure ticks in manifest.json.")
                        Button({ vm.prepareExport(ExportKind.PROJECT); panel = null }) { Text("Editable Android project backup") }
                        Text("Restore this backup from the Android project library. It is not the iOS .sdi format.")
                        Button({ vm.prepareExport(ExportKind.MP4); panel = null }) { Text("MP4 video (silent)") }
                        Text("MP4 uses the exact canvas, FPS and frame holds. Requires a compatible device encoder, even dimensions, and at most 120 seconds / 4 megapixels. Android audio mixing is not implemented.")
                        Button({ vm.prepareExport(ExportKind.GIF); panel = null }) { Text("Animated GIF (looping)") }
                        Text("GIF uses 256 colors and the opaque project background. Timing rounds to hundredths of a second; some viewers slow fast frames. Up to 120 seconds / 4 megapixels / 256 MiB. No audio.")
                        Button({ vm.prepareExport(ExportKind.PNG); panel = null }) { Text("Current frame PNG") }
                        Button({ vm.prepareExport(ExportKind.SEQUENCE); panel = null }) { Text("PNG sequence ZIP") }
                        Button({ vm.prepareExport(ExportKind.SPRITESHEET); panel = null }) { Text("Spritesheet PNG + timing ZIP") }
                        Text("Spritesheets preserve every frame at original size, up to 8 megapixels and an 8192-pixel edge. Larger projects can use PNG sequence.")
                    }
                    "brush" -> {
                        if (vm.tool == Tool.Text) {
                            Text("Editable text · system sans serif. Up to 512 characters / 8 lines. Tap the canvas to place new text; select text with Lasso to edit it.")
                            OutlinedTextField(vm.textContent, { if (it.length <= 512) vm.textContent = it }, label = { Text("Text content") }, maxLines = 8)
                            Text("Font size: ${vm.textFontSize.toInt()} pixels")
                            Slider(vm.textFontSize, { vm.textFontSize = it }, valueRange = 8f..128f)
                            StudioColorPicker("Text color", vm.color) { vm.color = it or 0xff000000.toInt() }
                            Button({ vm.addText(doc, Point(8f, 8f)) }) { Text("Add new text at top left") }
                            if (vm.selectedText != null) {
                                Button({ vm.editText(doc) }) { Text("Apply to selected text") }
                                TextButton({ panel = "deleteSelection" }) { Text("Delete selected text") }
                            }
                        } else if (vm.tool == Tool.Fill) {
                            Text("Tap to fill from the merged visible frame, including background, layer opacity and blends. Hidden layers, onion skin, grid and selection handles are excluded. The new fill belongs to the active visible unlocked layer.")
                            StudioColorPicker("Fill color", vm.color) { vm.cancelFill(); vm.color = it or 0xff000000.toInt() }
                            Text("Tolerance: ${vm.fillTolerance} / 255")
                            Slider(vm.fillTolerance.toFloat(), { vm.configureFill(tolerance = it.toInt()) }, valueRange = 0f..255f, steps = 254)
                            Text("Maximum RGB channel difference from the tapped pixel. Zero matches exactly; 255 matches all colors.")
                            FilterChip(vm.fillContiguous, { vm.configureFill(contiguous = !vm.fillContiguous) }, { Text("Contiguous") })
                            Text(if (vm.fillContiguous) "Only the connected region (four neighboring pixels)." else "Every matching pixel across the canvas, including disconnected regions.")
                            Text("Up to 4,194,304 canvas pixels and 20,000 pixel runs per fill, with a five-second work limit. Fills have pixel edges and cannot yet be selected, transformed or resized with the canvas. Undo/Redo and layer operations remain available.")
                            if (vm.filling) TextButton({ vm.cancelFill(); vm.report("Fill cancelled; no fill was added.") }) { Text("Cancel fill") }
                        } else if (vm.tool == Tool.Eyedropper) {
                            Text("Tap to sample the visible canvas, including layer opacity and erased areas. Hidden layers, onion skin and selection handles are excluded. Sampling returns to your previous color drawing tool.")
                        } else if (vm.tool == Tool.Hand) {
                            Text("Hand · ${(vm.viewportZoom * 100).toInt()}%")
                            Text("Drag to pan; pinch to zoom around your fingers. This moves the view, not the artwork.")
                            Slider(vm.viewportZoom, { vm.viewport(it, 0f, 0f) }, valueRange = 0.25f..8f)
                            TextButton({ vm.fitViewport() }) { Text("Fit canvas") }
                        } else if (vm.tool == Tool.Lasso || vm.tool == Tool.Move) {
                            Text("Pixel fills cannot be selected or transformed. Lasso encloses whole unlocked drawings. A selection switches to Move. Drag inside its box; corners resize and the top handle rotates. Keep transformed drawings inside the canvas.")
                            Text("${vm.selectedStrokeIDs.size} selected objects")
                            if (vm.selectedText != null) TextButton({ vm.chooseTool(Tool.Text) }) { Text("Edit text") }
                            FilterChip(vm.selectionPreservesAspect,
                                { vm.chooseSelectionAspectLock(!vm.selectionPreservesAspect) },
                                { Text("Keep proportions") })
                            Text(if (vm.selectionPreservesAspect) "Corner handles scale both axes together." else "Corner handles resize width and height independently. Stroke thickness follows the geometric mean of both scales.")
                            Row {
                                SelectionShape.entries.forEach { shape ->
                                    FilterChip(vm.selectionShape == shape, { vm.chooseSelectionShape(shape) }, { Text(shape.name) })
                                }
                            }
                            Row(Modifier.horizontalScroll(rememberScrollState())) {
                                SelectionMode.entries.forEach { mode ->
                                    FilterChip(vm.tool == Tool.Lasso && vm.selectionMode == mode,
                                        { vm.chooseSelectionMode(mode) }, { Text(mode.name) })
                                }
                            }
                            Text("Choose Add or Subtract, then draw another lasso. A nonempty selection returns to Move.")
                            Row {
                                TextButton({ vm.selectVisibleArtwork() }) { Text("Select all") }
                                TextButton({ vm.selectVisibleArtwork(invert = true) }) { Text("Invert") }
                            }
                            Text("Copy and Cut keep editable drawings. Paste uses the active layer and original coordinates.")
                            Row(Modifier.horizontalScroll(rememberScrollState())) {
                                TextButton({ vm.copyArtwork() }, enabled = vm.selectedStrokeIDs.isNotEmpty()) { Text("Copy") }
                                TextButton({ vm.copyArtwork(cut = true) }, enabled = vm.selectedStrokeIDs.isNotEmpty()) { Text("Cut") }
                                TextButton({ vm.pasteArtwork() }, enabled = vm.canPasteArtwork) { Text("Paste") }
                                TextButton({ vm.duplicateArtwork() }, enabled = vm.selectedStrokeIDs.isNotEmpty()) { Text("Duplicate artwork") }
                            }
                            Row {
                                TextButton({ vm.flipArtwork(true) }, enabled = vm.selectedStrokeIDs.isNotEmpty()) { Text("Flip horizontal") }
                                TextButton({ vm.flipArtwork(false) }, enabled = vm.selectedStrokeIDs.isNotEmpty()) { Text("Flip vertical") }
                            }
                            if (vm.selectedStrokeIDs.isNotEmpty()) {
                                Text("Nudge in canvas pixels")
                                Row {
                                    listOf(1f, 5f, 10f).forEach { step ->
                                        FilterChip(vm.selectionNudge == step, { vm.selectionNudge = step; vm.persistToolSettings() }, { Text("${step.toInt()} px") })
                                    }
                                }
                                Row(Modifier.horizontalScroll(rememberScrollState())) {
                                    TextButton({ vm.positionSelection(dx = -vm.selectionNudge) }) { Text("Nudge left") }
                                    TextButton({ vm.positionSelection(dx = vm.selectionNudge) }) { Text("Nudge right") }
                                    TextButton({ vm.positionSelection(dy = -vm.selectionNudge) }) { Text("Nudge up") }
                                    TextButton({ vm.positionSelection(dy = vm.selectionNudge) }) { Text("Nudge down") }
                                }
                                Text("Align selection to canvas")
                                Row(Modifier.horizontalScroll(rememberScrollState())) {
                                    ArtworkAlignment.entries.forEach { alignment ->
                                        TextButton({ vm.positionSelection(alignment = alignment) }) { Text(alignment.label) }
                                    }
                                }
                                Text("Moves the selected group together, keeping spacing and layers. Each action is one Undo step.")
                                Text("Stacking within each selected layer")
                                Row(Modifier.horizontalScroll(rememberScrollState())) {
                                    TextButton({ vm.orderArtwork(ArtworkOrder.Forward) }) { Text("Forward") }
                                    TextButton({ vm.orderArtwork(ArtworkOrder.Backward) }) { Text("Backward") }
                                    TextButton({ vm.orderArtwork(ArtworkOrder.Front) }) { Text("Bring to front") }
                                    TextButton({ vm.orderArtwork(ArtworkOrder.Back) }) { Text("Send to back") }
                                }
                                Text("Crossing an eraser mark changes whether it erases this artwork. Layer stacking stays unchanged.")
                                Text("Move selection to layer")
                                Text("Keeps editable strokes in this frame. Destination opacity/blend apply; source-layer eraser marks stay behind. Moved strokes sit above existing destination marks.")
                                Row(Modifier.horizontalScroll(rememberScrollState())) {
                                    doc.layers.forEach { target ->
                                        TextButton({ vm.moveArtworkToLayer(target.id) },
                                            enabled = target.visible && !target.locked && target.opacity > 0f) { Text(target.name) }
                                    }
                                }
                            }
                            TextButton({ vm.deselect() }) { Text("Deselect") }
                            TextButton({ panel = "deleteSelection" }, enabled = vm.selectedStrokeIDs.isNotEmpty()) { Text("Delete selected artwork") }
                        } else {
                        if (vm.tool.isDrawing && vm.tool != Tool.Eraser) {
                            Text("Mirror around canvas center")
                            Row(Modifier.horizontalScroll(rememberScrollState())) {
                                MirrorMode.entries.forEach { mode ->
                                    FilterChip(vm.mirrorMode == mode, { vm.mirrorMode = mode }, { Text(mode.name) })
                                }
                            }
                            Text("Mirrored marks stay individually editable; Undo removes the whole gesture.")
                        }
                        if (vm.tool == Tool.Pencil) {
                            Text("Brush family")
                            Row(Modifier.horizontalScroll(rememberScrollState())) {
                                BrushFamily.entries.forEach { family ->
                                    FilterChip(vm.brushFamily == family, { vm.chooseBrush(family) },
                                        { Text(family.name.replace("Pen", " Pen")) })
                                }
                            }
                            if (vm.brushFamily in listOf(BrushFamily.Calligraphy, BrushFamily.DipPen, BrushFamily.Hatch)) {
                                Text("Nib angle: ${vm.nibAngle.toInt()}°")
                                Slider(vm.nibAngle, { vm.nibAngle = it }, valueRange = -180f..180f,
                                    onValueChangeFinished = { vm.persistToolSettings() })
                            }
                            TextButton({ vm.resetSelectedBrush() }) { Text("Reset this brush") }
                            Text("Size, opacity, smoothing and nib angle are remembered separately for each brush.")
                            Text("Textures retain their pattern when saved or exported. Dip Pen varies width with stroke direction; stylus pressure is not yet supported.")
                        }
                        Text("Width: ${vm.width.toInt()} pixels")
                        Slider(vm.width, { vm.width = it }, valueRange = 1f..128f)
                        Text("${if (vm.tool == Tool.Eraser) "Erase strength" else "Opacity"}: ${(vm.strokeOpacity * 100).toInt()}%")
                        Slider(vm.strokeOpacity, { vm.strokeOpacity = it }, valueRange = 0f..1f)
                        if (vm.tool == Tool.Pencil || vm.tool == Tool.Eraser) {
                            Text("Smoothing: ${vm.smoothing.toInt()}")
                            Slider(vm.smoothing, { vm.smoothing = it }, valueRange = 0f..10f, steps = 9)
                            Text("Higher smoothing steadies the stroke with more pointer lag. Zero follows your input directly.")
                        }
                        if (vm.tool.isSelectable) listOf(0xffe52b38, 0xff000000, 0xffffffff, 0xff246bfe, 0xff22aa55).forEach { value ->
                            TextButton({ vm.color = value.toInt() }) { Text(if (vm.color == value.toInt()) "● Selected color" else "Choose color", color = Color(value)) }
                        }
                        if (vm.tool.isSelectable) StudioColorPicker("Drawing color", vm.color) { vm.color = it }
                        if (vm.tool == Tool.Eraser) Text("Erases drawing marks on the active layer only.")
                        if (vm.tool.isClosedShape) {
                            FilterChip(vm.shapeFilled, { vm.shapeFilled = !vm.shapeFilled }, { Text("Filled shape") })
                            FilterChip(vm.shapeEqualSides, { vm.shapeEqualSides = !vm.shapeEqualSides },
                                { Text(when (vm.tool) { Tool.Rectangle -> "Square"; Tool.Ellipse -> "Circle"; else -> "Equal width and height" }) })
                            Text("Drag from one corner to the opposite corner. Lasso the finished shape to move, resize or rotate it.")
                        } else if (vm.tool == Tool.Line) Text("Drag between the two endpoints. Lasso the line to move or rotate it.")
                        }
                    }
                    "layers" -> {
                        Button({ vm.addLayer() }) { Text("Add layer") }
                        doc.layers.forEach { layer ->
                            TextButton({ vm.selectLayer(layer.id) }) { Text((if (layer.id == doc.activeLayerID) "● " else "") + layer.name) }
                            Row { TextButton({ vm.updateLayer(layer.id, visible = !layer.visible) }, enabled = !layer.locked) { Text(if (layer.visible) "Hide" else "Show") }
                                TextButton({ vm.updateLayer(layer.id, locked = !layer.locked) }) { Text(if (layer.locked) "Unlock" else "Lock") } }
                            Row(Modifier.horizontalScroll(rememberScrollState())) {
                                TextButton({ selectedLayerAction = layer.id; layerName = layer.name; panel = "renameLayer" }) { Text("Rename") }
                                TextButton({ vm.duplicateLayer(layer.id) }, enabled = doc.layers.size < 32) { Text("Duplicate layer") }
                                TextButton({ selectedLayerAction = layer.id; panel = "deleteLayer" }, enabled = !layer.locked && doc.layers.size > 1) { Text("Delete layer") }
                            }
                            Text("Blend: ${layer.blend.label}")
                            Row(Modifier.horizontalScroll(rememberScrollState())) {
                                LayerBlend.entries.forEach { blend ->
                                    FilterChip(selected = layer.blend == blend,
                                        onClick = { vm.updateLayer(layer.id, blend = blend) },
                                        enabled = !layer.locked && FrameRenderer.supports(blend),
                                        label = { Text(blend.label) })
                                }
                            }
                            if (!FrameRenderer.supports(LayerBlend.Multiply)) Text("Disabled blend modes require Android 10 or later.")
                            var opacity by remember(layer.id, layer.opacity) { mutableFloatStateOf(layer.opacity) }
                            Slider(opacity, { opacity = it }, enabled = !layer.locked, onValueChangeFinished = { vm.updateLayer(layer.id, opacity = opacity) })
                        }
                        Row { TextButton({ vm.moveLayer(true) }) { Text("Move active up") }; TextButton({ vm.moveLayer(false) }) { Text("Move active down") } }
                    }
                    "grid" -> {
                        FilterChip(doc.grid.enabled, { vm.updateGrid(doc.grid.copy(enabled = !doc.grid.enabled)) }, { Text("Show canvas grid") })
                        var spacing by remember(doc.id, doc.grid.spacing) { mutableFloatStateOf(doc.grid.spacing.toFloat()) }
                        Text("Spacing: ${spacing.toInt()} canvas pixels")
                        Slider(spacing, { spacing = it }, valueRange = 8f..256f, onValueChangeFinished = { vm.updateGrid(doc.grid.copy(spacing = spacing.toInt())) })
                        var opacity by remember(doc.id, doc.grid.opacity) { mutableFloatStateOf(doc.grid.opacity) }
                        Text("Opacity: ${(opacity * 100).toInt()}%")
                        Slider(opacity, { opacity = it }, onValueChangeFinished = { vm.updateGrid(doc.grid.copy(opacity = opacity)) })
                        Row {
                            listOf("Gray" to 0xff777777.toInt(), "White" to -1, "Blue" to 0xff3399ff.toInt()).forEach { (name, color) ->
                                FilterChip(doc.grid.color == color, { vm.updateGrid(doc.grid.copy(color = color)) }, { Text(name) })
                            }
                        }
                        Text("Grid guides save with the project and follow canvas zoom. They stay out of playback, thumbnails, color sampling and rendered exports.")
                    }
                    "onion" -> {
                        FilterChip(doc.onion.enabled, { vm.updateOnion(doc.onion.copy(enabled = !doc.onion.enabled)) }, { Text("Show onion skin") })
                        Text("Previous frames")
                        Row { (0..4).forEach { count ->
                            FilterChip(doc.onion.previous == count, { vm.updateOnion(doc.onion.copy(previous = count)) }, { Text("$count") })
                        } }
                        Text("Next frames")
                        Row { (0..4).forEach { count ->
                            FilterChip(doc.onion.next == count, { vm.updateOnion(doc.onion.copy(next = count)) }, { Text("$count") })
                        } }
                        var opacity by remember(doc.id, doc.onion.opacity) { mutableFloatStateOf(doc.onion.opacity) }
                        Text("Ghost opacity: ${(opacity * 100).toInt()}%")
                        Slider(opacity, { opacity = it }, onValueChangeFinished = { vm.updateOnion(doc.onion.copy(opacity = opacity)) })
                        FilterChip(doc.onion.tinted, { vm.updateOnion(doc.onion.copy(tinted = !doc.onion.tinted)) }, { Text("Red previous / blue next") })
                        Text("Farther frames fade gradually. Guides stay out of playback and exports; your settings save with this project.")
                    }
                    "hold" -> FrameRangeControls(vm, doc, enabled = !playing && !vm.closing) { panel = null }
                    "renameLayer" -> OutlinedTextField(layerName, { layerName = it.take(80) }, label = { Text("Layer name") }, singleLine = true)
                    "deleteLayer" -> Text("Remove this layer and all its drawings from every frame? Other layers stay unchanged. Undo restores the whole layer.")
                    "deleteSelection" -> Text("Deletes only the explicitly selected drawings. Undo restores them.")
                    "delete" -> Text("Deletes only the active frame. Undo restores it.")
                }
            }
        }, confirmButton = {
            TextButton({
                if (panel == "project") {
                    if (vm.document == settingsCapture && settingsDraft.name.trim() == settingsCapture.name &&
                        settingsDraft.width == settingsCapture.width && settingsDraft.height == settingsCapture.height && settingsDraft.fps == settingsCapture.fps && settingsDraft.backgroundColor == settingsCapture.backgroundColor) {
                        panel = null; return@TextButton
                    }
                    if (vm.updateProject(settingsCapture, settingsDraft.name, settingsDraft.width, settingsDraft.height, settingsDraft.fps, fitArtwork, settingsDraft.backgroundColor)) panel = null
                    return@TextButton
                }
                when (panel) {
                    "delete" -> vm.deleteFrame()
                    "deleteSelection" -> vm.deleteSelection()
                    "deleteLayer" -> selectedLayerAction?.let { vm.deleteLayer(it) }
                    "renameLayer" -> selectedLayerAction?.let { vm.renameLayer(it, layerName) }
                }
                panel = null; selectedLayerAction = null
            }, enabled = !vm.closing && (panel != "renameLayer" || layerName.isNotBlank()) && (panel != "project" || settingsDraft.valid)) {
                Text(if (panel == "project") "Apply settings" else if (panel == "delete" || panel == "deleteLayer" || panel == "deleteSelection") "Delete" else if (panel == "renameLayer") "Save name" else "Done")
            }
        }, dismissButton = {
            if (panel == "project" || panel == "delete" || panel == "deleteLayer" || panel == "deleteSelection" || panel == "renameLayer") {
                TextButton({ panel = null; selectedLayerAction = null }) { Text("Cancel") }
            }
        })
}

private fun selectionHandles(bounds: ArtworkBounds, width: Int, height: Int, radius: Float): List<Pair<String, Point>> {
    fun clipped(x: Float, y: Float) = Point(x.coerceIn(radius, width-radius), y.coerceIn(radius, height-radius))
    return listOf("rotate" to clipped(bounds.center.x, if (bounds.top > radius*3) bounds.top-radius*2 else bounds.bottom+radius*2),
        "scale" to clipped(bounds.left,bounds.top), "scale" to clipped(bounds.right,bounds.top),
        "scale" to clipped(bounds.left,bounds.bottom), "scale" to clipped(bounds.right,bounds.bottom))
}

@Composable private fun DrawingSurface(vm: StudioViewModel, doc: Document, frame: Frame, playing: Boolean, onion: Boolean) {
    var pending by remember(doc.id, doc.revision, vm.tool) { mutableStateOf<List<Point>>(emptyList()) }
    var pendingSeed by remember(doc.id) { mutableStateOf(0) }
    var transformed by remember(doc.id, doc.revision, vm.tool) { mutableStateOf<Frame?>(null) }
    LaunchedEffect(doc.id, doc.width, doc.height) { vm.fitViewport() }
    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds().onSizeChanged { vm.fitViewport() }
        .pointerInput(doc.id, doc.width, doc.height, vm.tool, playing, vm.closing) {
            if (vm.tool == Tool.Hand && !playing && !vm.closing) detectTransformGestures { centroid, pan, zoom, _ ->
                val old = vm.viewportZoom
                val next = (old * zoom).coerceIn(0.25f, 8f)
                val ratio = next / old
                val cx = centroid.x - size.width / 2f; val cy = centroid.y - size.height / 2f
                val fit = minOf(size.width.toFloat() / doc.width, size.height.toFloat() / doc.height)
                val canvasWidth = doc.width * fit * next; val canvasHeight = doc.height * fit * next
                val limitX = ((canvasWidth + size.width) / 2 - minOf(48f, canvasWidth / 2)).coerceAtLeast(0f)
                val limitY = ((canvasHeight + size.height) / 2 - minOf(48f, canvasHeight / 2)).coerceAtLeast(0f)
                vm.viewport(next, (cx - (cx - vm.viewportX) * ratio + pan.x).coerceIn(-limitX, limitX),
                    (cy - (cy - vm.viewportY) * ratio + pan.y).coerceIn(-limitY, limitY))
            }
        }, contentAlignment = Alignment.Center) {
        val ratio = doc.width.toFloat() / doc.height
        val canvasWidth = minOf(maxWidth, maxHeight * ratio)
        val canvasHeight = canvasWidth / ratio
        Canvas(Modifier.size(canvasWidth, canvasHeight).graphicsLayer {
            scaleX = vm.viewportZoom; scaleY = vm.viewportZoom
            translationX = vm.viewportX; translationY = vm.viewportY
        }.clipToBounds().pointerInput(doc.id, doc.revision, vm.tool, vm.width, vm.color, vm.strokeOpacity, vm.smoothing, vm.mirrorMode, vm.shapeFilled, vm.shapeEqualSides, playing, vm.closing, vm.selectedStrokeIDs, vm.selectionMode, vm.selectionShape, vm.selectionPreservesAspect, vm.brushFamily, vm.nibAngle) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                if (playing || vm.closing || vm.tool == Tool.Hand) return@awaitEachGesture
                val tool = vm.tool; val width = vm.width; val color = vm.color; val opacity = vm.strokeOpacity
                val mirror = vm.mirrorMode
                val brush = vm.brushFamily; val nibAngle = vm.nibAngle; val brushSeed = newID().hashCode(); pendingSeed = brushSeed
                val drawing = tool.isDrawing
                val filled = vm.shapeFilled && tool.isClosedShape
                val equalSides = vm.shapeEqualSides
                if (drawing && (doc.layer.locked || !doc.layer.visible || doc.layer.opacity == 0f)) return@awaitEachGesture
                fun point(x: Float, y: Float) = Point((x * doc.width / size.width).coerceIn(0f, doc.width.toFloat()), (y * doc.height / size.height).coerceIn(0f, doc.height.toFloat()))
                val first = point(down.position.x, down.position.y)
                val points = mutableListOf(first)
                val smoother = StrokeSmoother(first, if (tool == Tool.Pencil || tool == Tool.Eraser) vm.smoothing else 0f)
                val ids = vm.selectedStrokeIDs
                val selectionMode = vm.selectionMode
                val selectionShape = vm.selectionShape
                val preservesAspect = vm.selectionPreservesAspect
                val bounds = ArtworkSelection.bounds(doc.frame, ids)
                val radius = minOf(22f * doc.width / size.width / vm.viewportZoom, minOf(doc.width,doc.height)/4f)
                val handle = if (tool == Tool.Move && bounds != null) selectionHandles(bounds,doc.width,doc.height,radius)
                    .filter { kotlin.math.hypot(it.second.x-first.x,it.second.y-first.y) <= radius }
                    .minByOrNull { kotlin.math.hypot(it.second.x-first.x,it.second.y-first.y) }?.first else null
                if (tool == Tool.Move && (bounds == null || (handle == null && !bounds.contains(first)))) return@awaitEachGesture
                fun movement(current: Point): ArtworkTransform {
                    val b = bounds ?: return ArtworkTransform()
                    val ax = first.x-b.center.x; val ay = first.y-b.center.y
                    val bx = current.x-b.center.x; val by = current.y-b.center.y
                    return when(handle) {
                        "scale" -> if (preservesAspect) {
                            ArtworkTransform(scale = ((ax*bx+ay*by)/(ax*ax+ay*ay).coerceAtLeast(0.001f)).coerceIn(0.25f,4f))
                        } else {
                            ArtworkTransform(scale = (if (kotlin.math.abs(ax) > 0.001f) bx/ax else 1f).coerceIn(0.25f,4f),
                                heightScale = (if (kotlin.math.abs(ay) > 0.001f) by/ay else 1f).coerceIn(0.25f,4f))
                        }
                        "rotate" -> {
                            var angle = ((kotlin.math.atan2(by,bx)-kotlin.math.atan2(ay,ax))*180/Math.PI).toFloat()
                            if (angle > 180) angle -= 360; if (angle < -180) angle += 360
                            ArtworkTransform(angle = angle)
                        }
                        else -> ArtworkTransform(dx = current.x-first.x, dy = current.y-first.y)
                    }
                }
                var overflow = false
                if (tool != Tool.Move && tool != Tool.Fill && tool != Tool.Eyedropper && tool != Tool.Text && !tool.isShape) pending = points.toList()
                down.consume()
                try {
                    while (true) {
                        val event = awaitPointerEvent()
                        // A second touch cancels the single-object gesture without committing.
                        if (event.changes.any { it.id != down.id && it.pressed }) break
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        val current = point(change.position.x, change.position.y)
                        if (tool == Tool.Move && bounds != null) transformed = movement(current).apply(doc.frame, ids, bounds)
                        else if (tool == Tool.Fill || tool == Tool.Eyedropper || tool == Tool.Text) {
                            val dx = current.x - first.x; val dy = current.y - first.y
                            val tolerance = 8f * doc.width / size.width / vm.viewportZoom
                            if (dx * dx + dy * dy > tolerance * tolerance) overflow = true
                        }
                        else if (tool == Tool.Lasso && selectionShape == SelectionShape.Rectangle) {
                            pending = ShapePath.points(Tool.Rectangle, first, current, false)
                        }
                        else if (tool.isShape) pending = ShapePath.points(tool, first, current, equalSides)
                        else {
                            val cap = if (tool == Tool.Lasso) 1024 else 8192
                            val next = smoother.next(current)
                            if (points.last() != next) {
                                if (points.size < cap) points.add(next) else overflow = true
                            }
                            // Preserve the actual lift-off endpoint. This same
                            // final path is previewed and then committed once.
                            if (!change.pressed && points.last() != current) {
                                if (points.size < cap) points.add(current) else overflow = true
                            }
                            pending = points.toList()
                        }
                        change.consume()
                        if (!change.pressed) {
                            if (overflow) vm.report(if (tool == Tool.Text) "Tap without dragging to place text." else if (tool == Tool.Eyedropper) "Tap without dragging to sample a color." else if (tool == Tool.Fill) "Tap without dragging to fill." else "Outline too long. Draw a simpler outline.")
                            else when(tool) {
                                Tool.Text -> vm.addText(doc, first)
                                Tool.Eyedropper -> vm.sampleColor(doc, current)
                                Tool.Fill -> vm.fillAt(doc, first)
                                Tool.Lasso -> vm.selectArea(doc, if (selectionShape == SelectionShape.Rectangle) pending else points, selectionMode, ids, selectionShape)
                                Tool.Move -> vm.transformSelection(doc, ids, movement(current))
                                else -> vm.commitStroke(doc, if (tool.isShape) pending else points, tool, width, color, filled, opacity, mirror, brush, brushSeed, nibAngle)
                            }
                            break
                        }
                    }
                } finally { pending = emptyList(); transformed = null }
            }
        }) {
            val canvas = drawContext.canvas.nativeCanvas
            val checkpoint = canvas.save()
            try {
                canvas.scale(size.width / doc.width, size.height / doc.height)
                val live = if (pending.isNotEmpty() && !playing && vm.tool.isDrawing)
                    Stroke(layerID = doc.activeLayerID, points = pending, color = vm.color, width = vm.width, tool = vm.tool,
                        filled = vm.shapeFilled && (vm.tool.isClosedShape), opacity = vm.strokeOpacity,
                        brush = if (vm.tool == Tool.Pencil) vm.brushFamily else BrushFamily.Round, brushSeed = pendingSeed, nibAngle = vm.nibAngle)
                        .takeIf { runCatching { BrushRenderer.work(it) }.isSuccess } else null
                val shown = if (!playing) transformed ?: frame else frame
                val preview = if (live != null) shown.copy(strokes = shown.strokes + live.mirrored(doc.width, doc.height, vm.mirrorMode)) else shown
                if (onion && !playing) FrameRenderer.drawOnion(canvas, doc, preview)
                else FrameRenderer.draw(canvas, doc, preview)
                if (!playing) {
                    val unit = doc.width / size.width / vm.viewportZoom
                    if (doc.grid.enabled && doc.grid.opacity > 0f) {
                        val gridPaint = android.graphics.Paint().apply {
                            color = doc.grid.color; alpha = (doc.grid.opacity * 255).toInt(); strokeWidth = unit
                        }
                        for (x in doc.grid.spacing until doc.width step doc.grid.spacing)
                            canvas.drawLine(x.toFloat(), 0f, x.toFloat(), doc.height.toFloat(), gridPaint)
                        for (y in doc.grid.spacing until doc.height step doc.grid.spacing)
                            canvas.drawLine(0f, y.toFloat(), doc.width.toFloat(), y.toFloat(), gridPaint)
                    }
                    val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                        color = 0xffe52b38.toInt(); style = android.graphics.Paint.Style.STROKE; strokeWidth = 1.5f*unit
                        pathEffect = android.graphics.DashPathEffect(floatArrayOf(5f*unit,4f*unit),0f)
                    }
                    if (vm.tool == Tool.Lasso && pending.isNotEmpty()) {
                        val path = android.graphics.Path().apply {
                            moveTo(pending.first().x,pending.first().y)
                            pending.drop(1).forEach { lineTo(it.x,it.y) }; close()
                        }
                        canvas.drawPath(path,paint)
                    }
                    val bounds = ArtworkSelection.bounds(shown,vm.selectedStrokeIDs)
                    if (bounds != null) {
                        canvas.drawRect(bounds.left,bounds.top,bounds.right,bounds.bottom,paint)
                        if (vm.tool == Tool.Move) {
                            val radius = minOf(22f*unit,minOf(doc.width,doc.height)/4f)
                            selectionHandles(bounds,doc.width,doc.height,radius).forEach { (kind,p) ->
                                paint.pathEffect = null; paint.style = android.graphics.Paint.Style.FILL
                                paint.color = if (kind == "rotate") 0xffe52b38.toInt() else 0xffffffff.toInt()
                                canvas.drawCircle(p.x,p.y,6f*unit,paint)
                                paint.style = android.graphics.Paint.Style.STROKE; paint.color = 0xffe52b38.toInt()
                                canvas.drawCircle(p.x,p.y,6f*unit,paint)
                            }
                        }
                    }
                }
            } finally { canvas.restoreToCount(checkpoint) }
        }
    }
}


@Composable
private fun FrameRangeControls(vm: StudioViewModel, document: Document, enabled: Boolean, onApplied: () -> Unit) {
    val captured = remember { document }
    var firstText by remember { mutableStateOf((captured.frames.indexOfFirst { it.id == captured.activeFrameID } + 1).toString()) }
    var countText by remember { mutableStateOf("1") }
    var ticksText by remember { mutableStateOf(captured.frame.hold.toString()) }
    var pendingDelete by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    val first = firstText.toIntOrNull()
    val count = countText.toIntOrNull()
    val ticks = ticksText.toIntOrNull()
    val current = document == captured && enabled
    val validRange = first != null && count != null && first >= 1 && count in 1..96 &&
        first <= captured.frames.size && count <= captured.frames.size - first + 1
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(firstText, { firstText = it.filter(Char::isDigit).take(4) }, label = { Text("First frame (1–${captured.frames.size})") }, singleLine = true)
        OutlinedTextField(countText, { countText = it.filter(Char::isDigit).take(2) }, label = { Text("Number of frames (1–96)") }, singleLine = true)
        OutlinedTextField(ticksText, { ticksText = it.filter(Char::isDigit).take(3) }, label = { Text("Exposure ticks per frame (1–600)") }, singleLine = true)
        if (validRange) Text("Frames $first through ${first!! + count!! - 1}")
        if (!current) Text("Project changed. Close and reopen this panel before applying.")
        Button({
            if (first != null && count != null && ticks != null && vm.editFrameRange(captured, first, count, ticks, false)) onApplied()
        }, enabled = current && validRange && ticks != null && ticks in 1..600) { Text("Apply exposure to range") }
        Button({
            if (first != null && count != null && vm.editFrameRange(captured, first, count, null, true)) onApplied()
        }, enabled = current && validRange && count != null && count >= 2) { Text("Reverse range") }
        Row {
            TextButton({ if (first != null && count != null && vm.copyFrameRange(captured, first, count)) onApplied() },
                enabled = current && validRange) { Text("Copy range") }
            TextButton({ if (first != null && count != null && vm.copyFrameRange(captured, first, count, cut = true)) onApplied() },
                enabled = current && validRange && count != null && count < captured.frames.size) { Text("Cut range") }
        }
        Row {
            TextButton({ if (first != null && count != null && vm.moveFrameRange(captured, first, count, true)) onApplied() },
                enabled = current && validRange && first != null && first > 1) { Text("Move earlier") }
            TextButton({ if (first != null && count != null && vm.moveFrameRange(captured, first, count, false)) onApplied() },
                enabled = current && validRange && first != null && count != null && first + count - 1 < captured.frames.size) { Text("Move later") }
        }
        Button({ if (first != null && count != null && vm.duplicateFrameRange(captured, first, count)) onApplied() },
            enabled = current && validRange && count != null && captured.frames.size + count <= 500) { Text("Duplicate range") }
        TextButton({ if (first != null && count != null) pendingDelete = first to count },
            enabled = current && validRange && count != null && count < captured.frames.size) { Text("Delete range…") }
        pendingDelete?.let { requested ->
            AlertDialog(onDismissRequest = { pendingDelete = null },
                title = { Text("Delete selected frames?") },
                text = { Text("Delete frames ${requested.first} through ${requested.first + requested.second - 1}? One Undo restores them.") },
                confirmButton = { TextButton({
                    pendingDelete = null
                    if (vm.deleteFrameRange(captured, requested.first, requested.second)) onApplied()
                }, enabled = current) { Text("Delete frames") } },
                dismissButton = { TextButton({ pendingDelete = null }) { Text("Cancel") } })
        }
        Text("Reverse preserves each frame's artwork and exposure. One Undo restores the whole edit. Frame identities and the selected frame stay intact.")
    }
}
