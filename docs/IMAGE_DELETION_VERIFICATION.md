# Explicit image deletion

Issue #196: Delete image lives in the existing Move popup. It identifies the current frame's managed picture and opens a confirmation. Cancel and popup dismissal make no document change. Confirmation uses the shared strictly decoded deleteImage command with explicit frame and image identity, captured project/revision/context and repeated cancellation checks. Hidden, transparent or locked image layers reject the operation. A stale confirmation cannot overwrite intervening work.

Only the selected frame's picture reference is removed. The frame, its layer, all drawings, audio and other frames sharing original bytes remain. The actual production history owns the original image bytes and rights needed for Undo. Deletion and restoration use the same renderer, exporter and device storage as other Studio edits. Historical full-canvas raster records without managed placement are not silently converted or deleted.

Production verification covers actual transparent PNG pixels, source bytes/rights retention through Undo/Redo, cold reopen after deletion, batch rollback, strict wire fields, locks, stale context and cancellation at every observed command checkpoint. The authored native journey checks actual library Add, confirmation/Cancel, Delete/Undo/Redo, retained layers and saved pixels after app termination/reopen. UI-definition compilation is not native runtime evidence. All mandatory checks and independent exact-source review remain merge gates.

One managed image per frame remains the current limit. Direct image handles, rotation/flips/crop, multiple image objects and image clipboard remain separate work. No schema, source membership, asset pack, dependency, account or backend changes. The native suite's existing time bounds remain unchanged.
