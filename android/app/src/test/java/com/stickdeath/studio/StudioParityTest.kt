package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Pure-JVM checks of the schema-35 parity primitives in StudioParity.kt. */
class StudioParityTest {
    private fun <T> rejects(block: () -> T) { try { block(); fail("Invalid value was accepted") } catch (_: IllegalArgumentException) { } }

    @Test fun lockModesMatchTheIOSRules() {
        assertEquals(listOf("free", "full", "position", "alpha"), LayerLockMode.entries.map { it.swiftName })
        LayerLockMode.entries.forEach { assertEquals(it, LayerLockMode.fromSwift(it.swiftName.uppercase())); assertEquals(it, LayerLockMode.fromStored(it.name)) }
        assertNull(LayerLockMode.fromSwift("pinned"))
        rejects { LayerLockMode.fromStored("pinned") }
        // Free allows everything; Full nothing; Position only new marks and deletion; Alpha nothing but brush paint.
        assertTrue(LayerLockMode.Free.allowsNewMarks && LayerLockMode.Free.allowsErase && LayerLockMode.Free.allowsTransform && LayerLockMode.Free.allowsDelete)
        assertFalse(LayerLockMode.Full.allowsNewMarks || LayerLockMode.Full.allowsErase || LayerLockMode.Full.allowsTransform || LayerLockMode.Full.allowsDelete)
        assertTrue(LayerLockMode.Position.allowsNewMarks && LayerLockMode.Position.allowsDelete)
        assertFalse(LayerLockMode.Position.allowsErase || LayerLockMode.Position.allowsTransform)
        assertFalse(LayerLockMode.Alpha.allowsNewMarks || LayerLockMode.Alpha.allowsErase || LayerLockMode.Alpha.allowsTransform || LayerLockMode.Alpha.allowsDelete)
        assertTrue(LayerLockMode.Full.isFull); assertFalse(LayerLockMode.Alpha.isFull)
    }

    @Test fun layerLabelsAreThePhotoCraftSwatches() {
        val swift = mapOf("Red" to "#FC5D5B", "Orange" to "#F79744", "Yellow" to "#DCD64B", "Green" to "#85DC6A", "Seafoam" to "#1C8488",
            "Blue" to "#78ADF6", "Indigo" to "#544BE7", "Magenta" to "#CC1A7E", "Fuchsia" to "#B014C0", "Violet" to "#9176D5", "Gray" to "#9C9C9C")
        assertEquals(swift.keys.toList(), LayerLabel.entries.map { it.name })
        LayerLabel.entries.forEach { label ->
            assertEquals(swift.getValue(label.name), label.hex)
            assertEquals(label, LayerLabel.fromHex(label.hex.lowercase()))
            assertEquals(label.hex.substring(1).toLong(16).toInt() or 0xff000000.toInt(), label.argb)
            assertEquals(7, label.cellHex.length)
        }
        assertNull(LayerLabel.fromHex("#123456")); assertNull(LayerLabel.fromHex(null)); assertNull(LayerLabel.fromHex(""))
    }

    @Test fun imageCropValidatesLikeIOS() {
        ImageCrop.full.validate(); ImageCrop(0.25, 0.5, 0.5, 0.5).validate(); ImageCrop(0.0, 0.0, 0.01, 0.01).validate()
        assertTrue(ImageCrop.full.isFull); assertFalse(ImageCrop(0.0, 0.0, 0.99, 1.0).isFull)
        listOf(ImageCrop(-0.1, 0.0, 0.5, 0.5), ImageCrop(0.0, 0.0, 0.005, 0.5), ImageCrop(0.6, 0.0, 0.5, 0.5),
            ImageCrop(0.0, 0.6, 0.5, 0.5), ImageCrop(Double.NaN, 0.0, 0.5, 0.5)).forEach { crop -> rejects { crop.validate() } }
        assertEquals(ImageCrop(0.1, 0.2, 0.6, 0.5), ImageCrop.fromEdges(0.1, 0.2, 0.7, 0.7))
    }

