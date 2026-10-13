# Native CI budget and cancelled-run evidence

Source `f3f34ef012804a0c0db8b91f7de98eb0b14de082`, run 34728363046, passed every production stage and the actual iOS app build. The native job was cancelled by its overall 50-minute limit; the check annotation explicitly reports that deadline. The final iPhone result counts and recording are unavailable, so this run is not a native UI pass.

The job began at 00:35:48UTC. Production checks and the app build finished around 00:56:39; test setup reached a booted simulator around 00:59:07. That leaves less than 27 minutes before the overall deadline for a UI suite permitted to run 28 minutes, followed by result export and artifact upload. The previous 18-journey job used 49 minutes51 seconds overall.

The same single standard macos-15 job now has a 60-minute overall allowance. The 180-second per-test limit, 1680-second shared UI-suite limit, all 18 journeys and their assertions, serial simulator execution, build-worker limits and failure propagation remain unchanged. This fixes the containing job's budget; it does not make a failed test pass.

The production shell runner now registers its uniquely created evidence directory in the Actions output before invoking any long-running child. The existing always-run upload step can therefore retain partial evidence if the job is cancelled. Previously that output was written only after the test command returned, so cancellation skipped the main artifact upload. Missing or incomplete test results still leave a cancelled or failed gate; a directory is not a verification receipt.

A new controlled-process probe runs the actual shell script in a temporary Git fixture, blocks the selector with a fake child and cancels only that owned process group. It checks that the path was published before cancellation and that the same directory and marker survive. The probe failed against the previous script and passed after the correction. It does not execute or claim an iOS simulator test.

The complete final job log and cancellation annotations are preserved. Only the small simulator-setup artifact was listed; its temporary download links returned 403, so its bytes and CRC were not verified. The unavailable main UI artifact cannot be reconstructed from that setup record. The corrected source requires a new actual native run.

## Budget audit at `ee35143` + wave 3 (2026-10-12, #124)

Facts derived with `scripts/native-smoke/test_budget.py` from the checked-in
inventory; nothing here was executed on a Mac.

| Quantity | Before wave 3 | After wave 3 | Where it is pinned |
| --- | ---: | ---: | --- |
| `func test` cases in `Tests/NativeUI/StudioSmokeUITests.swift` | 108 | 110 (`testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize`, `testCompleteProjectJourneyCreateDrawLayerAudioExportPNGAndColdReopen`) | `MAXIMUM_CASES` in `test_budget.py` must equal this; `build_shard_budget` rejects any other count |
| Journeys with the explicit 240 s allowance | 14 (3360 s) | 15 (3600 s) — the complete journey has two launches and an export decode | `EXTENDED_CASE_SECONDS` + `executionTimeAllowance = 240` as the first statement |
| Whole-suite bound (unsharded) | 20 580 s | 21 000 s = 110 × 180 + 15 × 60 + 300 | `suiteSeconds` |
| Shard 0 / shard 1 cases | 54 / 54 | 55 / 55 (sorted names, alternating) | `build_shard_budget` |
| Shard 0 / shard 1 suite seconds | 10 500 / 10 380 | 10 620 (7 long) / 10 680 (8 long) | `ui-test-budget.json` in each artifact |
| Shard job ceilings | 222 / 198 min | **224 / 203 min** = ceil((suite + 25 min build/preservation [+ 22 min auth on shard 0]) / 60) with zero slack | `docs/ci-candidates/spatter-client-verify.yml` (candidate; the live workflow still says 222/198 until applied) and `Tests/NativeSmokeHarness/test_suite_budget.py` |
| Auth cases (`Tests/AuthState/AuthStateTests.swift`) | 19 | 19 | `run_auth_ci.py` requires `passedTests == 19`; step `timeout-minutes: 22` |
| Fixture source pin | `373b4673…8460` | `f45485ab…31e1` (SHA-256 of the whole UI test file) | `FIXTURE_SOURCE_SHA256` in `run_recorded_test.py`; `test_image_seed.py` fails when it drifts |
| Photos / video fixture consumers | shard 1 / shard 0 | shard 1 (`testPhotoImportUndoPersistenceAndRealPNGExport`) / shard 0 (`testRotoscopePhotosActualPlayheadUndoAndColdReopen`) | `fixture_requirements()` seeds only the shard that runs the consumer when the pin matches; any unreviewed source seeds both |

### The exact-source gate, in one place

1. `run_smoke_ci.sh` refuses to run with uncommitted changes (`git diff --quiet HEAD --`) and records `git rev-parse HEAD` into `source-and-config.json` through `prepare_offline_run.py`.
2. `run_recorded_test.py` rebuilds the budget from the checked-in test file at that commit, refuses filters/retries, writes `ui-test-budget.json` (`sourceCommit`, `assignmentSHA256`, `sourceSHA256`) and refuses a prepared build whose `sourceCommit` differs from the shard checkout.
3. `shard_receipt.py collect` binds the XCResult's actual test identifiers (not counts) to the assigned names, the commit, the run id/attempt and every gate outcome; `aggregate` fails on a missing, duplicate, skipped, failed, cross-run or cross-attempt receipt, and on any red dependency job.
4. `native-ios-build` is green only when both receipts aggregate; re-running a single shard produces a different attempt and fails aggregation by design.
5. Release gate: the receipt's `sourceCommit` must equal the release head (`docs/RELEASE_CHECKLIST.md` §1–2).

Status: **DEFERRED (not run)** — Linux host, no Xcode. The last public outcome remains the recorded `b50033cc` shard-0 failure (#124); no newer run is claimed.
