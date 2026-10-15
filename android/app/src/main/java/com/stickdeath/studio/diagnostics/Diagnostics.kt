package com.stickdeath.studio.diagnostics

import com.stickdeath.studio.SdiJson
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/** First-party, opt-in diagnostics (#291, Android half). Contract v1 is shared with iOS
 * `DiagnosticsReport.swift` and `backend/sql/diagnostics.sql`: one UTC day of allowlisted counters
 * per app version, build and OS major. No free text, stack frames, identifiers, file names,
 * project contents or precise times are ever queued or sent. Off by default; this file is plain
 * JVM code so the rules are covered by JUnit without a device. */
enum class DiagnosticsCounter(val key: String, val label: String) {
    AppLaunch("app_launch", "App launches"),
    Crash("crash", "Crashes"),
    Hang("hang", "Hangs"),
    CpuException("cpu_exception", "CPU limit exceptions"),
    DiskWriteException("disk_write_exception", "Disk write limit exceptions"),
    MemoryLimitExit("memory_limit_exit", "Memory limit terminations"),
    WatchdogExit("watchdog_exit", "Watchdog terminations"),
    UncaughtException("uncaught_exception", "Uncaught exceptions");

    companion object { fun of(key: String): DiagnosticsCounter? = entries.firstOrNull { it.key == key } }
}

object DiagnosticsLimits {
    const val CONTRACT_VERSION = 1
    const val MAX_COUNT = 10_000
    const val MAX_QUEUED_REPORTS = 14
    const val MAX_AGE_DAYS = 30L
}

class DiagnosticsContext private constructor(val appVersion: String, val build: String, val osMajor: Int) {
    companion object {
        /** Normalizes raw values so a malformed version string can never carry free text. */
        fun of(appVersion: String?, build: Long?, osMajor: Int) = DiagnosticsContext(
            DiagnosticsSanitizer.appVersion(appVersion), DiagnosticsSanitizer.build(build?.toString()), DiagnosticsSanitizer.osMajor(osMajor))
    }
}

data class DiagnosticsReport(
    val appVersion: String, val build: String, val osMajor: Int,
    /** UTC calendar day; the only time information sent. */
    val day: LocalDate,
    /** Counter key → 1…10 000. */
    val counters: Map<String, Int>,
    val platform: String = "android",
) {
    val bucket: String get() = "$day|$appVersion|$build|$osMajor"
    fun count(counter: DiagnosticsCounter): Int = counters[counter.key] ?: 0

    /** The exact wire object (sorted keys) the uploader sends and the preview shows. */
    fun toWire(): Map<String, Any> = mapOf(
        "v" to DiagnosticsLimits.CONTRACT_VERSION, "platform" to platform, "app_version" to appVersion, "build" to build,
        "os_major" to osMajor, "day" to day.toString(), "counters" to counters.toSortedMap())

    fun toJson(pretty: Boolean = false): String = SdiJson.encode(toWire(), pretty)
}

object DiagnosticsSanitizer {
    const val UNKNOWN = "unknown"
    private val version = Regex("""[0-9]{1,4}(\.[0-9]{1,4}){0,2}""")
    private val buildDigits = Regex("""[0-9]{1,9}""")

    fun appVersion(raw: String?): String = if (raw != null && version.matches(raw)) raw else UNKNOWN
    fun build(raw: String?): String = if (raw != null && buildDigits.matches(raw)) raw else UNKNOWN
    fun osMajor(raw: Int): Int = raw.coerceIn(0, 99)
    fun count(raw: Int): Int = raw.coerceIn(0, DiagnosticsLimits.MAX_COUNT)
    fun day(epochMillis: Long): LocalDate = Instant.ofEpochMilli(epochMillis).atOffset(ZoneOffset.UTC).toLocalDate()

