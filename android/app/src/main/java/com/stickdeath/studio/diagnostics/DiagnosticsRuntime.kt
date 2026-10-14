package com.stickdeath.studio.diagnostics

import android.content.Context
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import java.io.File

/** Device side of the opt-in diagnostics queue (#291): the consent flag in app-private
 * SharedPreferences, the queue file in `files/diagnostics/queue.txt`, and an uncaught-exception
 * breadcrumb that adds one to `uncaught_exception` for the day. Opting out deletes the queue.
 * The redacted local crash reports of [com.stickdeath.studio.LocalCrashReporter] are separate
 * and are never uploaded. This build has no INTERNET permission, so [submitter] is null and the
 * upload reports the truthful "not available" state. */
class DiagnosticsStore(context: Context, private val now: () -> Long = System::currentTimeMillis) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("sdi_diagnostics", Context.MODE_PRIVATE)
    private val file get() = File(File(app.filesDir, "diagnostics"), "queue.txt")
    val submitter: DiagnosticsSubmitter? = null

    val optedIn: Boolean get() = prefs.getBoolean(KEY, false)

    fun setOptedIn(value: Boolean) {
        prefs.edit().putBoolean(KEY, value).commit()
        if (!value) delete()
    }

    fun context(): DiagnosticsContext {
        val info = try { app.packageManager.getPackageInfo(app.packageName, 0) } catch (_: Exception) { null }
        val code = info?.let { if (android.os.Build.VERSION.SDK_INT >= 28) it.longVersionCode else @Suppress("DEPRECATION") it.versionCode.toLong() }
        // Android API level stands in for the OS major; both are coarse platform versions.
        return DiagnosticsContext.of(info?.versionName, code, android.os.Build.VERSION.SDK_INT)
    }

    fun load(): DiagnosticsQueue {
        if (!optedIn) { delete(); return DiagnosticsQueue() }
        val text = try { file.takeIf { it.isFile && it.length() <= 64 * 1024 }?.readText(Charsets.UTF_8) } catch (_: Exception) { null }
        return DiagnosticsQueue.parse(text ?: "", now())
    }

    fun record(counter: DiagnosticsCounter, amount: Int = 1) {
        if (!optedIn) return
        val queue = load()
        queue.record(counter, amount, now(), now(), context())
        save(queue)
    }

    fun save(queue: DiagnosticsQueue) {
        val target = file
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, "queue.tmp")
        temp.writeText(queue.serialize(), Charsets.UTF_8)
        if (!temp.renameTo(target)) { target.delete(); temp.renameTo(target) }
    }

    fun delete() { file.delete() }

    fun upload(): DiagnosticsUploadOutcome {
        val queue = load()
        val outcome = DiagnosticsUploader.upload(queue, optedIn, submitter, now())
        if (optedIn) save(queue)
        return outcome
    }

    /** Chains in front of the existing handler; only a counter is written, never the throwable. */
    fun installBreadcrumbs() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is Breadcrumbs) return
        Thread.setDefaultUncaughtExceptionHandler(Breadcrumbs(previous))
    }

    private inner class Breadcrumbs(private val previous: Thread.UncaughtExceptionHandler?) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(thread: Thread, error: Throwable) {
            try { record(DiagnosticsCounter.UncaughtException) } catch (_: Throwable) { }
            previous?.uncaughtException(thread, error)
        }
    }

    companion object { const val KEY = "optIn.v1" }
}

/** Account → Diagnostics section: opt-in switch, exact payload preview, delete and send. */
@Composable
fun DiagnosticsSettingsSection(store: DiagnosticsStore) {
    var optedIn by remember { mutableStateOf(store.optedIn) }
    var revision by remember { mutableStateOf(0) }
    var status by remember { mutableStateOf<String?>(null) }
    var showPayload by remember { mutableStateOf(false) }
    val queue = remember(optedIn, revision) { store.load() }
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Share diagnostics", modifier = Modifier.weight(1f))
            Switch(optedIn, { store.setOptedIn(it); optedIn = it; status = null; revision++ })
        }
        Text("Daily counts of launches and uncaught exceptions with the app version and Android API level. No drawings, project names, prompts, account details, device identifiers or exact times.",
            style = MaterialTheme.typography.bodySmall)
        if (optedIn) {
            Text(if (queue.reports.isEmpty()) "Nothing queued on this device." else "${queue.reports.size} day(s) queued on this device.")
            Row {
                TextButton({ showPayload = !showPayload }) { Text(if (showPayload) "Hide payload" else "View what will be sent") }
                TextButton({ store.delete(); revision++; status = "Queued diagnostics deleted." }, enabled = queue.reports.isNotEmpty()) { Text("Delete queued") }
                TextButton({ status = store.upload().message; revision++ }) { Text("Send completed days") }
            }
            if (showPayload) Text(queue.previewJson(), style = MaterialTheme.typography.bodySmall)
        } else {
            Text(DiagnosticsUploadOutcome.Disabled.message, style = MaterialTheme.typography.bodySmall)
        }
        status?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}
