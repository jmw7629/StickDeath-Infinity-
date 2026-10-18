# Spatter Studio integration: context, control registry and atomic batches

Issues: #203 (context), #204 (command registry), #205 (atomic batches).
Status: implemented in source. Swift compilation and every Swift suite named
below are **deferred to macOS CI**; nothing here has been run natively.

## Context snapshot (#203)

`SpatterContextSnapshot` (`StickDeathInfinity/Services/Spatter/SpatterStudioControlRegistry.swift`)
is a bounded, typed description of what Spatter can see:

- screen: tool, panel (a known `StudioPanelType` raw value or `unknown`), playback,
  dirty/saving state and real Undo/Redo availability;
- selection: drawing count (capped at 4,096), image count (0 or 1), whether the
  selected audio clip exists in the document;
- frame and layer: one-based active and displayed frame numbers, active layer
  number, name (truncated to 80 characters), visibility and lock mode;
- document statistics: canvas size, FPS, frame count, total ticks, duration,
  drawings on the active frame and in the document, frames with images, audio clips,
  grid/onion state and revision.

It holds no artwork, audio bytes, file paths or credentials. `isStale(comparedTo:)`
reports a different project, revision, frame, layer, tool, selection or playback
state. `readiness(of:)` explains whether a grammar's preconditions hold; it is
guidance only, because Apply always recaptures and revalidates the live editor.

The Spatter local-edit panel shows the snapshot as "What Spatter sees", the
selected tool's registry explanation and the grammars ready now. A plan preview
records the snapshot it was built from and warns when it has gone stale.

The cloud advice snapshot (`SpatterContext.StudioSnapshot` in
`ViewModels/SpatterAIViewModel.swift`) is unchanged by this work; feeding it the
new document statistics is a follow-up outside this area's file ownership.

## Control registry (#204)

`SpatterStudioControlRegistry.controls` lists every drawing tool (toolbar and
hidden), every Studio panel, and the header and timeline controls. Each has one
route:

| Route | Meaning |
| --- | --- |
| `instructions([...])` | Named local grammars prepare the same typed `StudioCommand` the manual control uses. |
| `manual(reason)` | Spatter explains the control but never operates it. |
| `blocked(reason)` | Spatter refuses even when asked (Export, Add Picture): the user takes that step. |

`validate()` fails on duplicate IDs, unknown grammars, catalogue grammars
reachable from no control, unmapped `DrawingTool` cases, unknown panel keys and
empty reasons. The SwiftUI panel maps `StudioPanelType` with an exhaustive
`switch`, so a new panel cannot compile without a registry decision.

Pixel tools other than Fill (Gradient, Smudge, Sharpen, Dodge, Burn, Blur), selection
tools (Lasso, Wand), freehand tools other than Brush, and view tools (Hand, Zoom)
are `manual`: no grammar exists for them, and the registry says so rather than
implying coverage.

### Fill, select-by-ID and source reference (catalog v4, 2026-10-18)

| Grammar | Control | Typed command | Path |
| --- | --- | --- | --- |
| `fill` — "Fill at (50%, 50%) with #FF0000[, opacity 80%][, tolerance 16][, all layers]." | `tool.fill` | `fillAtPoint` | The edit session captures the active frame/layer with `StudioFillService.capture` and computes the region with `StudioFillService.element` (the Fill tool's own path, off the main thread, cancellable). The request carries that result as `preparedFills`; the executor refuses `fillAtPoint` without it (`unsupportedCapability`), with a mismatched project/revision/arguments/color (`staleRevision`), inside a multi-command batch, or on a hidden/locked layer. Contiguous, no expand/gap closing, anti-aliased (the tool defaults). A selection-clipped fill stays with the Fill tool. The prepared region never enters the wire form. |
| `selectByID` — `Select drawings "id-1", "id-2".` / `Clear drawing selection.` | `tool.move` | `selectElements` | Explicit stable IDs on the active frame; drawings on visible, non-fully-locked layers only, never erasers or invisible strokes. Selection is editor state: no revision, no Undo step. |
| `sourceReference` — `Record source https://… as licensed reference [with note "…"].` / `Clear source reference.` | `panel.spatterAI` | `setSourceReference` | Stores URL text, rights basis and time on `StudioDocument.spatterSource` (one Undo step, saved with the project). Nothing is fetched. See #279 below. |

### Source references and video length (#279)

Every generative grammar (circle motion, stick figure, scene, two-actor and
multi-clause briefs) calls `SpatterSourceRightsGate.require` before preparing
commands. Without a recorded source it passes. With one, the rights gate must
allow the recorded basis (`unknown` and future-dated records are refused) and
the request must be 20–60 seconds; only the multi-clause brief (0.5–60 s) can
reach that range, so the others refuse with an explicit reason. A successful
source-referenced brief appends a length receipt (seconds, FPS, URL, basis,
recording time, "nothing was fetched") to the Spatter summary.

The stale 240-frame caps are reconciled with the exporter:
`SpatterSourceVideoBounds.exporterFrameCap` is 1,440
(`StudioMovieExportService.Limits.maximumFrames`) and
`StudioCommandExecutor.maximumAppendedFrames` is 1,000, the project frame limit
that binds first. At 24 FPS a 60 s video (1,440 ticks) therefore needs poses held
for 1–2 ticks. No 60 s MP4 has been rendered on a device yet (deferred).

## Atomic batches (#205)

A batch (2–8 context-only lines) prepares every line against one captured
document and commits one typed request: one revision, one Undo step. The
executor stages a copy, so any failure leaves the editor, history and
clipboard untouched. This work adds:

- a factual rollback notice when every line prepared but the combined request
  failed while committing (`SpatterInstructionBatch.rollbackNotice`), used by
  the edit session for batches only; stale-revision and project errors keep
  their stale status;
- tests for commit-time conflict (two lines deleting the same captured layer),
  cancellation at every executor checkpoint, cancellation while preparing a
  later line, an intervening user edit between preparation and commit, and a
  deadline expiring at each preparation and commit checkpoint.

## Verification

| Check | Result |
| --- | --- |
| `Tests/SpatterPlanner` (3 new cases) | deferred to macOS CI (no Swift toolchain on the Linux host) |
| `Tests/SpatterStudioEditSession` (1 new case) | deferred to macOS CI |
| Native panel rendering of the new context section | deferred (native UI) |
| `scripts/verify_native_compile_sources.py` | passed on Linux |
| `scripts/verify_control_index.py` | passed on Linux |
| `scripts/sync_pbxproj_sources.py` | new file registered; in sync |
| 2026-10-18 `Tests/SpatterPlanner` (4 new cases: source gate/receipt, select-by-ID + prepared fill, shared-edit replay, reconciled caps) | 18/18 passed on Linux (Swift 6.0.3, stub SwiftUI/UIKit/CoreGraphics modules) |
| 2026-10-18 `Tests/StudioCommands` | 70/70 passed on Linux with the same stubs |
| Spatter session fill/select/source branches, `Tests/SpatterMotionRecipe` (catalog 40 / v4), `Tests/SpatterStudioEditSession` | deferred to macOS CI (need ImageIO / the view model) |
| Native Spatter fill on a device, real StudioFillService region | deferred (native) |
