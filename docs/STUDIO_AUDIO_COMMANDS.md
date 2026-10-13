# Shared audio clip commands

`updateAudioClip` edits the volume, mute state and linear fades of an existing,
project-managed clip. Manual controls and the validated Studio command executor
use `StudioDocumentEditor.updateAudioClip`; they do not keep separate audio models.
Spatter's existing local-edit popup submits these same commands from explicit
instructions. Free-form audio requests, audio generation and automatic publishing
remain unfinished.

An authenticated/authorized host captures the current project and revision before
submitting a bounded `StudioCommandRequest`. Untrusted JSON must enter through
`StudioViewModel.applyStudioCommands(Data)`, which runs the strict wire decoder.
Do not invoke the model executor as a remote authorization boundary. The local
guest editor remains offline and makes no provider request for these operations.

The command payload is:

```json
{
  "updateAudioClip": {
    "clipID": "an-existing-managed-clip-id",
    "settings": {
      "volume": 0.4,
      "isMuted": false,
      "fades": { "fadeIn": 0.25, "fadeOut": 0.25 }
    }
  }
}
```

- Omitted settings preserve their current values. Supply at least one setting.
- Volume is finite and between zero and one; it is independent of lane volume.
- Mute is independent of lane mute. Neither operation discards source audio.
- Both fade durations are required when `fades` is present. Their nonnegative,
  finite sum must fit the clip. Two zero values explicitly clear the envelope.
- Fades use the same 48 kHz source-anchored envelope as the manual inspector.
  Existing trim, split, duplication and movement preserve the source phase.
- Unknown fields, wrong types, missing/foreign IDs, historical metadata without
  a managed source, invalid settings and stale project/revision are rejected.
- Before assignment, the view model checks source-byte availability and source
  timing through the production save preflight, rejects audio edits during
  playback and rechecks revision, clipboard, input state and cancellation.
- A mixed batch produces one full-document Undo/Redo operation. Failure leaves
  the batch unapplied. An unchanged command preserves revision and redo history.
- `changedAudioClipIDs` reports actual resulting differences, including those
  caused by Undo/Redo. An edit receipt is not a completed save or export receipt.

Audio import, transport/export invocation, lane settings, clip creation, trim
and placement are not newly added to this wire command. Shell, admin and public
publication are not granted to content or provider text.

## Explicit local Spatter instructions

Select a clip in Audio, then open Spatter → Local Studio edits. The audio example
menu fills an editable draft; only Apply local edit executes it. Supported complete
instructions are:

- `Set selected audio clip volume to 40%.`
- `Mute selected audio clip.`
- `Unmute selected audio clip.`
- `Fade selected audio clip in over 0.05 seconds and out over 0.10 seconds.`
- `Clear selected audio clip fades.`

Supply a finite percentage from 0 through 100. Each fade may be 0–300 seconds,
and their sum must fit the selected clip. Case and ordinary whitespace are
flexible; extra actions and trailing text are rejected. Instructions are limited
to 1,024 UTF-8 bytes. Unrecognized instructions never fall back to a provider.

The session captures account, project, revision, tool, layer, frame, selection,
audio clip, popup and playback state. It checks that capture after both async
preparation boundaries and before the atomic command. Closing/cancelling the
session, switching accounts or changing the target prevents application. Drafts
remain visible after success or rejection. Receipts distinguish an actual edit
from an unchanged clip; save status comes from the real project store.

## Verification

The existing production command suite checks strict JSON, malformed nested
fields, identities, no-ops, source envelope values, cancellation and whole-batch
rollback. The actual audio timeline suite additionally exercises the view model,
manual/command equivalence, real stereo PCM gain/fades/silence, missing source
and source-overrun rejection, playback/reentrant edits and device save/cold reopen.
These tests run in the existing mandatory workflow stages; no mock editor or
alternate persistence model is substituted. Native simulator verification and
independent review remain separate gates before merge.

Parser and session tests additionally cover malformed/suffixed prompts, selected
target binding, cancellation at both preparation boundaries, stale account and
screen context, every supported instruction, factual no-ops, real mixed PCM,
Undo/Redo and device save/cold reopen. The native UI suite includes choosing the
audio example, applying it, verifying the real inspector, Undo/Redo and reopening
the saved project. A compiled UI definition is not a passed simulator journey.
