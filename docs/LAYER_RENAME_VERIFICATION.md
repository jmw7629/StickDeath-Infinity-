# Reversible layer names

This slice contributes to #158. The existing expanded Layers row now opens a native **Rename layer** alert with the current name, Save name and Cancel. It applies a single typed `updateLayer` command to the captured stable layer ID, project and revision. Cancelling changes nothing; a changed selection, project or revision rejects the stale edit. Renaming to the same normalized name adds no history entry.

Names are trimmed in the user flow and must contain 1–120 characters, fit within 4,096 UTF-8 bytes and contain no control characters. The same validator protects typed layer creation and updates. Invalid input does not truncate or silently save a different name. Existing stored names are not migrated or rewritten.

A label change is metadata: the last layer and locked layers may be renamed without removing their locks. Layer IDs, order, frames, drawing pixels, original imported bytes, audio and license attribution remain unchanged. One Undo restores the old name and Redo restores the new name. Device save and cold reopen preserve the exact accepted name.

Production command tests exercise Unicode, invalid names, complete transaction history, stable IDs and no-op behavior. Actual image-library integration tests verify the same ViewModel path, original bytes and rights, real PNG pixels, save/cold reopen, stale revision/selection, last-layer naming and preservation of a full lock. The native UI journey exercises an actual drawn layer, Cancel, invalid empty input, Save name, Undo/Redo, unchanged canvas pixels and cold reopening the named layer.

Local production checks and Xcode typechecking are separate from Simulator execution. The added native journey must run before its behavior can be claimed verified. This slice does not complete layer drag reordering, imported-image duplication, every lock mode or the rest of #158. Independent review and all mandatory native checks remain required before merge.

## Native baseline and observation correction

The preceding c12 source built the app and passed all production stages plus 33 of 34 native journeys. Confirmed layer deletion and the expanded licensed image library both passed their actual Undo/cold-reopen paths. The first audio cancellation test stopped before opening Audio: its eight-second geometry observer repeatedly queried frame, existence and hittability. Original app diagnostics show the same canvas rectangle at 02:31:40.205, 02:31:44.272 and 02:31:45.377, with a valid visible point at 02:31:44.220. The app remained responsive; do not infer a crash from recording/container timing.

The observer now samples geometry once per poll and checks existence and hittability once afterward. It retains the one-second unchanged rectangle, expected bounds, minimum size, eight-second wait and all downstream assertions. A failed geometry wait also retains a screenshot. No test retry, skipped assertion or larger runtime limit is introduced. Original failed logs, completed XCResult, recording and attachments remain preserved. The corrected observer and new rename journey still require the next native run.
