# Independent track volume — issue #179

The selected audio clip inspector now includes its numbered track's volume.
This changes the whole lane without rewriting individual clip levels, mute,
trim, timing, selection or original sound bytes. The existing clip slider is
explicitly labeled “Selected clip volume” for accessibility. The timeline and
its four lanes remain in the existing Audio workspace.

## Production behavior

- A slider gesture captures the project, document revision, lane and original
  level. Releasing it applies one reversible document edit. A changed project,
  stale revision, invalid lane, playback, save, unavailable historical source
  or cancelled operation commits nothing. Unchanged values add no history.
- Four optional canonical track levels use a 0–100% range. Missing historical
  metadata means 100% on every lane. The first actual edit promotes the document
  to schema 13; older clients reject that schema rather than dropping the level.
  Validation rejects missing/extra entries, nonfinite values and values outside
  the range. Decoding an older project does not migrate or overwrite it.
- The actual shared mixer multiplies clip volume by track volume. Either the
  clip's mute or the lane's mute still produces silence. Zero volume creates
  real silence without changing those independent mute choices or deleting audio.
- Moving a clip uses the destination lane's level. The production command also
  supports an empty lane, so clips later placed there inherit its level. The
  visible slider appears for the selected clip's lane; it does not add a toolbar.
- Timeline playback, saved-clip preview and mixed MP4 use the same mixer. Raw
  sound-library audition remains independent of project mixing settings.

## Verification contract

Production `StudioAudioTimeline` checks the actual view model and storage for
independent gain/mute/selection, one-step Undo/Redo, save/list/cold reopen and
source-byte equality. It covers invalid/forged/stale/busy captures, no-op history,
early and late cancellation, an intervening edit, empty lanes, destination-lane
gain and historical decoding/schema validation.

Production `StudioAudioMix` decodes real stereo CAF files. It measures overlapping
clips with separate clip and track gains, mute precedence, and zero-gain silence.
Production `StudioMixedMovieExport` decodes actual H.264/AAC files at 0% and 25%
track volume, checking sample timing, stereo levels, silence, video pixels,
unchanged originals and intermediate/output cleanup.

`testAudioTrackVolumePreservesClipSettingsUndoAndColdReopen` changes the real
native slider, checks that clip volume and mute are unchanged, exercises Undo
and Redo, and saves/relaunches/reopens the project. It captures the actual
inspector before and after cold reopening. The preceding 43 native test bodies
are unchanged; the suite now has 44 journeys with the same 180-second per-case,
3900-second suite and 95-minute job limits, and no new retries or skips.

Passing local production and SDK checks is not an iOS runtime result. The exact
source still needs the full native suite, original screenshot inspection and
independent review. Physical-device listening, any exposed fades and the full
mix-control matrix remain open under #179. Broader Spatter audio commands remain
part of its separate completion contract.
