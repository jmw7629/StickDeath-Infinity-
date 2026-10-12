# Studio audio session, clipping policy and mixed-MP4 audio checks

Covers issues #178, #179, #180 and #181. Everything below describes code in this branch; the "Verification" section says what has and has not been run.

## System audio session (#180)

`StudioAudioSessionController` (in `StickDeathInfinity/Services/StudioAudioPreviewSession.swift`) is the one owner of `AVAudioSession` policy for Studio playback.

- Before `StudioAudioTimelineSession` or `StudioAudioPreviewSession` creates an `AVAudioPlayer`, it calls `begin(owner:onEvent:)`, which sets category `.playback`, mode `.default`, and activates the session. Activation failure is reported as a notice; no player is created.
- `AVAudioSession.interruptionNotification` (type `.began`) and `routeChangeNotification` (reason `.oldDeviceUnavailable`) stop every registered owner. The timeline shows "Audio playback was interrupted by another app or a call and has stopped." or "The audio output device was disconnected, so playback stopped." Playback is never auto-resumed.
- When the last owner calls `end(owner:)`, observers are removed and the session is deactivated with `.notifyOthersOnDeactivation`.
- On platforms without `AVAudioSession` (macOS test hosts, Linux parsing) the controller keeps the owner bookkeeping and is otherwise a no-op, so `dispatch(_:)` is testable everywhere.

The "Preview is silent" hint in the project clip list now uses `StudioAudioPreviewSilence.reason(for:in:)`, which mirrors the mixer: clip/track mute, then SoundCraft solo ("another track is soloed"), then zero clip/track volume.

## Clipping policy and opt-in normalization (#179)

`StudioAudioMixService.Options.normalizeToMinusOneDBFS` (default **off**):

- Off: the summed mix is written exactly; `peakAbsoluteSample` and `overRangeSampleCount` report any overload and the mixed-MP4 mux refuses an over-range mix with a message that names the Normalize option.
- On: a first pass measures the real summed peak; one gain `0.8912509 / peak` (−1 dBFS) scales every sample in the written pass. Quiet mixes are raised, loud mixes are lowered, silence keeps gain 1. The receipt records `appliedGain`, `measuredPeakBeforeGain` and `normalizedToMinusOneDBFS`; the mux receipt carries `audioAppliedGain`/`audioNormalizedToMinusOneDBFS`, and the MP4 panel shows the gain. Clip and track volumes in the project are never changed.

The MP4 export controls expose this as the "Normalize audio to −1 dBFS" toggle (`studio.export.movie.normalize`), shown only when the project has audio.

## Mixed-MP4 audio verification (#181)

- Per-clip loudness: while muxing, `StudioAudioVideoMuxService.ClipWindowRMS` accumulates the mixer PCM energy over each clip's `[startTime, startTime+duration)` window; after writing, the decoded AAC is accumulated over the same windows. Each window must satisfy `|RMS_source − RMS_decoded| ≤ 0.01 + 0.15 × max(RMS_source, RMS_decoded)`, and a source window louder than RMS 0.01 must not decode below RMS 0.001. A failure is `MuxError.audioLoudness(clipIndex, sourceRMS, decodedRMS)`; the receipt records `audioClipWindowsChecked` and `maximumAudioRMSDeviation`.
- Audio ending after the animation: `StudioMuxCapture.capture` now calls `holdingLastFrameForAudio`. The captured copy of the document extends the last frame's exposure by the whole frame ticks needed to reach the latest clip end, plus the fewest extra ticks that keep the movie duration a whole number of 48 kHz samples (for example 7 fps rounds up to a multiple of 7 ticks). The editable project is untouched; `Snapshot.heldLastFrameTicks`, the proof, the mux receipt and the MP4 manifest record `heldLastFrameTicks`, and the panel notice says how many ticks were held. A clip that would need more than 600 ticks, or push the last frame past the 600-tick exposure limit, still fails with `unresolvedAudio` and an explicit message.

## Delete confirmation (#178)

The selected-clip "Delete" button (`studio.audio.delete`, unchanged) now stops playback and opens a `confirmationDialog` naming the clip and track. "Delete clip" (`studio.audio.delete-clip.confirm`, destructive) performs `deleteAudioClip` only if the clip still exists; "Cancel" (`studio.audio.delete-clip.cancel`) changes nothing. The message states that the saved sound stays in the library and Undo restores the placement.

## Verification

- Linux (this host): `swiftc -parse` passes for every edited Swift file; `StudioAudioPreviewSilence.reason(...)` and the hold-tick arithmetic were extracted verbatim and executed with the Linux toolchain as part of a 5-group harness that passes.
- Deferred (needs macOS/Xcode): `Tests/StudioAudioMix` (normalization pass), `Tests/StudioAudioVideoMux` (held last frame, normalized mix accepted, RMS deviation), `Tests/StudioAudioTimeline` (hint rules, session controller), `Tests/StudioMixedMovieExport`, the simulator/device AVAudioSession behaviour (ring switch, interruption, route loss) and the native UI journeys. None of these has been run for this commit; the RMS tolerance and the padding-pixel tolerance in the movie tests are first estimates that the deferred runs must confirm or correct.
