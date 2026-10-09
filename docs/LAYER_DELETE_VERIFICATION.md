# Confirmed layer deletion

This incremental slice contributes to #158 and #196. In the existing Layers panel, select and expand a layer, choose **Delete selected layer**, and confirm the captured layer name and affected-frame count. Cancel makes no edit. The last layer and every locked layer are protected; playback, an unsaved stroke/text draft or an active save prevents arming the action. A changed project, revision or selected layer invalidates an open confirmation.

The same typed `deleteLayer` command removes the explicit stable layer ID and only its content across all frames, including a raster owned by that layer. It preserves other layers, frames and audio. One complete-document Undo restores it; Redo reapplies it. Cancellation or a later failing command rolls back the entire batch. Original raster bytes and licence provenance remain retained while referenced by history or clipboard. Normal device save/reopen stores the actual removal; no cloud request is involved.

Production checks exercise real multi-frame documents, receipts, unchanged unrelated strokes, missing/last/locked/stale rejection, cancellation and rollback, strict wire validation, actual image pixels/export, original-byte and rights retention, Undo/Redo and cold reopening through production storage. The new native UI journey exercises cancel, confirmation, actual canvas removal, one-step Undo/Redo and save/cold reopen. Local compilation of that journey is not a Simulator pass.

This does not complete layer rename/reorder/duplicate UX, multiple image objects or direct image move/scale/rotate/crop. Existing single-toolbar layout and options popup are preserved. Runtime verification and independent review remain required before merge.
