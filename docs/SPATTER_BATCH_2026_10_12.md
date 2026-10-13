# Spatter implementation batch — October 12, 2026

Bounded batch over the Spatter-owned surfaces (issues #203, #204, #205, #207,
#208, #209, #212, #213, #215, #216). Owner policy applied: no paid external AI
call anywhere, provider-neutral transport, retired messaging/call scope, no
fabricated acceptance. Verification is **deferred** except where a command was
actually run on this Linux host (listed at the end); Xcode and the macOS suites
were not run here.

## Retired-scope cleanup (#208, #207)

* `SpatterKnowledgeBase.retiredModuleIDs` / `retiredTerms` / `isRetired` /
  `activeModules`: modules 071–075, 088 and `core_livekit_collaboration` (plus
  any module whose text names LiveKit, calls, messenger, DMs) never reach
  `buildContext`, `search`, tool lookups or local ranking. `allModules` still
  holds all 120 modules for provenance.
* `SpatterCloudPrompt.compose(...)` (Foundation-only) now builds the whole cloud
  system prompt. `retireScope` replaces the historical "Collaboration: LiveKit
  calls, voice/video flow…" line with the current rooms line; runtime knowledge
  rows containing retired terms are dropped. The `private let systemPrompt`
  literal in `SpatterService` is byte-identical to the base because
  `scripts/verify_spatter_client.py` pins it against the PR base; the owner of
  `scripts/` can relax that pin so the literal itself can be cleaned.
* `Resources/SpatterBrain/*.json`: retired modules carry `retired: true` and a
  reason; the 1000-index lists `retiredFiles`. Files remain valid JSON and no
  module was deleted. No Swift code parses these resources today.
* Test: `Tests/SpatterConversation` "composed cloud prompt excludes retired
  messaging and call modules…" asserts the composed prompt contains no
  `LiveKit`, `video call`, `voice call`, `messenger`, or the word `DM`/`DMs`.

## Grounded help (#207)

* `SpatterInstructionCatalog` (in `SpatterKnowledgeBase.swift`) is the single
  registry of local grammars (31 entries, version 2) with examples, reached
  `StudioCommand` cases and one-line summaries. `currentStudioCapabilities` is
  generated from it; the snapshot `capabilities` list uses its names.
* `accountGuide` and `roomsGuide` added with honest wording (deletion not
  available, guest scope, invite codes are not auth tokens, no chat/calls,
  Watch Together, Calendar). `authorityGuide` routes account, rooms and
  messaging questions to them.
* `currentGuideVersion` bumped to **`2026-10-12.1`** (website help checker:
  `website/help.js` still cites `2026-10-09.5`; the website owner should update).

## New grammars (#204)

`Models/SpatterMotionRecipe.swift` (parsers + typed `prepare`) and
`Services/Spatter/SpatterStudioEditSession.swift` (dispatch, receipts):

| Grammar | Example | Command |
| --- | --- | --- |
| selectionTranslate | `Move selected drawings by (10%, -5%).` | `translateElements` |
| selectionTransform | `Scale selected drawings to 150% and rotate 45 degrees.` | `transformElements` |
| selectionReflect | `Flip selected drawings horizontally.` | `reflectElements` |
| imageRotation | `Rotate selected image clockwise.` | `rotateImage` |
| imageCrop | `Crop selected image to (10%, 10%, 80%, 80%).` | `cropImage` |
| imagePlacement | `Place selected image at (10%, 20%) with size (40%, 30%) and angle 25 degrees.` | `updateImagePlacement` |
| textUpdate | `Set selected text to "Hello" in #FF0000.` | `updateText` |
| audioTrack (extended) | `Pan audio track 2 to L40.`, `Solo audio track 3.` | `updateAudioTrack` pan/soloed |

Each grammar is anchored (suffix injection rejects the whole instruction),
bounded (1 KiB, no control characters, numeric ranges) and uses the captured
selection/image authority of the session. Parser and prepare tests are in
`Tests/SpatterMotionRecipe`; dispatch tests in `Tests/SpatterStudioEditSession`.

## Context (#203)

`SpatterContext.StudioSnapshot` gains `capabilities`, `canUndo`, `canRedo`,
`activeLayerIndex` and `namesShared`. `SpatterAIViewModel.shareProjectNames`
(default off) makes the cloud copy use `"Current project"` / `"Layer N"`; local
guidance keeps real names. The 8 KiB cap is unchanged. **UI wiring needed in
`StudioView` (not owned here):** a sub-toggle bound to
`spatterVM.shareProjectNames` under the existing Cloud advice toggle, and
optionally `movieState:` passed to `SpatterMotionRecipePanel`.

## Transport contract (#209)

* Client: `SpatterBackendClient.completeReply` decodes
  `{schemaVersion:1, reply, usage:{units}, budget:{remaining, resetsAt}}` and the
  legacy `choices` shape; request body now carries `schemaVersion: 1`.
  `SpatterCloudReply`, `SpatterBudget`; 503 → "not configured on the server";
  429 mentions the daily budget. `SpatterAIViewModel.budgetText` shows
  "Remaining today: N" (mounted in `SpatterChatView`; the Studio sheet lives in
  `StudioView`).
* Backend: `backend/spatter/handler.py` (Supabase JWT verification contract,
  per-user daily budget semantics, `NullProvider` → 503, no provider calls),
  `README.md` (table/RPC deployment candidate), `test_handler.py` (unittest with
  fakes).
* `SpatterBotModels.BotConfiguration` never encodes/decodes credentials;
  `credentialFields` is empty with an honest notice; SpatterCC views are marked
  retired in code. `Services/SpatterBotService.swift` is outside this batch's
  ownership and still contains the legacy save path (now receives empty
  credentials).

## Undo offer (#205)

`SpatterStudioEditSession.canUndoAppliedEdit` / `undoAppliedEdit` offer "Undo
Spatter edit" only while `document.revision == receipt.revision`; otherwise the
notice explains that the document changed. The undo is the typed `.undo`
transaction with the receipt revision as `expectedRevision`.

## Export receipt (#215)

`SpatterExportReceipt {editRequestID, revision, byteCount, durationSeconds,
frameCount, sha256}` measured from the real file (`SpatterSHA256`, FIPS 180-4,
Foundation-only). `SpatterExportReceipt.make(from: StudioMoviePanelState)` and
`SpatterExportReceiptView` display it in the Spatter panel when `movieState` is
passed. **GIF:** `StudioMoviePanelState` has no GIF direct-request path
(`StudioGIFExportSession` is separate), so a GIF receipt is deferred.

## Evaluation corpus (#216) and scaffolds (#212, #213)

* `Tests/SpatterEval/briefs.v1.json` (23 briefs: support/edit/create/export/
  hostile) and `Tests/SpatterEval/main.swift` runner writing pass/fail with seed.
* `SpatterQualityReport.analyze(document:requestedTicks:generatedLayerIDs:)`:
  blank frames, frozen frames without holds, out-of-canvas points, limb-length
  variance, requested vs actual ticks; audio/MP4 decode explicitly `unmeasured`.
* `backend/spatter/draft_queue_contract.md`: `spatter_draft_jobs` shape and
  state machine; no capacity or daily-success claim.

## Commands actually run on this Linux host

* `swiftc -swift-version 5 -parse-as-library AppConfig.swift SpatterBackendClient.swift Tests/SpatterClient/main.swift` + run → `SPATTER_CLIENT_TESTS=PASS 32/32`.
* `python3 -m unittest backend.spatter.test_handler -v` → 8 tests OK.
* `swiftc -parse` on every edited Swift file and the four macOS-only suites → OK.
* Scratch (not committed) Linux compiles of `SpatterKnowledgeBase.swift` +
  prompt check (`PROMPT_CHECK=PASS retired=7 active=113`) and of `SpatterSHA256`
  against four FIPS vectors (`SHA256_CHECK=PASS`).
* `scripts/verify_spatter_client.py` (BASE_SHA = branch base) and
  `scripts/verify_retired_communications.py` → PASS.

Deferred (need macOS/Xcode): `Tests/SpatterMotionRecipe`,
`Tests/SpatterStudioEditSession`, `Tests/SpatterConversation`,
`Tests/SpatterPersonalMemory`, `Tests/SpatterStickFigure`, the new
`Tests/SpatterEval` runner, and the native app build.

## October 13 continuation (wave 3, agent D) — epic #31 evidence

* **#206 briefs → animations.** `SpatterMultiClauseBrief` plans one to three actors with
  up to six clauses each from an eleven-verb vocabulary (walk, run, jump, wave, fall, punch,
  kick, sit, duck, throw, explode), per-clause durations, 0.5–60 s and a deterministic seed,
  and emits one `appendFrames` command per brief (a new typed `StudioCommand` that creates
  up to 240 frames of plain primitives in one history step). Poses are generated per tick
  with constant bone lengths; identical consecutive poses merge into held frames; briefs
  that exceed the generated-element budget hold poses for 2–4 ticks or are refused with the
  longest supported length. A `SpatterStoryboard` (schema `spatter_storyboard` v1) is attached
  to every receipt.
* **#280 impact primitives.** `SpatterImpactPrimitive` (seed, origin, direction, intensity,
  palette) produces streaks, pooling and fade over 2–24 frames; the `explodes` action uses it.
  Style sheet: `docs/SPATTER_IMPACT_STYLE_SPEC.md`; creative tuning is owner-managed.
