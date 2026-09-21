# Rectangle and freehand area selection

Issue #152; Studio selection remains an incomplete product area.

The existing single Lasso popup now provides Rectangle and Freehand, New/Add/Subtract, real smoothing in document pixels, and Copy/Delete/Deselect. An outline encloses whole drawing bounds; it does not cut pixels. Selection does not change the document, save state, revision or Undo stack. Copy, Move and Delete use the same production operations as the existing Move tool.

The visible outline and selection share one bounded region. Brush bounds come from canonical rendering geometry, including reflection and translation. Hidden, transparent and fully locked layers are excluded; position locks still prevent movement. Input, layout, project, frame, revision, selection, playback and tool changes invalidate a gesture. Cancellation applies no partial selection. Rectangle uses two stored points; freehand compresses collinear samples and has a 512-point limit. Complex/invalid input reports failure without deleting or replacing artwork.

## Verification before the next native CI run

- 12 production area-selection groups passed, using the actual StudioViewModel, document editor, renderer, device persistence and PNG exporter. Coverage includes New/Add/Subtract, empty selection, concave enclosure, real smoothing, layer locks, group movement, clipboard, deletion, Undo/Redo, save/list/cold reopen, decoded export pixels, cancellation, stale context, all ten brush geometry families and bounded invalid input.
- 11 existing Move groups and 13 existing clipboard groups passed after the canonical-bounds change.
- iOS SDK typecheck passed for the three changed production view/view-model bodies in the complete target source context.
- All 26 native UI test definitions compile. The new Rectangle/Delete/Undo/Redo/cold-reopen journey has **not yet run** in Simulator. Compilation is not native runtime verification.
- The macOS production area-selection suite is wired into the existing native CI workflow. No new app source file or Xcode membership was required.

The first local test probe sampled a rectangle corner and failed; it was corrected to the known filled interior. The first iOS typecheck found an actor-isolated view-model property used from a nested drawing helper; capturing immutable document dimensions fixes that compiler error. Original failure evidence is retained privately.

## Remaining gates

Native runtime execution and original captures for this change, independent review, eligible merge and preview update remain required. Imported-image placement and text element selection are unfinished. Polygon, Magnetic, Smart and feathered pixel selection are unavailable and are labeled accordingly. Physical-device pressure/input, iPad and additional transformed-canvas gesture journeys remain unverified. Do not close the full selection issue based only on this slice.
