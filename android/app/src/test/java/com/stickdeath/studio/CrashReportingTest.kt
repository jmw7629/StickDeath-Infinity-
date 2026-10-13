package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrashReportingTest {
    @Test fun redactionRemovesIdentifyingText() {
        val message = "Could not save \"Sunset over Lagos\" for joe@example.com at /data/user/0/com.stickdeath.studio/files/studio-projects/0a1b2c3d-0000-4000-8000-00000000abcd.json; content://media/external/1234567 token 9876543210"
        val redacted = CrashReportFormatter.redact(message)
        listOf("Sunset", "joe@", "/data/", "0a1b2c3d", "1234567", "9876543210").forEach { assertFalse(it, redacted.contains(it)) }
        assertTrue(redacted.contains("[email]") && redacted.contains("[path]") && redacted.contains("\"[redacted]\"") && redacted.contains("content://[redacted]"))
        assertTrue(CrashReportFormatter.redact("x".repeat(1000)).length <= 400)
    }

    @Test fun formattedReportHasNoDeviceIdentifiersAndBoundedFrames() {
        val error = IllegalStateException("Project \"Private\" failed", RuntimeException("root /tmp/secret/file"))
        val report = CrashReportFormatter.format(error, "0.1.0", 1, 1_700_000_000_000L, "main", 34)
        assertTrue(report.startsWith("sdi-android-crash-report v1\n"))
        assertTrue(report.contains("exception=java.lang.IllegalStateException") && report.contains("cause=java.lang.RuntimeException"))
        assertFalse(report.contains("Private")); assertFalse(report.contains("/tmp/secret"))
        assertTrue(report.lines().count { it.startsWith("  at ") } <= 2 * (CrashReportFormatter.MAX_FRAMES + 1))
        assertTrue(report.contains("app=0.1.0 (1)") && report.contains("api=34"))
    }

    @Test fun retentionKeepsFiveRecentReportsWithinThirtyDays() {
        val now = 1_700_000_000_000L
        val day = 24L * 60 * 60 * 1000
        val entries = (0 until 7).map { CrashReportRetention.Entry("crash-${now - it * day}.txt", now - it * day) } +
            CrashReportRetention.Entry("crash-${now - 40 * day}.txt", now - 40 * day) + CrashReportRetention.Entry("crash-${now + day}.txt", now + day)
        val toDelete = CrashReportRetention.toDelete(entries, now)
        // Expired (40 days), clock-skewed future, and the three oldest live ones go so four remain before the new write.
        assertTrue(toDelete.contains("crash-${now - 40 * day}.txt") && toDelete.contains("crash-${now + day}.txt"))
        assertEquals(5, toDelete.size)
        assertEquals(4, entries.size - toDelete.size)
        assertEquals(emptyList<String>(), CrashReportRetention.toDelete(entries.take(4), now))
        assertEquals(1_700_000_000_000L, CrashReportRetention.timestampOf("crash-1700000000000.txt"))
        assertEquals(null, CrashReportRetention.timestampOf("notes.txt"))
    }
}
