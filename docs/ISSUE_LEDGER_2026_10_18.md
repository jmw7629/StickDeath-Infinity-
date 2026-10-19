# Open-issue evidence ledger — 2026-10-18

Prepared against PR #309 head `c3d87d2` (branch `claude/studio-sdi-overhaul-kurekj`). Nothing here has been posted to GitHub. All 115 open issues were read (body, acceptance bullets and last comment) from the public API on 2026-10-18.

## Closes section for the PR body (CLOSE_ON_MERGE only)

```
Closes #203
Closes #205
Closes #208
Closes #209
```

## Counts

| Status | Count |
| --- | --- |
| CLOSE_ON_MERGE | 4 |
| DEVICE_VERIFY | 31 |
| OWNER_GATED | 34 |
| CODE_REMAINING | 17 |
| EPIC | 29 |
| **Total** | **115** |

## CI basis and rules

- Ran and passed on c3d87d2: all native-production-tests steps (macOS production suites), spatter-production-tests (Linux), backend-candidates (SQL tests, Python tests, backup drill), source-security, website verify, android-debug-build.
- Not yet complete: native-ios-shards and native-ios-build (app build, simulator UI and auth journeys). Nothing that needs those is marked CLOSE_ON_MERGE.
- CLOSE_ON_MERGE = every acceptance bullet is met by code on this branch and by a named automated check that ran. DEVICE_VERIFY = code done, needs simulator/device UI evidence. OWNER_GATED = an owner action is the next step (named). CODE_REMAINING = named code gap. EPIC = closes with its children.
- Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step. It is repeated only where it is the remaining step.
- Finding outside the ledger: `SpatterAIViewModel.pricingGuide` and `docs/BILLING_CONTRACT.md` still describe a free trial; `docs/PLAN_DECISIONS_2026_10_15.md` records no trial (see #207, #259).

## Ledger

| # | Title | Status | Evidence | Remaining / owner action |
| --- | --- | --- | --- | --- |
| #203 | [SDI AI01] Give Spatter accurate screen, tool and document context | CLOSE_ON_MERGE | Typed bounded context `SpatterContextSnapshot` (screen/tool/panel/selection/frame/layer/document stats/revision, no artwork or paths) and `isStale(comparedTo:)` in `StickDeathInfinity/Services/Spatter/SpatterStudioControlRegistry.swift`; cloud snapshot redaction (`sharingNames`) and opt-in `useCloud` in `SpatterAIViewModel`. Tests: `Tests/SpatterConversation` ('changed project revision discards stale cloud reply without altering actual document', redaction/identity-scope checks, unavailable-state classification) in native-production-tests step 'Verify real local and cloud Spatter conversation state'; registry/readiness cases in `Tests/SpatterPlanner` (native-production-tests step 'Verify deterministic brief planner impact primitives registry extensions batches and quality gates'). | None for acceptance. The 'What Spatter sees' panel is not exercised by a native UI journey; that belongs to #124/#265. |
| #205 | [SDI AI03] Make multi-command AI edits atomic, cancellable and reversible | CLOSE_ON_MERGE | `SpatterInstructionBatch` (2-8 lines, one revision, one Undo), `SpatterInstructionPreview.plan`, `SpatterStudioEditSession` deadline/cancellation checkpoints and `revertAppliedEdit`. Tests: `Tests/SpatterPlanner` ('batch commit failures cancellation and intervening edits roll back the whole batch': mid-batch failure, every cancellation checkpoint, clipboard version restored, stale batch keeps intervening user edit, restored document equality) in native-production-tests step 'Verify deterministic brief planner impact primitives registry extensions batches and quality gates'; `Tests/SpatterStudioEditSession` (deadline after preparation, deadline at middle/final precommit checkpoints, overlapping/duplicate request rejection, late cancel) in native-production-tests step 'Verify cancellable Studio edits and factual persistence state'. | None for acceptance. |
| #208 | [SDI AI06] Preserve personality and safe device-local memory controls | CLOSE_ON_MERGE | On-device opt-in memory store with inspect/edit/export/import/reset sheet (`SpatterPersonalMemorySheet`, `StickDeathInfinity/Views/Studio/StudioView.swift`), no inference of absent memory, per-account records. Tests: `Tests/SpatterPersonalMemory` (disabled default, account/guest isolation, actual reset, import/export schema and bounds, symlink/FIFO rejection, memory never crosses the cloud request boundary) in native-production-tests step 'Verify opt-in local Spatter preferences and account isolation'; `Tests/SpatterConversation` (historical brain packs preserved, retired phone/call questions refused) in native-production-tests step 'Verify real local and cloud Spatter conversation state'. | None for acceptance. The sheet itself has no native UI journey; covered by the general native gate #124. |
| #209 | [SDI AI07] Complete authenticated provider-neutral AI transport and budget controls | CLOSE_ON_MERGE | Provider-neutral backend handler `backend/spatter/handler.py` + `providers.ProviderRouter` (atomic model/provider switch, per-attempt timeout, bounded retries) + `metering.py`; client never holds provider keys for the SDI backend. Tests: `backend/spatter/test_handler.py` (missing/malformed/expired/wrong-role tokens refused, null provider 503 with no budget use, 429 budget exhaustion without provider call, provider failure refunds) and `test_metering.py` incl. `ProviderRouterTests` (transient retry, non-transient stop, model switch, invalid config) in backend-candidates step 'Run the Spatter backend handler tests'; `Tests/SpatterClient` and `Tests/SpatterOwnKey` in spatter-production-tests steps 'Compile and execute actual Foundation production source' and 'Verify Spatter plan access and own AI key client against fake transports'. | None for acceptance. Deploying the handler with real provider secrets is an owner deployment step, not part of this issue's acceptance. |
| #124 | [SDI F02] Pass the complete app build and exact-source native regression gates | DEVICE_VERIFY | All native-production-tests steps, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed on c3d87d2. native-ios-shards / native-ios-build (app build, simulator journeys) are still pending on c3d87d2. Last recorded shard result (run 38516791084 on 39f29cb0): auth 19/19, UI shard 0 35 passed / 20 failed. | Green native-ios-shards and native-ios-build on the exact merge head, with xcresult/log/receipt preserved; triage any failing journeys from the original artifacts. |
| #126 | [SDI F04] Publish current source-labelled SwiftUI captures and a native review route | DEVICE_VERIFY | Install/review route documented in `docs/NATIVE_SIMULATOR_REVIEW.md` and `docs/TESTFLIGHT_DISTRIBUTION.md`; the shard job uploads the unsigned simulator app ('Upload native simulator review app'). | Publish captures from the exact-head native shard artifacts once #124 is green; TestFlight depends on owner signing (#266). |
| #127 | [SDI F05] Compare the supplied visual references against actual native layouts | DEVICE_VERIFY | Reference-to-screen map in `docs/VISUAL_REFERENCE_MAP.md` (missing captures marked). | Same-size portrait/landscape/iPad native captures compared against the references; needs the native shards (#124) or a device run. |
| #149 | [SDI S11] Complete gradient, blur, smudge, sharpen and burn effects | DEVICE_VERIFY | PR #309 commit 59b5536 adds the Gradient tool (linear/radial, fade, dither, replayable `.fill` with `StudioGradientDescriptor`, schema 36) and selection-limited Smudge/Blur/Sharpen/Dodge/Burn via `StudioSelectionMask.clip`. native-production-tests steps passed: 'Verify gradient fill, selection masks, wand regions and element hit tests', 'Verify real Smudge pixels replay cache cancellable sessions and exports', 'Verify real Blur pixels replay history cancellable sessions and exported media', 'Verify real Sharpen pixels replay history cancellable sessions and exported media', 'Verify real Dodge and Burn exposure history settings cancellation and exported media'. | Native gesture journeys for the new Gradient tool and selection-limited effects (none run yet; native shards pending). |
| #153 | [SDI S15] Implement wand selection with real tolerance and sampling | DEVICE_VERIFY | PR #309 (59b5536): Wand on drawing layers with tolerance/contiguous/New-Add-Subtract and Feather (`StudioWandRegion`, `StudioSelectionElementHitTest`); Move/Copy/Cut/Delete act on the touched drawings. native-production-tests step 'Verify gradient fill, selection masks, wand regions and element hit tests' passed. | Native journey covering zoomed wand selection and downstream move/delete/copy on the canvas. |
| #170 | [SDI D04] Finish portable project backup, import and restore | DEVICE_VERIFY | Versioned portable bundle export/import with collision-safe IDs and `importPortableProject(droppingMissingAudio:)` (`StudioViewModel.swift`). native-production-tests step 'Verify portable project backups with original assets and cancellation' passed. | Device-to-device round trip, interrupted import and missing-asset recovery on real devices (Files journey in native shards). |
| #171 | [SDI D05] Bound local storage, asset lifetime and cache eviction | DEVICE_VERIFY | Status banner moved to an overlay so save errors no longer change canvas geometry (`StudioView.swift` `.overlay(alignment: .top)` 'studio.status'); recoverable unsaved revisions reported. native-production-tests steps 'Verify actual production device storage and legacy preservation' and 'Verify accurate local storage and safe regenerable cache release' passed. | Re-run the unchanged imported-image journey and a low-space write failure in the native shards / on device. |
| #174 | [SDI P01] Record creator consent and rights for official-channel and marketing publication | DEVICE_VERIFY | Native 'Submit a rendered video' form with rights text, audience, per-destination toggles and terms version (`ProfileView.swift` ~1013-1040); backend consent binding `backend/sql/consent-versions.sql`, `registration.py:_verify_consent`, `test_ingestion.py::test_registration_requires_server_verified_consent` in backend-candidates step 'Run backend Python tests with fake transports'. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step. | Native submission journey (refusal, withdrawn consent, changed render) against a configured test upload service. |
| #180 | [SDI AU08] Synchronize audio transport with animation playback and scrub | DEVICE_VERIFY | Windowed playback beyond 120 s, scrub audition (`StudioAudioScrubAudition` in `AudioPanels.swift`), interruption/route stop notice. native-production-tests steps 'Verify production StudioAudioTimeline', 'Verify production StudioAudioMix', 'Verify actual movie import cold reopen and synchronized mixed MP4' passed. | Route change/headphones/backgrounding and long-project drift measured on a device. |
| #188 | [SDI P02] Validate and moderate real rendered submissions before release | DEVICE_VERIFY | Media validation, consent and content gate at registration, licensed-asset admission (`test_ingestion.py::test_catalogued_assets_are_admitted_with_their_licence_and_unknown_ones_refused`, `test_store_requires_a_registry_before_admitting_credits_and_keeps_the_matched_licence`) in backend-candidates; native Profile -> Publishing status over `sdi_publish_status` (c78e68f). Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step. | Native publishing-status journey showing rejected/pending/unavailable states against a test backend. |
| #199 | [SDI V01] Implement video import with real metadata and managed lifetime | DEVICE_VERIFY | PR #309 (59b5536): decoded movie bytes retained as project-managed media (`AnimationProject.videoSources`, `StudioVideoReference` with measured metadata and trim/speed mapping), pruned with document/undo history. native-production-tests steps 'Verify real video-frame timing orientation cancellation and cleanup' and 'Verify bounded actual movie frame sequences and trim boundaries' passed; new journeys in `Tests/StudioDocument` and `Tests/StudioImageSequence`. | Native Photos/Files permission, cancel and cold-reopen-after-original-removal journey. |
| #200 | [SDI V02] Implement rotoscope extraction at the actual playhead | DEVICE_VERIFY | Playhead-to-source mapping (`StudioVideoFrameImportService.Mapping`), variable-frame-rate classification tests, reference layers (`Layer.isReference`) excluded from PNG/GIF/MP4. native-production-tests steps 'Verify real video-frame timing orientation cancellation and cleanup' and 'Verify bounded actual movie frame sequences and trim boundaries' passed. | Native rotoscope journey at the actual playhead (seek, cancel, repeat). |
| #206 | [SDI AI04] Build editable animations from varied natural-language briefs | DEVICE_VERIFY | `SpatterMultiClauseBrief` (1-3 actors, per-clause timing, seed), `StudioCommand.appendFrames`, storyboard receipts, golden fingerprints. native-production-tests steps 'Verify deterministic brief planner impact primitives registry extensions batches and quality gates', 'Verify editable procedural stick motion and real movie export' and 'Verify cancellable Studio edits and factual persistence state' passed. | Playback of generated briefs in the app: native journey `testSpatterLocalMotionEditsExportsAndReopens` (Tests/NativeUI) is pending in the native shards. |
| #211 | [SDI AD03] Build the exact-render approval queue and decision history | DEVICE_VERIFY | Native admin review screen with digest/version-bound preview renewal (local 439cc79, merged), approval SQL `backend/sql/admin-approval.sql`, digest invalidation test `backend/sql/tests/150_review_source_digest.sql` in backend-candidates step 'Apply SQL candidates in README order and run the SQL tests'. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step. | Play a full-resolution render with audio in the native admin against a configured upload/preview service; needs the owner identity (#246). |
| #214 | [SDI AI10] Build revision and approval workflow for generated videos | DEVICE_VERIFY | PR #309 (898a644): review list returns storyboard, source_project_digest and quality report; `sdi_review_bind_source_digest`; approval invalidated on a changed digest (`150_review_source_digest.sql`) in backend-candidates. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step. | Native admin presentation of script/storyboard/project/preview on a configured backend. |
| #215 | [SDI AI11] Make Spatter invoke real export and return factual artifacts | DEVICE_VERIFY | Direct MP4 and GIF handoff from Spatter into the export panel (`StudioView.swift` `spatterMovieRequest`/`spatterGIFRequest`), receipts from the real exporter. native-production-tests steps 'Verify MP4 panel state and completion-owned share lifetime' and 'Verify GIF panel and completion-owned sharing leases' passed. | Native journey `testSpatterDirectMP4PreviewRetainsEditableProject` and a GIF equivalent in the native shards. |
| #219 | [SDI SO03] Implement feed video playback, share and creator-permitted export | DEVICE_VERIFY | HTTPS-only `FeedPost.safeURL`, `ShareLink`, export only when `allow_export` (`FeedExportPolicy`), creator toggle via `sdi_export_consent`; `Tests/CommunityFeed` in spatter-production-tests step 'Verify community feed and profile clients against fake transports'. | Native playback/mute/autoplay/bandwidth behavior against real approved media. |
| #224 | [SDI SO06] Finish genuine profile editing and creator portfolios | DEVICE_VERIFY | Handle rules (`CreatorHandle`), avatar downscale/upload (`AvatarUploadService`), portfolio from approved renditions, unavailable follower totals shown honestly; `Tests/CommunityFeed` in spatter-production-tests. | Native profile edit/account-switch journey; owner must confirm the `avatars` storage bucket exists on the live project. |
| #232 | [SDI R05] Synchronize shared Studio edits with versioned commands | DEVICE_VERIFY | PR #309 (e06ab3e): `StudioRoomBridge` (`ViewModels/StudioViewModel+Rooms.swift`) publishes committed Studio commands and applies remote ones via the strict decoder; `Tests/CommunityRooms` (18/18) in spatter-production-tests step 'Verify Rooms client, invitation consent and versioned command sync'. | Two authorized clients editing frames/layers/audio against a test backend (reconnect, undo ownership, revocation). |
| #233 | [SDI R06] Transfer selected collaboration assets with quotas and cleanup | DEVICE_VERIFY | Bounded room asset transfer (`RoomAssetTransfer`, `sdi_room_asset` in `backend/sql/rooms-v2.sql`, `tests/035_rooms_rebase_assets.sql`), scheduled `room_asset_sweep` (461d61e, `test_workers.py`) in backend-candidates. | Resume/cancel/corrupt-asset and expired-membership cleanup across two devices. |
| #242 | [SDI P07] Provide six configurable quick-share destinations and native file sharing | DEVICE_VERIFY | Six configurable destinations (iOS `Tests/StudioQuickShare` in native-production-tests step 'Verify six quick-share destinations and format choices'; Android `QuickShareTest` in android-debug-build 'Compile debug application and instrumentation APK, run JVM unit tests'); Save to Files for MP4/GIF/PNG. | Share to installed and missing destination apps, cancellation and retry on a device. |
| #245 | [SDI P10] Expose publish progress, cancellation, retry and removal status | DEVICE_VERIFY | Profile -> Publishing reads `sdi_publish_status` with retry/cancel/removal gating (c78e68f); admin publish-stage view (898a644); `Tests/AccountServices` in spatter-production-tests step 'Verify support, privacy choices, server entitlement and notification clients'. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step. | Native and admin status journeys across an app/backend restart on a test backend. |
| #247 | [SDI AD04] Build moderation, reports, blocks and takedown controls | DEVICE_VERIFY | Queues for feed, War Room, room reports and feed-removal appeals; server-enforced actor separation; `Tests/CommunityAdmin` in spatter-production-tests step 'Verify admin step-up policy, health, agents, finance and moderation queues'; `docs/CONTENT_POLICY.md` section 4. | Native/web admin moderation journey on a test backend. |
| #257 | [SDI AD07] Expose service health, backups and release operations safely | DEVICE_VERIFY | `AdminHealthContent` over `sdi_admin_health`; restore-drill reporting (`verify_backup.sh --report`, `restore_drill` in `backend/sql/admin-hardening.sql`, `AdminOperationsPanels.swift`); `Tests/CommunityAdmin` in spatter-production-tests; backend-candidates step 'Rehearse backup and restore on the throwaway cluster'. | Native admin health/backup view on a configured backend. |
| #259 | [SDI B08] Build accurate pricing, annual selection and subscription settings | DEVICE_VERIFY | `SubscriptionView`/`ChoosePlanView` show `Product.displayPrice` or 'Plans are not configured yet'; trial copy returns nil (c78e68f); `Tests/BillingPlans` in native-production-tests step 'Verify billing plan catalogue, StoreKit state machine and plan copy'. | Locale formatting and purchase-state copy on a device/StoreKit sandbox. Also correct `docs/BILLING_CONTRACT.md` (lines ~67, 136-142 still describe a trial; `docs/PLAN_DECISIONS_2026_10_15.md` says no trial). |
| #262 | [SDI SEC06] Implement account export, deletion and consent-retention controls | DEVICE_VERIFY | `sdi_account_lifecycle` request/cancel/export in `AuthService.swift` and Settings/Profile; `backend/ops/sweeps.py` deletion run (`test_workers.py::SweepTests`) in backend-candidates. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step. | Native deletion/export journey with outstanding room/billing/publication records on a test backend. |
| #264 | [SDI QA01] Verify accessibility and adaptive layouts across the native app | DEVICE_VERIFY | Dynamic Type helpers, contrast token, `testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize` (Tests/NativeUI), `docs/ACCESSIBILITY_DYNAMIC_TYPE.md`. | The audit journey and portrait/landscape/iPad captures; native-ios-shards / native-ios-build (app build, simulator journeys) are still pending on c3d87d2. VoiceOver needs a person on a device. |
| #265 | [SDI QA02] Run the complete native user journey and regression acceptance gate | DEVICE_VERIFY | `testCompleteProjectJourneyCreateDrawLayerAudioExportPNGAndColdReopen` (Tests/NativeUI). | native-ios-shards / native-ios-build (app build, simulator journeys) are still pending on c3d87d2. Services journeys (auth, feed, rooms, War Room, approval) need a configured isolated test backend. |
| #270 | [SDI W02] Build the responsive product website from real native app capabilities | DEVICE_VERIFY | Static site with captures page (`website/screens.html`), FAQ (`website/about.html`), store/help pages; website verify job (`check_help.mjs --check`, `build_site.mjs --check`, `a11y_perf.mjs`) passed. | iPhone Safari + VoiceOver check of the deployed review build; deployment depends on #269. Confirm every capture is source-labelled from an exact native run. |
| #272 | [SDI W04] Build a searchable help center and bounded customer support intake | DEVICE_VERIFY | Signed-in support requests with receipts on the web (`website/account.js`, 5ec9711) and native (`SupportClient`, `SupportRequestsView`, c78e68f); `Tests/AccountServices` in spatter-production-tests; `backend/sql/support-requests.sql`; help check in website verify. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step. | Authorized submit/duplicate/withdraw/delete on a deployed test backend from a mobile browser and the app. |
| #285 | [SDI AD10] Build the admin user directory and account actions (search, block, suspend, appeals) | DEVICE_VERIFY | Directory (sign-up source, report counts), block/suspend/restore/reset-flags actions with reasons and audit, affected-member notices (3fae20c); SQL test `150_admin_user_flags_notices.sql` (non-admin denial) in backend-candidates; web admin list. | Native/web admin directory journey on a test backend. |
| #130 | [SDI A02] Complete Sign in with Apple and private-relay account handling | OWNER_GATED | Apple sign-in delegate with cancellation mapping, private-relay handle fallback, credential-revocation observer (`AuthService.swift`); `testAppleUsernameFallsBackForPrivateRelayAndDisplayNameIsBounded` in the auth shard (pending). | Owner: enable Sign in with Apple for the App ID, create the Services ID/key and configure the Supabase Apple provider; then sign in on a physical device (first authorization, private relay, revoke in Settings). |
| #131 | [SDI A03] Complete Google sign-in and secure callback handling | OWNER_GATED | OAuth browser session cancel -> no banner, `access_denied` -> calm denial (`OAuthBrowserSession`, `oauthCallbackDenial`). | Owner: create the Google OAuth client and enable the Supabase Google provider with the app's redirect; then login/logout/relaunch on device. |
| #132 | [SDI A04] Complete GitHub sign-in with minimal OAuth permissions | OWNER_GATED | Scopes limited to `read:user user:email`; denial mapping and tests in the auth suite. | Owner: register the GitHub OAuth App (callback = Supabase) and enable the provider; then native callback cancel/replay and sign-in. |
| #133 | [SDI A05] Complete Microsoft sign-in and supported account types | OWNER_GATED | Tenant hint (`ProviderHint.microsoft`), `AADSTS` error mapping, tenant section in `docs/AUTH_PROVIDER_CONFIGURATION.md`. | Owner: decide personal/work/school support, register the Azure app and enable the Supabase Azure provider; then native redirect and restoration. |
| #136 | [SDI A08] Finish branded splash and reliable startup routing | OWNER_GATED | `SDIBrandMark` renders the `SDIBrandSkull` asset when present (`SplashScreenView.swift`); Reduce Motion respected; routing in `AppFlowView.startupDestination`, pinned by `testDeepLinkRouterClassifiesBeforeNavigation`. | Owner: supply the owned skull/red-glow artwork as the `SDIBrandSkull` asset; then cold/warm launch check on device. |
| #186 | [SDI SEC01] Inventory the existing backend and admin before configuration changes | OWNER_GATED | Candidate inventory in `docs/BACKEND_ARCHITECTURE_PUBLIC.md` and `docs/RLS_REVIEW.md`. | Owner: run the read-only live backend/admin inventory with project credentials and keep the findings private. |
| #190 | [SDI D07] Implement bounded temporary uploads and post-publication cleanup | OWNER_GATED | Bounded staging, retention and post-publication cleanup (feed publisher, sweeps; `test_workers.py`) in backend-candidates; encryption delegated to the host volume (`docs/OPERATING_RUNBOOK.md`). | Owner: provision an encrypted staging volume on the host and deploy the workers; then a crash-safety cleanup drill. |
| #191 | [SDI AU03] Expand licensed free sound packs with deduplication and provenance | OWNER_GATED | Sound credits through MP4 manifests (`StudioSoundCredits.swift`); provenance verifier `scripts/verify_sound_catalogue_provenance.py` in spatter-production-tests step 'Verify bundled sound catalogue provenance and deduplication' (2,127 distinct sounds). | Owner: source licensed audio for the missing music/ambience/comedy categories and downloadable packs. |
| #194 | [SDI IM02] Curate thousands of original or free StickDeath-style Studio images | OWNER_GATED | Catalogue/pack code with rights gate; 2,025 distinct images (207 bundled + 1,818 optional) per earlier audit; CI 'Verify licensed image catalogue and every original PNG'. | Owner: provide or approve rights-cleared image sources to reach the curation target. |
| #213 | [SDI AI09] Establish measurable motion, artwork and audio quality gates | OWNER_GATED | `SpatterQualityReport` brief-scope report; MP4 manifests record decoded frame count/duration and project digest; `draft_queue` refuses review without decoded counts (`test_a_quality_record_without_decoded_movie_counts_never_reaches_review`) in backend-candidates; planner quality cases in native-production-tests. | Owner: choose the reference clips and visual thresholds (creative tuning is owner-managed per AGENTS.md 2026-10-09). |
| #238 | [SDI SEC05] Protect provider credentials and OAuth refresh tokens | OWNER_GATED | Server-only OAuth flow (`backend/publishing/owner_oauth.py`), legacy client credential views deleted, native-production-tests step 'Scan release sources for credentials' passed. | Owner: place provider keys/refresh tokens in the approved server secret store and run a rotation/revocation drill on the live deployment. |
| #239 | [SDI P04] Connect the existing owner YouTube channel through secure OAuth | OWNER_GATED | `backend/publishing/owner_oauth.py` server-side flow with minimal scopes. | Owner: create the Google Cloud OAuth client and consent screen, then connect the existing channel through the private flow. |
| #241 | [SDI P06] Render the small SDI watercolor logo on official-channel copies | OWNER_GATED | PR #309 (03ca826): `StudioChannelRendition` placement/contrast/refusal rules; exporter composites the `SDIChannelWatercolorMark` asset only on channel copies and refuses when it is absent. spatter-production-tests step 'Verify official-channel mark placement, contrast and refusal rules' and the macOS movie-export steps in native-production-tests passed. | Owner: supply the approved transparent watercolor SDI mark as `SDIChannelWatercolorMark`. |
| #243 | [SDI P08] Build honest destination adapters and owner-approved social marketing | OWNER_GATED | Dry-run destination adapters (`backend/publishing/destinations.py`), `test_workers.py::DestinationTests` in backend-candidates. | Owner: confirm platform terms and provide server-held credentials per destination before any adapter leaves dry-run. |
| #246 | [SDI AD02] Securely provision the owner command-center identity | OWNER_GATED | `sdi_provision_owner` (service role, no password) tested in SQL test 060 in backend-candidates. | Owner: run private owner enrollment with MFA on the live project; then verify owner access and ordinary-user denial. |
| #249 | [SDI B01] Verify and reuse the existing Stripe account in read-only mode | OWNER_GATED | Procedure and test/live separation in `docs/BILLING_CONTRACT.md` and `docs/LAUNCH_REHEARSAL.md` section E; no Stripe call made. | Owner: connect the existing Stripe account read-only and confirm identity, currency and existing products. |
| #250 | [SDI B02] Define 4.99 and 9.99 monthly plans and approved annual pricing | OWNER_GATED | `backend/billing/contract.py:ApprovedProduct` refuses annual without owner configuration; downgrade without data loss in `070_billing_lifecycle_finance.sql`; `test_billing.py` in backend-candidates; `docs/PLAN_DECISIONS_2026_10_15.md`. | Owner: approve annual amounts (or none) and the entitlement matrix, and create the 4.99/9.99 products in App Store Connect and Stripe. |
| #251 | [SDI B03] Implement StoreKit purchase, restore and subscription states | OWNER_GATED | StoreKit client and server entitlement reconciliation (`reconcileEntitlementsWithServer`, c78e68f); `Tests/BillingPlans` in native-production-tests; `Tests/AccountServices` in spatter-production-tests. | Owner: create App Store Connect subscription products and sandbox testers; then sandbox purchase/restore/revocation on device. |
| #254 | [SDI B07] Build a provider-backed finance ledger and reconciliation report | OWNER_GATED | `backend/sql/billing-finance.sql` record/report (6 discrepancy classes, period summary, exports, agent costs), `070_*.sql` in backend-candidates; web admin finance forms (5ec9711). | Owner: Stripe access (#249) so actual revenue/fees/refunds/payouts reconcile by provider IDs; tax remains a manual import. |
| #256 | [SDI SEC08] Verify backup restoration, audit integrity and incident response | OWNER_GATED | backend-candidates step 'Rehearse backup and restore on the throwaway cluster' (`scripts/backend/verify_backup.sh`); runbooks updated. | Owner: run the restore drill against isolated copies of the live project. |
| #260 | [SDI SEC03] Retire legacy messaging and calling entry points across the backend | OWNER_GATED | Retired sources deleted; source-security step 'Verify retired messaging and calls cannot enter the native target' (`scripts/verify_retired_communications.py`: native target, deep links, Spatter prompt, Android, backend SQL/Python) passed; SQL retirement candidate `backend/sql/security-retire-communications.sql` tested by `130_security_lifecycle.sql` in backend-candidates. | Owner: apply `security-retire-communications.sql` to the live project and run `sdi_legacy_communication_exposure` there (the verifier states it does not inspect a live database). |
| #261 | [SDI SEC04] Define and enforce content, age and moderation rules for animated submissions | OWNER_GATED | `docs/CONTENT_POLICY.md`; submission refused without `min_age` attestation (`090_*.sql`) in backend-candidates. | Owner: legal review of the policy text and the minimum-age decision. |
| #266 | [SDI QA03] Deliver a signed native review build and physical-device performance evidence | OWNER_GATED | `Tests/NativePerformance/StudioPerformanceUITests.swift`, `docs/PERFORMANCE_MEASUREMENT_PROTOCOL.md`. | Owner: signing identity, device enrollment and TestFlight access; then on-device performance runs. |
| #269 | [SDI W01] Verify existing website source, hosting, domain and reversible deployment | OWNER_GATED | `docs/WEBSITE_HOSTING.md` (GoDaddy decision, Netlify migration, rollback), `docs/WEBSITE_INVENTORY.md`. | Owner: GoDaddy cPanel upload, nameserver switch preserving the Microsoft 365 records, SSL, then Netlify removal; private reference-source inventory. |
| #271 | [SDI W03] Connect a secure website account and subscription portal | OWNER_GATED | Account page plans from PLAN_DECISIONS, checkout/portal only when `account-config.js` billing is set (5ec9711); `stripe_checkout.py` portal action. | Owner: Stripe test-mode products/keys (#249/#250) and a deployed checkout function; then isolation/callback/payment-failure tests. |
| #273 | [SDI W05] Publish versioned product policies and actionable privacy choices | OWNER_GATED | Versioned policies `website/policies/*-v1.html` (1.0-draft), `sdi_consent_action` publish/current/accept, native policy links and marketing permission grant/withdraw (c78e68f), `PrivacyChoicesView`. | Owner: legal review and approval of the draft policies, then publish them as effective. |
| #276 | [SDI W08] Implement consented customer email and lifecycle delivery | OWNER_GATED | `notifications.sql` prefs/suppressions, `backend/mail/` templates, dedup queue, blast cadence (fe01d2d); `test_mail.py` with an in-process SMTP sink in backend-candidates. | Owner: authorize the sender domain/mailbox (SPF/DKIM) on the existing provider. |
| #278 | [SDI W10] Run the complete app-business launch rehearsal and operating handoff | OWNER_GATED | `docs/LAUNCH_REHEARSAL.md` script and access inventory; offline part A run. | Owner: sandbox parts B/C need Stripe test mode, a configured test backend and provider sandboxes. |
| #279 | [SDI AI13] Generate 20-60 second videos from YouTube and web sources with rights gating | OWNER_GATED | PR #309 (e06ab3e): `setSourceReference` command, `SpatterSourceRightsGate`, 20-60 s bound with length receipt; `Tests/SpatterPlanner` in native-production-tests. | Owner: decide the source-rights rule (which sources and bases are allowed). |
| #280 | [SDI AI14] Define the StickDeath blood and impact style spec as reusable motion primitives | OWNER_GATED | `SpatterImpactPrimitive` deterministic streaks/burst/pooling/fade, `docs/SPATTER_IMPACT_STYLE_SPEC.md`; planner case 'impact primitive is deterministic, bounded, pools blood and matches its golden fingerprint' in native-production-tests. | Owner: reference clips and style tuning (owner-managed). Code follow-up: the goldens are geometry fingerprints (`Golden.impactBlood`), not the decoded-pixel tests the issue asks for. |
| #281 | [SDI W11] Support mailbox agent for support@stickdeathinfinity.com | OWNER_GATED | Support intake `backend/sql/support-requests.sql`, web/native support clients. | Owner: mailbox access method and credentials for support@stickdeathinfinity.com. |
| #283 | [SDI W13] Add Discord and Facebook adapters and agent-scheduled daily/weekly marketing cadence | OWNER_GATED | Discord/Facebook/X dry-run adapters, `sdi_marketing_cadence_due` queues only approved drafts, email-blast cadence with consent/suppression (fe01d2d, `test_mail.py`) in backend-candidates; `docs/BRAND_VOICE.md` draft. | Owner: approve the brand voice and provide platform credentials/terms confirmation. |
| #289 | [SDI AND04] Android billing, push and Play Store release | OWNER_GATED | `docs/ANDROID_DELIVERY.md` release checklist, data-safety and listing drafts. | Owner: Play Console account, signing key custody, Play Billing products and Firebase project. |
| #290 | [SDI W14] Push notifications and in-app announcements for iOS and Android | OWNER_GATED | `notifications.sql` compose/schedule/cancel/fan-out, `backend/notifications/push.py` with `SinkTransport`, `test_workers.py::PushWorkerTests` in backend-candidates; iOS preferences/inbox (`NotificationsClient`, `NotificationCenterView`); Android `NotificationPreferences.kt`. | Owner: APNs key and FCM project; then test-device delivery. |
| #142 | [SDI S04] Complete airbrush, watercolor, neon and calligraphy behavior | CODE_REMAINING | Airbrush Build-up, Watercolor Bleed/Grain, Neon core and Additive glow (plus-lighter), calligraphy angle/speed: `Tests/StudioBrushes`, alpha-lock cases in `Tests/StudioBrushIntegration`; native-production-tests steps 'Verify deterministic native brush geometry and actual pixels', 'Verify native brush edits, live rendering and persistence', 'Verify actual SwiftUI renderer pixels on macOS'. | Add an MP4 frame-vs-canvas comparison for these families (no MP4 assertion in `Tests/StudioBrushIntegration`); then the native gesture journey. |
| #198 | [SDI IM06] Provide safe asset removal, attribution and catalogue updates | CODE_REMAINING | Quarantine (`ReleasePolicy`), image credits, sound credits in MP4 manifests. | Catalogue revision update path beyond `advance(revision:)` and offline version-change/missing-asset tests. |
| #201 | [SDI V03] Complete video trim, orientation, timing and optional audio extraction | CODE_REMAINING | Soundtrack extraction with mapping persisted on `AudioClip.videoMapping` (59b5536); source in/out and speed controls (`StudioImageImportPanel.swift`); native-production-tests step 'Verify real movie soundtrack trim speed cancellation and owned cleanup'. | Rotation/aspect controls are not exposed in the video panel; then final MP4 A/V sync and portrait/landscape cold reopen on device. |
| #204 | [SDI AI02] Extend Spatter's validated command registry across Studio | CODE_REMAINING | 37+ grammars, catalog v4 with `fillAtPoint`, `selectElements`, `setSourceReference` (e06ab3e); injection/malformed tests in `Tests/SpatterPlanner` (native-production-tests). | `SpatterStudioControlRegistry` marks Export and Add Picture `blocked` and Lasso/Wand/Gradient/Smudge/Blur/Sharpen/Dodge/Burn `manual`; the issue asks for routes covering selections, import and export (or an owner decision narrowing scope). |
| #207 | [SDI AI05] Finish grounded customer-service and in-app help answers | CODE_REMAINING | Versioned guide (`currentGuideVersion`), support/hostile cases in `Tests/SpatterConversation` and `Tests/SpatterEval/briefs.v2.json` (75 briefs) in native-production-tests. | `SpatterAIViewModel.pricingGuide` still says 'A trial applies to both Creator and Pro', contradicting `docs/PLAN_DECISIONS_2026_10_15.md` (no free trial). Fix the guide and add a conversation assertion. |
| #212 | [SDI AI08] Implement a persistent daily original-video draft queue | CODE_REMAINING | `backend/spatter/draft_queue.py` with leases, retries, missed-day reporting, quality-record gate; `test_draft_queue.py` in backend-candidates step 'Run the Spatter backend handler tests'. Without a renderer every job fails with the owner-gate message. | Implement the headless draft renderer the owner referenced on 2026-10-18 (not present at c3d87d2); then owner capacity approval. |
| #216 | [SDI AI12] Run adversarial and end-to-end Spatter acceptance evaluation | CODE_REMAINING | 75-brief corpus, runner writes a JSON report with seed; native-production-tests step 'Verify Spatter brief evaluation suite against production Studio commands' passed. | Results are pass/fail per brief (no per-dimension factuality/adherence/editability/reversibility/privacy/quality scores) and the JSON is written to the runner temp directory without an upload-artifact step, so failed cases are not preserved. |
| #217 | [SDI SO01] Build the real social video wall and pagination | CODE_REMAINING | `FeedTimeline.merge` dedupe, 40-page cap, offline page-0 cache, all states in `HomeFeedView`; `FeedPublisher` digest-verified copy (`test_workers.py::FeedPublisherTests`); `Tests/CommunityFeed` in spatter-production-tests. | Feed thumbnails for published copies; then native comparison with the Photo4 card reference. |
| #220 | [SDI SO04] Complete Trending, Recent, Following and Featured feeds | CODE_REMAINING | Four server rankings with rule text, server-side blocked/removed filtering (`010_feed_integrity.sql`) in backend-candidates. | Cursor-stable paging (still offset with a 40-page cap in `video-feed.sql`). |
| #234 | [SDI R07] Finish native room browser, join flow and active-project handoff | CODE_REMAINING | Room browser/join/handoff in `CollabRoomView` with sync counts (e06ab3e). | The owner-approved (2026-10-18) project snapshot hand-off to approved members (size cap, checksum, member-only download, expiry, import as new project) is not on c3d87d2; then native two-client journeys. |
| #248 | [SDI AD05] Control AI providers, budgets, daily drafts and emergency stop | CODE_REMAINING | `AdminAgentsContent` over `sdi_agent_admin` (caps, permissions, emergency stop), typed agent commands (898a644); `Tests/CommunityAdmin` in spatter-production-tests. | Masked provider-configuration health view is not implemented. |
| #263 | [SDI SEC07] Bound resource use, abuse rates and provider costs | CODE_REMAINING | Quotas across admin/feed/support/rooms/push/email/finance/marketing; publishing slot cap (461d61e) in backend-candidates. | Burst, duplicate-job and quota-exhaustion fixtures are not written. |
| #275 | [SDI W07] Verify website discovery, accessibility, performance and private analytics | CODE_REMAINING | Sitemap/robots, private pages excluded, local opt-in counters only; website verify `a11y_perf.mjs` budgets passed. | No aggregate site/product event collection or funnel report exists (owner may instead narrow the scope to 'no analytics'). |
| #284 | [SDI AD09] Build the agent management console (pause, permissions, budgets, logs) | CODE_REMAINING | Agent list/pause/caps/instructions with rollback, emergency stop, typed commands (898a644); `Tests/CommunityAdmin` in spatter-production-tests. | Approval inbox for agent proposals above their caps. |
| #286 | [SDI AND01] Android app: architecture decision and parity plan | CODE_REMAINING | Parity matrix in `docs/ANDROID_DELIVERY.md`; shared fixtures `Tests/SDIFixtures` verified in android-debug-build 'Verify shared .sdi fixtures match their generator and expectations'. | iOS-side opening of the shared fixtures and a both-client re-export comparison; owner sign-off on the architecture decision. |
| #288 | [SDI AND03] Android account, community, collaboration and Spatter parity | CODE_REMAINING | Android War Room, challenges, room command sync, account lifecycle and notification clients with JVM tests (215ebd0) in android-debug-build. | Android auth (email/Google/guest) and network access are not implemented, so no authenticated journey is possible yet. |
| #291 | [SDI QA05] Crash reporting and privacy-respecting product analytics (iOS, Android, web) | CODE_REMAINING | Opt-in diagnostics contract/queue/uploader (`Tests/Diagnostics` in native-production-tests step 'Verify opt-in diagnostics contract, queue and uploader'), admin diagnostics summary (898a644), Android local crash reports. | Crash reporting with symbolication/release tagging on iOS and web, and crash-spike alerts in the command center. |
| #3 | [SDI epic] Delivery inventory, acceptance traceability and backlog maintenance | EPIC | Children: #125 closed, #128 closed, #265 DEVICE_VERIFY, #267 closed | Closes when its 1 open child issue(s) close. |
| #4 | [SDI epic] Native build, regression and release evidence | EPIC | Children: #123 closed, #124 DEVICE_VERIFY, #266 OWNER_GATED | Closes when its 2 open child issue(s) close. |
| #5 | [SDI epic] Preserve historical projects and completed implementation | EPIC | Children: #169 closed, #123 closed, #170 DEVICE_VERIFY | Closes when its 1 open child issue(s) close. |
| #6 | [SDI epic] Reference-faithful native visual and accessibility verification | EPIC | Children: #127 DEVICE_VERIFY, #264 DEVICE_VERIFY | Closes when its 2 open child issue(s) close. |
| #7 | [SDI epic] Shared visual tokens and adaptive native layouts | EPIC | Children: #139 closed, #140 closed, #127 DEVICE_VERIFY, #264 DEVICE_VERIFY | Closes when its 2 open child issue(s) close. |
| #8 | [SDI epic] Splash, welcome and truthful onboarding | EPIC | Children: #136 OWNER_GATED, #137 closed | Closes when its 1 open child issue(s) close. |
| #9 | [SDI epic] Apple, Google, GitHub and Microsoft sign-in with session restoration | EPIC | Children: #129 closed, #130 OWNER_GATED, #131 OWNER_GATED, #132 OWNER_GATED, #133 OWNER_GATED, #134 closed, #135 closed | Closes when its 4 open child issue(s) close. |
| #10 | [SDI epic] Profiles, ownership and optional public achievements | EPIC | Children: #224 DEVICE_VERIFY, #227 closed | Closes when its 1 open child issue(s) close. |
| #11 | [SDI epic] Native navigation, Rooms and protected routes | EPIC | Children: #138 closed, #234 CODE_REMAINING, #210 closed | Closes when its 1 open child issue(s) close. |
| #12 | [SDI epic] Shared native components and honest service states | EPIC | Children: #264 DEVICE_VERIFY, #140 closed, #138 closed | Closes when its 1 open child issue(s) close. |
| #13 | [SDI epic] Current SwiftUI review captures, Simulator and TestFlight route | EPIC | Children: #126 DEVICE_VERIFY, #266 OWNER_GATED | Closes when its 2 open child issue(s) close. |
| #14 | [SDI epic] Device-first projects, crash recovery and backups | EPIC | Children: #168 closed, #170 DEVICE_VERIFY, #171 DEVICE_VERIFY, #172 closed | Closes when its 2 open child issue(s) close. |
| #15 | [SDI epic] Minimal server storage and verified temporary-media cleanup | EPIC | Children: #190 OWNER_GATED, #262 DEVICE_VERIFY, #189 closed, #245 DEVICE_VERIFY | Closes when its 3 open child issue(s) close. |
| #16 | [SDI epic] Licensed dependencies and thousands of redistributable assets | EPIC | Children: #173 closed, #194 OWNER_GATED, #195 closed, #198 CODE_REMAINING | Closes when its 2 open child issue(s) close. |
| #17 | [SDI epic] Studio project library and lifecycle | EPIC | Children: #167 closed | All listed children are closed; close the epic when the native gate (#124/#265) is accepted. |
| #18 | [SDI epic] Canonical Studio canvas, tools and rendered output | EPIC | Children: #141 closed, #142 CODE_REMAINING, #143 closed, #144 closed, #145 closed, #146 closed, #147 closed, #148 closed, #149 DEVICE_VERIFY, #150 closed, #151 closed, #152 closed, #153 DEVICE_VERIFY, #154 closed, #155 closed, #156 closed, #157 closed | Closes when its 3 open child issue(s) close. |
| #19 | [SDI epic] Single snapping toolbar and tool-specific submenus | EPIC | Children: #139 closed, #140 closed | All listed children are closed; close the epic when the native gate (#124/#265) is accepted. |
| #29 | [SDI epic] Complete every visible Studio control | EPIC | Children: #158 closed, #159 closed, #160 closed, #161 closed, #162 closed, #163 closed, #164 closed, #165 closed, #166 closed | All listed children are closed; close the epic when the native gate (#124/#265) is accepted. |
| #30 | [SDI epic] Audio, image/video import and real media export | EPIC | Children: #175 closed, #176 closed, #191 OWNER_GATED, #192 closed, #177 closed, #178 closed, #179 closed, #180 DEVICE_VERIFY, #193 closed, #181 closed, #196 closed, #197 closed, #199 DEVICE_VERIFY, #200 DEVICE_VERIFY, #201 CODE_REMAINING, #182 closed, #183 closed, #184 closed, #185 closed, #202 closed | Closes when its 5 open child issue(s) close. |
| #31 | [SDI epic] Spatter support, editable video creation and owner-approved daily drafts | EPIC | Children: #203 CLOSE_ON_MERGE, #204 CODE_REMAINING, #205 CLOSE_ON_MERGE, #206 DEVICE_VERIFY, #207 CODE_REMAINING, #208 CLOSE_ON_MERGE, #209 CLOSE_ON_MERGE, #212 CODE_REMAINING, #213 OWNER_GATED, #214 DEVICE_VERIFY, #215 DEVICE_VERIFY, #216 CODE_REMAINING | Closes when its 12 open child issue(s) close. |
| #32 | [SDI epic] Consented official YouTube and user-selected social publishing | EPIC | Children: #174 DEVICE_VERIFY, #188 DEVICE_VERIFY, #189 closed, #239 OWNER_GATED, #240 closed, #241 OWNER_GATED, #242 DEVICE_VERIFY, #243 OWNER_GATED, #244 closed, #245 DEVICE_VERIFY | Closes when its 7 open child issue(s) close. |
| #116 | [SDI] Complete native app delivery — Studio-first build tracker | EPIC | Children: #3 EPIC, #4 EPIC, #5 EPIC, #6 EPIC, #7 EPIC, #8 EPIC, #9 EPIC, #10 EPIC, #11 EPIC, #12 EPIC, #13 EPIC, #14 EPIC, #15 EPIC, #16 EPIC, #17 EPIC, #18 EPIC, #19 EPIC, #29 EPIC, #30 EPIC, #31 EPIC, #32 EPIC, #117 EPIC, #118 EPIC, #119 EPIC, #120 EPIC, #121 EPIC, #122 EPIC, #268 EPIC | Closes when its 28 open child issue(s) close. |
| #117 | [SDI epic] Social video wall and challenge lifecycle | EPIC | Children: #217 CODE_REMAINING, #218 closed, #219 DEVICE_VERIFY, #220 CODE_REMAINING, #223 closed | Closes when its 3 open child issue(s) close. |
| #118 | [SDI epic] Invitation-based Studio collaboration rooms | EPIC | Children: #228 closed, #229 closed, #230 closed, #231 closed, #232 DEVICE_VERIFY, #233 DEVICE_VERIFY, #234 CODE_REMAINING, #235 closed | Closes when its 3 open child issue(s) close. |
| #119 | [SDI epic] War Room video matchups and trustworthy results | EPIC | Children: #221 closed, #222 closed, #236 closed, #225 closed, #226 closed, #237 closed | All listed children are closed; close the epic when the native gate (#124/#265) is accepted. |
| #120 | [SDI epic] Admin command center, approval and operations | EPIC | Children: #210 closed, #246 OWNER_GATED, #211 DEVICE_VERIFY, #247 DEVICE_VERIFY, #248 CODE_REMAINING, #255 closed, #257 DEVICE_VERIFY | Closes when its 5 open child issue(s) close. |
| #121 | [SDI epic] $4.99 and $9.99 subscriptions, annual plans and existing Stripe integration | EPIC | Children: #249 OWNER_GATED, #250 OWNER_GATED, #251 OWNER_GATED, #252 closed, #253 closed, #258 closed, #254 OWNER_GATED, #259 DEVICE_VERIFY | Closes when its 5 open child issue(s) close. |
| #122 | [SDI epic] Authorization, privacy, moderation and release safeguards | EPIC | Children: #186 OWNER_GATED, #187 closed, #260 OWNER_GATED, #261 OWNER_GATED, #238 OWNER_GATED, #262 DEVICE_VERIFY, #263 CODE_REMAINING, #256 OWNER_GATED | Closes when its 7 open child issue(s) close. |
| #268 | [SDI epic] Product website and complete app-business operations | EPIC | Children: #269 OWNER_GATED, #270 DEVICE_VERIFY, #271 OWNER_GATED, #272 DEVICE_VERIFY, #273 OWNER_GATED, #274 closed, #275 CODE_REMAINING, #276 OWNER_GATED, #277 closed, #278 OWNER_GATED | Closes when its 8 open child issue(s) close. |

## Comment text per issue (ready to post)

### #3 — [SDI epic] Delivery inventory, acceptance traceability and backlog maintenance

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #125 closed, #128 closed, #265 DEVICE_VERIFY, #267 closed

**Remaining / owner action:** Closes when its 1 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #4 — [SDI epic] Native build, regression and release evidence

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #123 closed, #124 DEVICE_VERIFY, #266 OWNER_GATED

**Remaining / owner action:** Closes when its 2 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #5 — [SDI epic] Preserve historical projects and completed implementation

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #169 closed, #123 closed, #170 DEVICE_VERIFY

**Remaining / owner action:** Closes when its 1 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #6 — [SDI epic] Reference-faithful native visual and accessibility verification

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #127 DEVICE_VERIFY, #264 DEVICE_VERIFY

**Remaining / owner action:** Closes when its 2 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #7 — [SDI epic] Shared visual tokens and adaptive native layouts

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #139 closed, #140 closed, #127 DEVICE_VERIFY, #264 DEVICE_VERIFY

**Remaining / owner action:** Closes when its 2 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #8 — [SDI epic] Splash, welcome and truthful onboarding

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #136 OWNER_GATED, #137 closed

**Remaining / owner action:** Closes when its 1 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #9 — [SDI epic] Apple, Google, GitHub and Microsoft sign-in with session restoration

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #129 closed, #130 OWNER_GATED, #131 OWNER_GATED, #132 OWNER_GATED, #133 OWNER_GATED, #134 closed, #135 closed

**Remaining / owner action:** Closes when its 4 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #10 — [SDI epic] Profiles, ownership and optional public achievements

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #224 DEVICE_VERIFY, #227 closed

**Remaining / owner action:** Closes when its 1 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #11 — [SDI epic] Native navigation, Rooms and protected routes

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #138 closed, #234 CODE_REMAINING, #210 closed

**Remaining / owner action:** Closes when its 1 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #12 — [SDI epic] Shared native components and honest service states

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #264 DEVICE_VERIFY, #140 closed, #138 closed

**Remaining / owner action:** Closes when its 1 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #13 — [SDI epic] Current SwiftUI review captures, Simulator and TestFlight route

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #126 DEVICE_VERIFY, #266 OWNER_GATED

**Remaining / owner action:** Closes when its 2 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #14 — [SDI epic] Device-first projects, crash recovery and backups

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #168 closed, #170 DEVICE_VERIFY, #171 DEVICE_VERIFY, #172 closed

**Remaining / owner action:** Closes when its 2 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #15 — [SDI epic] Minimal server storage and verified temporary-media cleanup

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #190 OWNER_GATED, #262 DEVICE_VERIFY, #189 closed, #245 DEVICE_VERIFY

**Remaining / owner action:** Closes when its 3 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #16 — [SDI epic] Licensed dependencies and thousands of redistributable assets

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #173 closed, #194 OWNER_GATED, #195 closed, #198 CODE_REMAINING

**Remaining / owner action:** Closes when its 2 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #17 — [SDI epic] Studio project library and lifecycle

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #167 closed

**Remaining / owner action:** All listed children are closed; close the epic when the native gate (#124/#265) is accepted.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #18 — [SDI epic] Canonical Studio canvas, tools and rendered output

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #141 closed, #142 CODE_REMAINING, #143 closed, #144 closed, #145 closed, #146 closed, #147 closed, #148 closed, #149 DEVICE_VERIFY, #150 closed, #151 closed, #152 closed, #153 DEVICE_VERIFY, #154 closed, #155 closed, #156 closed, #157 closed

**Remaining / owner action:** Closes when its 3 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #19 — [SDI epic] Single snapping toolbar and tool-specific submenus

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #139 closed, #140 closed

**Remaining / owner action:** All listed children are closed; close the epic when the native gate (#124/#265) is accepted.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #29 — [SDI epic] Complete every visible Studio control

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #158 closed, #159 closed, #160 closed, #161 closed, #162 closed, #163 closed, #164 closed, #165 closed, #166 closed

**Remaining / owner action:** All listed children are closed; close the epic when the native gate (#124/#265) is accepted.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #30 — [SDI epic] Audio, image/video import and real media export

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #175 closed, #176 closed, #191 OWNER_GATED, #192 closed, #177 closed, #178 closed, #179 closed, #180 DEVICE_VERIFY, #193 closed, #181 closed, #196 closed, #197 closed, #199 DEVICE_VERIFY, #200 DEVICE_VERIFY, #201 CODE_REMAINING, #182 closed, #183 closed, #184 closed, #185 closed, #202 closed

**Remaining / owner action:** Closes when its 5 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #31 — [SDI epic] Spatter support, editable video creation and owner-approved daily drafts

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #203 CLOSE_ON_MERGE, #204 CODE_REMAINING, #205 CLOSE_ON_MERGE, #206 DEVICE_VERIFY, #207 CODE_REMAINING, #208 CLOSE_ON_MERGE, #209 CLOSE_ON_MERGE, #212 CODE_REMAINING, #213 OWNER_GATED, #214 DEVICE_VERIFY, #215 DEVICE_VERIFY, #216 CODE_REMAINING

**Remaining / owner action:** Closes when its 12 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #32 — [SDI epic] Consented official YouTube and user-selected social publishing

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #174 DEVICE_VERIFY, #188 DEVICE_VERIFY, #189 closed, #239 OWNER_GATED, #240 closed, #241 OWNER_GATED, #242 DEVICE_VERIFY, #243 OWNER_GATED, #244 closed, #245 DEVICE_VERIFY

**Remaining / owner action:** Closes when its 7 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #116 — [SDI] Complete native app delivery — Studio-first build tracker

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #3 EPIC, #4 EPIC, #5 EPIC, #6 EPIC, #7 EPIC, #8 EPIC, #9 EPIC, #10 EPIC, #11 EPIC, #12 EPIC, #13 EPIC, #14 EPIC, #15 EPIC, #16 EPIC, #17 EPIC, #18 EPIC, #19 EPIC, #29 EPIC, #30 EPIC, #31 EPIC, #32 EPIC, #117 EPIC, #118 EPIC, #119 EPIC, #120 EPIC, #121 EPIC, #122 EPIC, #268 EPIC

**Remaining / owner action:** Closes when its 28 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #117 — [SDI epic] Social video wall and challenge lifecycle

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #217 CODE_REMAINING, #218 closed, #219 DEVICE_VERIFY, #220 CODE_REMAINING, #223 closed

**Remaining / owner action:** Closes when its 3 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #118 — [SDI epic] Invitation-based Studio collaboration rooms

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #228 closed, #229 closed, #230 closed, #231 closed, #232 DEVICE_VERIFY, #233 DEVICE_VERIFY, #234 CODE_REMAINING, #235 closed

**Remaining / owner action:** Closes when its 3 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #119 — [SDI epic] War Room video matchups and trustworthy results

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #221 closed, #222 closed, #236 closed, #225 closed, #226 closed, #237 closed

**Remaining / owner action:** All listed children are closed; close the epic when the native gate (#124/#265) is accepted.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #120 — [SDI epic] Admin command center, approval and operations

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #210 closed, #246 OWNER_GATED, #211 DEVICE_VERIFY, #247 DEVICE_VERIFY, #248 CODE_REMAINING, #255 closed, #257 DEVICE_VERIFY

**Remaining / owner action:** Closes when its 5 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #121 — [SDI epic] $4.99 and $9.99 subscriptions, annual plans and existing Stripe integration

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #249 OWNER_GATED, #250 OWNER_GATED, #251 OWNER_GATED, #252 closed, #253 closed, #258 closed, #254 OWNER_GATED, #259 DEVICE_VERIFY

**Remaining / owner action:** Closes when its 5 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #122 — [SDI epic] Authorization, privacy, moderation and release safeguards

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #186 OWNER_GATED, #187 closed, #260 OWNER_GATED, #261 OWNER_GATED, #238 OWNER_GATED, #262 DEVICE_VERIFY, #263 CODE_REMAINING, #256 OWNER_GATED

**Remaining / owner action:** Closes when its 7 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #124 — [SDI F02] Pass the complete app build and exact-source native regression gates

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** All native-production-tests steps, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed on c3d87d2. native-ios-shards / native-ios-build (app build, simulator journeys) are still pending on c3d87d2. Last recorded shard result (run 38516791084 on 39f29cb0): auth 19/19, UI shard 0 35 passed / 20 failed.

**Remaining / owner action:** Green native-ios-shards and native-ios-build on the exact merge head, with xcresult/log/receipt preserved; triage any failing journeys from the original artifacts.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #126 — [SDI F04] Publish current source-labelled SwiftUI captures and a native review route

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Install/review route documented in `docs/NATIVE_SIMULATOR_REVIEW.md` and `docs/TESTFLIGHT_DISTRIBUTION.md`; the shard job uploads the unsigned simulator app ('Upload native simulator review app').

**Remaining / owner action:** Publish captures from the exact-head native shard artifacts once #124 is green; TestFlight depends on owner signing (#266).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #127 — [SDI F05] Compare the supplied visual references against actual native layouts

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Reference-to-screen map in `docs/VISUAL_REFERENCE_MAP.md` (missing captures marked).

**Remaining / owner action:** Same-size portrait/landscape/iPad native captures compared against the references; needs the native shards (#124) or a device run.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #130 — [SDI A02] Complete Sign in with Apple and private-relay account handling

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Apple sign-in delegate with cancellation mapping, private-relay handle fallback, credential-revocation observer (`AuthService.swift`); `testAppleUsernameFallsBackForPrivateRelayAndDisplayNameIsBounded` in the auth shard (pending).

**Remaining / owner action:** Owner: enable Sign in with Apple for the App ID, create the Services ID/key and configure the Supabase Apple provider; then sign in on a physical device (first authorization, private relay, revoke in Settings).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #131 — [SDI A03] Complete Google sign-in and secure callback handling

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** OAuth browser session cancel -> no banner, `access_denied` -> calm denial (`OAuthBrowserSession`, `oauthCallbackDenial`).

**Remaining / owner action:** Owner: create the Google OAuth client and enable the Supabase Google provider with the app's redirect; then login/logout/relaunch on device.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #132 — [SDI A04] Complete GitHub sign-in with minimal OAuth permissions

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Scopes limited to `read:user user:email`; denial mapping and tests in the auth suite.

**Remaining / owner action:** Owner: register the GitHub OAuth App (callback = Supabase) and enable the provider; then native callback cancel/replay and sign-in.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #133 — [SDI A05] Complete Microsoft sign-in and supported account types

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Tenant hint (`ProviderHint.microsoft`), `AADSTS` error mapping, tenant section in `docs/AUTH_PROVIDER_CONFIGURATION.md`.

**Remaining / owner action:** Owner: decide personal/work/school support, register the Azure app and enable the Supabase Azure provider; then native redirect and restoration.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #136 — [SDI A08] Finish branded splash and reliable startup routing

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `SDIBrandMark` renders the `SDIBrandSkull` asset when present (`SplashScreenView.swift`); Reduce Motion respected; routing in `AppFlowView.startupDestination`, pinned by `testDeepLinkRouterClassifiesBeforeNavigation`.

**Remaining / owner action:** Owner: supply the owned skull/red-glow artwork as the `SDIBrandSkull` asset; then cold/warm launch check on device.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #142 — [SDI S04] Complete airbrush, watercolor, neon and calligraphy behavior

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Airbrush Build-up, Watercolor Bleed/Grain, Neon core and Additive glow (plus-lighter), calligraphy angle/speed: `Tests/StudioBrushes`, alpha-lock cases in `Tests/StudioBrushIntegration`; native-production-tests steps 'Verify deterministic native brush geometry and actual pixels', 'Verify native brush edits, live rendering and persistence', 'Verify actual SwiftUI renderer pixels on macOS'.

**Remaining / owner action:** Add an MP4 frame-vs-canvas comparison for these families (no MP4 assertion in `Tests/StudioBrushIntegration`); then the native gesture journey.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #149 — [SDI S11] Complete gradient, blur, smudge, sharpen and burn effects

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** PR #309 commit 59b5536 adds the Gradient tool (linear/radial, fade, dither, replayable `.fill` with `StudioGradientDescriptor`, schema 36) and selection-limited Smudge/Blur/Sharpen/Dodge/Burn via `StudioSelectionMask.clip`. native-production-tests steps passed: 'Verify gradient fill, selection masks, wand regions and element hit tests', 'Verify real Smudge pixels replay cache cancellable sessions and exports', 'Verify real Blur pixels replay history cancellable sessions and exported media', 'Verify real Sharpen pixels replay history cancellable sessions and exported media', 'Verify real Dodge and Burn exposure history settings cancellation and exported media'.

**Remaining / owner action:** Native gesture journeys for the new Gradient tool and selection-limited effects (none run yet; native shards pending).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #153 — [SDI S15] Implement wand selection with real tolerance and sampling

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** PR #309 (59b5536): Wand on drawing layers with tolerance/contiguous/New-Add-Subtract and Feather (`StudioWandRegion`, `StudioSelectionElementHitTest`); Move/Copy/Cut/Delete act on the touched drawings. native-production-tests step 'Verify gradient fill, selection masks, wand regions and element hit tests' passed.

**Remaining / owner action:** Native journey covering zoomed wand selection and downstream move/delete/copy on the canvas.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #170 — [SDI D04] Finish portable project backup, import and restore

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Versioned portable bundle export/import with collision-safe IDs and `importPortableProject(droppingMissingAudio:)` (`StudioViewModel.swift`). native-production-tests step 'Verify portable project backups with original assets and cancellation' passed.

**Remaining / owner action:** Device-to-device round trip, interrupted import and missing-asset recovery on real devices (Files journey in native shards).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #171 — [SDI D05] Bound local storage, asset lifetime and cache eviction

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Status banner moved to an overlay so save errors no longer change canvas geometry (`StudioView.swift` `.overlay(alignment: .top)` 'studio.status'); recoverable unsaved revisions reported. native-production-tests steps 'Verify actual production device storage and legacy preservation' and 'Verify accurate local storage and safe regenerable cache release' passed.

**Remaining / owner action:** Re-run the unchanged imported-image journey and a low-space write failure in the native shards / on device.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #174 — [SDI P01] Record creator consent and rights for official-channel and marketing publication

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Native 'Submit a rendered video' form with rights text, audience, per-destination toggles and terms version (`ProfileView.swift` ~1013-1040); backend consent binding `backend/sql/consent-versions.sql`, `registration.py:_verify_consent`, `test_ingestion.py::test_registration_requires_server_verified_consent` in backend-candidates step 'Run backend Python tests with fake transports'. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step.

**Remaining / owner action:** Native submission journey (refusal, withdrawn consent, changed render) against a configured test upload service.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #180 — [SDI AU08] Synchronize audio transport with animation playback and scrub

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Windowed playback beyond 120 s, scrub audition (`StudioAudioScrubAudition` in `AudioPanels.swift`), interruption/route stop notice. native-production-tests steps 'Verify production StudioAudioTimeline', 'Verify production StudioAudioMix', 'Verify actual movie import cold reopen and synchronized mixed MP4' passed.

**Remaining / owner action:** Route change/headphones/backgrounding and long-project drift measured on a device.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #186 — [SDI SEC01] Inventory the existing backend and admin before configuration changes

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Candidate inventory in `docs/BACKEND_ARCHITECTURE_PUBLIC.md` and `docs/RLS_REVIEW.md`.

**Remaining / owner action:** Owner: run the read-only live backend/admin inventory with project credentials and keep the findings private.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #188 — [SDI P02] Validate and moderate real rendered submissions before release

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Media validation, consent and content gate at registration, licensed-asset admission (`test_ingestion.py::test_catalogued_assets_are_admitted_with_their_licence_and_unknown_ones_refused`, `test_store_requires_a_registry_before_admitting_credits_and_keeps_the_matched_licence`) in backend-candidates; native Profile -> Publishing status over `sdi_publish_status` (c78e68f). Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step.

**Remaining / owner action:** Native publishing-status journey showing rejected/pending/unavailable states against a test backend.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #190 — [SDI D07] Implement bounded temporary uploads and post-publication cleanup

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Bounded staging, retention and post-publication cleanup (feed publisher, sweeps; `test_workers.py`) in backend-candidates; encryption delegated to the host volume (`docs/OPERATING_RUNBOOK.md`).

**Remaining / owner action:** Owner: provision an encrypted staging volume on the host and deploy the workers; then a crash-safety cleanup drill.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #191 — [SDI AU03] Expand licensed free sound packs with deduplication and provenance

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Sound credits through MP4 manifests (`StudioSoundCredits.swift`); provenance verifier `scripts/verify_sound_catalogue_provenance.py` in spatter-production-tests step 'Verify bundled sound catalogue provenance and deduplication' (2,127 distinct sounds).

**Remaining / owner action:** Owner: source licensed audio for the missing music/ambience/comedy categories and downloadable packs.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #194 — [SDI IM02] Curate thousands of original or free StickDeath-style Studio images

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Catalogue/pack code with rights gate; 2,025 distinct images (207 bundled + 1,818 optional) per earlier audit; CI 'Verify licensed image catalogue and every original PNG'.

**Remaining / owner action:** Owner: provide or approve rights-cleared image sources to reach the curation target.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #198 — [SDI IM06] Provide safe asset removal, attribution and catalogue updates

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Quarantine (`ReleasePolicy`), image credits, sound credits in MP4 manifests.

**Remaining / owner action:** Catalogue revision update path beyond `advance(revision:)` and offline version-change/missing-asset tests.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #199 — [SDI V01] Implement video import with real metadata and managed lifetime

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** PR #309 (59b5536): decoded movie bytes retained as project-managed media (`AnimationProject.videoSources`, `StudioVideoReference` with measured metadata and trim/speed mapping), pruned with document/undo history. native-production-tests steps 'Verify real video-frame timing orientation cancellation and cleanup' and 'Verify bounded actual movie frame sequences and trim boundaries' passed; new journeys in `Tests/StudioDocument` and `Tests/StudioImageSequence`.

**Remaining / owner action:** Native Photos/Files permission, cancel and cold-reopen-after-original-removal journey.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #200 — [SDI V02] Implement rotoscope extraction at the actual playhead

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Playhead-to-source mapping (`StudioVideoFrameImportService.Mapping`), variable-frame-rate classification tests, reference layers (`Layer.isReference`) excluded from PNG/GIF/MP4. native-production-tests steps 'Verify real video-frame timing orientation cancellation and cleanup' and 'Verify bounded actual movie frame sequences and trim boundaries' passed.

**Remaining / owner action:** Native rotoscope journey at the actual playhead (seek, cancel, repeat).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #201 — [SDI V03] Complete video trim, orientation, timing and optional audio extraction

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Soundtrack extraction with mapping persisted on `AudioClip.videoMapping` (59b5536); source in/out and speed controls (`StudioImageImportPanel.swift`); native-production-tests step 'Verify real movie soundtrack trim speed cancellation and owned cleanup'.

**Remaining / owner action:** Rotation/aspect controls are not exposed in the video panel; then final MP4 A/V sync and portrait/landscape cold reopen on device.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #203 — [SDI AI01] Give Spatter accurate screen, tool and document context

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CLOSE_ON_MERGE

**Evidence:** Typed bounded context `SpatterContextSnapshot` (screen/tool/panel/selection/frame/layer/document stats/revision, no artwork or paths) and `isStale(comparedTo:)` in `StickDeathInfinity/Services/Spatter/SpatterStudioControlRegistry.swift`; cloud snapshot redaction (`sharingNames`) and opt-in `useCloud` in `SpatterAIViewModel`. Tests: `Tests/SpatterConversation` ('changed project revision discards stale cloud reply without altering actual document', redaction/identity-scope checks, unavailable-state classification) in native-production-tests step 'Verify real local and cloud Spatter conversation state'; registry/readiness cases in `Tests/SpatterPlanner` (native-production-tests step 'Verify deterministic brief planner impact primitives registry extensions batches and quality gates').

**Remaining / owner action:** None for acceptance. The 'What Spatter sees' panel is not exercised by a native UI journey; that belongs to #124/#265.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

This issue is listed in PR #309's Closes section and closes when that PR merges.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #204 — [SDI AI02] Extend Spatter's validated command registry across Studio

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** 37+ grammars, catalog v4 with `fillAtPoint`, `selectElements`, `setSourceReference` (e06ab3e); injection/malformed tests in `Tests/SpatterPlanner` (native-production-tests).

**Remaining / owner action:** `SpatterStudioControlRegistry` marks Export and Add Picture `blocked` and Lasso/Wand/Gradient/Smudge/Blur/Sharpen/Dodge/Burn `manual`; the issue asks for routes covering selections, import and export (or an owner decision narrowing scope).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #205 — [SDI AI03] Make multi-command AI edits atomic, cancellable and reversible

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CLOSE_ON_MERGE

**Evidence:** `SpatterInstructionBatch` (2-8 lines, one revision, one Undo), `SpatterInstructionPreview.plan`, `SpatterStudioEditSession` deadline/cancellation checkpoints and `revertAppliedEdit`. Tests: `Tests/SpatterPlanner` ('batch commit failures cancellation and intervening edits roll back the whole batch': mid-batch failure, every cancellation checkpoint, clipboard version restored, stale batch keeps intervening user edit, restored document equality) in native-production-tests step 'Verify deterministic brief planner impact primitives registry extensions batches and quality gates'; `Tests/SpatterStudioEditSession` (deadline after preparation, deadline at middle/final precommit checkpoints, overlapping/duplicate request rejection, late cancel) in native-production-tests step 'Verify cancellable Studio edits and factual persistence state'.

**Remaining / owner action:** None for acceptance.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

This issue is listed in PR #309's Closes section and closes when that PR merges.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #206 — [SDI AI04] Build editable animations from varied natural-language briefs

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** `SpatterMultiClauseBrief` (1-3 actors, per-clause timing, seed), `StudioCommand.appendFrames`, storyboard receipts, golden fingerprints. native-production-tests steps 'Verify deterministic brief planner impact primitives registry extensions batches and quality gates', 'Verify editable procedural stick motion and real movie export' and 'Verify cancellable Studio edits and factual persistence state' passed.

**Remaining / owner action:** Playback of generated briefs in the app: native journey `testSpatterLocalMotionEditsExportsAndReopens` (Tests/NativeUI) is pending in the native shards.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #207 — [SDI AI05] Finish grounded customer-service and in-app help answers

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Versioned guide (`currentGuideVersion`), support/hostile cases in `Tests/SpatterConversation` and `Tests/SpatterEval/briefs.v2.json` (75 briefs) in native-production-tests.

**Remaining / owner action:** `SpatterAIViewModel.pricingGuide` still says 'A trial applies to both Creator and Pro', contradicting `docs/PLAN_DECISIONS_2026_10_15.md` (no free trial). Fix the guide and add a conversation assertion.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #208 — [SDI AI06] Preserve personality and safe device-local memory controls

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CLOSE_ON_MERGE

**Evidence:** On-device opt-in memory store with inspect/edit/export/import/reset sheet (`SpatterPersonalMemorySheet`, `StickDeathInfinity/Views/Studio/StudioView.swift`), no inference of absent memory, per-account records. Tests: `Tests/SpatterPersonalMemory` (disabled default, account/guest isolation, actual reset, import/export schema and bounds, symlink/FIFO rejection, memory never crosses the cloud request boundary) in native-production-tests step 'Verify opt-in local Spatter preferences and account isolation'; `Tests/SpatterConversation` (historical brain packs preserved, retired phone/call questions refused) in native-production-tests step 'Verify real local and cloud Spatter conversation state'.

**Remaining / owner action:** None for acceptance. The sheet itself has no native UI journey; covered by the general native gate #124.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

This issue is listed in PR #309's Closes section and closes when that PR merges.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #209 — [SDI AI07] Complete authenticated provider-neutral AI transport and budget controls

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CLOSE_ON_MERGE

**Evidence:** Provider-neutral backend handler `backend/spatter/handler.py` + `providers.ProviderRouter` (atomic model/provider switch, per-attempt timeout, bounded retries) + `metering.py`; client never holds provider keys for the SDI backend. Tests: `backend/spatter/test_handler.py` (missing/malformed/expired/wrong-role tokens refused, null provider 503 with no budget use, 429 budget exhaustion without provider call, provider failure refunds) and `test_metering.py` incl. `ProviderRouterTests` (transient retry, non-transient stop, model switch, invalid config) in backend-candidates step 'Run the Spatter backend handler tests'; `Tests/SpatterClient` and `Tests/SpatterOwnKey` in spatter-production-tests steps 'Compile and execute actual Foundation production source' and 'Verify Spatter plan access and own AI key client against fake transports'.

**Remaining / owner action:** None for acceptance. Deploying the handler with real provider secrets is an owner deployment step, not part of this issue's acceptance.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

This issue is listed in PR #309's Closes section and closes when that PR merges.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #211 — [SDI AD03] Build the exact-render approval queue and decision history

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Native admin review screen with digest/version-bound preview renewal (local 439cc79, merged), approval SQL `backend/sql/admin-approval.sql`, digest invalidation test `backend/sql/tests/150_review_source_digest.sql` in backend-candidates step 'Apply SQL candidates in README order and run the SQL tests'. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step.

**Remaining / owner action:** Play a full-resolution render with audio in the native admin against a configured upload/preview service; needs the owner identity (#246).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #212 — [SDI AI08] Implement a persistent daily original-video draft queue

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** `backend/spatter/draft_queue.py` with leases, retries, missed-day reporting, quality-record gate; `test_draft_queue.py` in backend-candidates step 'Run the Spatter backend handler tests'. Without a renderer every job fails with the owner-gate message.

**Remaining / owner action:** Implement the headless draft renderer the owner referenced on 2026-10-18 (not present at c3d87d2); then owner capacity approval.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #213 — [SDI AI09] Establish measurable motion, artwork and audio quality gates

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `SpatterQualityReport` brief-scope report; MP4 manifests record decoded frame count/duration and project digest; `draft_queue` refuses review without decoded counts (`test_a_quality_record_without_decoded_movie_counts_never_reaches_review`) in backend-candidates; planner quality cases in native-production-tests.

**Remaining / owner action:** Owner: choose the reference clips and visual thresholds (creative tuning is owner-managed per AGENTS.md 2026-10-09).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #214 — [SDI AI10] Build revision and approval workflow for generated videos

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** PR #309 (898a644): review list returns storyboard, source_project_digest and quality report; `sdi_review_bind_source_digest`; approval invalidated on a changed digest (`150_review_source_digest.sql`) in backend-candidates. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step.

**Remaining / owner action:** Native admin presentation of script/storyboard/project/preview on a configured backend.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #215 — [SDI AI11] Make Spatter invoke real export and return factual artifacts

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Direct MP4 and GIF handoff from Spatter into the export panel (`StudioView.swift` `spatterMovieRequest`/`spatterGIFRequest`), receipts from the real exporter. native-production-tests steps 'Verify MP4 panel state and completion-owned share lifetime' and 'Verify GIF panel and completion-owned sharing leases' passed.

**Remaining / owner action:** Native journey `testSpatterDirectMP4PreviewRetainsEditableProject` and a GIF equivalent in the native shards.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #216 — [SDI AI12] Run adversarial and end-to-end Spatter acceptance evaluation

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** 75-brief corpus, runner writes a JSON report with seed; native-production-tests step 'Verify Spatter brief evaluation suite against production Studio commands' passed.

**Remaining / owner action:** Results are pass/fail per brief (no per-dimension factuality/adherence/editability/reversibility/privacy/quality scores) and the JSON is written to the runner temp directory without an upload-artifact step, so failed cases are not preserved.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #217 — [SDI SO01] Build the real social video wall and pagination

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** `FeedTimeline.merge` dedupe, 40-page cap, offline page-0 cache, all states in `HomeFeedView`; `FeedPublisher` digest-verified copy (`test_workers.py::FeedPublisherTests`); `Tests/CommunityFeed` in spatter-production-tests.

**Remaining / owner action:** Feed thumbnails for published copies; then native comparison with the Photo4 card reference.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #219 — [SDI SO03] Implement feed video playback, share and creator-permitted export

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** HTTPS-only `FeedPost.safeURL`, `ShareLink`, export only when `allow_export` (`FeedExportPolicy`), creator toggle via `sdi_export_consent`; `Tests/CommunityFeed` in spatter-production-tests step 'Verify community feed and profile clients against fake transports'.

**Remaining / owner action:** Native playback/mute/autoplay/bandwidth behavior against real approved media.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #220 — [SDI SO04] Complete Trending, Recent, Following and Featured feeds

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Four server rankings with rule text, server-side blocked/removed filtering (`010_feed_integrity.sql`) in backend-candidates.

**Remaining / owner action:** Cursor-stable paging (still offset with a 40-page cap in `video-feed.sql`).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #224 — [SDI SO06] Finish genuine profile editing and creator portfolios

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Handle rules (`CreatorHandle`), avatar downscale/upload (`AvatarUploadService`), portfolio from approved renditions, unavailable follower totals shown honestly; `Tests/CommunityFeed` in spatter-production-tests.

**Remaining / owner action:** Native profile edit/account-switch journey; owner must confirm the `avatars` storage bucket exists on the live project.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #232 — [SDI R05] Synchronize shared Studio edits with versioned commands

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** PR #309 (e06ab3e): `StudioRoomBridge` (`ViewModels/StudioViewModel+Rooms.swift`) publishes committed Studio commands and applies remote ones via the strict decoder; `Tests/CommunityRooms` (18/18) in spatter-production-tests step 'Verify Rooms client, invitation consent and versioned command sync'.

**Remaining / owner action:** Two authorized clients editing frames/layers/audio against a test backend (reconnect, undo ownership, revocation).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #233 — [SDI R06] Transfer selected collaboration assets with quotas and cleanup

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Bounded room asset transfer (`RoomAssetTransfer`, `sdi_room_asset` in `backend/sql/rooms-v2.sql`, `tests/035_rooms_rebase_assets.sql`), scheduled `room_asset_sweep` (461d61e, `test_workers.py`) in backend-candidates.

**Remaining / owner action:** Resume/cancel/corrupt-asset and expired-membership cleanup across two devices.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #234 — [SDI R07] Finish native room browser, join flow and active-project handoff

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Room browser/join/handoff in `CollabRoomView` with sync counts (e06ab3e).

**Remaining / owner action:** The owner-approved (2026-10-18) project snapshot hand-off to approved members (size cap, checksum, member-only download, expiry, import as new project) is not on c3d87d2; then native two-client journeys.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #238 — [SDI SEC05] Protect provider credentials and OAuth refresh tokens

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Server-only OAuth flow (`backend/publishing/owner_oauth.py`), legacy client credential views deleted, native-production-tests step 'Scan release sources for credentials' passed.

**Remaining / owner action:** Owner: place provider keys/refresh tokens in the approved server secret store and run a rotation/revocation drill on the live deployment.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #239 — [SDI P04] Connect the existing owner YouTube channel through secure OAuth

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `backend/publishing/owner_oauth.py` server-side flow with minimal scopes.

**Remaining / owner action:** Owner: create the Google Cloud OAuth client and consent screen, then connect the existing channel through the private flow.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #241 — [SDI P06] Render the small SDI watercolor logo on official-channel copies

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** PR #309 (03ca826): `StudioChannelRendition` placement/contrast/refusal rules; exporter composites the `SDIChannelWatercolorMark` asset only on channel copies and refuses when it is absent. spatter-production-tests step 'Verify official-channel mark placement, contrast and refusal rules' and the macOS movie-export steps in native-production-tests passed.

**Remaining / owner action:** Owner: supply the approved transparent watercolor SDI mark as `SDIChannelWatercolorMark`.

**Update 2026-10-19:** The owner supplied three transparent marks, installed as `SDIChannelWatercolorMark` (red SD with white infinity), `SDIChannelMarkSkull` and `SDIChannelMarkWordmark`. By owner decision they rotate across channel videos. `StudioChannelRendition.markAssetName(forSequence:)` gives a publication sequence that never repeats consecutively. Without a sequence, a stable FNV-1a hash of the project ID picks the mark, so re-rendering the same video for approval reproduces the same mark. The movie manifest records `channelMarkAsset`. Native compositing with the installed assets remains to be verified on macOS/iOS CI.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #242 — [SDI P07] Provide six configurable quick-share destinations and native file sharing

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Six configurable destinations (iOS `Tests/StudioQuickShare` in native-production-tests step 'Verify six quick-share destinations and format choices'; Android `QuickShareTest` in android-debug-build 'Compile debug application and instrumentation APK, run JVM unit tests'); Save to Files for MP4/GIF/PNG.

**Remaining / owner action:** Share to installed and missing destination apps, cancellation and retry on a device.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #243 — [SDI P08] Build honest destination adapters and owner-approved social marketing

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Dry-run destination adapters (`backend/publishing/destinations.py`), `test_workers.py::DestinationTests` in backend-candidates.

**Remaining / owner action:** Owner: confirm platform terms and provide server-held credentials per destination before any adapter leaves dry-run.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #245 — [SDI P10] Expose publish progress, cancellation, retry and removal status

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Profile -> Publishing reads `sdi_publish_status` with retry/cancel/removal gating (c78e68f); admin publish-stage view (898a644); `Tests/AccountServices` in spatter-production-tests step 'Verify support, privacy choices, server entitlement and notification clients'. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step.

**Remaining / owner action:** Native and admin status journeys across an app/backend restart on a test backend.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #246 — [SDI AD02] Securely provision the owner command-center identity

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `sdi_provision_owner` (service role, no password) tested in SQL test 060 in backend-candidates.

**Remaining / owner action:** Owner: run private owner enrollment with MFA on the live project; then verify owner access and ordinary-user denial.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #247 — [SDI AD04] Build moderation, reports, blocks and takedown controls

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Queues for feed, War Room, room reports and feed-removal appeals; server-enforced actor separation; `Tests/CommunityAdmin` in spatter-production-tests step 'Verify admin step-up policy, health, agents, finance and moderation queues'; `docs/CONTENT_POLICY.md` section 4.

**Remaining / owner action:** Native/web admin moderation journey on a test backend.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #248 — [SDI AD05] Control AI providers, budgets, daily drafts and emergency stop

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** `AdminAgentsContent` over `sdi_agent_admin` (caps, permissions, emergency stop), typed agent commands (898a644); `Tests/CommunityAdmin` in spatter-production-tests.

**Remaining / owner action:** Masked provider-configuration health view is not implemented.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #249 — [SDI B01] Verify and reuse the existing Stripe account in read-only mode

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Procedure and test/live separation in `docs/BILLING_CONTRACT.md` and `docs/LAUNCH_REHEARSAL.md` section E; no Stripe call made.

**Remaining / owner action:** Owner: connect the existing Stripe account read-only and confirm identity, currency and existing products.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #250 — [SDI B02] Define 4.99 and 9.99 monthly plans and approved annual pricing

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `backend/billing/contract.py:ApprovedProduct` refuses annual without owner configuration; downgrade without data loss in `070_billing_lifecycle_finance.sql`; `test_billing.py` in backend-candidates; `docs/PLAN_DECISIONS_2026_10_15.md`.

**Remaining / owner action:** Owner: approve annual amounts (or none) and the entitlement matrix, and create the 4.99/9.99 products in App Store Connect and Stripe.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #251 — [SDI B03] Implement StoreKit purchase, restore and subscription states

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** StoreKit client and server entitlement reconciliation (`reconcileEntitlementsWithServer`, c78e68f); `Tests/BillingPlans` in native-production-tests; `Tests/AccountServices` in spatter-production-tests.

**Remaining / owner action:** Owner: create App Store Connect subscription products and sandbox testers; then sandbox purchase/restore/revocation on device.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #254 — [SDI B07] Build a provider-backed finance ledger and reconciliation report

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `backend/sql/billing-finance.sql` record/report (6 discrepancy classes, period summary, exports, agent costs), `070_*.sql` in backend-candidates; web admin finance forms (5ec9711).

**Remaining / owner action:** Owner: Stripe access (#249) so actual revenue/fees/refunds/payouts reconcile by provider IDs; tax remains a manual import.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #256 — [SDI SEC08] Verify backup restoration, audit integrity and incident response

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** backend-candidates step 'Rehearse backup and restore on the throwaway cluster' (`scripts/backend/verify_backup.sh`); runbooks updated.

**Remaining / owner action:** Owner: run the restore drill against isolated copies of the live project.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #257 — [SDI AD07] Expose service health, backups and release operations safely

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** `AdminHealthContent` over `sdi_admin_health`; restore-drill reporting (`verify_backup.sh --report`, `restore_drill` in `backend/sql/admin-hardening.sql`, `AdminOperationsPanels.swift`); `Tests/CommunityAdmin` in spatter-production-tests; backend-candidates step 'Rehearse backup and restore on the throwaway cluster'.

**Remaining / owner action:** Native admin health/backup view on a configured backend.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #259 — [SDI B08] Build accurate pricing, annual selection and subscription settings

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** `SubscriptionView`/`ChoosePlanView` show `Product.displayPrice` or 'Plans are not configured yet'; trial copy returns nil (c78e68f); `Tests/BillingPlans` in native-production-tests step 'Verify billing plan catalogue, StoreKit state machine and plan copy'.

**Remaining / owner action:** Locale formatting and purchase-state copy on a device/StoreKit sandbox. Also correct `docs/BILLING_CONTRACT.md` (lines ~67, 136-142 still describe a trial; `docs/PLAN_DECISIONS_2026_10_15.md` says no trial).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #260 — [SDI SEC03] Retire legacy messaging and calling entry points across the backend

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Retired sources deleted; source-security step 'Verify retired messaging and calls cannot enter the native target' (`scripts/verify_retired_communications.py`: native target, deep links, Spatter prompt, Android, backend SQL/Python) passed; SQL retirement candidate `backend/sql/security-retire-communications.sql` tested by `130_security_lifecycle.sql` in backend-candidates.

**Remaining / owner action:** Owner: apply `security-retire-communications.sql` to the live project and run `sdi_legacy_communication_exposure` there (the verifier states it does not inspect a live database).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #261 — [SDI SEC04] Define and enforce content, age and moderation rules for animated submissions

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `docs/CONTENT_POLICY.md`; submission refused without `min_age` attestation (`090_*.sql`) in backend-candidates.

**Remaining / owner action:** Owner: legal review of the policy text and the minimum-age decision.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #262 — [SDI SEC06] Implement account export, deletion and consent-retention controls

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** `sdi_account_lifecycle` request/cancel/export in `AuthService.swift` and Settings/Profile; `backend/ops/sweeps.py` deletion run (`test_workers.py::SweepTests`) in backend-candidates. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step.

**Remaining / owner action:** Native deletion/export journey with outstanding room/billing/publication records on a test backend.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #263 — [SDI SEC07] Bound resource use, abuse rates and provider costs

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Quotas across admin/feed/support/rooms/push/email/finance/marketing; publishing slot cap (461d61e) in backend-candidates.

**Remaining / owner action:** Burst, duplicate-job and quota-exhaustion fixtures are not written.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #264 — [SDI QA01] Verify accessibility and adaptive layouts across the native app

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Dynamic Type helpers, contrast token, `testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize` (Tests/NativeUI), `docs/ACCESSIBILITY_DYNAMIC_TYPE.md`.

**Remaining / owner action:** The audit journey and portrait/landscape/iPad captures; native-ios-shards / native-ios-build (app build, simulator journeys) are still pending on c3d87d2. VoiceOver needs a person on a device.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #265 — [SDI QA02] Run the complete native user journey and regression acceptance gate

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** `testCompleteProjectJourneyCreateDrawLayerAudioExportPNGAndColdReopen` (Tests/NativeUI).

**Remaining / owner action:** native-ios-shards / native-ios-build (app build, simulator journeys) are still pending on c3d87d2. Services journeys (auth, feed, rooms, War Room, approval) need a configured isolated test backend.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #266 — [SDI QA03] Deliver a signed native review build and physical-device performance evidence

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `Tests/NativePerformance/StudioPerformanceUITests.swift`, `docs/PERFORMANCE_MEASUREMENT_PROTOCOL.md`.

**Remaining / owner action:** Owner: signing identity, device enrollment and TestFlight access; then on-device performance runs.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #268 — [SDI epic] Product website and complete app-business operations

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** EPIC

**Evidence:** Children: #269 OWNER_GATED, #270 DEVICE_VERIFY, #271 OWNER_GATED, #272 DEVICE_VERIFY, #273 OWNER_GATED, #274 closed, #275 CODE_REMAINING, #276 OWNER_GATED, #277 closed, #278 OWNER_GATED

**Remaining / owner action:** Closes when its 8 open child issue(s) close.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #269 — [SDI W01] Verify existing website source, hosting, domain and reversible deployment

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `docs/WEBSITE_HOSTING.md` (GoDaddy decision, Netlify migration, rollback), `docs/WEBSITE_INVENTORY.md`.

**Remaining / owner action:** Owner: GoDaddy cPanel upload, nameserver switch preserving the Microsoft 365 records, SSL, then Netlify removal; private reference-source inventory.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #270 — [SDI W02] Build the responsive product website from real native app capabilities

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Static site with captures page (`website/screens.html`), FAQ (`website/about.html`), store/help pages; website verify job (`check_help.mjs --check`, `build_site.mjs --check`, `a11y_perf.mjs`) passed.

**Remaining / owner action:** iPhone Safari + VoiceOver check of the deployed review build; deployment depends on #269. Confirm every capture is source-labelled from an exact native run.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #271 — [SDI W03] Connect a secure website account and subscription portal

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Account page plans from PLAN_DECISIONS, checkout/portal only when `account-config.js` billing is set (5ec9711); `stripe_checkout.py` portal action.

**Remaining / owner action:** Owner: Stripe test-mode products/keys (#249/#250) and a deployed checkout function; then isolation/callback/payment-failure tests.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #272 — [SDI W04] Build a searchable help center and bounded customer support intake

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Signed-in support requests with receipts on the web (`website/account.js`, 5ec9711) and native (`SupportClient`, `SupportRequestsView`, c78e68f); `Tests/AccountServices` in spatter-production-tests; `backend/sql/support-requests.sql`; help check in website verify. Backend SQL runs only on the CI throwaway PostgreSQL cluster; the live project install (docs/BACKEND_INSTALL_OWNER.md) is an owner step.

**Remaining / owner action:** Authorized submit/duplicate/withdraw/delete on a deployed test backend from a mobile browser and the app.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #273 — [SDI W05] Publish versioned product policies and actionable privacy choices

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Versioned policies `website/policies/*-v1.html` (1.0-draft), `sdi_consent_action` publish/current/accept, native policy links and marketing permission grant/withdraw (c78e68f), `PrivacyChoicesView`.

**Remaining / owner action:** Owner: legal review and approval of the draft policies, then publish them as effective.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #275 — [SDI W07] Verify website discovery, accessibility, performance and private analytics

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Sitemap/robots, private pages excluded, local opt-in counters only; website verify `a11y_perf.mjs` budgets passed.

**Remaining / owner action:** No aggregate site/product event collection or funnel report exists (owner may instead narrow the scope to 'no analytics').

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #276 — [SDI W08] Implement consented customer email and lifecycle delivery

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `notifications.sql` prefs/suppressions, `backend/mail/` templates, dedup queue, blast cadence (fe01d2d); `test_mail.py` with an in-process SMTP sink in backend-candidates.

**Remaining / owner action:** Owner: authorize the sender domain/mailbox (SPF/DKIM) on the existing provider.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #278 — [SDI W10] Run the complete app-business launch rehearsal and operating handoff

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `docs/LAUNCH_REHEARSAL.md` script and access inventory; offline part A run.

**Remaining / owner action:** Owner: sandbox parts B/C need Stripe test mode, a configured test backend and provider sandboxes.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #279 — [SDI AI13] Generate 20-60 second videos from YouTube and web sources with rights gating

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** PR #309 (e06ab3e): `setSourceReference` command, `SpatterSourceRightsGate`, 20-60 s bound with length receipt; `Tests/SpatterPlanner` in native-production-tests.

**Remaining / owner action:** Owner: decide the source-rights rule (which sources and bases are allowed).

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #280 — [SDI AI14] Define the StickDeath blood and impact style spec as reusable motion primitives

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `SpatterImpactPrimitive` deterministic streaks/burst/pooling/fade, `docs/SPATTER_IMPACT_STYLE_SPEC.md`; planner case 'impact primitive is deterministic, bounded, pools blood and matches its golden fingerprint' in native-production-tests.

**Remaining / owner action:** Owner: reference clips and style tuning (owner-managed). Code follow-up: the goldens are geometry fingerprints (`Golden.impactBlood`), not the decoded-pixel tests the issue asks for.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #281 — [SDI W11] Support mailbox agent for support@stickdeathinfinity.com

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Support intake `backend/sql/support-requests.sql`, web/native support clients.

**Remaining / owner action:** Owner: mailbox access method and credentials for support@stickdeathinfinity.com.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #283 — [SDI W13] Add Discord and Facebook adapters and agent-scheduled daily/weekly marketing cadence

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** Discord/Facebook/X dry-run adapters, `sdi_marketing_cadence_due` queues only approved drafts, email-blast cadence with consent/suppression (fe01d2d, `test_mail.py`) in backend-candidates; `docs/BRAND_VOICE.md` draft.

**Remaining / owner action:** Owner: approve the brand voice and provide platform credentials/terms confirmation.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #284 — [SDI AD09] Build the agent management console (pause, permissions, budgets, logs)

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Agent list/pause/caps/instructions with rollback, emergency stop, typed commands (898a644); `Tests/CommunityAdmin` in spatter-production-tests.

**Remaining / owner action:** Approval inbox for agent proposals above their caps.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #285 — [SDI AD10] Build the admin user directory and account actions (search, block, suspend, appeals)

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** DEVICE_VERIFY

**Evidence:** Directory (sign-up source, report counts), block/suspend/restore/reset-flags actions with reasons and audit, affected-member notices (3fae20c); SQL test `150_admin_user_flags_notices.sql` (non-admin denial) in backend-candidates; web admin list.

**Remaining / owner action:** Native/web admin directory journey on a test backend.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #286 — [SDI AND01] Android app: architecture decision and parity plan

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Parity matrix in `docs/ANDROID_DELIVERY.md`; shared fixtures `Tests/SDIFixtures` verified in android-debug-build 'Verify shared .sdi fixtures match their generator and expectations'.

**Remaining / owner action:** iOS-side opening of the shared fixtures and a both-client re-export comparison; owner sign-off on the architecture decision.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #288 — [SDI AND03] Android account, community, collaboration and Spatter parity

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Android War Room, challenges, room command sync, account lifecycle and notification clients with JVM tests (215ebd0) in android-debug-build.

**Remaining / owner action:** Android auth (email/Google/guest) and network access are not implemented, so no authenticated journey is possible yet.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #289 — [SDI AND04] Android billing, push and Play Store release

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `docs/ANDROID_DELIVERY.md` release checklist, data-safety and listing drafts.

**Remaining / owner action:** Owner: Play Console account, signing key custody, Play Billing products and Firebase project.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #290 — [SDI W14] Push notifications and in-app announcements for iOS and Android

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** OWNER_GATED

**Evidence:** `notifications.sql` compose/schedule/cancel/fan-out, `backend/notifications/push.py` with `SinkTransport`, `test_workers.py::PushWorkerTests` in backend-candidates; iOS preferences/inbox (`NotificationsClient`, `NotificationCenterView`); Android `NotificationPreferences.kt`.

**Remaining / owner action:** Owner: APNs key and FCM project; then test-device delivery.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```

### #291 — [SDI QA05] Crash reporting and privacy-respecting product analytics (iOS, Android, web)

```markdown
## Evidence ledger, 2026-10-18 (PR #309 head `c3d87d2`)

**Status:** CODE_REMAINING

**Evidence:** Opt-in diagnostics contract/queue/uploader (`Tests/Diagnostics` in native-production-tests step 'Verify opt-in diagnostics contract, queue and uploader'), admin diagnostics summary (898a644), Android local crash reports.

**Remaining / owner action:** Crash reporting with symbolication/release tagging on iOS and web, and crash-spike alerts in the command center.

CI on c3d87d2: native-production-tests, spatter-production-tests, backend-candidates, source-security, website verify and android-debug-build passed; native simulator shards pending, so no native UI acceptance is claimed here.

---
_Generated by [Claude Code](https://claude.ai/code)_
```