    @Test fun quarterTurnsMapDisplayCornersToSourceCorners() {
        val w = 200; val h = 100
        fun triangle(turns: Int) = ImageGeometry.sourceTriangle(w, h, ImageCrop.full, turns).toList()
        // Display TL, TR, BL in source pixels: 0 turns = TL,TR,BL; 1 CW = BL,TL,BR; 2 = BR,BL,TR; 3 = TR,BR,TL.
        assertEquals(listOf(0f, 0f, 200f, 0f, 0f, 100f), triangle(0))
        assertEquals(listOf(0f, 100f, 0f, 0f, 200f, 100f), triangle(1))
        assertEquals(listOf(200f, 100f, 0f, 100f, 200f, 0f), triangle(2))
        assertEquals(listOf(200f, 0f, 200f, 100f, 0f, 0f), triangle(3))
        assertEquals(triangle(0), triangle(4))
        // A crop of the right half with no turns starts at x = 100.
        assertEquals(listOf(100f, 0f, 200f, 0f, 100f, 100f), ImageGeometry.sourceTriangle(w, h, ImageCrop(0.5, 0.0, 0.5, 1.0), 0).toList())
        (0..3).forEach { turns ->
            val (a, b) = ImageGeometry.displayToCrop(0.3, 0.8, turns)
            val (u, v) = ImageGeometry.cropToDisplay(a, b, turns)
            assertEquals(0.3, u, 1e-12); assertEquals(0.8, v, 1e-12)
        }
    }

    @Test fun recroppingShrinksTheQuadWithoutRescalingContent() {
        val quad = listOf(Point(10f, 10f), Point(110f, 10f), Point(110f, 60f), Point(10f, 60f))
        // Keep the right half of an unturned image: the quad becomes its right half.
        assertEquals(listOf(Point(60f, 10f), Point(110f, 10f), Point(110f, 60f), Point(60f, 60f)),
            ImageGeometry.recroppedQuad(quad, ImageCrop.full, ImageCrop(0.5, 0.0, 0.5, 1.0), 0))
        // Turned once clockwise the source's right edge shows at the bottom, so the kept region is the bottom half.
        assertEquals(listOf(Point(10f, 35f), Point(110f, 35f), Point(110f, 60f), Point(10f, 60f)),
            ImageGeometry.recroppedQuad(quad, ImageCrop.full, ImageCrop(0.5, 0.0, 0.5, 1.0), 1))
        // Re-cropping relative to an existing crop keeps scale: half of the right half is the right quarter.
        assertEquals(listOf(Point(85f, 10f), Point(110f, 10f), Point(110f, 60f), Point(85f, 60f)),
            ImageGeometry.recroppedQuad(listOf(Point(60f, 10f), Point(110f, 10f), Point(110f, 60f), Point(60f, 60f)), ImageCrop(0.5, 0.0, 0.5, 1.0), ImageCrop(0.75, 0.0, 0.25, 1.0), 0))
        // Restoring the full crop grows the quad back.
        assertEquals(quad, ImageGeometry.recroppedQuad(listOf(Point(60f, 10f), Point(110f, 10f), Point(110f, 60f), Point(60f, 60f)), ImageCrop(0.5, 0.0, 0.5, 1.0), ImageCrop.full, 0))
        assertEquals(listOf(Point(35f, -15f), Point(85f, -15f), Point(85f, 85f), Point(35f, 85f)), ImageGeometry.turnedQuad(quad))
    }

    @Test fun softEraserPassesReachTheRequestedStrengthAtTheCentre() {
        val passes = SoftEraser.passes(1f)
        assertEquals(4, passes.size)
        assertEquals(listOf(0.4375f, 0.625f, 0.8125f, 1f), passes.map { it.widthFactor })
        assertEquals(1.0, SoftEraser.removedFraction(1f, 4), 1e-9)
        assertEquals(0.5, SoftEraser.removedFraction(0.5f, 4), 1e-6)
        assertTrue(SoftEraser.removedFraction(0.5f, 1) < SoftEraser.removedFraction(0.5f, 4))
        assertEquals(0.0, SoftEraser.removedFraction(0f, 4), 0.0)
        rejects { SoftEraser.passAlpha(1.5f) }
    }

