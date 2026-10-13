package com.stickdeath.studio

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Offline catalogue browsing; playback never inserts a clip or changes history. */
@Composable fun BundledSoundControls(vm: StudioViewModel, doc: Document, enabled: Boolean) {
    val context = LocalContext.current.applicationContext
    var sounds by remember { mutableStateOf<List<BundledSound>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var category by remember { mutableStateOf<String?>(null) }
    val collections = rememberLibraryCollections("sounds")
    var page by remember(query, category, collections.collection) { mutableIntStateOf(0) }
    LaunchedEffect(context) {
        try { sounds = withContext(Dispatchers.IO) { BundledSounds.load(context) } }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = failure.message ?: "Sound library could not open." }
    }
    Text("Sound library · ${sounds.size} bundled effects")
    Text("CC0 · offline. Preview checks the actual file; Add copies decoded audio into this project. Decoded audio is bounded to 4 MiB per sound; unsupported decoder output reports an error rather than truncating.")
    if (vm.message.isNotEmpty()) Text(vm.message)
    if (vm.importingAudio) {
        Text("Preparing sound for this project…")
        TextButton({ vm.cancelAudioImport() }) { Text("Cancel sound operation") }
    }
    if (error != null) Text(error!!)
    else if (sounds.isEmpty()) Text("Loading sound catalogue…")
    OutlinedTextField(query, { query = it.take(120) }, label = { Text("Search sounds, tags or creators") }, singleLine = true)
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        FilterChip(category == null, { category = null }, { Text("All") })
        sounds.map { it.category }.distinct().sorted().forEach { name ->
            FilterChip(category == name, { category = name }, { Text(name) })
        }
    }
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        listOf("All", "Favorites", "Recent imports").forEach { name ->
            FilterChip(collections.collection == name, { collections.collection = name }, { Text(name) }, enabled = name == "All" || collections.ready)
        }
    }
    collections.error?.let { Text(it) }
    if (collections.collection == "Recent imports") TextButton({ collections.clearRecent() }, enabled = collections.ready && !collections.busy) { Text("Clear recent imports") }
    val matches = remember(sounds, query, category, collections.collection, collections.snapshot) {
        val terms = query.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        val filtered = sounds.filter { sound ->
            (category == null || category == sound.category) && terms.all { term ->
                (sound.title + " " + sound.author + " " + sound.tags.joinToString(" ")).lowercase().contains(term)
            }
        }
        when (collections.collection) {
            "Favorites" -> filtered.filter { it.id in collections.snapshot.favorites }
            "Recent imports" -> { val byID = filtered.associateBy { it.id }; collections.snapshot.recent.mapNotNull { byID[it] } }
            else -> filtered
        }
    }
    val pages = maxOf(1, (matches.size + 11) / 12)
    val actualPage = page.coerceIn(0, pages - 1)
    Text("${matches.size} matching sounds · page ${actualPage + 1}/$pages")
    matches.drop(actualPage * 12).take(12).forEach { sound -> key(sound.id) {
        Text(sound.title)
        Text("${sound.category} · ${"%.2f".format(sound.duration)}s · ${sound.author} · CC0")
        Row {
            TextButton({ vm.previewBundledSound(doc, sound) }, enabled = enabled && !vm.previewingAudio && !vm.importingAudio) { Text("Preview") }
            TextButton({ vm.addBundledSound(doc, sound) }, enabled = enabled && !vm.importingAudio && doc.audioClips.size < 16) { Text("Add to project") }
        }
        var credits by remember { mutableStateOf(false) }
        TextButton({ collections.toggle(sound.id) }, enabled = collections.ready && !collections.busy) {
            Text(if (sound.id in collections.snapshot.favorites) "Remove favorite" else "Favorite")
        }
        TextButton({ credits = !credits }) { Text(if (credits) "Hide source" else "Source and license") }
        if (credits) Text("${sound.sourceURL}\nCC0-1.0 · https://creativecommons.org/publicdomain/zero/1.0/")
    } }
    Row {
        TextButton({ page = actualPage - 1 }, enabled = actualPage > 0) { Text("Previous sounds") }
        TextButton({ page = actualPage + 1 }, enabled = actualPage + 1 < pages) { Text("Next sounds") }
    }
    if (vm.previewingAudio) TextButton({ vm.stopAudioPreview() }) { Text("Stop sound preview") }
}
