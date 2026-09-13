# Animated GIF export

The existing Export panel offers a real animated GIF produced by Apple's Image I/O from the same Studio frame compositor as PNG and MP4. It captures the current document and original raster data together, before yielding. Later drawing and save operations cannot alter the captured revision, frame IDs or exported pixels.

The format loops continuously, uses a white background, reduces colors, and contains no audio or editor guides. The displayed thumbnail is explicitly the first frame decoded from the completed GIF file. Sharing passes the actual animated file to the native activity controller; opening or cancelling that controller is not a destination-save or publication receipt.

## Limits and ownership

- At most 240 frames, 1–50 FPS, 8,388,608 aggregate frame pixels, 32 MiB of original raster data and 32 MiB of accepted output. The pixel bound permits four full 1080 × 1920 frames. Longer projects can use MP4. Limits are implementation constraints, not entitlements.
- Cumulative centisecond boundaries keep total timing within half a centisecond of the source, including 12/24 FPS. The encoder decodes every resulting frame and verifies count, dimensions, loop and delay properties before returning.
- Frame rendering and verification yield and check cancellation. Image I/O's finalization is a bounded synchronous operation; cancellation cannot interrupt that individual call.
- Output is published as two files in an exclusively created directory. Descriptor, inode, hard-link and digest checks govern access and cleanup. Unknown entries, changed bytes or replaced/moved directories block deletion. A path from a pre-return cleanup failure provides no deletion authority.
- Close, backgrounding, account/project changes, unfinished drawing and stale callbacks are guarded. An offered native sharing request remains owned until the consumer completion callback; disappearance, presentation timeout or a dismissal animation cannot establish that the sharing app stopped reading.
- The GIF share registry admits one outstanding GIF consumer in this process. It does not retain a view, account object or editor. The existing MP4 registry is unchanged.

## Verification scope

Private production checks use actual Apple frameworks, the complete document/view model/device storage and real decoded output. Twelve session groups passed, including a saved/reopened two-frame red project whose later blue edit did not change the GIF, cancellation, synchronous close, account change, stale callbacks, unknown-file preservation and consumer failure. Eight panel/lease groups passed with actual decoded red GIF files. Events supplied by these tests are controlled callback probes, not claims of UIKit execution.

The original encoder/file suite has 20 groups covering actual pixels, timing, source preservation, cancellation, size limits and file integrity. A maximum-capacity benchmark encoded and decoded eight 1024 × 1024 frames, rejected a ninth before rendering, and cleaned its owned output. Export measured 138,145,792 bytes peak resident memory on the development Mac; the full benchmark including additional verification decoding reached 213,852,160 bytes. These measurements do not establish physical iPhone memory use. The original larger cap was reduced after its benchmark exceeded 500 MiB.

At source `5a6963a4babbfc9a2c99176837fa756f1bf91120`, the native GIF journey passed in 52.095 seconds on iPhone 16 Pro / iOS 18.5. It drew a real first frame, added a blank second frame, exported GIF, verified the two-frame/12-FPS/17-centisecond receipt and decoded thumbnail, opened the native Save to Files share action, cancelled, and checked that the file remained available. Original simulator captures and the result bundle are preserved. Successful destination save/reopen, iPad and physical-device behavior remain unverified. No live upload, charge or test message is sent.

This work does not add GIF to the browser companion, implement general Spatter generation, or complete the remaining Studio, community and publishing requirements. Independent final approval and green mandatory native checks remain merge gates.

## Verification capacity

At source `49379a8850880264f6208cc5e1696ca6d9ebe8c4`, [run 34738631027](https://github.com/jmw7629/StickDeath-Infinity-/actions/runs/34738631027) passed the actual app build, every production stage and all 19 iPhone 16 Pro / iOS 18.5 journeys, with zero failures or skips. The native suite took 1,627.146 seconds, leaving only 52.854 seconds inside its previous 1,680-second allowance. This includes the real expanded-library AAC playback, save, terminate, reopen and replay journey. Its complete archive has SHA-256 `92c1a2cd62eeec09104a64cf91405805c5031f3acc22b023a04540ea91cb673d`; all 419 entries, CRCs and source/config records were verified.

This candidate adds three actual GIF production suites and a twentieth native journey. The shared UI-suite cap increases by exactly one existing 180-second test allowance, to 1,860 seconds. The containing standard macos-15 job increases from 60 to 65 minutes to fit the additional production compiles, UI coverage and evidence preservation. No previously failing test is being retried with a larger individual allowance: the preceding 19-journey source is fully green and all individual tests remain capped at 180 seconds.

Existing assertions, failure propagation, artifact preservation, serial execution, two build workers, runner class and concurrency policy remain unchanged. The harness probes still require fixture failure, UI failure and timeout to fail the run. Local GIF compile times are development-Mac measurements, not a CI forecast. Physical devices, destination save/reopen and independent final approval remain unverified.

## Recorded native timeout and correction

[Run 34741164661](https://github.com/jmw7629/StickDeath-Infinity-/actions/runs/34741164661) built the actual app and passed every production stage, including all three GIF suites. The native result was **19 passed, one failed, zero skipped**. The existing bucket-fill journey exceeded its unchanged 180-second limit while revealing the PNG preview; the overall job remains failed. The complete 514,798,989-byte evidence archive, all 1,784 entries and their CRCs were verified. Archive SHA-256: `d3b6b1bc64574c5c1edb3a29232051a308757d6e1d0ad96936bc02fdaee6e524`.

The raw UI log records repeated initial one-second XCTest polls for controls already present, and two successive canvas captures before inspecting the first result. The correction uses an immediate real accessibility existence check before the existing bounded wait in 16 call sites used by this journey and its shared helpers. Time spent checking is deducted from the original wait allowance. Hittability, geometry, typed input, actual gestures, screenshot comparisons, undo/redo, save, cold reopen and decoded PNG checks remain intact. The fill loop inspects each captured image before requesting another. The app source is unchanged by this test correction.

The individual 180-second and suite 1,860-second limits are unchanged. The corrected journey must pass a new exact-source simulator run. Simulator app preservation is added to the same existing macOS job to support subsequent local Intel/Apple Silicon review; packaging checks alone are not a successful local app launch.
