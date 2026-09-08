# Native iOS recovery and Studio verification

Codex continues issue #110 and PR #111 under Joseph Willis's 2026-09-08 ownership transfer. Native SwiftUI Studio is the product. Media, community, messaging, calls, collaboration, calendar, challenges, publishing and profile remain in scope. Historical demo values are not live product evidence.

## Latest completed native run

Exact source `b3ca09f22001879f502aa4a8794b51e796c075ae`, [run 34271791257](https://github.com/jmw7629/StickDeath-Infinity-/actions/runs/34271791257):

- **App build passed:** actual Xcode 16.4 native job `102214893246` reported `BUILD SUCCEEDED` at 20:07:59 UTC on 2026-09-08.
- **115 production checks passed:** 29 Spatter/configuration, three complete model, 24 actual storage, ten Studio document, eight macOS SwiftUI renderer pixel, 13 decoded PNG export, 16 typed command and 12 actual Studio view-model command/persistence cases. Source security passed separately.
- **Native UI suite failed/incomplete:** the actual iPhone 16 Pro / iOS 26.2 portrait-and-landscape test passed, including the unchanged canvas size assertions. The new export test exceeded its 120-second allowance while repeatedly querying accessibility and then failed a 538-versus-540 screenshot-dimension assertion. The overall 480-second deadline interrupted the restarted drawing test before completion; the spritesheet recovery test never started.
- The original recording decodes, but the abruptly terminated xcodebuild left an incomplete result bundle. This is not a passing regression run and is not eligible for merge. The original artifact `10075035447` is preserved; SHA-256 `ebbf426992459d2d058464ad2ce5b9ee28d31363b5ee523dcbd061e11062ed67`.

Earlier source `7a21be7cf486295924741119e95a970fffb6fdfb`, [run 34268560396](https://github.com/jmw7629/StickDeath-Infinity-/actions/runs/34268560396), passed the app build and 103 production checks. Its real simulator drawing/undo/redo/manual-save/library/terminate/relaunch/reopen journey passed the reopened raster comparison (at most four changed pixels). Its landscape test failed; the b3 run above verifies that particular repair. Neither run establishes complete visual parity or physical-device/TestFlight readiness.

## Reviewed continuation awaiting exact-head CI

The subsequent committed continuation adds local Spatter guidance and separate conversation state for Studio and Messages, explicit cloud choice/disclosure, immutable submitted prompts, cancellation and stale-project/account protection. It preserves embedded knowledge/personality and routes cloud advice through the existing authenticated backend client. Thirteen actual production coordinator cases and the 29 transport/configuration cases passed independent review. **Chat remains advice-only:** it does not generate editable documents, execute commands, export or publish.

The new native audio importer decodes actual selected file bytes through Apple AVFoundation, produces measured waveform peaks, enforces encoded/decoded limits, preserves originals and cleans only owned temporary files. Fourteen production decoder/storage tests and an additional compressed-audio limit probe passed independent review. This foundation alone does not prove Files-picker interaction, clip preview, timeline synchronization, trimming, mixing or audio export. MP3 and raw ADTS-AAC routes lack codec-specific runtime fixtures.

The complete 87-source app candidate passed an iOS 17 device-SDK typecheck with unchanged inputs. The checked-in project retains every previous app source and its separate UI target. This local typecheck is not a replacement for the next Xcode CI build or simulator run.

The native harness now permits four bounded 180-second journeys plus startup within a 900-second suite deadline; the macOS job remains capped at 35 minutes. Only child processes owned by the harness receive bounded SIGINT/TERM/KILL cleanup, allowing it a chance to finalize its result. Timeout/failure codes remain red, and missing required result evidence cannot turn a successful test process green. Independent process/reporting checks passed; actual native finalization still requires the next run. The export-specific capture correction is separately reviewed before inclusion.

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
