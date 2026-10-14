# Audio transport, scrub and drift (#180)

Status: implementation in source; native verification deferred to macOS CI and device acceptance (#124, #265). Nothing below is a device PASS claim.

## Canonical time conversion

`StudioAudioTransport` (Foundation-only, `Services/StudioAudioTimelineLogic.swift`) is the single seconds/ticks conversion for the transport.

- `seconds(atTick:fps:)` is `tick / fps`.
- `tick(atSeconds:fps:totalTicks:)` floors with a one-millionth-tick tolerance. A floor-only conversion maps some exact frame-start times to the previous tick because of binary floating point: for example tick 123 at 15 FPS gives `8.2 * 15 = 122.99999999999999`. The Linux suite counts these misses across 14 frame rates and 216,000 ticks and checks that the tolerant conversion has none.
- `floorSafeSeconds(_:fps:)` moves a boundary time forward by at most a few ULPs, so `StudioViewModel.displayAudioPlaybackTime` (which still floors) shows the correct frame. Both Studio timelines pass their transport times through it. The proper long-term fix is the view-model patch listed under "Owner/coordinator patches".
- `FrameClock` is a binary search over cumulative exposure holds. For every tick it gives the same result as `StudioDocument.frameIndex(atTick:)`.

## Drift measurement during playback

The animation follows the audio player clock. `StudioAudioDriftMonitor` compares that clock with the monotonic host clock on every 60 Hz transport tick:

- Drift beyond one project frame (1/fps, clamped to 1/120–1/12 s) re-anchors the clock and counts a correction.
- A backwards jump (loop wrap or seek) re-anchors the clock without counting as drift.
- A player that reports playing but does not advance for one second is a stall. `StudioAudioTimelineSession` then stops and shows a notice, so the animation never freezes behind silent output.
- `StudioAudioTimelineSession.driftReport` publishes the samples, the maximum and mean absolute drift, the corrections, the discontinuities and the maximum frame error.

Linux evidence (`Tests/StudioAudioLogic`, groups 7–10) covers these simulations:

- 20 minutes at 60 Hz with 10 ms output quantization: maximum frame error is at most one frame and there are no corrections.
- Looping every 7 s: exactly 8 discontinuities.
- 0.1% clock skew over 10 minutes: 13–15 bounded corrections.
- A player stuck at 5 s: the stall is detected at 6 s.

The macOS group "real playback measures audio-clock drift" runs the same monitor against an actual AVAudioPlayer. That run is deferred.

## Audible scrub

Dragging or tapping the audio-workspace ruler, or using the VoiceOver adjust action, seeks the playhead. It then plays a 150 ms grain through `StudioAudioScrubAudition`:

- Each grain is a real offline mix of the project's clips over the window starting at the playhead. It uses the same `StudioAudioMixService` and windowing code as preview playback, then plays once through AVAudioPlayer with the same anti-clipping gain.
- While one grain is being prepared, further requests keep only the newest position (`StudioAudioScrubPlanner`).
- Positions with no clip stay silent; no substitute sound is generated.
- Every mix output is owned and cleaned up. If cleanup fails, the output is kept and the cleanup is retried, never guessed.
- Pressing Play waits for any in-flight grain to release the shared mixer before the timeline mix starts.
- "Audible scrubbing" is a per-device toggle in the Play button's context menu (`studio.audio.audible-scrub`). It defaults to on.

Limits: grains decode whole assets through the existing mixer, so a scrub over large assets lags by the mix time. A mix that is already running (preview or export) keeps the mixer, and scrubbing stays silent. Route changes and interruptions stop a grain through `StudioAudioSessionController`.

## Verification state

| Check | State |
| --- | --- |
| `Tests/StudioAudioLogic` groups 7–10 (Linux CI step) | deferred: no swiftc on the authoring host |
| `Tests/StudioAudioTimeline` drift and scrub groups (macOS) | deferred |
| Native app build and UI journeys | deferred |
| Device drift over long projects and exported MP4 sync | not run; tracked by #124 and #265 |

## Owner/coordinator patches (outside this change's file ownership)

- `ViewModels/StudioViewModel.swift`, `displayAudioPlaybackTime`: replace `document.frameIndex(atTick: Int(min(Double(document.totalTimelineTicks), max(0, seconds * Double(fps))).rounded(.down)))` with `document.frameIndex(atTick: StudioAudioTransport.tick(atSeconds: seconds, fps: fps, totalTicks: document.totalTimelineTicks))`. Any standalone suite that compiles the view model must then also compile `StudioAudioTimelineLogic.swift`.
