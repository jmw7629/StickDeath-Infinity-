package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Blend-name contract against StudioLayerBlendMode.swift raw values; pure JVM. */
class LayerBlendTest {
    private val swiftRawValues = mapOf(
        LayerBlend.Normal to "normal", LayerBlend.Darken to "darken", LayerBlend.Multiply to "multiply",
        LayerBlend.ColorBurn to "color-burn", LayerBlend.LinearBurn to "linear-burn",
        LayerBlend.Lighten to "lighten", LayerBlend.Screen to "screen",
        LayerBlend.ColorDodge to "color-dodge", LayerBlend.LinearDodge to "linear-dodge",
        LayerBlend.Overlay to "overlay", LayerBlend.SoftLight to "soft-light", LayerBlend.HardLight to "hard-light",
        LayerBlend.Difference to "difference", LayerBlend.Exclusion to "exclusion",
        LayerBlend.Hue to "hue", LayerBlend.Saturation to "saturation", LayerBlend.Color to "color", LayerBlend.Luminosity to "luminosity")

    @Test fun everyModeHasTheSwiftRawValueAndRoundTrips() {
        assertEquals(18, LayerBlend.entries.size)
        assertEquals(swiftRawValues.keys, LayerBlend.entries.toSet())
        swiftRawValues.forEach { (blend, raw) ->
            assertEquals(raw, blend.swiftName)
            assertEquals(blend, LayerBlend.fromSwift(raw))
            assertEquals(blend, LayerBlend.fromSwift(blend.swiftName))
        }
        assertEquals(LayerBlend.entries.size, LayerBlend.entries.map { it.swiftName }.toSet().size)
    }

    @Test fun swiftLookupIsCaseInsensitiveAndUnknownStaysNull() {
        assertEquals(LayerBlend.ColorBurn, LayerBlend.fromSwift("Color-Burn"))
        assertEquals(LayerBlend.Multiply, LayerBlend.fromSwift("MULTIPLY"))
        assertEquals(LayerBlend.LinearDodge, LayerBlend.fromSwift("Linear-Dodge"))
        assertNull(LayerBlend.fromSwift("colorBurn"))
        assertNull(LayerBlend.fromSwift("plus-lighter"))
        assertNull(LayerBlend.fromSwift(""))
        assertNull(LayerBlend.fromSwift("ColorBurn"))
    }

    @Test fun localEnvelopeReadsOldEnumNamesAndNewRawValues() {
        LayerBlend.entries.forEach { blend ->
            assertEquals(blend, LayerBlend.fromStored(blend.name))
            assertEquals(blend, LayerBlend.fromStored(blend.swiftName))
        }
        try { LayerBlend.fromStored("Dissolve"); fail("Unknown stored blend was accepted") } catch (_: IllegalArgumentException) { }
    }

    @Test fun historicalSixAreNotExtended() {
        val historical = setOf(LayerBlend.Normal, LayerBlend.Multiply, LayerBlend.Screen, LayerBlend.Overlay, LayerBlend.Darken, LayerBlend.Lighten)
        assertEquals(historical, LayerBlend.historical)
        historical.forEach { assertFalse(it.name, it.isExtended) }
        (LayerBlend.entries - historical).forEach { assertTrue(it.name, it.isExtended) }
        assertFalse(LayerBlend.Normal.needsModernBlend)
        assertTrue(LayerBlend.LinearDodge.needsModernBlend)
    }
}
