# Native iOS recovery and Studio verification

Codex continues issue #110 and PR #111 under Joseph Willis's 2026-09-08 ownership transfer. Native SwiftUI Studio is the product. Media, community, messaging, calls, collaboration, calendar, challenges, publishing and profile remain in scope. Historical demo values are not live product evidence.

## Latest completed native run

Exact source `bd5649b2b2e9423d9e23a86ae12fd45f7c7a542f`, second attempt of [run 34277435359](https://github.com/jmw7629/StickDeath-Infinity-/actions/runs/34277435359), completed with **142 production checks and the actual native app build passing, and two of four native UI tests passing**. Source security passed separately. The iPhone 16 Pro / iOS 26.2 portrait-and-landscape journey passed (96.574 seconds); real drawing, undo/redo, save, termination, relaunch and reopened-pixel verification passed (63.707 seconds).

The PNG test created real blank/drawn PNG previews and presented the native share sheet. Its lookup failed because the observed Save to Files action is an accessibility **Cell**, while the test searched Buttons. The spritesheet recovery test stopped before export because its ungrouped size label did not match the actual en_US label `Original canvas · 1,080 × 1,920`. Seven frames are visible in the recording. The correction targets the recorded native share container/cell/close button and the exact localized dimension label, retaining all file, error, cancellation and pixel assertions. Those remaining assertions have not passed yet.

The complete original artifact `10077544500` contains the result bundle, attachments and a decoded 1206×2622 simulator recording; SHA-256 `2749d60008193b920bf16bdac14e2258f1ab0bbe6982a338f7a67097dc8cc4d9`. The unchanged MP4 declares a 495.6367-second movie timeline and a 449.2733-second encoded-media timeline; decoder clocks differ. Both the test process's failure65 and recorder success0 were preserved. This remains a red native regression gate and is not eligible for merge. The first attempt's 120-second simulator boot timeout occurred before any test/recording; its separate three-file artifact `10076729539` is also preserved. No third unchanged retry was requested.

Independent visual inspection found the landscape attachment captured mid-rotation. Original recording frames at media PTS 215.0 and 215.5 show settled landscape with the visible canvas and controls; the transient attachment must not be presented as parity evidence. The next test retains its size/hittability assertions, waits for stable canvas geometry fully inside the landscape app, and attaches a full-display screenshot afterward. This capture correction still requires the next simulator run.

## Earlier simulator evidence

Exact source `b3ca09f22001879f502aa4a8794b51e796c075ae`, [run 34271791257](https://github.com/jmw7629/StickDeath-Infinity-/actions/runs/34271791257):

- **App build passed:** actual Xcode 16.4 native job `102214893246` reported `BUILD SUCCEEDED` at 20:07:59 UTC on 2026-09-08.
- **115 production checks passed:** 29 Spatter/configuration, three complete model, 24 actual storage, ten Studio document, eight macOS SwiftUI renderer pixel, 13 decoded PNG export, 16 typed command and 12 actual Studio view-model command/persistence cases. Source security passed separately.
- **Native UI suite failed/incomplete:** the actual iPhone 16 Pro / iOS 26.2 portrait-and-landscape test passed, including the unchanged canvas size assertions. The new export test exceeded its 120-second allowance while repeatedly querying accessibility and then failed a 538-versus-540 screenshot-dimension assertion. The overall 480-second deadline interrupted the restarted drawing test before completion; the spritesheet recovery test never started.
- The original recording decodes, but the abruptly terminated xcodebuild left an incomplete result bundle. This is not a passing regression run and is not eligible for merge. The original artifact `10075035447` is preserved; SHA-256 `ebbf426992459d2d058464ad2ce5b9ee28d31363b5ee523dcbd061e11062ed67`.

Earlier source `7a21be7cf486295924741119e95a970fffb6fdfb`, [run 34268560396](https://github.com/jmw7629/StickDeath-Infinity-/actions/runs/34268560396), passed the app build and 103 production checks. Its real simulator drawing/undo/redo/manual-save/library/terminate/relaunch/reopen journey passed the reopened raster comparison (at most four changed pixels). Its landscape test failed; the b3 run above verifies that particular repair. Neither run establishes complete visual parity or physical-device/TestFlight readiness.

## Implemented continuation and remaining verification

The subsequent committed continuation adds local Spatter guidance and separate conversation state for Studio and Messages, explicit cloud choice/disclosure, immutable submitted prompts, cancellation and stale-project/account protection. It preserves embedded knowledge/personality and routes cloud advice through the existing authenticated backend client. Thirteen actual production coordinator cases and the 29 transport/configuration cases passed independent review. **Chat remains advice-only:** it does not generate editable documents, execute commands, export or publish.

The new native audio importer decodes actual selected file bytes through Apple AVFoundation, produces measured waveform peaks, enforces encoded/decoded limits, preserves originals and cleans only owned temporary files. Fourteen production decoder/storage tests and an additional compressed-audio limit probe passed independent review. This foundation alone does not prove Files-picker interaction, clip preview, timeline synchronization, trimming, mixing or audio export. MP3 and raw ADTS-AAC routes lack codec-specific runtime fixtures.

The 87-source app at `bd5649b` passed the actual CI native build above. Subsequent source `49d20c3b9e2a90a3835f15d91472c31c28d83987` adds actual Files import, project-managed immutable audio bytes, stable clip asset IDs, measured waveforms, AVAudioPlayer preview/stop/gain and reversible attachment/deletion through the canonical document. Missing references and save-capacity failures preserve dirty work and show real errors. Fourteen new integration tests and 13 Spatter regressions passed independent review, as did an unchanged-input 88-source iOS device-SDK typecheck. Actual simulator Files selection and physical-device audibility remain unverified; multi-track playback, trim/snap and mixed audio export remain unfinished. Historical catalog labels explicitly show unavailable audio.

The next native test candidate adds real Files-picker cancellation and Studio Spatter local/unconfigured-cloud journeys. Their assertions preserve unchanged document history and canvas pixels; they do not inject an importer URL or replacement responder. Six bounded 180-second journeys plus startup fit a 1,260-second suite deadline; the macOS job remains capped at 35 minutes. Only child processes owned by the harness receive bounded SIGINT/TERM/KILL cleanup. Timeout/failure codes remain red, and missing required result evidence cannot turn a successful test process green. These added UI journeys have not run on a simulator yet.

Source `f09c5332673acc231d6c73827a42cbfe5f5b7d83` adds ten deterministic native brush families as a rendering foundation. Nineteen actual geometry/CoreGraphics/SwiftUI pixel groups and adversarial cancellation/coordinate/opacity probes passed independent review. Original strokes are not yet switched to this engine; brush library/input/history integration remains separate work. Paint alpha and stroke opacity apply once, work is bounded, and varying-alpha gradients are explicitly unsupported. All 90 committed app sources match a passing unchanged-input iOS device-SDK typecheck. The next CI includes 175 production checks and six UI journeys; these counts are expected gates, not a claim that the next run passed.

## Production contracts and evidence boundaries

The workflow compiles complete production sources for each focused suite, not mirrored client, storage, editor or renderer implementations. Test networking uses declared URLProtocol fixtures/injected transports; no live provider, messages, charges or public uploads are used. The actual simulator app is preflighted to require empty backend configuration before launch.

Offline Studio uses one canonical editable document and layer/frame identities, full-document history, immutable retained raster/audio records and atomic versioned saves. Historical originals are not overwritten; incomplete legacy timing fails explicitly. PNG sequence/spritesheet output is rendered from that document, bounded, cancellable and decoded from real output files. The native share panel exposes those returned files; platform delivery must not be claimed before a real result.

Typed Studio commands use validated project/revision preconditions, bounded transactions, rollback and the actual view-model history/autosave path. The synchronous work preflight may explicitly refuse commands on very complex projects. This is not natural-language generation or arbitrary shell/admin access.

`SPATTER_BACKEND_URL` is a public Info.plist build setting. Missing/invalid configuration cannot create a request. SDK-managed authentication precedes optional runtime knowledge transport, and an account/session change aborts the request. Provider keys stay server-side. The current response contract is `choices[0].message.content`; the backend must validate sessions and authorization. Server `appMetadata` is not a substitute for an RLS/security audit.

## Review surface and remaining gates

[Private Studio review](https://stickdeath-infinity-review.joewillisny.chatgpt.site) reuses the original React Studio with isolated browser projects. Its v5 publication passed actual HTTPS Chromium/WebKit drawing, undo/redo, frame clipboard, save/reopen, PNG decoding, font and native screenshot/recording checks. The evidence gallery labels its native source separately. A browser companion is not a native iOS build and does not prove exact pixel parity.

Remaining gates include the complete next-head native regression suite; exposed Studio tools/brushes/layers and full document journeys; real audio/video workflows and MP4/GIF; Spatter document generation/export; authenticated and moderated community/calls; consent-aware official publication with owner OAuth; signing, physical devices and TestFlight. The local full Xcode build still lacks a matching installed simulator runtime, so approved macOS CI supplies actual native evidence. No release or merge has been claimed.

## Historical compiler recovery

The original `fe191ee` continuation corrected actual compiler-reported configuration and source membership issues in the existing branch. [Run 34257440327](https://github.com/jmw7629/StickDeath-Infinity-/actions/runs/34257440327) at `e505892d3c70aeb6b5983f0cf32bca8108a0bb4f` was the first verified native build milestone. Earlier Linux-only 22-test reports and later 29-test client reports proved their focused source behavior, not native compilation. The current results above supersede those historical readiness states.
