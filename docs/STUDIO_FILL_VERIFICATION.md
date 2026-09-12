# Native bucket fill

Bucket fill captures the actual artwork at the selected frame, computes coverage, and commits one editable element to the active layer. It uses the same document, renderer, persistence, history and export paths as other Studio artwork. Settings remain in the existing dismissible tool-options popup. The primary floating toolbar is unchanged; there is no secondary right toolbar.

## Behavior

- Contiguous fills the connected region containing the tap. All Similar selects matching pixels throughout the canvas.
- Tolerance compares straight RGBA channels against the original tapped pixel, from 0 through 128. It does not progressively follow a changing color across an image.
- Sample All Layers captures the visible composite; otherwise the active layer is sampled with transparency preserved.
- Expand/Shrink changes the region by up to five pixels. Gap Close seals gaps up to the selected radius for Contiguous mode and is disabled for All Similar.
- Antialias applies actual coverage values at the region boundary. Color and opacity affect rendered, saved and exported pixels.
- A hidden or fully locked layer is not a fill target. Alpha-lock is not implemented by this slice and is rejected explicitly.
- A touch retains its original frame, layer, settings and viewport. Changing that context cancels the touch. A running fill can be cancelled and cannot commit into a changed document.

## Persistence and resource bounds

Schema 6 adds a versioned sparse coverage mask to the canonical element. Masks retain stable frame/layer ownership and are duplicated with new element IDs. One committed fill is one undo step. Actual storage preflight precedes committing coverage, and mask memory contributes to the existing history budget. Original imported raster files are preserved.

Limits are 4,194,304 pixels, 65,536 spans per fill, and 262,144 spans per document. Invalid, overlapping or noncanonical span data is rejected. A fill exceeding its limits reports failure without adding an element. Historical documents continue to decode; old unsupported fill elements without a coverage mask remain explicitly unsupported in export.

PNG and MP4 use the same coverage renderer as the canvas. This change does not implement GIF, video import, rotoscope, or natural-language Spatter fill requests.

## Verification scope

Local Apple-framework checks passed for 14 production groups covering enclosed regions, tolerance, edge coverage, actual sampling of filled artwork, layer/frame copies, undo/redo, save/cold reopen, PNG boundaries, decoded H.264 pixels/timing, cancellation and changed-context rejection. Seventeen existing artwork-sampling groups also passed. The byte-identical region algorithm has 16 passing groups.

The final candidate's 12 changed native bodies typechecked with all 119 application declarations. All 18 proposed UI journey definitions compiled against the iOS SDK. The new native journey creates an enclosure, fills it blue, verifies actual pixels, undoes/redoes, saves/reopens, and checks a real PNG.

These local checks do not establish execution of the new iOS journey. The next exact source revision still needs the complete macOS CI native app build and all 18 native journeys. Final independent review, physical-device behavior and release signing remain separate gates.
