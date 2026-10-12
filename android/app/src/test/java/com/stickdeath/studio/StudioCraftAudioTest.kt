package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

/** Plain JVM checks of the SoundCraft math ported from StudioCraftAudio.swift; no Android runtime. */
class StudioCraftAudioTest {
    private val epsilon = 1e-12

    @Test fun fadeShapesMatchTheSwiftFormulas() {
        FadeShape.entries.forEach { shape ->
            assertEquals(shape.name, 0.0, shape.gain(0.0), epsilon)
            assertEquals(shape.name, 1.0, shape.gain(1.0), epsilon)
            // Out-of-range and non-finite inputs clamp exactly as the Swift port does.
            assertEquals(shape.name, 0.0, shape.gain(-0.5), epsilon)
            assertEquals(shape.name, 1.0, shape.gain(7.0), epsilon)
            assertEquals(shape.name, 0.0, shape.gain(Double.NaN), epsilon)
            assertEquals(shape.name, 0.0, shape.gain(Double.NEGATIVE_INFINITY), epsilon)
        }
        assertEquals(0.25, FadeShape.Linear.gain(0.25), epsilon)
        assertEquals(sin(0.5 * PI / 2), FadeShape.EqualPower.gain(0.5), epsilon)
        assertEquals(0.5, FadeShape.SCurve.gain(0.5), epsilon)
        assertEquals(0.125, FadeShape.Exponential.gain(0.5), epsilon)
        assertEquals(0.875, FadeShape.Logarithmic.gain(0.5), epsilon)
        assertEquals(0.027, FadeShape.Exponential.gain(0.3), epsilon)
        assertEquals(1.0 - 0.7 * 0.7 * 0.7, FadeShape.Logarithmic.gain(0.3), epsilon)
    }

    @Test fun fadeShapeNamesRoundTripWithSwiftRawValues() {
        val expected = mapOf(FadeShape.Linear to "linear", FadeShape.EqualPower to "equalPower", FadeShape.SCurve to "sCurve",
            FadeShape.Exponential to "exponential", FadeShape.Logarithmic to "logarithmic")
        assertEquals(expected.keys, FadeShape.entries.toSet())
        expected.forEach { (shape, raw) ->
            assertEquals(raw, shape.swiftName)
            assertEquals(shape, FadeShape.fromSwift(raw))
            assertEquals(shape, FadeShape.fromSwift(raw.uppercase()))
            assertEquals(shape, FadeShape.fromStored(raw))
            assertEquals(shape, FadeShape.fromStored(shape.name))
        }
        assertEquals(null, FadeShape.fromSwift("cosine"))
        try { FadeShape.fromStored("cosine"); fail("Unknown fade shape was accepted") } catch (_: IllegalArgumentException) { }
    }

    @Test fun linearFadeEnvelopeIsUnchangedAndShapesApplyPerEdge() {
        val linear = AudioFade(start = 1.0, end = 5.0, fadeIn = 2.0, fadeOut = 1.0)
        assertFalse(linear.hasCurveShapes)
        assertEquals(0.0, linear.gain(1.0), epsilon)
        assertEquals(0.5, linear.gain(2.0), epsilon)
        assertEquals(1.0, linear.gain(3.5), epsilon)
        assertEquals(0.5, linear.gain(4.5), epsilon)
        assertEquals(0.0, linear.gain(5.0), epsilon)
        val shaped = linear.copy(inShape = FadeShape.EqualPower, outShape = FadeShape.Exponential)
        assertTrue(shaped.hasCurveShapes)
        assertEquals(sin(0.5 * PI / 2), shaped.gain(2.0), epsilon)
        assertEquals(1.0, shaped.gain(3.5), epsilon)
        assertEquals(0.125, shaped.gain(4.5), epsilon)
        // The envelope is the minimum of both edges, as in AudioFadeEnvelope.gain(atSourceFrame:).
        val both = AudioFade(0.0, 4.0, 2.0, 2.0, FadeShape.Exponential, FadeShape.SCurve)
        both.validate(4.0)
        assertEquals(0.125, both.gain(1.0), epsilon)
        assertEquals(0.5, both.gain(3.0), epsilon)
    }

