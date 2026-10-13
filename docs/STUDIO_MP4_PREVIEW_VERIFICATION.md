# Native MP4 preview

The existing MP4 export panel decodes the actual validated local output with AVPlayer. It exposes play/pause/replay, real playback time and seeking without changing the primary toolbar or adding a secondary dock. Video and mixed-audio files use the same preview. Playback never starts automatically.

A single export-consumer lease retains the files while the decoder uses them. Sharing, new export, panel/account/project changes and backgrounding stop the decoder before releasing its files. Generation and seek identities reject stale callbacks. Decoder failures release the preview while preserving a reusable completed output. Initial readiness has a 15-second bound and a retry message; that timeout-expiry branch has not been fault-injected.

## Scrubbing correction

The thumb uses immediate, clamped interaction state while a finger is dragging. The player pauses, then performs one exact seek when the drag ends. Accessibility or keyboard updates without editing callbacks still seek directly. Periodic paused-clock callbacks cannot reset an active drag. The time readout continues to report the actual decoder position, separately from the requested thumb position. Stale seek completions cannot replace a newer request, and stopping the preview clears the pending interaction before it can restart playback.

Sixteen production groups exercise real AVPlayer picture pixels, H.264/AAC decoding with non-silent PCM, playback clock/pause/seek/end/replay, consumer exclusivity, account/background/cleanup, share handoff, reentrancy and release. The two new groups export an actual four-frame movie, retain thumb feedback during dragging, verify the released seek against both the decoder clock and the decoded later blank frame, exercise rapid accessibility updates, and stop an interrupted scrub without deleting the reusable output. Two existing groups inject the framework failure notification into a genuine player; these are controlled failure fixtures, not spontaneous device failures.

## Native evidence and remaining verification

Source `69f3bed83863fc305081f07a06cda6a55a2475d4`, workflow34725564609, passed the actual app build and every production stage. On iPhone16Pro/iOS18.5, 17 of18 journeys passed, one failed and none were skipped. Both eyedropper journeys, styled brush/shape/fill/Undo/save/reopen/PNG, full bundled-audio/mix/reopen, sole-toolbar docking and separate animation-only MP4/native-share cancellation passed.

The mixed-MP4 journey displayed the actual decoded first frame, then failed its seek-time assertion: the slider and readout stayed at0.00/0.33 seconds after a75% adjustment. The full log, result bundle, original capture and recording are preserved with verified archive SHA/CRC. Later mixed-file seek-picture, playback-completion and native-sharing assertions were not reached. This correction retains all18 journeys, the original timing/picture assertions and execution limits, adding a failure-time screenshot and hierarchy.

The16 production-player groups passed locally. The corrected actual native UI interaction still requires a new simulator run. Local SDK checks do not substitute for that result. Physical speaker output, successful destination save/reopen, iPad/device playback, signing and TestFlight remain unverified. GIF and general video import remain separate unfinished features. No public uploads run during testing.
