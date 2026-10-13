package com.stickdeath.studio

import java.io.File

/** Local crash capture (#291, Android half). An uncaught exception is written as a redacted text
 * report in app-private storage, then the default handler runs so the process still terminates.
 * Nothing is uploaded: there is no analytics or crash SDK and no network permission. Reports hold
 * no project contents, names, paths, identifiers or account data; the redaction is tested. */
object CrashReportFormatter {
    const val MAX_FRAMES = 60
    private val email = Regex("""[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}""")
    private val path = Regex("""(?:/[\w.\-]+){2,}""")
    private val uuid = Regex("""[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}""")
    private val quoted = Regex("\"[^\"]*\"|“[^”]*”")
    private val longDigits = Regex("""\d{6,}""")
    private val contentUri = Regex("""content://\S+""")

    /** Keep the shape of a message, drop anything that could identify a person, file or project. */
    fun redact(text: String): String = text
        .replace(contentUri, "content://[redacted]")
        .replace(email, "[email]")
        .replace(uuid, "[uuid]")
        .replace(path, "[path]")
        .replace(quoted, "\"[redacted]\"")
        .replace(longDigits, "[number]")
        .take(400)

    fun format(throwable: Throwable, appVersion: String, versionCode: Long, timestampMillis: Long, threadName: String, androidApi: Int): String {
        val out = StringBuilder()
        out.append("sdi-android-crash-report v1\n")
        out.append("time=").append(timestampMillis).append('\n')
        out.append("app=").append(appVersion).append(" (").append(versionCode).append(")\n")
        out.append("api=").append(androidApi).append('\n')
        out.append("thread=").append(redact(threadName)).append('\n')
        var current: Throwable? = throwable; var depth = 0
        while (current != null && depth < 4) {
            out.append(if (depth == 0) "exception=" else "cause=").append(current.javaClass.name).append('\n')
            out.append("message=").append(redact(current.message ?: "")).append('\n')
            current.stackTrace.take(MAX_FRAMES).forEach { frame ->
                out.append("  at ").append(frame.className).append('.').append(frame.methodName)
                    .append('(').append(frame.fileName ?: "Unknown").append(':').append(frame.lineNumber).append(")\n")
            }
            if (current.stackTrace.size > MAX_FRAMES) out.append("  … ").append(current.stackTrace.size - MAX_FRAMES).append(" more\n")
            current = current.cause?.takeIf { it !== current }; depth++
        }
        return out.toString()
    }

    /** Fallback when formatting itself fails: the exception class only. */
    fun minimal(throwable: Throwable): String = "sdi-android-crash-report v1\nexception=${throwable.javaClass.name}\n"
}

/** At most [MAX_REPORTS] reports, none older than [MAX_AGE_MILLIS]; oldest are removed first. */
object CrashReportRetention {
    const val MAX_REPORTS = 5
    const val MAX_AGE_MILLIS = 30L * 24 * 60 * 60 * 1000
    const val MAX_BYTES_PER_REPORT = 64 * 1024
    data class Entry(val name: String, val timestampMillis: Long)
    /** Names to delete so that, after adding one new report, the retention rule holds. */
    fun toDelete(existing: List<Entry>, nowMillis: Long, addingOne: Boolean = true): List<String> {
        val expired = existing.filter { nowMillis - it.timestampMillis > MAX_AGE_MILLIS || it.timestampMillis > nowMillis + 60_000 }
        val live = (existing - expired.toSet()).sortedByDescending { it.timestampMillis }
        val keep = if (addingOne) MAX_REPORTS - 1 else MAX_REPORTS
        return (expired + live.drop(keep.coerceAtLeast(0))).map { it.name }.distinct()
    }
    fun fileName(timestampMillis: Long) = "crash-$timestampMillis.txt"
    fun timestampOf(fileName: String): Long? = Regex("""crash-(\d{1,19})\.txt""").matchEntire(fileName)?.groupValues?.get(1)?.toLongOrNull()
}

/** Installs the handler once per process. Reports live in `files/crash-reports/`. */
class LocalCrashReporter(private val context: android.content.Context) {
    private val directory get() = File(context.filesDir, "crash-reports")
    fun install() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is Handler) return
        Thread.setDefaultUncaughtExceptionHandler(Handler(previous))
    }
    private inner class Handler(private val previous: Thread.UncaughtExceptionHandler?) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(thread: Thread, error: Throwable) {
            try { write(error, thread.name) } catch (_: Throwable) { }
            previous?.uncaughtException(thread, error)
        }
    }
    internal fun write(error: Throwable, threadName: String, nowMillis: Long = System.currentTimeMillis()) {
        val folder = directory
        if (!folder.isDirectory && !folder.mkdirs()) return
        val existing = folder.listFiles().orEmpty().mapNotNull { file -> CrashReportRetention.timestampOf(file.name)?.let { CrashReportRetention.Entry(file.name, it) } }
        CrashReportRetention.toDelete(existing, nowMillis).forEach { File(folder, it).delete() }
        val info = try { context.packageManager.getPackageInfo(context.packageName, 0) } catch (_: Exception) { null }
        val versionCode = info?.let { if (android.os.Build.VERSION.SDK_INT >= 28) it.longVersionCode else @Suppress("DEPRECATION") it.versionCode.toLong() } ?: 0L
        val text = try { CrashReportFormatter.format(error, info?.versionName ?: "unknown", versionCode, nowMillis, threadName, android.os.Build.VERSION.SDK_INT) }
            catch (_: Throwable) { CrashReportFormatter.minimal(error) }
        File(folder, CrashReportRetention.fileName(nowMillis)).writeText(text.take(CrashReportRetention.MAX_BYTES_PER_REPORT), Charsets.UTF_8)
    }
    fun reports(): List<File> = directory.listFiles().orEmpty().filter { CrashReportRetention.timestampOf(it.name) != null }.sortedByDescending { it.name }
    fun deleteAll(): Int = reports().count { it.delete() }
    /** Thread dump text is never included; this is the full redacted report for the creator to read. */
    fun read(file: File): String = if (file.parentFile == directory) file.readText(Charsets.UTF_8).take(CrashReportRetention.MAX_BYTES_PER_REPORT) else ""
}
