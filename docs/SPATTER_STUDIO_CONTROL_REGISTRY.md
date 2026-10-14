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

Pixel tools (Fill, Smudge, Sharpen, Dodge, Burn, Blur), selection tools (Lasso,
Wand), freehand tools other than Brush, and view tools (Hand, Zoom) are
`manual`: no grammar exists for them, and the registry says so rather than
implying coverage.

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
