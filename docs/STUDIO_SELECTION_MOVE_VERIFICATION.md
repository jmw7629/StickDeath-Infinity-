# Studio Move and selection verification

Move now translates explicitly selected drawing elements through the same transactional Studio command entry point used by local typed commands. The white floating toolbar and its single dismissible options popup retain their layout. There is no secondary right toolbar.

The optional schema7 translation preserves original brush samples, seeds, shape metadata and sparse fill coverage. The canonical live/thumbnail/export renderer applies it in document coordinates. Moving outside the canvas clips the view without deleting original artwork. Undo, Redo, frame clipboard, layer duplication and production save/reopen preserve it. Historical elements without translation retain their prior encoding; unsupported readers must reject the newer document format.

Touch input captures project, revision, frame, selection, mode and canvas layout. Preview does not mutate the saved document or history. Changed context, tool, frame, playback, backgrounding or interrupted touch cancels the move; a successful end makes one reversible command. Position/full/alpha locks and hidden layers reject movement. New/Add/Subtract operate the real selection; Subtract never drags the remaining selection. Delete requires explicit elements; Deselect only changes selection.

## Actual production verification

Ten production groups passed on macOS against the actual model, command executor, view model, device storage, SwiftUI renderer and decoded PNG output. They cover historical decoding, preview/commit, stale capture, one-step history, cold reopen, PNG pixels, off-canvas recovery, frame clipboard, layer duplication, fill masks, all ten brush families, locked/hidden/invalid content, command wire equivalence, six cancellation checkpoints, and multi-selection editing. The standalone production model suite passed3/3. Seven changed primary bodies and all127 app declarations passed an iOS SDK type check; all21 native UI test definitions type-checked. These SDK checks do not prove an app build or simulator execution.

The initial strict brush-pixel comparison on Intel macOS found a Rough Pen rasterization difference of two channels at1/255 intensity after integer translation. The other nine brush families were exact. Apple Silicon CI measured the same two-channel limit for Grain, with the other families exact. The final test requires identical production geometry and limits rasterization differences to at most four channels, each at most1/255. It preserves the original failure and measured diagnostic rather than claiming exact pixel parity.

The first Move CI run passed all ten production Move groups, then stopped in the existing fill integration suite before building the app or running native UI tests. The fill test still classified document schema7 as unsupported. That failure reproduced against the actual production sources on the Intel Mac. The correction tests styled-brush round trips through every supported schema and rejects the next unsupported version, retaining all other fill, pixel, persistence and export assertions. No production app source or test time limit changes for this correction.

After the correction, all15 production fill groups passed on the Intel Mac, including mixed brush/shape/fill history and cold reopen, actual PNG and H.264 decoding, coverage/memory limits, in-flight cancellation and stale-context rejection. The complete21-journey native run is still required.

The next run passed Move and fill, then the standalone audio-mix compiler exposed a model dependency on `StudioCommandError`. Document operations now throw document-domain validation errors; the shared model compiles without importing the command decoder. The original failure reproduced against an immutable nine-source copy. The corrected actual audio-mix suite, all ten Move groups and the iOS SDK check pass locally. Native runtime verification remains separate.

## Pending gates and limits

The added native Move drawing/drag/Undo/Redo/cold-reopen journey has not executed yet. Its existing real screenshot assertions verify the old location clears and the moved image survives history and restart. Physical-device, independent review and release gates remain outstanding.

Imported-image placement movement, selection Copy/Flip/ordering/locking, marquee, lasso and wand are unfinished. Remaining selection action buttons report that state; they do not claim success. The current hit test uses element bounds for strokes/shapes and actual coverage for fills. This is element selection, not a pixel-accurate lasso. Translations are finite and bounded to100,000 document units per axis; one command addresses at most1,024 existing elements. Extremely complex projects may be rejected by the shared interactive command budget.
