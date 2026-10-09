# Managed image movement on the canvas

Issue #196. The existing Move popup offers **Move image on canvas** and
**Move drawings**. Selecting the image shows a red outline; dragging inside
it previews placement, then commits through `updateImagePlacement` at release.
Position image still provides precise coordinates and size. There is one
toolbar and one dismissible options popup.

The image remains inside the document bounds. A full-canvas image must be
resized before it can move. Taps and fully clamped moves make no Undo entry.
An actual move makes one entry; Undo/Redo, export, and device persistence use
the same placement. Source bytes, alpha, asset identity, and attribution remain
intact. Drawings, layers, frames and audio are not moved with the image.

The gesture captures project/revision/frame/image identity, original placement,
image selection identity, viewport/zoom/pan and foreground state. Layer locks,
visibility, tool/frame changes, reselecting the target, interrupted touch,
cancellation, or a changed document discard the preview. The preview never
writes the document or saves an intermediate position. Returning to a previous
frame cannot revive a cancelled selection. Pasting drawings restores drawing
targeting.

Production verification uses the real view model, managed PNG, renderer,
history, command transaction, and device storage. Coverage includes real pixel
movement and bounds, one Undo/Redo, source-independent cold reopen, no-op taps,
invalid input, every observed cancellation checkpoint, target reselection,
playback, frame/tool changes, and hidden/locked layers. Existing drawing and
clipboard suites are also required.

The native journey imports an actual licensed library image, halves its size,
selects image movement in the popup, physically drags it, compares real canvas
pixels, checks Undo/Redo, and cold-reopens the saved project. Definition
compilation is not runtime verification. Record the exact CI source/result
separately; no simulator pass is claimed by this document.

Remaining scope: image resize handles, rotation, flips, crop, image clipboard,
and multiple managed images per frame. The current image model still permits
one managed raster per frame. Image movement is an explicit target, avoiding
ambiguous selection through overlapping drawing content.

## Native evidence corrections included with this slice

Published source `7272b218501154fb8a8cc25575cc0335ebfbc016`, run
`35491555925`, built the linked app and passed all production stages. Actual
native journeys finished **34 passed, 2 failed, 0 skipped**. Layer rename and
editable-text cold reopen passed; the remaining failures were image coordinate
keyboard focus and the text-cancel fixture's canvas stability observation.
Original logs, result bundle, attachments and recordings are preserved.

Each image coordinate field now has its own optional enum focus identity, owned
by the popup. One persistent, measured scroll container replaces alternate
interactive copies, so keyboard and viewport changes retain focused input.
Short menus still fit their content; long menus scroll within the same popup.

The native canvas wait now reuses the existing single-query geometry observer:
the same eight-second deadline and one-second stable interval, followed by
existence, hittability and app-bounds checks. The original diagnostics showed
2.83 seconds for a frame query and 3.18 seconds for a second hit-test query while
the recording showed the canvas still present. All pixel, Undo/Redo, editing,
and cold-reopen assertions remain. No journey retry, skip, disabled animation,
or larger per-case/suite/job timeout was introduced. These corrections still
require the next exact-source native run; local compilation is not proof of
their runtime result.
