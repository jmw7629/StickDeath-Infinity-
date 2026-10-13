package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The local grammar accepts the iOS example sentences and nothing looser. */
class SpatterCommandBridgeTest {
    private fun rejects(text: String) {
        try { SpatterCommandBridge.parse(text); fail("Accepted: $text") }
        catch (error: SpatterCommandException) { assertTrue(error.message!!.endsWith("Nothing changed.")) }
    }

    @Test fun everyExampleParsesAndDescribes() {
        SpatterCommandBridge.examples.forEach { example ->
            val command = SpatterCommandBridge.parse(example)
            assertTrue(example, SpatterCommandBridge.describe(command).isNotBlank())
        }
        assertEquals(31, SpatterCommandBridge.examples.size)
    }

    @Test fun parsedValuesMatchTheSentences() {
        assertEquals(SpatterCommand.SelectFrame(12), SpatterCommandBridge.parse("Select frame 12."))
        assertEquals(SpatterCommand.SelectLayer(2), SpatterCommandBridge.parse("  select LAYER 2. "))
        assertEquals(SpatterCommand.AddLayer("Foreground"), SpatterCommandBridge.parse("Add layer named \"Foreground\"."))
        assertEquals(SpatterCommand.UpdateActiveLayer(lock = LayerLockMode.Position), SpatterCommandBridge.parse("Set active layer lock to position."))
        assertEquals(SpatterCommand.UpdateActiveLayer(blend = LayerBlend.ColorBurn), SpatterCommandBridge.parse("Set active layer blend to color-burn."))
        assertEquals(SpatterCommand.UpdateActiveLayer(visible = false), SpatterCommandBridge.parse("Hide active layer."))
        assertEquals(SpatterCommand.UpdateActiveLayer(name = "Sky"), SpatterCommandBridge.parse("Rename active layer to \" Sky \"."))
        assertEquals(0.5f, (SpatterCommandBridge.parse("Set active layer opacity to 50%.") as SpatterCommand.UpdateActiveLayer).opacity)
        assertEquals(SpatterCommand.MoveActiveLayer(up = false), SpatterCommandBridge.parse("Move active layer down."))
        assertEquals(SpatterCommand.AudioTrack(1, volume = 0.4f), SpatterCommandBridge.parse("Set audio track 1 volume to 40%."))
        assertEquals(SpatterCommand.AudioTrack(1, muted = false), SpatterCommandBridge.parse("Unmute audio track 1"))
        assertEquals(SpatterCommand.AudioTrack(2, pan = -0.4f), SpatterCommandBridge.parse("Pan audio track 2 to L40."))
        assertEquals(SpatterCommand.AudioTrack(2, pan = 0f), SpatterCommandBridge.parse("Pan audio track 2 to centre."))
        assertEquals(SpatterCommand.AudioTrack(4, pan = 1f), SpatterCommandBridge.parse("Pan audio track 4 to R100."))
        assertEquals(SpatterCommand.AudioTrack(3, soloed = true), SpatterCommandBridge.parse("Solo audio track 3."))
        assertEquals(SpatterCommand.FrameExposure(12), SpatterCommandBridge.parse("Set selected frame exposure to 12 ticks."))
        assertEquals(SpatterCommand.FrameExposure(2, 1, 12), SpatterCommandBridge.parse("Set frames 1 through 12 exposure to 2 ticks."))
        assertEquals(SpatterCommand.DuplicateFrames(1, 12), SpatterCommandBridge.parse("Duplicate frames 1 through 12."))
        assertEquals(SpatterCommand.ReverseFrames(1, 12), SpatterCommandBridge.parse("Reverse frames 1 through 12."))
        assertEquals(SpatterCommand.RenameProject("Sunset"), SpatterCommandBridge.parse("Rename project to \"Sunset\""))
        assertEquals(SpatterCommand.OnionSkin(visible = true), SpatterCommandBridge.parse("Show onion skin."))
        assertEquals(SpatterCommand.OnionSkin(settings = OnionSettings(true, 2, 1, 0.35f, true)), SpatterCommandBridge.parse("Set onion skin to 2 previous frames, 1 next frame, 35% opacity, tinted."))
        assertEquals(SpatterCommand.Grid(visible = false), SpatterCommandBridge.parse("Hide grid."))
        assertEquals(SpatterCommand.Grid(settings = GridSettings(true, 32, 0.25f, 0xffe52b38.toInt())), SpatterCommandBridge.parse("Set grid to 32 canvas points spacing, 25% opacity, red tint."))
    }

    @Test fun looseOrDangerousTextIsRefused() {
        rejects(""); rejects("   ")
        rejects("Select frame 0.")
        rejects("Select frame 1. Delete active layer.")
        rejects("Delete all layers.")
        rejects("Set active layer opacity to 150%.")
        rejects("Set active layer blend to dissolve.")
        rejects("Set active layer lock to pinned.")
        rejects("Pan audio track 5 to L40.")
        rejects("Pan audio track 1 to L140.")
        rejects("Set frames 5 through 2 exposure to 2 ticks.")
        rejects("Set frames 1 through 97 exposure to 2 ticks.")
        rejects("Reverse frames 3 through 3.")
        rejects("Set selected frame exposure to 0 ticks.")
        rejects("Set onion skin to 3 previous frames, 1 next frame, 35% opacity, tinted.")
        rejects("Set grid to 4 canvas points spacing, 25% opacity, red tint.")
        rejects("Set grid to 32 canvas points spacing, 25% opacity, purple tint.")
        rejects("Rename project to \"\".")
        rejects("Add layer named \"\u0007\".")
        rejects("Select frame 1.\u0000")
        rejects("Select frame 1." + " ".repeat(1100))
        rejects("Please select frame 1.")
    }

    @Test fun quotedTextIsDataNotAnotherInstruction() {
        val command = SpatterCommandBridge.parse("Rename project to \"Delete active layer.\".")
        assertEquals(SpatterCommand.RenameProject("Delete active layer."), command)
        val layer = SpatterCommandBridge.parse("Add layer named \"Reverse frames 1 through 12.\".")
        assertEquals(SpatterCommand.AddLayer("Reverse frames 1 through 12."), layer)
    }

    @Test fun describeIsHonestAboutGuideConfiguration() {
        assertTrue(SpatterCommandBridge.describe(SpatterCommandBridge.parse("Set grid to 32 canvas points spacing, 25% opacity, red tint.")).contains("visibility is unchanged"))
        assertEquals("Audio track 2: pan L40", SpatterCommandBridge.describe(SpatterCommand.AudioTrack(2, pan = -0.4f)))
    }
}
