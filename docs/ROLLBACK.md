# Rollback (#267)

Rollback is a recorded, reversible step with evidence, like a release. Never
rewrite history on `main`, never delete evidence, and never roll back a user's
only original project.

## 1. Source: revert a merged PR

1. Identify the squash-merge commit of the PR on `main` (`git log --oneline --first-parent main`).
2. Create a branch and revert it without force: `git revert --no-edit <merge-sha>` (a squash merge is a single commit; for a true merge commit use `git revert -m 1 <sha>`).
3. Open a PR titled `Revert "<original title>" (#<pr>)` and let the exact-head CI run on the revert commit. The revert is not deployed or merged until `native-ios-build` is green on **that** head; a revert that fails CI is a new defect, not a rollback.
4. Record in the original issue: the reverted range, the reason, the failing evidence and the follow-up issue. Keep the original PR branch; do not delete it.
5. Partial rollback (one file) is a forward fix, not a revert; it needs the same review and CI.

Dirty work in other worktrees is preserved: the coordinator lock and disjoint file ownership mean a revert never touches another agent's uncommitted files.

## 2. Native build: go back to the last known-good app

- The last known-good CI build is identified by its run id, attempt and `sourceCommit` in `native-simulator-app-<sha>-<attempt>/manifest.json` (`archiveSHA256`). Keep that archive and manifest privately; CI retention is 3 days.
- For simulator review, install the previous archive by its own `manifest.json` instead of the current one (`docs/NATIVE_SIMULATOR_REVIEW.md`, uninstall step first).
- TestFlight/App Store rollback is owner-gated: Apple does not allow re-publishing an older build to the store; the owner either expires the current TestFlight build or submits a new build from the reverted source. Record which option was taken.

## 3. Review site rollback (as recorded in #126)

The owner-private review gallery (`stickdeath-infinity-review.joewillisny.chatgpt.site/?view=native`) is published as numbered versions from a labelled source commit; each checkpoint names its rollback version:

- Version 126 (published 2026-10-08 20:48:35 UTC from `e93021ea917213cf102e87a540ad4b62892a0318`): "Version 125 is the immediate rollback; earlier versions remain retained."
- Version 125 (19:04:39 UTC from `1d8ad54c05452b0bc8126cb04739985616c8bd86`): rollback 123, with 124 retained.
- Version 123 (16:13:15 UTC from `0d16eec49e667c32a693c725b8e79c9e052c79f8`): rollback 122.

Procedure: re-publish the retained prior version named in the current checkpoint, then repeat the same authenticated HTTPS checks the checkpoint recorded (metadata, provenance JSON, every original PNG hash and the root HTML status) before calling the rollback complete. Record the new checkpoint in #126 with the version numbers, time and source commit. Retired generated `dist` folders are only removed after the archive, source and deployed payload were verified (#295); keep the current and rollback archives at all times.

## 4. Data-format compatibility

- `StudioDocument.supportedSchemaVersions = 1...34` (`StickDeathInfinity/Models/StudioDocument.swift:5`). A build that supports up to version N opens every project from 1...N and raises `StudioDocumentError.invalid("This project version is not supported. The original has not been changed.")` for anything newer (`StudioDocument.swift:114`).
- **Projects saved with `schemaVersion` 34 cannot open on older builds.** Version 34 is written when fade curve shapes, balance pan or solo state are used (`StudioDocument.swift:687,692,711`). Rolling the app back to a build with `supportedSchemaVersions` ending below 34 makes those projects unopenable on that build; the file itself is not modified or lost, and the current build opens it again.
- Before any rollback that lowers the supported schema range, tell affected users to keep a Files backup (`.sdiproject`, see `docs/SUPPORT_RUNBOOK.md`) and do not advise deleting the project. The Android importer contract fixture for schema 34 is independent and does not imply cross-platform rollback support.
- `UserDefaults` tool preferences are versioned by key (`studio.drawing-tool-preferences.v1`); invalid or out-of-range saved preferences are rejected, not reset (`StudioViewModel.swift:4684`).

## 5. Backend and configuration

- Backend settings are injected at build time (`SPATTER_BACKEND_URL`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SDI_UPLOAD_SERVICE_URL`, …, `Info.plist`). Rolling back the app does not roll back server schema or data; coordinate with the owner before changing either.
- No automated deletion exists in the rollback path. Server-side retention and deletion remain documented owner decisions (`docs/PRODUCT_SCOPE_2026_09_19.md`).

## 6. Evidence after rollback

Record passed, failed and not-run checks separately for the rollback itself, with the exact head and run ids. Preserve the failed release evidence; a rollback does not erase the defect report.