    /** Drops unknown counters, clamps counts and omits zeros; null when the report breaks the contract. */
    fun sanitized(report: DiagnosticsReport): DiagnosticsReport? {
        if (report.platform != "android" || appVersion(report.appVersion) != report.appVersion ||
            build(report.build) != report.build || report.osMajor !in 0..99) return null
        val counters = report.counters.filterKeys { DiagnosticsCounter.of(it) != null }
            .mapValues { count(it.value) }.filterValues { it > 0 }
        return if (counters.isEmpty()) null else report.copy(counters = counters)
    }
}

/** Pure queue rules: at most 14 day-buckets, none older than 30 days or in the future. */
class DiagnosticsQueue(reports: List<DiagnosticsReport> = emptyList()) {
    var reports: List<DiagnosticsReport> = reports; private set

    fun record(counter: DiagnosticsCounter, amount: Int = 1, atMillis: Long, nowMillis: Long, context: DiagnosticsContext) {
        val add = DiagnosticsSanitizer.count(amount)
        if (add <= 0) return
        val day = DiagnosticsSanitizer.day(atMillis)
        val candidate = DiagnosticsReport(context.appVersion, context.build, context.osMajor, day, emptyMap())
        val existing = reports.firstOrNull { it.bucket == candidate.bucket }
        val updated = (existing ?: candidate).let { it.copy(counters = it.counters + (counter.key to DiagnosticsSanitizer.count(it.count(counter) + add))) }
        reports = reports.filter { it.bucket != candidate.bucket } + updated
        prune(nowMillis)
    }

    fun prune(nowMillis: Long) {
        val today = DiagnosticsSanitizer.day(nowMillis)
        val oldest = today.minusDays(DiagnosticsLimits.MAX_AGE_DAYS)
        reports = reports.mapNotNull(DiagnosticsSanitizer::sanitized)
            .filter { !it.day.isBefore(oldest) && !it.day.isAfter(today) }
            .distinctBy { it.bucket }
            .sortedWith(compareBy({ it.day }, { it.bucket }))
            .takeLast(DiagnosticsLimits.MAX_QUEUED_REPORTS)
    }

    /** Completed days only: today's bucket is still accumulating. */
    fun uploadable(nowMillis: Long): List<DiagnosticsReport> = DiagnosticsSanitizer.day(nowMillis).let { today -> reports.filter { it.day.isBefore(today) } }
    fun remove(sent: Collection<DiagnosticsReport>) { val keys = sent.map { it.bucket }.toSet(); reports = reports.filter { it.bucket !in keys } }
    fun clear() { reports = emptyList() }

    /** Exactly what would be sent, as a JSON array. */
    fun previewJson(): String = if (reports.isEmpty()) "[]" else SdiJson.encode(reports.map { it.toWire() }, pretty = true)

    /** Line storage: `day|version|build|os|key=n,key=n`. Damaged lines are skipped. */
    fun serialize(): String = reports.joinToString("\n") { r ->
        "${r.day}|${r.appVersion}|${r.build}|${r.osMajor}|" + r.counters.toSortedMap().entries.joinToString(",") { "${it.key}=${it.value}" }
    }

    companion object {
        fun parse(text: String, nowMillis: Long): DiagnosticsQueue {
            val parsed = text.lineSequence().take(64).mapNotNull line@{ line ->
                val parts = line.split('|')
                if (parts.size != 5) return@line null
                val day = try { LocalDate.parse(parts[0]) } catch (_: Exception) { return@line null }
                val osMajor = parts[3].toIntOrNull() ?: return@line null
                val counters = parts[4].split(',').mapNotNull pair@{ pair ->
                    val kv = pair.split('=')
                    if (kv.size != 2) return@pair null
                    kv[0] to (kv[1].toIntOrNull() ?: return@pair null)
                }.toMap()
                DiagnosticsReport(parts[1], parts[2], osMajor, day, counters)
            }.toList()
            return DiagnosticsQueue(parsed).also { it.prune(nowMillis) }
        }
    }
}

