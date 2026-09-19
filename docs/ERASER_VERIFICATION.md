# Native eraser modes and strength — issue #144

The existing sole Eraser popup now controls Hard/Soft, actual diameter in document pixels, and Strength. Both mode buttons have 44-point targets. Reset affects only the selected tool. There is no second toolbar.

New eraser strokes capture an optional versioned descriptor and upgrade the editable document to schema 9. Historical descriptor-free erasers keep their existing clear blend and width multiplier; opening or saving them does not replace their geometry. Existing version-1 tool preferences remain readable when the new optional mode field is absent.

The canonical live/thumbnail/export renderer composites one opaque coverage mask with destination-out and applies strength once per gesture. Hard uses a round outline; Soft blurs that outline by 20% of its diameter, adding a feather outside the core diameter. Zero strength bypasses rendering. Retracing can change antialiased boundary coverage but cannot exceed the gesture's captured strength. Separate gestures can accumulate. The mask affects only its own layer, including managed raster content, and does not modify original imported bytes.

The document validates the descriptor/tool combination, finite diameter and strength, nonempty points, supported version, and limits: 8,192 samples per stroke, 256 styled erasers per frame, 1,024 per document and 65,536 styled eraser samples per document. Invalid commits and typed command batches are transactional. Touch interruption keeps an explicitly discardable incomplete draft. Frame copying and layer duplication preserve eraser metadata with fresh element identities; full-document history restores both schema and pixels.

Hidden, zero-opacity, fully locked, alpha-locked and position-locked layers reject new erasing. **Selection-clipped erasing remains unfinished:** a nonempty selection causes an explicit refusal before preview/commit, rather than erasing outside the selection. Deselect to erase the active free layer. Issue #144 remains open for that remaining behavior and independent review.

`Tests/StudioEraser/main.swift` compiles the real production model, editor, device store, view model, shared SwiftUI renderer and exporters. It checks historical pixels, real alpha/feathering, layer isolation, locks, bounds, invalid schema/geometry, history, copying, preferences migration, cancelled input, actual device save/list/cold reopen, reopened PNG and H.264 files, and typed Spatter commands. It neither contacts a provider nor publishes media.

`testEraserModesStrengthUndoAndColdReopen` drives the real iOS toolbar, size/strength sliders, Hard/Soft buttons, canvas gestures, Undo/Redo, save and app termination/relaunch. It compares actual canvas pixels and preserves native screenshots. Compilation of this test alone is not a Simulator runtime pass.

The workflow runs the production eraser stage before the linked native build and full Simulator suite. Exact-source local and CI outcomes belong in the PR and issue evidence; a browser preview or these source-level descriptions do not certify the native runtime or a release build.
