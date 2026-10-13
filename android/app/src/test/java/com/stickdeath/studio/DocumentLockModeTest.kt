package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Document validation and model flags for the v26 features, on the plain JVM. */
class DocumentLockModeTest {
    private val base = Document.create("Lock modes", 64, 64, 12)
    private fun stroke(tool: Tool = Tool.Pencil, vararg points: Point = arrayOf(Point(8f, 8f), Point(40f, 40f))) =
        Stroke(layerID = base.activeLayerID, points = points.toList(), color = 0xff000000.toInt(), width = 4f, tool = tool)
    private fun withStroke(stroke: Stroke) = base.copy(frames = listOf(base.frame.copy(strokes = listOf(stroke))))
    private fun rejects(block: () -> Document) { try { block().validated(); fail("Invalid document was accepted") } catch (_: IllegalArgumentException) { } }

    @Test fun lockedIsDerivedFromTheLockMode() {
        assertFalse(Layer(name = "A").locked)
        assertTrue(Layer(name = "A", lockMode = LayerLockMode.Full).locked)
        assertFalse(Layer(name = "A", lockMode = LayerLockMode.Position).locked)
        assertTrue(Layer(name = "A", lockMode = LayerLockMode.Alpha).isEditable)
        assertFalse(Layer(name = "A", visible = false).isEditable)
        assertFalse(Layer(name = "A", opacity = 0f).isEditable)
        assertFalse(Layer(name = "A").needsV26); assertFalse(Layer(name = "A", lockMode = LayerLockMode.Full).needsV26)
        assertTrue(Layer(name = "A", lockMode = LayerLockMode.Position).needsV26); assertTrue(Layer(name = "A", label = LayerLabel.Blue).needsV26)
    }

    @Test fun toolAndBrushFlags() {
        assertTrue(Tool.SoftEraser.isEraser && Tool.SoftEraser.isDrawing && !Tool.SoftEraser.isSelectable && Tool.SoftEraser.needsV26)
        assertTrue(Tool.Eraser.isEraser && !Tool.Eraser.needsV26)
        assertFalse(Tool.Pencil.isEraser); assertTrue(Tool.Pencil.isSelectable)
        assertEquals(listOf(BrushFamily.Marker, BrushFamily.Crayon), BrushFamily.entries.filter { it.needsV26 })
        // A soft eraser mark is never mirrored, like the hard eraser.
        assertEquals(1, stroke(Tool.SoftEraser).mirrored(64, 64, MirrorMode.Both).size)
        assertEquals(4, stroke().mirrored(64, 64, MirrorMode.Both).size)
    }

    @Test fun documentsWithV26ContentValidateAndFlagTheEnvelope() {
        assertFalse(base.needsV26)
        val position = base.copy(layers = base.layers.map { it.copy(lockMode = LayerLockMode.Position, label = LayerLabel.Seafoam) }).validated()
        assertTrue(position.needsV26)
        assertTrue(withStroke(stroke(Tool.SoftEraser)).validated().needsV26)
        assertTrue(withStroke(stroke().copy(brush = BrushFamily.Marker)).validated().needsV26)
        assertTrue(withStroke(stroke().copy(brush = BrushFamily.Crayon, nibAngle = 10f)).validated().needsV26)
        assertTrue(withStroke(stroke().copy(preservesLayerAlpha = true)).validated().needsV26)
        assertTrue(BrushRenderer.work(stroke().copy(brush = BrushFamily.Marker)) > 0)
        assertTrue(BrushRenderer.work(stroke().copy(brush = BrushFamily.Crayon)) > BrushRenderer.work(stroke().copy(brush = BrushFamily.Marker)))
    }

    @Test fun invalidV26CombinationsReject() {
        rejects { withStroke(stroke(Tool.Line).copy(preservesLayerAlpha = true)) }
        rejects { withStroke(stroke().copy(preservesLayerAlpha = true, swiftLegacyPath = true)) }
        rejects { withStroke(stroke().copy(imageQuarterTurns = 1)) }
        rejects { withStroke(stroke().copy(imageCrop = ImageCrop.full)) }
        rejects { withStroke(stroke(Tool.SoftEraser).copy(filled = true)) }
        rejects { withStroke(stroke(Tool.SoftEraser).copy(brush = BrushFamily.Marker)) }
    }

    @Test fun selectionEligibilityFollowsTransformPermission() {
        val mark = stroke()
        val frame = base.frame.copy(strokes = listOf(mark))
        LayerLockMode.entries.forEach { mode ->
            val layers = base.layers.map { it.copy(lockMode = mode) }
            val eligible = ArtworkSelection.eligible(frame, layers)
            assertEquals(mode.name, mode.allowsTransform, mark.id in eligible)
        }
    }
}
