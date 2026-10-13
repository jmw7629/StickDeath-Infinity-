# Movie soundtrack import

In Audio → Import from Files, enable **Extract audio from a video**. Set source start/end and speed, choose a destination track, then select an MP4 or MOV. The prepared soundtrack is added at the selected animation frame. Source start/end are movie seconds; resulting clip duration is `(end - start) / speed`. Varispeed changes pitch as well as duration. Move, trim, mute, volume, waveform preview and export use the existing audio clip model.

Import uses a private security-scoped copy, reads one unprotected video track and one mono/stereo audio track, and retains the original movie in Files. The source is limited to 16 MB and one hour. Decoded output is stereo 44.1 kHz PCM WAV, up to 16 MB (about 95 seconds), inside the existing project audio budget. Original timeline gaps remain silence; absent audio is an explicit error. No microphone, cloud request, publication or external API is involved.

The importer owns temporary files, handles cancellation and timeout, and passes only immutable measured audio to the existing project/revision-checked attachment transaction. A project or frame change prevents attachment. The clip and owned bytes persist in the same project snapshot, with one-step Undo/Redo. Saving does not authorize sharing.

The video-frame import remains a separate reference-image operation. This does not implement an editable movie track, automatic frame sequence extraction, or automatic attachment of every movie soundtrack. Final mixed MP4 and native interaction acceptance remain part of issue #201; service tests and Xcode compile are separate gates.
