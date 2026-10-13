# Selected audio: precise trim values

Part of #178 and the Studio audio contract in #116. The existing audio inspector
adds **Trim values**, with source-start and duration fields, Apply trim and Cancel.
It retains the same four-track workspace and the single Studio toolbar.

Typing and cancelling are local drafts. Apply uses the canonical selected clip,
captured project/revision/source identity and the existing validated trim edit.
Both fields publish as one Undo transaction; no-op values add no history. Wrong
project, stale revision, selection changes, playback, cancellation, invalid
numbers and out-of-source bounds cannot change the document. Source bytes,
placement, track and gain remain unchanged. Decimal-comma keyboard input is
accepted in decimal-comma locales; nonfinite or malformed values are rejected.

Production checks exercise real imported stereo audio, actual mix decoding,
production save/cold reopen, Undo/Redo, cancellation and history. The native
journey edits the real fields, rejects an invalid trim, cancels, applies a valid
trim, performs Undo/Redo and cold-reopens the saved project.

Record exact check outcomes alongside the candidate. UI definition compilation
is not native runtime proof. This private slice remains unverified on iOS until
the actual simulator journey passes; independent release review is also required.