    @Test fun balanceLawKeepsCentreBitIdentical() {
        assertEquals(StudioCraftAudio.Balance(1.0, 1.0), StudioCraftAudio.balanceGains(0.0))
        assertEquals(StudioCraftAudio.Balance(1.0, 1.0), StudioCraftAudio.balanceGains(-0.0))
        assertEquals(StudioCraftAudio.Balance(1.0, 0.0), StudioCraftAudio.balanceGains(-1.0))
        assertEquals(StudioCraftAudio.Balance(0.0, 1.0), StudioCraftAudio.balanceGains(1.0))
        assertEquals(StudioCraftAudio.Balance(1.0, 0.5), StudioCraftAudio.balanceGains(-0.5))
        assertEquals(StudioCraftAudio.Balance(0.75, 1.0), StudioCraftAudio.balanceGains(0.25))
        // Clamping and non-finite handling match the Swift port.
        assertEquals(StudioCraftAudio.Balance(0.0, 1.0), StudioCraftAudio.balanceGains(1.5))
        assertEquals(StudioCraftAudio.Balance(1.0, 0.0), StudioCraftAudio.balanceGains(-7.0))
        assertEquals(StudioCraftAudio.Balance(1.0, 1.0), StudioCraftAudio.balanceGains(Double.NaN))
        val sample = 12345.678
        assertEquals(sample, sample * StudioCraftAudio.balanceGains(0.0).left, 0.0)
        assertEquals(sample, sample * StudioCraftAudio.balanceGains(0.0).right, 0.0)
    }

    @Test fun panLabelsReadLikeSoundCraft() {
        assertEquals("C", StudioCraftAudio.panLabel(0.0))
        assertEquals("L35", StudioCraftAudio.panLabel(-0.35))
        assertEquals("R100", StudioCraftAudio.panLabel(1.0))
        assertEquals("R100", StudioCraftAudio.panLabel(4.0))
        assertEquals("C", StudioCraftAudio.panLabel(Double.NaN))
    }

    @Test fun muteAndSoloRuleMatchesSoundCraft() {
        assertTrue(StudioCraftAudio.isTrackAudible(1, emptySet(), emptySet()))
        assertFalse(StudioCraftAudio.isTrackAudible(1, setOf(1), emptySet()))
        assertTrue(StudioCraftAudio.isTrackAudible(2, setOf(1), emptySet()))
        assertTrue(StudioCraftAudio.isTrackAudible(2, emptySet(), setOf(2)))
        assertFalse(StudioCraftAudio.isTrackAudible(1, emptySet(), setOf(2)))
        // Mute wins even when the track is soloed.
        assertFalse(StudioCraftAudio.isTrackAudible(2, setOf(2), setOf(2)))
        assertTrue(StudioCraftAudio.isTrackAudible(3, setOf(1), setOf(2, 3)))

        val tracks = listOf(AudioTrackMix(), AudioTrackMix(soloed = true), AudioTrackMix(muted = true), AudioTrackMix(muted = true, soloed = true))
        assertFalse(StudioCraftAudio.isTrackAudible(1, tracks))
        assertTrue(StudioCraftAudio.isTrackAudible(2, tracks))
        assertFalse(StudioCraftAudio.isTrackAudible(3, tracks))
        assertFalse(StudioCraftAudio.isTrackAudible(4, tracks))
        assertFalse(StudioCraftAudio.isTrackAudible(5, tracks))
        val noSolo = List(4) { AudioTrackMix(muted = it == 2) }
        assertTrue(StudioCraftAudio.isTrackAudible(1, noSolo))
        assertFalse(StudioCraftAudio.isTrackAudible(3, noSolo))
    }

    @Test fun trackMixValidatesPanRange() {
        AudioTrackMix(pan = -1f).validate(); AudioTrackMix(pan = 1f).validate(); AudioTrackMix().validate()
        listOf(1.5f, -1.01f, Float.NaN, Float.POSITIVE_INFINITY).forEach { pan ->
            try { AudioTrackMix(pan = pan).validate(); fail("Pan $pan was accepted") } catch (_: IllegalArgumentException) { }
        }
        assertEquals(AudioTrackMix(volume = 1f, muted = false, pan = 0f, soloed = false), AudioTrackMix())
    }
}
