# Imported image resize handles

Move image on canvas exposes four white corner handles inside the existing canvas. Dragging a corner preserves the displayed aspect ratio and anchors the opposite corner. Dragging the image interior still moves it. Numeric Position image controls remain available for independent width/height changes. No secondary toolbar is added.

A resize preview is transient. The final edit uses the existing validated `updateImagePlacement` command, commits one Undo step, and retains the managed original, alpha, attribution, reflection and quarter-turn rotation. Save/reopen and every compositor-based export read that same placement.

Sizing is constrained to the canvas. Crossing the opposite corner clamps to a positive minimum instead of inverting or deleting the image. Hidden, locked, stale, replaced or deselected image captures cannot commit; cancellation and scene/layout changes discard the preview.

The focused production image-library suite covers actual changed PNG pixels, Undo/Redo, save/reopen, original bytes and attribution, all four anchors, edge clamps, cancellation and stale/locked edits. Native corner-drag interaction is a separate runtime gate. Arbitrary-angle rotation, crop, multiple images per frame and the full image acceptance scope remain open.