* **#204 registry.** New grammars: tween with easing, frame clipboard (copy / paste / both),
  project settings (size, FPS), brush stroke in all thirteen families; catalogue v3 with 37
  grammars; `SpatterInstructionRouter` is the single classifier shared by the session,
  batches, preview and tests. Fill-at-point is not added: the fill path lives in
  `StudioFillService` (SwiftUI) and is not reachable from the Foundation command executor
  without changing CI source lists. "Select elements by description" is not added because
  selection is view-model state, not a typed document command.
* **#205 atomicity.** `SpatterInstructionBatch` applies 2–8 context-only lines as one
  revision; `SpatterInstructionPreview.plan` shows the typed commands before Apply;
  `SpatterStudioEditSession.revertAppliedEdit` removes exactly the created frames/layers
  (`deleteFrameRange` + `deleteLayer`) while they are unchanged, even after unrelated edits.
* **#213 quality gates.** `SpatterQualityReport` moved to the typecheckable grammar file,
  gained `Thresholds`, `verdict()` and optional `MovieMeasurement` (decoded frame count,
  duration, audio offset) findings; reports stay reviewer findings, never approval.
* **#212 daily draft queue.** `backend/sql/spatter-draft-jobs.sql` (unique `target_date`,
  state machine, ≤3 attempts, 15-minute leases, agent gate `spatter_daily_video`, missed
  days recorded) with `backend/sql/tests/070_spatter_draft_jobs.sql`; deterministic planner
  worker `backend/spatter/draft_queue.py` with fakes-only tests. Capacity and scheduling
  remain OWNER-GATED ⭐; without a renderer every job fails with that message.
