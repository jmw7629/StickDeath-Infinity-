# Studio mixed MP4 verification

The existing native Export panel can now render canonical Studio audio with the animation as H.264 video and stereo AAC. It captures the complete document, original audio bytes and raster sources once. Later editor changes do not change a running export. The existing PNG path and animation-only movie path retain their behavior.

## Implemented behavior

- Real visual rendering, float audio mixing and H.264/AAC encoding run sequentially from one immutable capture. Source trim, timeline placement, clip volume and mute affect decoded audio.
- The panel reports readiness only after checking the actual final file and removing its owned intermediate video/CAF files. The share request retains both MP4 and manifest through the actual native consumer lifetime.
- Cancel, close, account changes and leaving Studio cancel work. Unknown or replaced files are preserved. A retained recovery handle supports a safe retry and blocks another export during cleanup.
- Missing sources, audio beyond the animation, retained unresolved legacy audio, transparency, over-range mixes and size/timing limits return errors. No audio is silently discarded or normalized in export.
- Current mixed-output bounds include 240 frames, 128 clips, 16 audio sources, an even canvas, bounded pixels/input bytes and a duration representable in whole 48 kHz samples. Export uses the original frame rate and dimensions. No device memory benchmark or real-time deadline guarantee is claimed.

## Verification evidence

Production sources are compiled and executed with Apple rendering/media frameworks on macOS. Only the test image container adapts UIImage to NSImage. These checks do not prove a simulator, physical-device or signed release build.

- 24 mux groups pass: actual H.264/AAC streams, decoded pixels, rational timestamps, decoded stereo samples, different origins, cancellation, limits and file-identity preservation. Three reviewed mux/visual foundation files remain byte-for-byte unchanged. The ownership file differs only by removing one trailing blank line required by the repository whitespace gate; its original review input is preserved.
- 8 orchestration groups pass: actual source-offset/gain audio, muted silence, all export phases, task cancellation, intermediate cleanup and foreign-file recovery. Measured trim sample RMSE is below 0.000365; measured muted-region peak is zero for the generated test signal.
- 18 session groups pass: actual production VM save/reopen and unchanged source bytes, decoded mixed export from the captured revision, later mute independence, native-consumer file lifetime, account cancellation, byte limits, asynchronous recovery and reentrancy prevention. Existing animation-only cases remain.
- 46 existing movie-export regression groups pass against the current source and whole canonical model.
- The actual 114 application declarations and 9 changed production bodies pass arm64 iOS 17 SDK typechecking. The complete 14-journey native UI test source also typechecks. Four new Swift files have explicit membership in the app target.
- 8 existing movie panel/consumer-lifetime regression groups pass on unchanged final inputs. This exact commit’s linked build/native UI journeys must still run before calling this integration verified.

The new native journey uses the real bundled Wood Cracking 02 source, changes its volume, saves it with four frames, exports via the actual panel, checks the H.264/AAC receipt, opens the native share sheet and cancels without deleting the rendered file. It is proposed coverage until a matching simulator run passes.

## Review and release gate

Independent approval of the unchanged foundation is retained. The newly authored orchestration/session/UI/workflow integration has no independent approval. The owner currently requires a single agent; self-review does not satisfy the independent merge gate. A draft PR and SDK checks are not merge approval. No public upload, signing, TestFlight, microphone/device audio route or background export is claimed.

## Reproduction

The native verification workflow compiles and runs the checked-in production test programs before building the actual iOS target and executing all native UI journeys. It retains exact-source logs, screenshots and recording evidence. No test timeout is expanded or failing test skipped by this change. Fixtures use generated signals and approved bundled sounds; tests never publish or send messages.
