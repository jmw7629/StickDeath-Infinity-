# Managed image quarter turns

The existing Move popup has **Rotate left 90°** and **Rotate right 90°** actions,
each with a 44-point target and the current orientation as its accessibility
value. Tool options remain in the sole dismissible popup. These controls use the
same strict `rotateImage` command as other editor clients, with an explicit
frame, asset identity and direction. Unknown fields/directions are rejected.

Rotation preserves the original image bytes, attribution, alpha, other drawings
and frame/layer identities. The placed bounding box swaps width and height
around its center. If it reaches an edge, it shifts just enough to stay inside
the canvas. An image too large to fit after turning is rejected with guidance to
make it smaller using Position image. It is never silently cropped or shrunk.
Fit uses the rotated image's aspect ratio. Existing horizontal/vertical flips
travel with the image during rotation; subsequent flips refer to canvas axes.

Schema 16 adds optional `rasterQuarterTurns` (1, 2 or 3 clockwise turns). Nil
keeps historical orientation; old documents are not migrated just by reading.
Invalid schemas, orphan metadata and noncanonical rotation values reject.
The canonical document supplies one reversible edit, cancellation, stale
revision protection, and layer lock/visibility rules. Frame duplication and
clipboard preserve orientation. Image/layer deletion removes it, and Undo
restores the complete content. Source assets remain immutable.

The shared SwiftUI renderer rotates only the image in document coordinates,
then maps it into the viewport. Canvas, thumbnails and exports use that same
composition path. This slice compares actual reopened PNG RGBA against a
quarter-turn oracle, including existing flips, independent same-layer drawings,
Undo/Redo, frame copy and production device save/reopen. Command tests exercise
invalid input, all observed cancellation boundaries, history, locks, stale
context, edge placement and historical decoding. A native journey operates both
popup buttons, Undo/Redo and cold reopen. Compiling its definition is not proof
of running it on a simulator or device.

Arbitrary-angle image rotation, crop, resize handles, multiple images per frame
and image-specific clipboard remain unfinished parts of issue #196. This slice
does not establish new native GIF/MP4 acceptance or full Studio completion.