* **#214 approval.** `render_reviews.storyboard` and `source_project_digest` columns; the
  invalidation trigger now resets approval when either changes; `SpatterProjectDigest`
  provides the canonical bytes on the device side.
* **#279 sources.** `SpatterSourceReference`, `SpatterSourceRightsGate` (unknown basis
  refused) and `SpatterSourceVideoBounds` (20–60 s target, 240-frame exporter note). Actual
  source material stays OWNER-GATED ⭐; the `StudioDocument` field is a coordinator patch.
* **#207/#208/#203.** Pricing guide (USD 4.99 / 9.99 monthly, annual not configured, no live
  prices), `.library` and `.companion` contexts (the retired "messages" screen name is only an
  alias), guide version `2026-10-13.1`; a test asserts active knowledge and the composed prompt
  carry no messaging/call modules.
* **#216.** `Tests/SpatterEval/briefs.v2.json` with 75 briefs (support/edit/create/export/
  hostile); the runner accepts v1 and v2.
* **#238/#260.** The unmounted SpatterCC views, `SpatterBotService` and `SpatterBotModels`
  (client-side credential fields, seeded queues, a third-party model name) are deleted;
  `docs/ci-candidates/pbxproj-remove-spattercc.patch` removes their project entries.

Verification on this Linux host: the new `Tests/SpatterPlanner` suite (11 cases through the
real `StudioCommandExecutor`/`StudioDocumentEditor`) passes with stub SwiftUI/UIKit modules;
Python 18/18; SQL harness 7/7 with the README apply order extended; the macOS Spatter suites
are parse-checked only and remain DEFERRED (not run). See `REPORT.md` for exact commands.
