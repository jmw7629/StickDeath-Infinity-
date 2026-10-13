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
