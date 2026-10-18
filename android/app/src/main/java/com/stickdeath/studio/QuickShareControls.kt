package com.stickdeath.studio

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/** Export panel quick-share row (#242): six configurable shortcuts, each rendering a fresh file. */
@Composable fun QuickShareSection(vm: StudioViewModel, onStarted: () -> Unit) {
    val context = LocalContext.current
    val store = remember { QuickShareStore(context) }
    var configuration by remember { mutableStateOf(store.load()) }
    var editingSlot by remember { mutableStateOf<Int?>(null) }
    fun update(next: QuickShareConfiguration) { configuration = next; store.save(next) }
    Text("Quick share", style = MaterialTheme.typography.titleMedium)
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        configuration.slots.forEach { destination ->
            Button({
                val file = configuration.file(destination)
                if (destination == QuickShareDestination.Files) vm.prepareExport(file.exportKind)
                else vm.prepareExport(file.exportKind, share = true, targetPackages = destination.packages)
                onStarted()
            }, enabled = !vm.exporting && vm.exportArtifact == null, modifier = Modifier.padding(end = 4.dp)) { Text("${destination.title} · ${configuration.file(destination).label}") }
        }
    }
    Text("Each shortcut renders the file and hands it to that app through Android sharing. A missing app opens the system share sheet instead. Nothing is posted or uploaded by Studio, and it cannot confirm whether a post went live.", style = MaterialTheme.typography.bodySmall)
    TextButton({ editingSlot = if (editingSlot == null) 0 else null }) { Text(if (editingSlot == null) "Customize shortcuts" else "Done customizing") }
    val slot = editingSlot ?: return
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        configuration.slots.forEachIndexed { index, destination ->
            FilterChip(slot == index, { editingSlot = index }, { Text("${index + 1}. ${destination.title}") }, modifier = Modifier.padding(end = 4.dp))
        }
    }
    val selected = configuration.slots[slot]
    Text("Destination for shortcut ${slot + 1}")
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        QuickShareDestination.entries.forEach { destination ->
            FilterChip(selected == destination, { update(configuration.assign(destination, slot)) }, { Text(destination.title) }, modifier = Modifier.padding(end = 4.dp))
        }
    }
    Text("File for ${selected.title}")
    Row {
        selected.accepted.forEach { file ->
            FilterChip(configuration.file(selected) == file, { update(configuration.preferring(file, selected)) }, { Text(file.label) }, modifier = Modifier.padding(end = 4.dp))
        }
    }
    Text(configuration.instruction(selected), style = MaterialTheme.typography.bodySmall)
    TextButton({ update(QuickShareConfiguration()) }) { Text("Reset to YouTube, Instagram, TikTok, Facebook, X, Reddit") }
}

/** App-private storage of the six shortcuts and per-destination file choice. */
class QuickShareStore(context: android.content.Context) {
    private val preferences = context.getSharedPreferences("studio-quick-share", android.content.Context.MODE_PRIVATE)
    fun load() = QuickShareConfiguration.parse(preferences.getString(KEY, null))
    fun save(value: QuickShareConfiguration) { preferences.edit().putString(KEY, value.serialize()).apply() }
    companion object { const val KEY = "configuration.v1" }
}
