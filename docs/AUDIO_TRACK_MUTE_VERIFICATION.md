# Independent audio track mute — issue #179

Muting a track previously overwrote every clip's individual mute flag. Unmuting
that track could therefore revive a clip the creator had deliberately silenced.
The timeline now stores track mute separately from each clip's gain and mute.

## Production behavior

- The four track buttons change only canonical document track state. Muting an
  empty lane also applies to clips later placed there; moving a clip to another
  lane uses that destination lane's state. No original audio is removed.
- Each action is one reversible document edit. Selection, clip identities, trim,
  timing, source bytes and individual gain/mute remain intact. No-op actions do
  not add history. Invalid, stale, busy or cancelled operations commit nothing.
- The shared production mixer applies silence when either the track or its clip
  is muted. Timeline playback, saved-clip audition and final mixed MP4 use this
  same path. Raw library-source auditions remain independent of project tracks.
- Muted tracks have an accessible state. Clip cards reflect effective silence;
  the selected-clip inspector explicitly identifies a muted track, while its
  clip-mute button continues to control that clip independently.
- The optional `mutedAudioTracks` field defaults to absent for old documents.
  A track-state edit promotes the document to schema 12. Validation permits only
  sorted, unique lane IDs 1–4. Earlier schemas cannot carry the new metadata,
  and older app versions reject the newer document instead of silently dropping
  its mute state. Existing documents and original assets are not rewritten merely
  by decoding them; full-document undo restores the prior schema and state.

## Verification

A negative control against the unmodified production view model reproduced the
lost individual mute flag. That original failure is retained separately from
corrected test evidence.

`Tests/StudioAudioTimeline` exercises the actual production view model and device
storage: mute/unmute, one-step undo/redo, whole-document equality after save and
cold reopen, source-byte preservation, empty lanes and clip moves, validation,
no-op/stale/invalid actions, and early/late cancellation. The PCM fixtures explicitly
unmute their clip instead of relying on the old destructive track toggle.

`Tests/StudioAudioMix` decodes actual stereo CAF output and checks samples from
separate lanes, individual mute preservation after a bus toggle, and a valid
all-muted output retaining both source and clip identities.

`Tests/StudioMixedMovieExport` renders real H.264/AAC MP4s with the track muted and
unmuted. It verifies every decoded audio timestamp, stereo duration, silence and
expected gain, plus the original video frame pixels and timing, and safe cleanup.
The independently muted second clip stays silent in both renditions.

`testAudioTrackMutePreservesClipMuteUndoAndColdReopen` exercises visible native
track/clip buttons, undo/redo, inspector state, local save and cold reopening.
The suite contains 44 journeys, including independent track volume, with the same 180-second per-case and 3900-second
suite limits; no existing journey, assertion, retry or skip policy is relaxed.
Local SDK type-checking and XCTest compilation do not establish simulator runtime
success. Exact-source macOS CI must run the complete app and native journeys.

This slice does not complete #179: track gain, any exposed fades, the complete
control matrix, physical-device listening and independent review remain open.
