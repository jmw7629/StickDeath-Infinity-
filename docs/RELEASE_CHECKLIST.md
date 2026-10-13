# Release checklist (#267)

Source baseline for this checklist: `e48e789` (branch `claude/studio-sdi-overhaul-kurekj`).
Every item below is a gate to record, not a claim. Mark each one **passed**,
**failed**, **not run** or **owner-gated** with the exact commit and the
evidence location. Unrun verification is *deferred*, never passed. No item is
waived by this document, and a PR is a review artifact, not approval to merge.

## 1. Source and build

- [ ] The release commit is the exact head that CI verified (`git rev-parse HEAD` matches the run's `sourceCommit` in every receipt).
- [ ] `git diff --check` passes and the worktree is clean.
- [ ] `python3 scripts/verify_spatter_client.py` passes (no client AI credentials, production wiring intact).
- [ ] `python3 scripts/verify_retired_communications.py` passes (no messaging/call code in either native build definition, no microphone/contacts usage strings).
- [ ] `python3 scripts/verify_native_compile_sources.py` passes.
- [ ] `python3 -m unittest discover -s Tests/NativeSmokeHarness -p 'test_*.py'` passes (includes the control evidence map, suite/shard budget, source pin and disk preflight checks; the budget test reads the live workflow, so the shard ceilings in `.github/workflows/spatter-client-verify.yml` must match the inventory).
- [ ] `python3 -m unittest discover -s scripts/backlog -p 'test_*.py'` passes (backlog audit, cache adapter, queue renderer, ledger merger).
- [ ] `python3 scripts/verify_control_index.py` passes: every static `accessibilityIdentifier` in `StickDeathInfinity/**/*.swift` has a row in `docs/control-evidence-map.csv`, no row is stale, and every `uiTest` reference names a function that exists. Review rows whose `operation` ends in `(identifier-derived; review source)`, rows whose `issue` is `unmapped`, and rows with `history=no` on controls that are expected to edit the document; a visible no-op fails this checklist (#125).
- [ ] `xcodebuild -project StickDeathInfinity.xcodeproj -scheme StickDeathInfinity -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` succeeds on the exact head (CI job `native-ios-shards`, step "Build checked-in native iOS target").
- [ ] A Release-configuration archive with the owner's signing identity builds on the owner's Mac. Not possible on Linux; **owner-gated**.

## 2. Exact-head CI gates (`.github/workflows/spatter-client-verify.yml`)

Record the run id, attempt and outcome for each required job on the release commit:

| Job | Runner | What it proves | Outcome |
| --- | --- | --- | --- |
| `spatter-production-tests` | ubuntu | Foundation production source compiles and executes; ArtCraft ports | |
| `source-security` | ubuntu | provider removal, harness tests, compile-source lists, retired communications | |
| `native-production-tests` | macos-15 | production model/storage/document/audio/image/export suites | |
| `native-ios-shards` (shard 0 and shard 1) | macos-15 | native build; all 110 `StudioSmokeUITests` journeys (55/55) split across two shards with no retries; shard 0 also runs the 19 isolated auth cases (`run_auth_ci.py` requires `passedTests == 19`) and preserves the simulator review app | |
| `native-ios-build` | ubuntu | aggregates both shard receipts; fails on any partial, cancelled or missing shard | |

- [ ] `native-ios-build` is green only because every shard receipt is present and passed (`scripts/native-smoke/shard_receipt.py aggregate`). A re-run of a single failed shard is not a passing release.
- [ ] `scripts/native-smoke/test_budget.py` `MAXIMUM_CASES` equals the actual number of `func test` cases in `Tests/NativeUI/StudioSmokeUITests.swift`; new journeys bump the constant, the `FIXTURE_SOURCE_SHA256` pin in `run_recorded_test.py` and the shard timeouts together (currently 224/203 min, derived in `docs/NATIVE_CI_BUDGET_VERIFICATION.md`; the live workflow carries them only once `docs/ci-candidates/spatter-client-verify.yml` is applied).
- [ ] The two wave-3 journeys have run at least once on the exact head: `testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize` (#264) and `testCompleteProjectJourneyCreateDrawLayerAudioExportPNGAndColdReopen` (#265). Their first run is **not run** until the shard artifacts exist; failures are defects to fix, never assertions to relax.
- [ ] Known separate failure on `b50033cc` (run 37816602055 shard 0, "Project control must be fully visible before interaction") is either fixed at the exact head or recorded as open in #292. Do not weaken the assertion.

## 3. Evidence retention

- [ ] Artifacts from the release run are downloaded and stored privately before their 3-day retention lapses: `native-studio-<sha>-<attempt>-<shard>`, `native-auth-<sha>-<attempt>`, `native-simulator-setup-<sha>-<attempt>-<shard>`, `native-shard-receipt-<sha>-<attempt>-<shard>`, `native-simulator-app-<sha>-<attempt>`.
- [ ] SHA-256 of every retained archive is recorded next to the run id (see `docs/NATIVE_SIMULATOR_REVIEW.md` for the app archive).
- [ ] Original XCTest attachments (PNG captures) are kept byte-identical; any published rendition links back to the labelled source commit (#126).
- [ ] Failed and interrupted runs are preserved with their exit codes (for example the disk-full save failure and exit 124 finalization interruption recorded in #295); they are not overwritten by later passes.

## 4. Visual and accessibility acceptance (owner-gated until native evidence exists)

- [ ] `docs/VISUAL_REFERENCE_MAP.md` comparison-status column is no longer all `deferred` for the screens in the release scope (#127).
- [ ] Portrait, landscape and iPad captures at matching viewport sizes exist for Studio, popup, audio and export (#264).
- [ ] Token contrast at the release head matches `docs/STUDIO_CONTROL_CONTRAST_VERIFICATION.md` "Token re-measurement 2026-10-12": `textFaint` `#6B7280` (≥ 3.25:1 on its `LayerPanel` surfaces) and `sdTextMuted` `#757575` (≥ 3.45:1 on every `sd*` surface); any new muted token is measured before release.
- [ ] Dynamic Type, VoiceOver and Reduce Motion checks were run on a device or simulator and recorded separately as passed/failed/not run; the audit journey's `accessibility-audit-recorded-*` attachments were triaged (`docs/ACCESSIBILITY_DYNAMIC_TYPE.md` §4) and the remaining fixed `.font(.system(size:))` count is recorded against the migration recipe (§2).

## 5. App Store metadata placeholders (owner supplies the final text)

| Field | Current source value | Owner decision needed |
| --- | --- | --- |
| Bundle identifier | `com.willisnmb.stickdeathinfinity` (`StickDeathInfinity/Info.plist`) | confirm matches App Store Connect record |
| Display name | `StickDeath ∞`; bundle name `StickDeath Infinity` | confirm |
| Version / build | `1.0.0` / `1` (`CFBundleShortVersionString`, `CFBundleVersion`) | set release values |
| Category, age rating, description, keywords, support URL, marketing URL | not in source | **placeholder** |
| Screenshots | must be real captures from the release commit, not web renders | **placeholder** |
| Privacy nutrition labels | see section 6; account identifiers (email) are collected by sign-in, which the manifest draft does not enumerate | **owner decision** |
| In-app purchases | requested USD 4.99 and USD 9.99 monthly only; annual pricing requires explicit configuration | **owner decision**; see limitation on `$19.99` / `$79.99` copy in `docs/KNOWN_LIMITATIONS.md` |
| Export compliance | no custom encryption beyond system TLS found in source; confirm | **owner decision** |

## 6. Privacy manifest (`StickDeathInfinity/PrivacyInfo.xcprivacy`)

The manifest is referenced by the app target in `StickDeathInfinity.xcodeproj/project.pbxproj` (file reference `7C1E5A0D2B4F4C8E9A1D3F61`, Resources build phase entry `7C1E5A0D2B4F4C8E9A1D3F60` at `ee35143`); a native build must still confirm it is copied into the bundle (deferred). The reason codes below cite the Swift usage that justifies them at `e48e789`; section 10 re-verifies the categories at `ee35143`. Recheck the lines before submission.

- `NSPrivacyAccessedAPICategoryUserDefaults` — **CA92.1** (defaults readable only by this app): `ViewModels/StudioViewModel.swift:114,840` (`toolDefaults: UserDefaults`), `Views/Components/AppTutorialView.swift:94,114` (`UserDefaults.standard.set(true, forKey: "tutorial_completed")`), `Services/StudioImageCatalogue.swift:250-253`, `Services/StudioSoundCatalogue.swift:189-192`, `@AppStorage` in `Views/Onboarding/OnboardingView.swift:8`, `Views/Auth/WelcomeView.swift:14`, `App/AppFlowView.swift:8`, `Views/Messages/CalendarView.swift:8`. No app-group suite was found.
- `NSPrivacyAccessedAPICategoryDiskSpace` — **E174.1** (check space before writing or deleting on the same volume): `App/AppConfig.swift:359` (`volumeAvailableCapacityForImportantUsage` before writing an upload journal), `Services/StudioImageCatalogue.swift:522-524` (`attributesOfFileSystem` / `.systemFreeSize` before caching an image pack), `Storage/DeviceStorageManager.swift:82-83` (`deviceStorageAvailable()`). 85F4.1 was **not** chosen: `deviceStorageAvailable()` has no caller that displays the value to the user at this commit; add 85F4.1 if a storage screen starts showing free space.
- `NSPrivacyAccessedAPICategoryFileTimestamp` — **C617.1** (files inside the app container): `fstat`/`stat` `st_mtimespec`/`st_ctimespec` comparisons in `Storage/DeviceStorageManager.swift:896-897,1082,1305,1400`, `ViewModels/StudioViewModel.swift:1000`, `ViewModels/SpatterAIViewModel.swift:746-747`, `Services/StudioAudioMixService.swift:583`, `Services/StudioImageProviderFile.swift:233`, `Services/StudioMovieExportService.swift:305`, `Services/StudioAudioVideoMuxService.swift:275-276`, `Services/StudioMuxOwnership.swift:214`; and **3B52.1** (files the user granted through the document picker or Photos): `Services/StudioImageImportService.swift:200-203` and `Services/StudioAudioImportService.swift:139-142` `fstat` the picked input descriptor to detect source changes during copy.
- `NSPrivacyAccessedAPICategorySystemBootTime` — **35F9.1** (elapsed time between in-app events): `ProcessInfo.processInfo.systemUptime` in `Storage/DeviceStorageManager.swift:1160,1179,1184,1254,1257` (idle timeout and page budget), `Models/AdminOverviewModel.swift:56`, `ViewModels/StudioViewModel.swift:4125,4145` (playback clock), `Views/Studio/StudioCanvasView.swift:565,923` (gesture timing).
- `NSPrivacyTracking` is `false` and `NSPrivacyTrackingDomains` is empty: no advertising or tracking SDK is linked. The only package dependency in `StickDeathInfinity.xcodeproj` is `supabase-swift` (`XCRemoteSwiftPackageReference`, `upToNextMajorVersion` from 2.0.0); `Package.swift` still lists `client-sdk-swift` (LiveKit) but it is not linked by the Xcode project and `scripts/verify_retired_communications.py` rejects it.
- `NSPrivacyCollectedDataTypes` is an **empty array in the draft** because no analytics SDK exists (grep for firebase/amplitude/mixpanel/crashlytics/sentry finds only the app's own "SpatterAnalytics" admin view names). Sign-in does send account identifiers to the configured Supabase backend; the owner decides whether to enumerate `NSPrivacyCollectedDataTypeEmailAddress` / `UserID` here and in the App Store privacy labels before submission. Do not submit with an unreviewed empty array.
- Usage strings present: `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` (`Info.plist:38-41`). No microphone, contacts or location usage strings exist.

## 7. Third-party notices and rights

- [ ] `docs/THIRD_PARTY_NOTICES.md` matches the bundled `Resources/Licenses/*`, `Resources/StudioSounds/CREDITS.txt` and the image catalogue license entries at the release commit.
- [ ] No reference-corpus material (recovered SWFs, original sounds, extracted artwork) is in the bundle or repository.
- [ ] Any new bundled asset has its license file, source URL and SHA-256 recorded in the relevant catalogue.

## 7b. Backend and website gates (local, exact head)

- [ ] `scripts/backend/run_sql_tests.sh` → all `backend/sql/tests` pass on the exact head (9 files on 2026-10-13).
- [ ] `python3 -m unittest discover -s backend/tests -t .` → all pass (102 on 2026-10-13).
- [ ] `scripts/backend/verify_backup.sh` → `BACKUP RESTORE REHEARSAL PASSED`.
- [ ] `node scripts/website/check_help.mjs --check`, `node scripts/website/build_site.mjs --check`, `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node scripts/website/a11y_perf.mjs` → all green; results recorded in `docs/WEBSITE_INVENTORY.md`.
- [ ] CI candidates `docs/ci-candidates/backend-candidates.yml` and `website-verify.yml` promoted by the coordinator or run manually with the same commands; unrun gates are listed as deferred, never as passed.
- [ ] `admin-config.js` and `account-config.js` are `null` in the release commit; any configured copy lives only in the deployment.

## 8. Owner approvals (never automated)

- [ ] Owner has reviewed the exact release build on a device or the CI simulator app (`docs/NATIVE_SIMULATOR_REVIEW.md`).
- [ ] Every Spatter-generated video intended for feed, channel or social release has the owner's approval of the exact render digest in the admin command center; revisions invalidate approval.
- [ ] Pricing, entitlements and any annual plan are configured by the owner; no live charge was made as a test.
- [ ] Publishing/marketing permissions, moderation and rights checks are configured server-side; `SDI_PUBLISHING_CONSENT_VERSION` and `SDI_PUBLISHING_TERMS_URL` are set by the owner, not committed.
- [ ] Owner admin credentials and MFA are provisioned privately; nothing in source or issues.
- [ ] `docs/ROLLBACK.md` prerequisites are satisfied: the last known-good build, review-site version and backup of the owner's local projects are identified before release.

## 9. Known limitations and support

- [ ] `docs/KNOWN_LIMITATIONS.md` is regenerated against the release commit (every cited file:line still matches) and reviewed by the owner for user-facing wording.
- [ ] `docs/SUPPORT_RUNBOOK.md` reflects what the release can actually do (local projects, Files backups, no server-side deletion).

## 10. Store submission (#267) — required-reason APIs re-verified at `ee35143`

Before uploading any build, confirm `StickDeathInfinity/PrivacyInfo.xcprivacy` still matches the source. The greps below were run on 2026-10-12 against `StickDeathInfinity/**/*.swift`; rerun them on the release head and update the manifest if a category appears or disappears.

| Manifest category / reason | Evidence in source at `ee35143` | Verdict |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` — CA92.1 | `UserDefaults` in 6 files (`grep -rl UserDefaults`): tool preferences (`StudioViewModel`), tutorial completion (`AppTutorialView`), catalogue caches (`StudioImageCatalogue`, `StudioSoundCatalogue`), `@AppStorage` flags (Onboarding, Welcome, AppFlow). No app-group suite. | keep |
| `NSPrivacyAccessedAPICategoryDiskSpace` — E174.1 (check free space before writing) | `volumeAvailableCapacityForImportantUsage` in `Storage/DeviceStorageManager.swift:100-101`, `Services/StudioExportService.swift:513-514` (export preflight), `App/AppConfig.swift:332`; `.systemFreeSize` in `Services/StudioImageCatalogue.swift:523` (pack download). No screen displays free space to the user, so 85F4.1 is still not declared; `studio.storage.total` shows project bytes, not volume capacity. | keep |
| `NSPrivacyAccessedAPICategoryFileTimestamp` — C617.1 (app container) and 3B52.1 (user-granted files) | `fstat`/`fstatat` identity and change checks in `Storage/DeviceStorageManager.swift` (1050–1278, 1464–1472, 1717–1732), `ViewModels/StudioViewModel.swift:1020,1034`, `ViewModels/SpatterAIViewModel.swift:779,813`; picker-granted inputs in the image/audio import services. `attributesOfItem` at `DeviceStorageManager.swift:630` is an existence check. | keep both reasons |
| `NSPrivacyAccessedAPICategorySystemBootTime` — 35F9.1 (elapsed time) | `ProcessInfo.processInfo.systemUptime` in 10 files (storage idle/page budgets, playback clock, gesture timing, GIF/MP4 export deadlines, mux ownership, audio timeline tick, admin overview). Never sent off-device. | keep |
| Active keyboards (`activeInputModes`) | no match | not declared — correct |
| `NSPrivacyTracking` / tracking domains | no advertising or analytics SDK; only `supabase-swift` is linked | `false` / empty — correct |

Submission steps that remain the owner's: App Privacy answers (account identifiers sent at sign-in; see §5), export-compliance answer, age rating, screenshots from the release commit only (never web renders), review notes stating that connected features show honest unavailable states until the backend is configured, and the two monthly price points only. **Status: DEFERRED / owner-gated** — no build has been archived or uploaded.
