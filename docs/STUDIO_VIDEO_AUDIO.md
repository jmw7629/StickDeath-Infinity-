# Movie soundtrack import

In Audio → Import from Files, enable **Extract audio from a video**. Set source start/end and speed, choose a destination track, then select an MP4 or MOV. The prepared soundtrack is added at the selected animation frame. Source start/end are movie seconds; resulting clip duration is `(end - start) / speed`. Varispeed changes pitch as well as duration. Move, trim, mute, volume, waveform preview and export use the existing audio clip model.

Import uses a private security-scoped copy, reads one unprotected video track and one mono/stereo audio track, and retains the original movie in Files. The source is limited to 16 MB and one hour. Decoded output is stereo 44.1 kHz PCM WAV, up to 16 MB (about 95 seconds), inside the existing project audio budget. Original timeline gaps remain silence; absent audio is an explicit error. No microphone, cloud request, publication or external API is involved.

The importer owns temporary files, handles cancellation and timeout, and passes only immutable measured audio to the existing project/revision-checked attachment transaction. A project or frame change prevents attachment. The clip and owned bytes persist in the same project snapshot, with one-step Undo/Redo. Saving does not authorize sharing.

The video-frame import remains a separate reference-image operation. This does not implement an editable movie track, automatic frame sequence extraction, or automatic attachment of every movie soundtrack. Final mixed MP4 and native interaction acceptance remain part of issue #201; service tests and Xcode compile are separate gates.

## Streamed conversion without lost tails (wave 4, #201)

The soundtrack decoder now uses the conversion from the PR #115 workstream (commits 15dc086 and 570cb8d), which had been verified natively there:

- The reader decodes native-rate PCM.
- A bounded `AVAudioConverter` applies varispeed, and an explicit end-of-stream drains its final samples.
- Every source-backed edit segment must be covered by decoded samples. Genuine edit-list gaps remain silence.
- The output must reach exactly `round((end - start) / speed × 44 100)` frames.

The previous reader preallocated the PCM buffer and accepted a missing tail as zero-filled audio. Movies with tracks at several sample rates are rejected.

Tests (`Tests/StudioVideoAudio`) add these groups:

- tone-tail checks at 0.25×, 0.5×, 1×, 1.3×, 2× and 4×
- a fractional trim
- an internal edit-list gap
- 8, 48 and 96 kHz sources

The independent-decode comparison keeps the bounded 4-LSB equivalence from main. Handoff, save and cold-reopen equality stay exact. On this branch, native verification is deferred to macOS CI.

Timing uses one mapping for reference frames and soundtracks. `Mapping.projectTime(sourceSeconds:)` is the inverse of `sourceTime(projectSeconds:)`, and `projectDuration(sourceDuration:)` gives the clip length `(end - start) / speed`. Persisting that mapping with the clip is a model change (see `STUDIO_VIDEO_SEQUENCES.md`).
