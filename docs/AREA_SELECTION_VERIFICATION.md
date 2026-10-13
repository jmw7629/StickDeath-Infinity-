# Rectangle and freehand area selection

Issue #152; Studio selection remains an incomplete product area.

## Current lasso handoff (2026-10-09)

Completing a nonempty whole-artwork lasso switches automatically to Move, retains the selected document identities, shows the transform box and closes the options popup. Drag the selection to move it; use its handles to resize or rotate. Hand pans the canvas and is not the selection handoff. Drawing selections allow independent-axis resizing; image-backed selections retain proportions. Only visible, editable, unlocked artwork joins a movable group. Empty selections explain why no box appeared.

The explicit **Image pixels → Move** target selects part of an imported image. Its outline is converted into the existing canonical source-pixel mask with crop, rotation, reflection and alpha respected. A successful selection lifts a fragment into its own active layer, preserves the remainder and original source bytes, and selects the fragment with the existing Move handles. This is one reversible document edit. Whole-artwork selection remains transient and supports New/Add/Subtract; automatic pixel lifting is New only. Pixel lifting requires a visible, opaque, normal-blend, unlocked image-only layer without glow and at most four million source pixels. Unavailable operations report the limitation rather than flattening or deleting the original.

Evidence: 73 production image integration cases passed at `996e989`, including actual pixel masks, rendering, Move capture, Undo/Redo, atomic save and cold reopen. The full native app and UI-test targets compiled at `b63f310` (public equivalent `c1c427e`). One actual native simulator journey passed its automatic Move, partial deletion, Undo and cold-reopen assertions in 158.349 seconds. Xcode subsequently exhausted the SSD while packaging simulator diagnostics; its wrapper failed and the result bundle/captures are incomplete. Preserve that distinction: assertions passed, complete result artifact unavailable. The preceding zero-test invocation was not a pass, and a reused-expectation helper failure was corrected before this run. Independent review and release acceptance remain open.

The initial-slice notes below describe earlier scope, not the current implementation.

The initial single Lasso popup provided Rectangle and Freehand, New/Add/Subtract, real smoothing in document pixels, and Copy/Delete/Deselect. An outline encloses whole drawing bounds; it does not cut pixels. Selection does not change the document, save state, revision or Undo stack. Copy, Move and Delete use the same production operations as the existing Move tool.

The visible outline and selection share one bounded region. Brush bounds come from canonical rendering geometry, including reflection and translation. Hidden, transparent and fully locked layers are excluded; position locks still prevent movement. Input, layout, project, frame, revision, selection, playback and tool changes invalidate a gesture. Cancellation applies no partial selection. Rectangle uses two stored points; freehand compresses collinear samples and has a 512-point limit. Complex/invalid input reports failure without deleting or replacing artwork.

## Historical initial-slice verification

- 12 production area-selection groups passed, using the actual StudioViewModel, document editor, renderer, device persistence and PNG exporter. Coverage includes New/Add/Subtract, empty selection, concave enclosure, real smoothing, layer locks, group movement, clipboard, deletion, Undo/Redo, save/list/cold reopen, decoded export pixels, cancellation, stale context, all ten brush geometry families and bounded invalid input.
- 11 existing Move groups and 13 existing clipboard groups passed after the canonical-bounds change.
- iOS SDK typecheck passed for the three changed production view/view-model bodies in the complete target source context.
- All 26 native UI test definitions compile. The new Rectangle/Delete/Undo/Redo/cold-reopen journey has **not yet run** in Simulator. Compilation is not native runtime verification.
- The macOS production area-selection suite is wired into the existing native CI workflow. No new app source file or Xcode membership was required.

The first local test probe sampled a rectangle corner and failed; it was corrected to the known filled interior. The first iOS typecheck found an actor-isolated view-model property used from a nested drawing helper; capturing immutable document dimensions fixes that compiler error. Original failure evidence is retained privately.

## Historical initial-slice remaining gates

Native runtime execution and original captures for this change, independent review, eligible merge and preview update remain required. Imported-image placement and text element selection are unfinished. Polygon, Magnetic, Smart and feathered pixel selection are unavailable and are labeled accordingly. Physical-device pressure/input, iPad and additional transformed-canvas gesture journeys remain unverified. Do not close the full selection issue based only on this slice.
