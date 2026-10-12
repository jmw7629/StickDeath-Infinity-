package com.stickdeath.studio

import androidx.compose.runtime.*
import androidx.compose.material3.*
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription

/** Explicit clip selection; drafts are applied as one guarded history transaction. */
@Composable fun AudioClipControls(vm: StudioViewModel, doc: Document, enabled: Boolean, playbackSeconds: Double? = null, onImport: () -> Unit) {
    var selected by remember(doc.id) { mutableStateOf<String?>(null) }
    var libraryOpen by remember(doc.id) { mutableStateOf(false) }
    TextButton({ vm.stopAudioPreview(); libraryOpen = !libraryOpen }, enabled = enabled) { Text(if (libraryOpen) "Close sound library" else "Browse sound library") }
    if (libraryOpen) BundledSoundControls(vm, doc, enabled)
    Text("Import audio you have rights to use: PCM WAV or device-supported AAC/M4A, MP3, FLAC, Vorbis or Opus. Mono/stereo, 8–48 kHz, up to 60 s; both the file and decoded PCM must fit 4 MiB. Project limit: 16 clips / 8 MiB. Audio is copied into the local project backup.")
    Button(onImport, enabled = enabled && !vm.importingAudio && doc.audioClips.size < 16) { Text("Import audio from Files") }
    if (vm.importingAudio) {
        Text(vm.audioImportStage ?: "Preparing audio…")
        LinearProgressIndicator(Modifier.fillMaxWidth())
        TextButton({ vm.cancelAudioImport() }) { Text("Cancel audio operation") }
    }
    Text("Placement is in seconds; tracks 1–4 are independent of drawing layers. Clip preview plays only the selected saved trim, volume and mute. MP4 mixes saved clips over the animation duration. Overlapping clips sum, including on the same track; loud sums are limited to the PCM range. Scene playback mixes saved clips from the selected frame through the end, up to 120 seconds.")
    Text("Track mixer · saved track gain, pan, mute and solo affect clip preview, scene playback and MP4. Solo silences every track that is not soloed; pan is a stereo balance (centre leaves the mix unchanged).")
    doc.audioTracks.forEachIndexed { index, mix -> key(doc.id, doc.revision, index) {
        var gain by remember { mutableStateOf(mix.volume) }
        var pan by remember { mutableStateOf(mix.pan) }
        Row {
            Text("Track ${index + 1} · ${(gain * 100).toInt()}% · ${StudioCraftAudio.panLabel(pan.toDouble())}")
            FilterChip(mix.muted, { vm.editAudioTrack(doc, index, mix.copy(muted = !mix.muted)) },
                { Text(if (mix.muted) "Muted" else "Mute") }, enabled = enabled)
            FilterChip(mix.soloed, { vm.editAudioTrack(doc, index, mix.copy(soloed = !mix.soloed)) },
                { Text(if (mix.soloed) "Soloed" else "Solo") }, enabled = enabled,
                modifier = Modifier.semantics { contentDescription = "Track ${index + 1} solo" })
        }
        Slider(gain, { gain = it }, enabled = enabled,
            modifier = Modifier.semantics { contentDescription = "Track ${index + 1} volume" },
            onValueChangeFinished = { vm.editAudioTrack(doc, index, mix.copy(volume = gain)) })
        Slider(pan, { pan = it }, valueRange = -1f..1f, enabled = enabled,
            modifier = Modifier.semantics { contentDescription = "Track ${index + 1} pan" },
            onValueChangeFinished = { vm.editAudioTrack(doc, index, mix.copy(pan = pan)) })
    } }
    if (doc.audioTracks.any { it.soloed }) Text("Solo active: only soloed tracks play in preview, scene playback and MP4.")
    AudioTimeline(vm, doc, enabled, selected, playbackSeconds) { id -> vm.stopAudioPreview(); selected = id }
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
        var fadeIn by remember { mutableStateOf((clip.fade?.fadeIn ?: 0.0).toString()) }
        var fadeOut by remember { mutableStateOf((clip.fade?.fadeOut ?: 0.0).toString()) }
        var reanchorFades by remember { mutableStateOf(false) }
        var inShape by remember { mutableStateOf(clip.fade?.inShape ?: FadeShape.Linear) }
        var outShape by remember { mutableStateOf(clip.fade?.outShape ?: FadeShape.Linear) }
        OutlinedTextField(name, { name = it.take(80) }, label = { Text("Clip name") }, singleLine = true, enabled = enabled)
        OutlinedTextField(start, { start = it.take(20) }, label = { Text("Start on timeline (seconds, 0–3600)") }, singleLine = true, enabled = enabled)
        OutlinedTextField(offset, { offset = it.take(20) }, label = { Text("Source trim start (seconds)") }, singleLine = true, enabled = enabled)
        OutlinedTextField(duration, { duration = it.take(20) }, label = { Text("Trim duration (seconds)") }, singleLine = true, enabled = enabled)
        OutlinedTextField(track, { track = it.take(2) }, label = { Text("Track (1–4)") }, singleLine = true, enabled = enabled)
        Text("Volume ${(volume * 100).toInt()}%")
        Slider(volume, { volume = it }, enabled = enabled)
        FilterChip(muted, { muted = !muted }, { Text("Mute") }, enabled = enabled)
        OutlinedTextField(fadeIn, { fadeIn = it.take(20) }, label = { Text("Fade in (seconds)") }, singleLine = true, enabled = enabled)
        OutlinedTextField(fadeOut, { fadeOut = it.take(20) }, label = { Text("Fade out (seconds)") }, singleLine = true, enabled = enabled)
        FilterChip(reanchorFades, { reanchorFades = !reanchorFades }, { Text("Reanchor fades to this trim") }, enabled = enabled)
        Text("Fade in shape: ${inShape.label}")
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            FadeShape.entries.forEach { shape ->
                FilterChip(inShape == shape, { inShape = shape }, { Text(shape.label) }, enabled = enabled,
                    modifier = Modifier.semantics { contentDescription = "Fade in shape ${shape.label}" })
            }
        }
        Text("Fade out shape: ${outShape.label}")
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            FadeShape.entries.forEach { shape ->
                FilterChip(outShape == shape, { outShape = shape }, { Text(shape.label) }, enabled = enabled,
                    modifier = Modifier.semantics { contentDescription = "Fade out shape ${shape.label}" })
            }
        }
        Text("Fades use source time: split and trim keep the existing curve. Changing fade lengths or reanchoring starts a new curve on this trim; changing only the shape keeps the current fade span. Zero/zero removes fades.")
        Button({
            val a = start.toDoubleOrNull(); val b = offset.toDoubleOrNull(); val c = duration.toDoubleOrNull(); val t = track.toIntOrNull()
            val fi = fadeIn.toDoubleOrNull(); val fo = fadeOut.toDoubleOrNull()
            if (a == null || b == null || c == null || t == null || fi == null || fo == null) vm.report("Enter valid numeric timing and track values.")
            else {
                val envelope = (if (fi == 0.0 && fo == 0.0) null
                    else if (reanchorFades || fi != clip.fade?.fadeIn || fo != clip.fade?.fadeOut) AudioFade(b, b + c, fi, fo)
                    else clip.fade)?.copy(inShape = inShape, outShape = outShape)
                vm.editAudio(doc, clip.copy(name = name.trim(), start = a, sourceOffset = b, duration = c,
                    track = t, volume = volume, muted = muted, fade = envelope))
            }
        }, enabled = enabled) { Text("Apply audio edits") }
        Row {
            TextButton({ vm.previewAudio(doc, clip.id) }, enabled = enabled && !vm.previewingAudio) { Text("Preview saved clip") }
            TextButton({ vm.stopAudioPreview() }, enabled = vm.previewingAudio) { Text("Stop") }
        }
        var splitTime by remember { mutableStateOf((clip.start + clip.duration / 2).toString()) }
        OutlinedTextField(splitTime, { splitTime = it.take(20) },
            label = { Text("Split at timeline time (seconds)") }, singleLine = true, enabled = enabled)
        Text("Split and duplicate use saved clip settings. Split aligns to the nearest source sample and keeps both parts at least one source sample. Copies count toward project audio capacity.")
        Row {
            TextButton({
                val time = splitTime.toDoubleOrNull()
                if (time == null || !time.isFinite()) vm.report("Enter a valid split time.")
                else vm.expandAudio(doc, clip.id, time)
            }, enabled = enabled && !vm.importingAudio && doc.audioClips.size < 16) { Text("Split saved clip") }
            TextButton({ vm.expandAudio(doc, clip.id) },
                enabled = enabled && !vm.importingAudio && doc.audioClips.size < 16) { Text("Duplicate saved clip") }
        }
        TextButton({ if (vm.deleteAudio(doc, clip.id)) selected = null }, enabled = enabled) { Text("Delete clip (undo available)") }
    }
    if (vm.message.isNotEmpty()) Text(vm.message)
}
