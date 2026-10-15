package com.stickdeath.studio.diagnostics

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticsTest {
    private val now = 1_760_000_000_000L // 2025-10-09T08:53:20Z
    private val day = 24L * 60 * 60 * 1000
    private val context = DiagnosticsContext.of("1.4.2", 317, 34)

    @Test fun sanitizerKeepsOnlyCoarseValues() {
        assertEquals("1.4.2", DiagnosticsSanitizer.appVersion("1.4.2"))
        listOf("1.4.2-beta", "joe@example.com", "", "1.2.3.4", "/data/user/0").forEach { assertEquals(it, "unknown", DiagnosticsSanitizer.appVersion(it)) }
        assertEquals("unknown", DiagnosticsSanitizer.appVersion(null))
        assertEquals(99, DiagnosticsSanitizer.osMajor(140))
        assertEquals(LocalDate.parse("2025-10-09"), DiagnosticsSanitizer.day(now))
        val raw = DiagnosticsReport("1.4.2", "317", 34, LocalDate.parse("2025-10-09"), mapOf("crash" to 3, "free_text" to 9, "hang" to 0, "app_launch" to 99_999))
        assertEquals(mapOf("crash" to 3, "app_launch" to 10_000), DiagnosticsSanitizer.sanitized(raw)!!.counters)
        assertNull(DiagnosticsSanitizer.sanitized(raw.copy(appVersion = "Joe's build")))
        assertNull(DiagnosticsSanitizer.sanitized(raw.copy(counters = mapOf("project_name" to 1))))
        assertEquals("""{"app_version":"1.4.2","build":"317","counters":{"app_launch":10000,"crash":3},"day":"2025-10-09","os_major":34,"platform":"android","v":1}""",
            DiagnosticsSanitizer.sanitized(raw)!!.toJson())
    }

    @Test fun queueMergesBoundsAndExpires() {
        val queue = DiagnosticsQueue()
        queue.record(DiagnosticsCounter.UncaughtException, 1, now, now, context)
        queue.record(DiagnosticsCounter.UncaughtException, 2, now + 60_000, now, context)
        queue.record(DiagnosticsCounter.AppLaunch, 1, now, now, context)
        assertEquals(1, queue.reports.size)
        assertEquals(3, queue.reports[0].count(DiagnosticsCounter.UncaughtException))
        queue.record(DiagnosticsCounter.Crash, 0, now, now, context)
        assertEquals(1, queue.reports.size)
        (1..20).forEach { queue.record(DiagnosticsCounter.AppLaunch, 1, now - it * day, now, context) }
        assertEquals(DiagnosticsLimits.MAX_QUEUED_REPORTS, queue.reports.size)
        assertEquals(LocalDate.parse("2025-10-09"), queue.reports.last().day)
        assertEquals(LocalDate.parse("2025-10-09").minusDays(13), queue.reports.first().day)
        queue.record(DiagnosticsCounter.Crash, 1, now + 3 * day, now, context)
        assertFalse(queue.reports.any { it.day.isAfter(LocalDate.parse("2025-10-09")) })
        assertEquals(13, queue.uploadable(now).size)
        queue.prune(now + 40 * day)
        assertTrue(queue.reports.isEmpty())
    }

    @Test fun storageRoundTripAndDamagedLines() {
        val queue = DiagnosticsQueue()
        queue.record(DiagnosticsCounter.UncaughtException, 2, now - day, now, context)
        queue.record(DiagnosticsCounter.AppLaunch, 5, now, now, context)
        val text = queue.serialize()
        assertEquals(queue.reports, DiagnosticsQueue.parse(text, now).reports)
        val damaged = DiagnosticsQueue.parse("garbage\n2025-99-01|1|1|1|crash=1\n2025-10-08|1.4.1|316|34|crash=x,hang=2\n" + text, now)
        assertEquals(3, damaged.reports.size)
        assertEquals(mapOf("hang" to 2), damaged.reports.first { it.build == "316" }.counters)
        assertFalse(text.contains("@") || text.contains("/"))
    }

    @Test fun previewIsExactPayloadWithoutIdentifiers() {
        val queue = DiagnosticsQueue()
        assertEquals("[]", queue.previewJson())
        queue.record(DiagnosticsCounter.UncaughtException, 1, now, now, context)
        val preview = queue.previewJson()
        assertTrue(preview.contains("\"uncaught_exception\" : 1") && preview.contains("\"platform\" : \"android\""))
        listOf("user", "email", "device", "project", "stack", "time").forEach { assertFalse(it, preview.lowercase().contains(it)) }
    }

    @Test fun uploadOutcomesAreTruthful() {
        val queue = DiagnosticsQueue()
        assertEquals(DiagnosticsUploadOutcome.Disabled, DiagnosticsUploader.upload(queue, false, DiagnosticsSubmitter { "" }, now))
        assertEquals(DiagnosticsUploadOutcome.NotConfigured, DiagnosticsUploader.upload(queue, true, null, now))
        queue.record(DiagnosticsCounter.AppLaunch, 1, now, now, context)
        assertEquals(DiagnosticsUploadOutcome.NothingToSend, DiagnosticsUploader.upload(queue, true, DiagnosticsSubmitter { """{"status":"accepted"}""" }, now))
        (1..3).forEach { queue.record(DiagnosticsCounter.AppLaunch, 1, now - it * day, now, context) }
        val sent = mutableListOf<String>()
        var calls = 0
        val flaky = DiagnosticsSubmitter { body -> sent += body; if (++calls == 2) throw java.io.IOException("offline"); """{"status":"accepted"}""" }
        val partial = DiagnosticsUploader.upload(queue, true, flaky, now)
        assertTrue(partial is DiagnosticsUploadOutcome.Partial && partial.days == 1)
        assertTrue(sent.first().contains("\"day\":\"2025-10-06\""))
        assertEquals(3, queue.reports.size)
        val limited = DiagnosticsUploader.upload(queue, true, DiagnosticsSubmitter { """{"error":"Daily diagnostics limit reached.","code":"rate_limited"}""" }, now)
        assertEquals(DiagnosticsUploadOutcome.Failed("The diagnostics service asked to wait; the rest will be sent later."), limited)
        assertEquals(DiagnosticsUploadOutcome.Failed("Diagnostics consent is required."),
            DiagnosticsUploader.upload(queue, true, DiagnosticsSubmitter { """{"error":"Diagnostics consent is required.","code":"consent_required"}""" }, now))
        val replies = ArrayDeque(listOf("""{"status":"duplicate"}""", """{"status":"accepted"}"""))
        assertEquals(DiagnosticsUploadOutcome.Sent(2), DiagnosticsUploader.upload(queue, true, DiagnosticsSubmitter { replies.removeFirst() }, now))
        assertEquals(listOf(LocalDate.parse("2025-10-09")), queue.reports.map { it.day })
    }
}
