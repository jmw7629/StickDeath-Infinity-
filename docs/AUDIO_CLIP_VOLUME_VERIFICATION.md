# Selected clip volume — issue #179

The existing selected-clip slider now captures the project, revision and complete
selected clip at gesture start. A finished gesture changes one canonical clip
level with one Undo entry; track level, both mute states, placement, trim, asset
identity and original audio bytes stay intact. The existing immediate command
also uses this validated path.

Source inspection found that the previous slider retained its local dragged
value if an edit threw without changing document revision or selection. This
was a code-path finding, not a reproduced native UI failure. The control now
restores the current document value after success, rejection or missing capture.
Its draft is scoped to project/revision/clip identity and discarded when the
panel disappears or the app becomes inactive. The layout, toolbar, mixer,
document schema and asset library are unchanged.

The command rejects nonfinite/out-of-range levels, foreign projects, changed
revisions or clips, missing selection, playback/save/drawing state and early or
late cancellation. A second context check after storage preflight prevents an
intervening selection or document edit from being overwritten. An unchanged
level adds no history and preserves Redo.

## Verification

- All 47 production audio timeline groups pass, including four new groups for
  actual canonical edits, one-step Undo/Redo, full save/cold reopen, immutable
  source bytes, invalid/stale/foreign/busy/cancelled operations, late changes and
  no-op Redo preservation.
- All 14 production audio integration groups pass through the existing import,
  storage, preview, selection, capacity, cancellation and no-network paths.
- The changed view-model and SwiftUI panel bodies pass the iOS SDK check using
  120 production source inputs. All 44 native UI test definitions compile.
- The existing track-volume journey now also changes the clip slider from 80%
  to roughly 40%, checks its displayed level and independent mute state, and
  verifies that clip level survives track gain/history edits and cold reopening.
  The other 43 journey bodies and executable runner/time limits are unchanged.

These local checks do not establish iOS runtime or independent approval. The
enhanced native journey, interrupted-gesture interaction, actual device
listening and independent exact-source review remain pending. Fades and the full
audio acceptance contract remain open under #179. Do not infer a green app from
test-definition compilation or claim an audible listening check from PCM tests.
