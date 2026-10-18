package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QuickShareTest {
    @Test fun defaultsAreTheSixIosDestinations() {
        val config = QuickShareConfiguration()
        assertEquals(listOf("youtube", "instagram", "tiktok", "facebook", "x", "reddit"), config.slots.map { it.wire })
        assertEquals(QuickShareFile.MP4, config.file(QuickShareDestination.YouTube))
        assertEquals(QuickShareFile.PNG, config.file(QuickShareDestination.Pinterest))
    }

    @Test fun assigningAPinnedDestinationSwapsSoSlotsStayDistinct() {
        val swapped = QuickShareConfiguration().assign(QuickShareDestination.Reddit, 0)
        assertEquals(QuickShareDestination.Reddit, swapped.slots[0]); assertEquals(QuickShareDestination.YouTube, swapped.slots[5])
        val replaced = swapped.assign(QuickShareDestination.Files, 1)
        assertEquals(QuickShareDestination.Files, replaced.slots[1]); assertEquals(6, replaced.slots.toSet().size)
        assertEquals(replaced, replaced.assign(QuickShareDestination.Files, 9))
    }

    @Test fun unacceptedFilesAreIgnoredAndStorageRoundTrips() {
        val config = QuickShareConfiguration().preferring(QuickShareFile.GIF, QuickShareDestination.YouTube).preferring(QuickShareFile.GIF, QuickShareDestination.X)
        assertEquals(QuickShareFile.MP4, config.file(QuickShareDestination.YouTube))
        assertEquals(QuickShareFile.GIF, config.file(QuickShareDestination.X))
        assertEquals(config, QuickShareConfiguration.parse(config.serialize()))
    }

    @Test fun malformedStorageFallsBackToDefaults() {
        assertEquals(QuickShareConfiguration(), QuickShareConfiguration.parse("v=1;slots=youtube,youtube,tiktok,facebook,x,reddit;"))
        assertEquals(QuickShareConfiguration(), QuickShareConfiguration.parse("v=2;slots=youtube"))
        assertEquals(QuickShareConfiguration(), QuickShareConfiguration.parse("garbage"))
        val kept = QuickShareConfiguration.parse("v=1;slots=youtube,instagram,tiktok,facebook,x,reddit;file.youtube=GIF;file.x=PNG;")
        assertEquals(QuickShareFile.MP4, kept.file(QuickShareDestination.YouTube)); assertEquals(QuickShareFile.PNG, kept.file(QuickShareDestination.X))
    }

    @Test fun instructionsNeverClaimAPost() {
        QuickShareDestination.entries.forEach { assertTrue(QuickShareConfiguration().instruction(it).isNotBlank()) }
        assertTrue(QuickShareConfiguration().instruction(QuickShareDestination.TikTok).contains("cannot confirm a post"))
    }
}
