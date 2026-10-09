package com.stickdeath.studio

import androidx.compose.runtime.*
import androidx.compose.material3.*
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier

/** Explicit clip selection; drafts are applied as one guarded history transaction. */
@Composable fun AudioClipControls(vm: StudioViewModel, doc: Document, enabled: Boolean, onImport: () -> Unit) {
    var selected by remember(doc.id) { mutableStateOf<String?>(null) }
    Text("Import your licensed WAV: uncompressed 16-bit PCM, mono/stereo, 8–48 kHz, 20 ms–60 s, at most 1 MiB each. Project limit: 16 clips / 2 MiB. Audio is stored inside the local project backup.")
    Button(onImport, enabled = enabled && !vm.importingAudio && doc.audioClips.size < 16) { Text("Import WAV from Files") }
    if (vm.importingAudio) TextButton({ vm.cancelAudioImport() }) { Text("Cancel audio import") }
    Text("Placement is in seconds; tracks 1–4 are independent of drawing layers. Clip preview plays only the selected saved trim, volume and mute. MP4 mixes saved clips over the animation duration. Overlapping clips sum, including on the same track; loud sums are limited to the PCM range. Scene playback mixes saved clips from the selected frame through the end, up to 120 seconds; waveforms are not yet available.")
    if (doc.audioClips.isEmpty()) Text("No audio clips yet.")
    doc.audioClips.sortedWith(compareBy<AudioClip> { it.track }.thenBy { it.start }).forEach { clip ->
        FilterChip(selected == clip.id, { vm.stopAudioPreview(); selected = clip.id },
            { Text("${clip.name} · track ${clip.track} · ${clip.start}s · ${clip.duration}s${if (clip.muted) " · muted" else ""}") }, enabled = enabled)
    }
    val clip = doc.audioClips.firstOrNull { it.id == selected }
    if (clip != null) key(doc.revision, clip.id) {
        var name by remember { mutableStateOf(clip.name) }
        var start by remember { mutableStateOf(clip.start.toString()) }
        var offset by remember { mutableStateOf(clip.sourceOffset.toString()) }
        var duration by remember { mutableStateOf(clip.duration.toString()) }
        var track by remember { mutableStateOf(clip.track.toString()) }
        var volume by remember { mutableStateOf(clip.volume) }
        var muted by remember { mutableStateOf(clip.muted) }
        OutlinedTextField(name, { name = it.take(80) }, label = { Text("Clip name") }, singleLine = true, enabled = enabled)
        OutlinedTextField(start, { start = it.take(20) }, label = { Text("Start on timeline (seconds, 0–3600)") }, singleLine = true, enabled = enabled)
        OutlinedTextField(offset, { offset = it.take(20) }, label = { Text("Source trim start (seconds)") }, singleLine = true, enabled = enabled)
        OutlinedTextField(duration, { duration = it.take(20) }, label = { Text("Trim duration (seconds)") }, singleLine = true, enabled = enabled)
        OutlinedTextField(track, { track = it.take(2) }, label = { Text("Track (1–4)") }, singleLine = true, enabled = enabled)
        Text("Volume ${(volume * 100).toInt()}%")
        Slider(volume, { volume = it }, enabled = enabled)
        FilterChip(muted, { muted = !muted }, { Text("Mute") }, enabled = enabled)
        Button({
            val a = start.toDoubleOrNull(); val b = offset.toDoubleOrNull(); val c = duration.toDoubleOrNull(); val t = track.toIntOrNull()
            if (a == null || b == null || c == null || t == null) vm.report("Enter valid numeric timing and track values.")
            else vm.editAudio(doc, clip.copy(name = name.trim(), start = a, sourceOffset = b, duration = c, track = t, volume = volume, muted = muted))
        }, enabled = enabled) { Text("Apply audio edits") }
        Row {
            TextButton({ vm.previewAudio(doc, clip.id) }, enabled = enabled && !vm.previewingAudio) { Text("Preview saved clip") }
            TextButton({ vm.stopAudioPreview() }, enabled = vm.previewingAudio) { Text("Stop") }
        }
        TextButton({ if (vm.deleteAudio(doc, clip.id)) selected = null }, enabled = enabled) { Text("Delete clip (undo available)") }
    }
    if (vm.message.isNotEmpty()) Text(vm.message)
}
