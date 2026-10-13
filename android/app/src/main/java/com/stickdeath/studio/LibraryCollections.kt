package com.stickdeath.studio

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/** Only catalogue IDs are stored; this contains no project data or remote activity. */
class LibraryCollections(context: Context, private val kind: String) {
    init { require(kind == "images" || kind == "sounds") }
    val preferences: SharedPreferences = context.getSharedPreferences("studio-library-collections", Context.MODE_PRIVATE)
    data class Snapshot(val favorites: List<String> = emptyList(), val recent: List<String> = emptyList())
    private fun read(): Snapshot {
        val raw = preferences.getString(kind, null) ?: return Snapshot()
        require(raw.length <= 65536) { "Saved library preferences exceed their limit; originals preserved." }
        val j = JSONObject(raw)
        require(j.getInt("version") == 1)
        fun ids(key: String, maximum: Int): List<String> {
            val array = j.getJSONArray(key)
            require(array.length() <= maximum)
            return (0 until array.length()).map { array.getString(it).also { id ->
                require(id.length in 1..160 && id.all { c -> c.isLetterOrDigit() || c in "._-" })
            } }.also { require(it.distinct().size == it.size) }
        }
        return Snapshot(ids("favorites", 256), ids("recent", 50))
    }
    suspend fun load(): Snapshot = withContext(Dispatchers.IO) { lock.withLock { read() } }
    private suspend fun update(transform: (Snapshot) -> Snapshot): Snapshot = withContext(Dispatchers.IO) {
        lock.withLock {
            val value = transform(read())
            val json = JSONObject().put("version", 1).put("favorites", JSONArray(value.favorites)).put("recent", JSONArray(value.recent))
            require(preferences.edit().putString(kind, json.toString()).commit()) { "Library preferences could not be saved to this device." }
            value
        }
    }
    suspend fun toggle(id: String) = update { old ->
        require(id.length in 1..160 && id.all { it.isLetterOrDigit() || it in "._-" })
        if (id in old.favorites) old.copy(favorites = old.favorites - id)
        else { require(old.favorites.size < 256) { "Remove a favorite before adding more than 256." }; old.copy(favorites = old.favorites + id) }
    }
    suspend fun recordImport(id: String) = update { old ->
        require(id.length in 1..160 && id.all { it.isLetterOrDigit() || it in "._-" })
        old.copy(recent = (listOf(id) + old.recent.filterNot { it == id }).take(50))
    }
    suspend fun clearRecent() = update { it.copy(recent = emptyList()) }
    companion object { private val lock = Mutex() }
}

class LibraryCollectionControls {
    var snapshot by mutableStateOf(LibraryCollections.Snapshot())
    var ready by mutableStateOf(false)
    var busy by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var collection by mutableStateOf("All")
    var toggle: (String) -> Unit = {}
    var clearRecent: () -> Unit = {}
}

@Composable fun rememberLibraryCollections(kind: String): LibraryCollectionControls {
    val context = LocalContext.current.applicationContext
    val store = remember(context, kind) { LibraryCollections(context, kind) }
    val state = remember(store) { LibraryCollectionControls() }
    val scope = rememberCoroutineScope()
    var revision by remember(store) { mutableIntStateOf(0) }
    DisposableEffect(store) {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key -> if (key == kind) revision++ }
        store.preferences.registerOnSharedPreferenceChangeListener(listener)
        onDispose { store.preferences.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    LaunchedEffect(store, revision) {
        try { state.snapshot = store.load(); state.ready = true; state.error = null }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { state.ready = false; state.error = failure.message ?: "Library preferences could not open; saved data was preserved." }
    }
    fun update(action: suspend () -> LibraryCollections.Snapshot) {
        if (!state.ready || state.busy) return
        scope.launch {
            state.busy = true
            try { state.snapshot = action(); state.error = null }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { state.error = failure.message ?: "Library preferences could not be saved." }
            finally { state.busy = false }
        }
    }
    state.toggle = { id -> update { store.toggle(id) } }
    state.clearRecent = { update { store.clearRecent() } }
    return state
}