/** The server's answer for one report; mirrors iOS `DiagnosticsSubmitReply`. */
sealed class DiagnosticsSubmitReply {
    object Accepted : DiagnosticsSubmitReply()
    object Duplicate : DiagnosticsSubmitReply()
    object RateLimited : DiagnosticsSubmitReply()
    data class Refused(val message: String) : DiagnosticsSubmitReply()

    companion object {
        private val status = Regex(""""status"\s*:\s*"(accepted|duplicate)"""")
        private val code = Regex(""""code"\s*:\s*"rate_limited"""")
        private val error = Regex(""""error"\s*:\s*"((?:[^"\\]|\\.){1,200})"""")
        fun parse(body: String): DiagnosticsSubmitReply {
            status.find(body)?.let { return if (it.groupValues[1] == "accepted") Accepted else Duplicate }
            if (code.containsMatchIn(body)) return RateLimited
            return Refused(error.find(body)?.groupValues?.get(1) ?: "The diagnostics service refused the report.")
        }
    }
}

/** Sends one report's JSON to `rpc/sdi_diagnostics_submit` and returns the reply body. */
fun interface DiagnosticsSubmitter { fun submit(reportJson: String): String }

sealed class DiagnosticsUploadOutcome(val message: String) {
    object Disabled : DiagnosticsUploadOutcome("Diagnostics are off. Nothing is collected or sent.")
    object NotConfigured : DiagnosticsUploadOutcome("Diagnostics upload is not available in this build. Counts stay on this device and are deleted after 30 days or when you delete them.")
    object NothingToSend : DiagnosticsUploadOutcome("Nothing to send yet. Only completed days are sent.")
    data class Sent(val days: Int) : DiagnosticsUploadOutcome(if (days == 1) "Sent 1 day of diagnostics." else "Sent $days days of diagnostics.")
    data class Partial(val days: Int, val problem: String) : DiagnosticsUploadOutcome("Sent $days of the queued days. $problem")
    data class Failed(val problem: String) : DiagnosticsUploadOutcome(problem)
}

/** Uploads completed days in order and removes only acknowledged ones. A null submitter is the
 * truthful state of this build: the manifest has no INTERNET permission, so nothing is sent. */
object DiagnosticsUploader {
    fun upload(queue: DiagnosticsQueue, optedIn: Boolean, submitter: DiagnosticsSubmitter?, nowMillis: Long): DiagnosticsUploadOutcome {
        if (!optedIn) return DiagnosticsUploadOutcome.Disabled
        if (submitter == null) return DiagnosticsUploadOutcome.NotConfigured
        val pending = queue.uploadable(nowMillis)
        if (pending.isEmpty()) return DiagnosticsUploadOutcome.NothingToSend
        val done = mutableListOf<DiagnosticsReport>(); var sent = 0; var problem: String? = null
        for (report in pending) {
            val clean = DiagnosticsSanitizer.sanitized(report)
            if (clean == null) { done += report; continue }
            val reply = try { DiagnosticsSubmitReply.parse(submitter.submit(clean.toJson())) }
                catch (_: Exception) { problem = "The diagnostics service could not be reached. Queued days stay on this device."; break }
            when (reply) {
                DiagnosticsSubmitReply.Accepted, DiagnosticsSubmitReply.Duplicate -> { done += report; sent++ }
                DiagnosticsSubmitReply.RateLimited -> problem = "The diagnostics service asked to wait; the rest will be sent later."
                is DiagnosticsSubmitReply.Refused -> problem = reply.message
            }
            if (problem != null) break
        }
        queue.remove(done)
        return when {
            problem != null && sent == 0 -> DiagnosticsUploadOutcome.Failed(problem)
            problem != null -> DiagnosticsUploadOutcome.Partial(sent, problem)
            sent == 0 -> DiagnosticsUploadOutcome.NothingToSend
            else -> DiagnosticsUploadOutcome.Sent(sent)
        }
    }
}
