# Studio image positioning

This slice of #196 adds **Position image** inside the existing Move tool popup. X, Y, Width and Height edit a local draft in canvas pixels. Half size keeps its center; Fit canvas restores the imported image's aspect-fit geometry. Apply makes one document transaction. Cancel, the existing close button and an unchanged Apply do not change image content or create another Undo step. The existing keyboard dismissal also works with these numeric fields.

The shared, strictly decoded `updateImagePlacement` command requires an explicit frame and existing image identity. It rejects historical raster records without managed placement, wrong identities, nonfinite or outside-canvas geometry, hidden/transparent layers and full/position/alpha locks. Complete-document validation and cancellation happen before the staged editor is committed. UI captures also bind project, revision, frame, layer, image, tool and original geometry. Intervening edits cannot be overwritten by a stale popup.

Placement changes retain the original image, normalized PNG, stable layer/asset identity and attribution. Rendering, thumbnails, PNG/GIF/movie export and device persistence already consume that canonical placement. This slice changes placement metadata rather than resampling or replacing the original. The Studio command context now exposes the managed image's actual identity, layer and placement; historical image records remain distinguishable. This is a typed editing capability, not a claim that general natural-language Spatter requests are complete.

## Verification

The production command suite exercises strict wire decoding, unknown nested field rejection, identity, finite/bounded geometry, layer locks, visibility, cancellation, stale revisions, receipts and one-step Undo/Redo. The production image-library suite uses actual bundled CC0 PNGs through the actual import, renderer, command, storage and cold-reopen paths. It verifies changed output pixels at the requested horizontal coordinates, original bytes and rights retention, no-op behavior, cancellation and late tool changes. Its HTTP trap must remain at zero requests.

The authored native journey uses the real library, Move popup and keyboard. It checks Half size, Cancel with unchanged canvas pixels, numeric X input, Apply with changed canvas pixels, one-step Undo/Redo and cold-reopened pixels. It is not verified merely because its definitions compile. The next exact-source native run must execute it and retain its original screenshots, recording and XCResult. Mandatory checks and independent source review remain merge gates.

## Remaining scope

Only the existing single managed picture per frame is positioned here. Multiple image objects, direct canvas image-selection handles, rotation, flips, crop and image clipboard operations remain open under #196. Images must stay inside the canvas. Numeric width and height can change proportions; Fit canvas restores the original proportions. The drawing selection controls remain for drawn artwork. No secondary toolbar, new Xcode membership, dependency, asset pack, schema migration, live publication or backend request is introduced.


## Preceding native evidence and targeted journey corrections

Source a844032 completed 35 native journeys: 33 passed, two failed, zero skipped. Its linked app and all production stages passed. The earlier Audio canvas observer failure is resolved in this run. Original logs, complete XCResult, diagnostics, screenshots and recordings are retained without relabelling the result.

Layer Rename visibly opens its native alert, but the actual iOS 18.5 accessibility snapshot exposes its focused field as placeholder `Layer name`, with value `Layer 1`, and omits the SwiftUI identifier. The corrected journey checks the exact alert title, exactly one field, its actual placeholder and hittability before typing; all Cancel, empty-name, Save, pixel, Undo/Redo and cold-reopen assertions remain.

The Text journey lost 60 seconds waiting for the system's app-animation notification before its first keystrokes. It continued editing and saving, then hit the unchanged three-minute limit during relaunch. The cold-edit fixture now keeps the already selected text for its immediate edit, removing redundant deselect/reselect and toolbar round trips. Before/after and cold-reopen screenshots use the same Text-tool selection decoration and fixed text-box geometry. Actual changed glyphs, persisted pixel equality and the reopened editable `SDI!` source remain asserted. Other text fixtures keep their existing behavior. There is no retry, skip, injected document, disabled animation, or increased timeout. Both corrections require the next native run.
