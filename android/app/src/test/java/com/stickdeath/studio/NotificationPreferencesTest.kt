package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NotificationPreferencesTest {
    @Test fun defaultsSeparateTransactionalFromMarketing() {
        val defaults = NotificationPreferences()
        NotificationCategory.entries.filter { it.kind == NotificationKind.Transactional }.forEach { assertTrue(it.name, defaults.isEnabled(it)); assertFalse(it.canDisable) }
        assertFalse(defaults.isEnabled(NotificationCategory.Announcements))
        assertTrue(defaults.isEnabled(NotificationCategory.RoomInvitations))
        try { defaults.setting(NotificationCategory.SecurityAndAccount, false); fail("Required notice was disabled") } catch (_: IllegalArgumentException) { }
    }

    @Test fun deliveryRuleHonoursOptOutQuietHoursAndCap() {
        val prefs = NotificationPreferences(quietStartMinute = 22 * 60, quietEndMinute = 7 * 60, dailyCap = 2)
        assertTrue(prefs.inQuietHours(23 * 60)); assertTrue(prefs.inQuietHours(30)); assertFalse(prefs.inQuietHours(12 * 60))
        assertTrue(prefs.shouldDeliver(NotificationCategory.SecurityAndAccount, 23 * 60, 99).deliver)
        assertFalse(prefs.shouldDeliver(NotificationCategory.WarRoomResults, 23 * 60, 0).deliver)
        assertTrue(prefs.shouldDeliver(NotificationCategory.WarRoomResults, 12 * 60, 1).deliver)
        assertFalse(prefs.shouldDeliver(NotificationCategory.WarRoomResults, 12 * 60, 2).deliver)
        assertFalse(prefs.shouldDeliver(NotificationCategory.Announcements, 12 * 60, 0).deliver)
        val opted = prefs.setting(NotificationCategory.Announcements, true)
        assertTrue(opted.shouldDeliver(NotificationCategory.Announcements, 12 * 60, 0).deliver)
    }

    @Test fun serializationRoundTripsAndRejectsCorruptRecords() {
        val prefs = NotificationPreferences(quietStartMinute = 1320, quietEndMinute = 420, dailyCap = 3)
            .setting(NotificationCategory.Announcements, true).setting(NotificationCategory.ChallengeReminders, false)
        val text = prefs.serialize()
        assertTrue(text.startsWith("v=1;") && text.contains("Announcements=1;") && text.contains("ChallengeReminders=0;") && text.contains("quiet=1320-420;"))
        assertEquals(prefs, NotificationPreferences.parse(text))
        assertEquals(NotificationPreferences(), NotificationPreferences.parse(null))
        // An old record that claims a required notice is off reads back as on.
        assertTrue(NotificationPreferences.parse("v=1;SecurityAndAccount=0;").isEnabled(NotificationCategory.SecurityAndAccount))
        listOf("v=2;", "v=1;cap=0;", "v=1;quiet=5;", "v=1;Announcements=maybe;", "nonsense").forEach { corrupt ->
            try { NotificationPreferences.parse(corrupt); fail("Accepted $corrupt") } catch (_: IllegalArgumentException) { }
        }
    }
}
