# Studio audio fades

Issue #179 adds linear fade-in and fade-out to the existing selected-clip inspector. No second toolbar is introduced. Each duration is independent; both must be finite, nonnegative and fit within the clip without overlapping. Zero in both fields clears the envelope. Cancel discards the draft. Apply is one reversible edit and rejects changed projects, revisions or selections.

The canonical optional envelope uses source sample positions at 48 kHz. Trim, Split, Duplicate and moving between tracks preserve its phase; they do not restart a fade. Source revealed outside the envelope retains that edge's gain: zero at a faded edge, otherwise unity. Applying again establishes a new envelope for the selected range. Clip and track gain multiply the envelope; either mute remains silence. The original audio bytes remain unchanged.

Playback and MP4 export use the same production PCM mixer. There is no visual-only fade or alternate export calculation. The persisted document is promoted to version 14 on the first effective fade edit. Documents without an envelope retain their historical decoding and version. Versions that predate fades reject a document containing an envelope.

Verification includes decoded stereo PCM, exact split/trim/duplicate sample comparisons, muted output, malformed metadata, production commands with cancellation and stale-context rejection, full-document Undo/Redo, actual device-storage save/cold reopen, and decoded AAC from an actual H.264/MP4 export. A native UI journey exercises invalid input, Cancel, Apply, Undo/Redo and cold reopen; passing definition compilation alone is not runtime verification.

This slice supplies linear fades. Arbitrary automation curves, crossfades between selected clips and Spatter's natural-language fade commands remain separate work. Physical-device listening and the exact-source simulator result must be recorded separately from production sample checks.