    @Test fun rulerConstrainsToStraightLines() {
        val anchor = Point(100f, 100f)
        assertEquals(Point(130f, 112f), RulerConstraint(anchor, RulerMode.Off).constrain(Point(130f, 112f)))
        assertEquals(Point(130f, 100f), RulerConstraint(anchor, RulerMode.Horizontal).constrain(Point(130f, 112f)))
        assertEquals(Point(100f, 112f), RulerConstraint(anchor, RulerMode.Vertical).constrain(Point(130f, 112f)))
        val diagonal = RulerConstraint(anchor, RulerMode.Diagonal).constrain(Point(140f, 130f))
        assertEquals(135f, diagonal.x, 0.001f); assertEquals(135f, diagonal.y, 0.001f)
        val locked = RulerConstraint(anchor, RulerMode.FirstDirection)
        assertEquals(anchor, locked.constrain(Point(102f, 101f))) // below the lock distance nothing moves
        val first = locked.constrain(Point(140f, 103f)) // ~4°, snaps to horizontal
        assertEquals(140f, first.x, 0.001f); assertEquals(100f, first.y, 0.001f)
        val later = locked.constrain(Point(100f, 180f)) // direction stays locked afterwards
        assertEquals(100f, later.y, 0.001f)
    }

    @Test fun audioLimitsMatchIOSSecondsWithinAndroidBytes() {
        assertEquals(300.0, AudioLimits.MAX_CLIP_SECONDS, 0.0)
        assertEquals(3600.0, AudioLimits.MAX_TIMELINE_START_SECONDS, 0.0)
        // 4 MiB of PCM16: about 262 s at 8 kHz mono, about 21.8 s at 48 kHz stereo; never above 300 s.
        assertEquals((4 * 1024 * 1024 - 44) / 16000.0, AudioLimits.secondsFittingSource(8000, 1), 1e-9)
        assertEquals(300.0, AudioLimits.secondsFittingSource(1, 1), 0.0)
        assertTrue(AudioLimits.secondsFittingSource(48_000, 2) < 22.0 && AudioLimits.secondsFittingSource(48_000, 2) > 21.0)
        assertTrue(AudioLimits.durationMessage().contains("300"))
    }

    @Test fun gifDelaysRoundCumulativeBoundaries() {
        assertEquals(listOf(4, 4, 5), GifTiming.delaysCentiseconds(listOf(1, 1, 1), 24))
        // Boundaries 8.33, 16.67, 25, 33.33 cs round (ties up) to 8, 17, 25, 33.
        assertEquals(listOf(8, 9, 8, 8), GifTiming.delaysCentiseconds(listOf(1, 1, 1, 1), 12))
        assertEquals(listOf(100), GifTiming.delaysCentiseconds(listOf(60), 60))
        assertTrue(GifTiming.delaysCentiseconds(List(600) { 1 }, 60).all { it in 1..2 })
        rejects { GifTiming.delaysCentiseconds(emptyList(), 12) }
    }

    @Test fun exportFilenameMatchesTheSwiftPort() {
        assertEquals("animation", StudioExportFilename.base(null))
        assertEquals("animation", StudioExportFilename.base("   "))
        assertEquals("My-Film_2", StudioExportFilename.base(" My Film_2! "))
        // Non-ASCII letters are dropped and the surrounding run collapses to one dash, as in Swift.
        assertEquals("Sunset-ber-Lagos", StudioExportFilename.base("Sunset über Lagos"))
        assertEquals("a".repeat(40), StudioExportFilename.base("a".repeat(45)))
        assertEquals("animation", StudioExportFilename.base("---"))
        assertTrue(StudioExportFilename.isValid("Sunset-1")); assertFalse(StudioExportFilename.isValid("-x")); assertFalse(StudioExportFilename.isValid("a b"))
    }

    @Test fun swiftDatesUseTheReferenceEpoch() {
        assertEquals(0.0, SwiftDates.fromEpochMillis(978_307_200_000L), 0.0)
        assertEquals(978_307_200_000L + 1500, SwiftDates.toEpochMillis(1.5))
        assertEquals(1_700_000_000_000L, SwiftDates.toEpochMillis(SwiftDates.fromEpochMillis(1_700_000_000_000L)))
    }
}
