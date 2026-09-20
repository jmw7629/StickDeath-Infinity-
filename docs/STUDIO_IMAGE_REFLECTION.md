# Managed image reflections

Horizontal and vertical image flips live in the existing Move tool popup. Each
button names the image explicitly and shows its current orientation to
accessibility. There is no second toolbar. The buttons are unavailable during a
save, playback, pending drawing/text edit, or when the image layer is hidden,
transparent or locked.

`reflectImage` requires an explicit frame, managed image asset identity and
horizontal or vertical axis. Its strict wire decoder rejects unknown fields and
axes. The manual controls call this same command through the captured project
and revision; stale context or cancellation cannot publish a partial edit.

The canonical frame's optional `rasterReflection` stores two independent flags.
Absent metadata means original orientation, preserving historical documents.
An effective flip uses schema 15. Repeating an axis restores that orientation;
when both flags are off the field is nil. Placement, source bytes, provenance,
drawings, layer identity and other frames are unchanged. Frame duplication and
frame clipboard retain orientation. Explicit image/layer deletion clears the
corresponding metadata; full-document Undo restores it.

The shared SwiftUI frame renderer reflects only the image around the center of
its placed rectangle. It isolates that transform from other drawing content.
Canvas, thumbnails, PNG, GIF and MP4 therefore use the same composition path;
this slice's fresh pixel tests verify reopened PNG output. It does not establish
new native GIF/MP4 runtime acceptance by itself.

Verification covers both axes and their combination, off-center placement,
actual PNG pixels and alpha, original bytes/attribution, Undo/Redo, frame copies,
device save/cold reopen, strict decoding, every observed cancellation boundary,
locks, playback, stale context and historical decoding. A native UI journey
imports the licensed Dragon, uses both popup controls, checks changed canvas
pixels, Undo/Redo and cold reopen. UI compilation is not simulator execution.

Multiple managed image objects per frame, crop, rotation, resize handles and an
image-specific clipboard remain separate unfinished work in issue #196.
