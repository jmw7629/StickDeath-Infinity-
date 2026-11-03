package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test

/** Real transform validation at the pointer-preview boundary; no fake editor or copied geometry. */
class ArtworkTransformPreviewTest {
    private fun mark(width: Float, brush: BrushFamily = BrushFamily.Crayon) = Stroke(
        id = "selected", layerID = "ink", points = listOf(Point(400f, 400f), Point(500f, 460f)),
        color = 0xff000000.toInt(), width = width, tool = Tool.Pencil, brush = brush)
    private fun frame(mark: Stroke): Frame {
        val frame = Frame(id = "frame", strokes = listOf(mark))
        return Document.create("Selection preview", 1024, 1024, 12).copy(
            frames = listOf(frame), layers = listOf(Layer(id = "ink", name = "Ink")),
            activeFrameID = frame.id, activeLayerID = "ink").validated().frame
    }
    private val ids = setOf("selected")
    private fun bounds(frame: Frame) = requireNotNull(ArtworkSelection.bounds(frame, ids))
    private fun canonicalRefuses(transform: ArtworkTransform, frame: Frame) {
        try { transform.apply(frame, ids, bounds(frame)); fail("Canonical transform accepted invalid geometry") }
        catch (_: IllegalArgumentException) { }
    }

    @Test fun enlargedMaximumTexturedBrushIsARefusalInsteadOfAnUncaughtPreviewError() {
        val original = frame(mark(128f, BrushFamily.Stipple))
        val transform = ArtworkTransform(scale = 1.1f)
        val preview = transform.preview(original, ids, bounds(original))
        assertSame(original, preview.frame)
        assertEquals("Transformed brush width must remain 1–128 pixels.", preview.refusal)
        assertEquals(128f, original.strokes.single().width, 0f)
        canonicalRefuses(transform, original)
    }

    @Test fun shrinkingMinimumTexturedBrushNeverClampsItsCanonicalWidth() {
        BrushFamily.entries.filter { it != BrushFamily.Round }.forEach { family ->
            val original = frame(mark(1f, family))
            val transform = ArtworkTransform(scale = 0.5f)
            val preview = transform.preview(original, ids, bounds(original))
            assertSame(family.name, original, preview.frame)
            assertNotNull(family.name, preview.refusal)
            assertEquals(1f, original.strokes.single().width, 0f)
            canonicalRefuses(transform, original)
        }
    }

    @Test fun invalidDragRetainsLastValidPreviewAndCanRecoverWithoutAccumulatingMovement() {
        val original = frame(mark(128f))
        val bounds = bounds(original)
        val moved = ArtworkTransform(dx = 12f, dy = 8f).preview(original, ids, bounds)
        assertNull(moved.refusal)
        assertEquals(Point(412f, 408f), moved.frame.strokes.single().points.first())
        val rejected = ArtworkTransform(scale = 2f).preview(original, ids, bounds, moved.frame)
        assertSame(moved.frame, rejected.frame)
        assertNotNull(rejected.refusal)
        val recovered = ArtworkTransform(dx = 20f, dy = 9f).preview(original, ids, bounds, rejected.frame)
        assertNull(recovered.refusal)
        assertEquals(Point(420f, 409f), recovered.frame.strokes.single().points.first())
        assertEquals("selected", recovered.frame.strokes.single().id)
        assertEquals(Point(400f, 400f), original.strokes.single().points.first())
        assertEquals(128f, recovered.frame.strokes.single().width, 0f)
    }

    @Test fun importedSwiftRoundBrushKeepsPressureAndDescriptorWhenPreviewRefusesOrSucceeds() {
        val descriptor = """{"family":"round","grain":0.3,"pressureEnabled":true,"seed":7,"smoothing":3,"texture":0.5,"tipAngleDegrees":45,"version":1}"""
        val source = SwiftRoundBrush(descriptor, listOf(0.2, 1.0))
        source.validate(2)
        val original = frame(mark(128f, BrushFamily.Round).copy(swiftRoundBrush = source))
        val rejected = ArtworkTransform(scale = 2f).preview(original, ids, bounds(original))
        assertSame(original, rejected.frame)
        assertNotNull(rejected.refusal)
        canonicalRefuses(ArtworkTransform(scale = 2f), original)
        val accepted = ArtworkTransform(scale = 0.5f).preview(original, ids, bounds(original), rejected.frame)
        assertNull(accepted.refusal)
        val shown = accepted.frame.strokes.single()
        assertEquals(64f, shown.width, 0f)
        assertSame(source, shown.swiftRoundBrush)
        assertEquals(descriptor, shown.swiftRoundBrush!!.descriptor)
        assertEquals(listOf(0.2, 1.0), shown.swiftRoundBrush!!.pressures)
        assertEquals(128f, original.strokes.single().width, 0f)
    }

    @Test fun accumulatedNibTransformLimitAlsoRetainsLastValidPreview() {
        val original = frame(mark(64f, BrushFamily.Hatch).copy(brushTransform = BrushTransform(64f, 0f, 0f, 64f)))
        // This starts from a valid one-pixel source brush; growing twice is a valid 128px width,
        // but would exceed the canonical nib matrix limit. Preserve that independent validator.
        assertTrue(BrushRenderer.work(original.strokes.single()) > 0)
        val valid = ArtworkTransform(dx = 3f).preview(original, ids, bounds(original))
        assertNull(valid.refusal)
        val refused = ArtworkTransform(scale = 2f).preview(original, ids, bounds(original), valid.frame)
        assertSame(valid.frame, refused.frame)
        assertEquals("Brush transform capacity reached. Undo or use a smaller transform.", refused.refusal)
        canonicalRefuses(ArtworkTransform(scale = 2f), original)
    }
}
