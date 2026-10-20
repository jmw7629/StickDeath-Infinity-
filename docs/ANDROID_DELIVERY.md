# Android delivery contract

## Decision and authority

The owner's October 9 execution direction explicitly includes iOS, Android and the website. Android is an additive Kotlin/Jetpack Compose client under `android/`. SwiftUI remains the iOS product and first product priority. Android does not wrap the website or replace the SwiftUI app.

Native Kotlin was selected for direct touch/stylus, Canvas, MediaCodec, AudioTrack, content-provider and lifecycle integration. Kotlin Multiplatform could share selected pure models later, but it does not automatically make the existing Swift renderer or media pipeline portable. A cross-platform rewrite would discard working native behavior and conflict with the owner's preservation requirement. No second repository, paid service or separate animation project is required.

## Delivery order and actual boundaries

| Area | Current implementation | Remaining acceptance or implementation |
| --- | --- | --- |
| Local Studio | Canonical Kotlin frames/layers/artwork, history, atomic local projects, selection transforms, brush families (incl. marker/crayon), soft eraser, ruler, mirror, layer lock modes and labels, shapes/text/fill, image crop/turns, audio clips and exports | Physical-device acceptance, remaining tool parity (wand, gradient, blur, smudge, sharpen, dodge/burn, zoom tool), glow, region masks and full native visual comparison |
| Studio assets | Reuses licensed native sound and image bundles; local favorites/recent imports; source credits in imported artwork/clips | Optional native image-pack parity, complete device decoding and rights/update acceptance |
| Audio/media | Bounded WAV/compressed audio import (300 s cap within the 4 MiB source budget) and mixing; one video still at the animation playhead | Full video tracks, trim/orientation/timing, audio extraction, voice recording and device media acceptance |
| Sharing | Files exports with iOS-layout manifests, transparent PNG option, `.sdi` export of the supported subset; rendered-file Sharesheet; six configurable quick-share shortcuts (#242: YouTube, Instagram, TikTok, Facebook, X, Reddit by default; Threads, Pinterest, Files, Google Photos selectable; per-destination MP4/GIF/PNG choice) that send the fresh render with `ACTION_SEND` addressed to the app's package and fall back to the system chooser when it is missing | Receiving-app, missing-app and URI lifetime acceptance on devices; direct provider APIs (owner credentials and terms) and official-channel publication remain separate |
| Identity and Spatter | `connect/` package: Supabase GoTrue email, guest and PKCE OAuth (Apple/Google/GitHub/Microsoft when configured) with Keystore-encrypted session restore and refresh; Spatter cloud transport to the owner's provider-neutral backend; local `SpatterCommandBridge` grammar unchanged. Unconfigured builds stay network-free and say so | Owner-supplied public project values and provider setup; live end-to-end journeys against a test backend; grounded assistance context and generation; MFA/admin stays on iOS/web |
| Social and collaboration | `FeedClient`, `ProfileClient` and `RoomsClient` as before; `WarRoomClient` (list, propose/accept with explicit rule agreement, withdraw, block, one mutable authenticated vote, report, notices, appeal), `ChallengeClient` (server-clock phases, entries, submit/withdraw/favourite vote) and `RoomCommandClient` + `RoomCommandSync` + `RoomSessionCoordinator` (fenced `sdi_room_command` append/since, rebase, held overlapping conflicts, own-edit undo) over the same RPCs and protocol as iOS. Account panel tabs: War Room, Challenges (with server-gated moderator tools: create, schedule, cancel, remove entry), Shared rooms (summary, members, owner approve/decline/remove/block/role, invite mint/revoke, close/leave, Studio synchronisation), Calendar (read-only month), Notifications, Account data. `StudioSharedEdit` + `StudioRoomBridge` connect the open Studio project to its room: typed edits are published with frame:/layer:/audio: targets and remote edits replay through the same strict decoder, refusing divergent copies and keeping the local selection | Live acceptance against a test backend; mixed iOS/Android drawing replay (Android-native drawings travel as `studio.android.apply`, which iOS reports as not replayable); frame/layer structure, fills, images, audio clips, moved/restyled drawings, Undo/Redo and room undo are reported as not shared; room creation/project sharing from Android; calendar offline cache |
| Billing, notifications, admin | No live charges, push delivery or Android admin role is claimed; local notification preference model and local redacted crash reports; server notification preferences (push/email product and marketing opt-ins, daily cap 0–10) and the in-app announcements inbox with mark-read over `sdi_notify_action` (#290); account data export (saved through the document picker, held only in memory until then) and deletion request/cancel/status over `sdi_account_lifecycle` (#262) | Store purchase/restore and signed entitlement reconciliation, FCM delivery and device registration (owner gate), server-authorized admin access and distribution |

No user-to-user text chat, phone or video calling is included. Spatter assistance and project collaboration remain in scope. Private drafts never imply publication permission; generated public releases require owner approval of the exact render.

## Studio parity matrix (iOS schema 35 vs Android-local v26)

Status is implementation status only. Every Android row is unverified in this batch: the implementation container has no Android SDK, emulator or device, so compilation and behaviour are deferred to the CI compile/unit-test job (`.github/workflows/android-build.yml`, candidate update in `docs/ci-candidates/android-build.yml`) and a later emulator or device run of `app/src/androidTest`. "Done" means the code exists and is covered by tests that have not yet run; it is not a pass.

| Area | Feature | Android status | Notes |
| --- | --- | --- | --- |
| Tools | Pencil, eraser, line, rectangle, ellipse, triangle, diamond, star, arrow, text, image, fill, eyedropper, lasso, move, hand | Done | Shared `FrameRenderer` path for viewport, eyedropper and export |
| Tools | Soft eraser | Done (v26) | Four stacked destination-out passes with shrinking width (`SoftEraser`); same pixels on canvas and export; feathering is stepped, not Gaussian |
| Tools | Marker, crayon | Done (v26) | `BrushFamily.Marker` (chisel nib, flat ink) and `Crayon` (wax grain) in the procedural brush renderer; not pixel-equivalent to iOS |
| Tools | Ruler | Done | Gesture constraint (`RulerConstraint`): horizontal, vertical, 45° or lock-first-direction (15° steps) for pencil/eraser; shapes unchanged |
| Tools | Mirror | Done | `MirrorMode` off/vertical/horizontal/both; mirrored marks stay individually editable |
| Tools | Wand, gradient, blur, smudge, sharpen, dodge, burn | Missing | No Android tool; Swift import rejects elements using them |
| Tools | Zoom tool | Missing | Android uses pinch gestures and the Hand zoom slider only |
| Tools | Tilt/pressure input | Partial | Pressure retained for imported Swift round-brush dabs; no live stylus tilt |
| Brush families | Round, stipple, grain, rough pen, calligraphy, dip pen, halftone, hatch, marker, crayon | Done | Hatch is a single family |
| Brush families | Gradient, airbrush, watercolor, neon; hatch left/right variants | Missing | Imports using them reject with the original preserved |
| Layers | Order, visibility, full lock, opacity, rename, duplicate, delete | Done | |
| Layers | Lock modes free / full / position / alpha | Done (v26) | Same rules as `StudioDocumentEditor`: position allows new marks only; alpha allows pencil paint that keeps coverage (`preservesLayerAlpha`, rendered SRC_ATOP); erasing, fills, images, transforms need free. Import/export use the iOS raw values |
| Layers | Colour labels | Done (v26) | The eleven PhotoCraft swatches (`LayerLabel`), stored and exchanged as the iOS `colorLabel` hex; other hex values reject on import |
| Layers | Blend modes: normal, darken, multiply, color burn, lighten, screen, color dodge, linear dodge, overlay, soft light, hard light, difference, exclusion, hue, saturation, color, luminosity | Done (API 29+) | iOS raw values round-trip; 12 modes need Android 10 and are disabled below it. Soft Light uses Skia's curve where iOS measured Pegtop; pixel comparison deferred |
| Layers | Linear Burn | Missing (explicit) | No exact Android compositing mode; renderer and import refuse it, never draw Normal |
| Layers | Glow | Missing | Import rejects glow |
| Images | Import stills from Files/Photos, move/scale/rotate as artwork, source credit | Done | 4 MiB / 4 megapixel project cap |
| Images | Crop (normalized, upright source) and quarter-turn content rotation | Done (v26) | `ImageCrop`/`ImageGeometry`: the quad shrinks to the kept region so content scale is unchanged; turns happen inside an upright box. Not yet carried by `.sdi` import/export (iOS stores images as managed assets) |
| Images | Region masks, background cut, free image angle metadata | Missing | Free rotation exists through the selection handle (quad geometry), not as iOS `rasterRotationDegrees` |
| Audio | Clip import (WAV/compressed), trim, split, duplicate, placement, clip gain/mute, linear fades | Done | Clip and trim cap now 300 s as on iOS; the 4 MiB per-source / 8 MiB per-project PCM budget still bounds practical length (about 21.8 s at 48 kHz stereo, 262 s at 8 kHz mono); default clip volume 1.0 vs 0.8 on iOS |
| Audio | Track volume, mute, pan (balance law), solo (SoundCraft rule) | Done | Mixer, scene playback, MP4 and clip preview; pan slider and solo chip in the track mixer; Spatter sentences |
| Audio | Curved fades (equal power, S-curve, exponential, logarithmic) | Done | Same `gain(t)` formulas; fade times stay seconds on Android, 48 kHz frames on iOS |
| Audio | Voice recording, audio from video | Missing | |
| Export | PNG frame, ZIP frame set, spritesheet, MP4 with mixed audio, looping GIF, Sharesheet | Done | Filenames use the iOS `StudioExportFilename` rule (`<base>_%06d.png`, `<base>_spritesheet.png`) |
| Export | iOS-compatible manifests | Done | `ExportManifests` writes the `StudioExportService.Manifest` keys into ZIP `manifest.json`; MP4 and GIF produce the `StudioMovieExportService.Manifest` / `StudioGIFEncoder.Receipt` keys, saved as a separate file from the Export panel because single-file pickers cannot carry a sidecar. Non-white opaque backgrounds are recorded as `#RRGGBB` (Android extension) |
| Export | Transparent background PNG | Done | Export panel chip; applies to PNG, sequence and spritesheet; MP4/GIF stay opaque |
| Export | Android → iOS `.sdi` | Done (subset) | `SwiftProjectExport`: pencil/pen/pencil-legacy/round-brush strokes with pressure, lines, layers (order, visibility, opacity, blend, lock mode, label), holds, four-track mixer, schema 21 or 34. Textured brushes, soft eraser, shapes, text, images, fills, erasers and audio clips refuse the whole export with reasons listed in the panel |
| Export | GIF palette | Partial | RGB332 palette vs the iOS encoder; visual comparison deferred |
| Interchange | Swift `.sdi` import (schema 1–35) of pen/pencil/brush/line paths, round-brush descriptors, holds, layers with blends/lock modes/labels, mixer state | Partial | Clips, images, text, other tools/brushes, glow, unknown labels and unknown fields reject. Shared golden fixtures live in `Tests/SDIFixtures` |
| Assistant | Spatter command bridge | Done (local grammar) | `SpatterCommandBridge` parses the 31 iOS example sentences (select, layer add/delete/duplicate/update/move, audio track volume/mute/pan/solo, frame exposure/duplicate/reverse, project rename, onion skin, grid) into document commands applied as one Undo step. No assistant service, generation or network |

## Interchange remains an explicit delivery requirement

The current `sdi-android-local` envelope (v26) is an Android backup format. It is not the Swift `.sdi` codec. Android has a bounded Swift import path and a bounded export of the supported subset, described in [PROJECT_INTERCHANGE.md](PROJECT_INTERCHANGE.md); general native-project compatibility must not be advertised. PNG/MP4/GIF exchange is rendered media, not editable project interchange.

A shared codec must preserve stable identities, layer order/locks/blends, frame exposure/FPS, canvas/background, vector and raster content, asset ownership/provenance, audio source-time trims/fades/mix, schema migration and reversible command semantics. Unsupported data must be retained or rejected with the original preserved; no silent flattening or dropped effects. Cross-platform golden fixtures must be opened and re-exported by both production clients, with timing/pixel/audio comparisons and corrupted/unknown-version preservation. `Tests/SDIFixtures` now holds six deterministic schema-35 fixtures (one golden, five negative) with a Python verifier; the Android instrumented tests consume them, and an iOS Foundation-runnable check against the same bytes is still outstanding. The production interchange codec for images, text, effects and audio remains unfinished under #286.

## Owner and release prerequisites (#289) ⭐ owner-gated

- Verify an existing Google Play developer account and package ownership (`com.stickdeath.studio`) before any store submission.
- Establish signing-key custody and Play App Signing enrollment. Keep private keys/passwords out of the repository, issues and public artifacts. Debug APKs are not signed production releases.
- Verify the existing authorized push project and credentials before notification integration; do not create a paid Firebase/hosting subscription or claim delivery without credentials and device evidence.
- Configure approved products (USD 4.99 and USD 9.99 monthly only; annual needs explicit owner configuration), store policies and server-side entitlements (`backend/sql/billing.sql`). No real purchase is a test.
- Retain the current SwiftUI build/signing/TestFlight gates independently. An Android compiler pass cannot close iOS acceptance.

### Release checklist (offline draft; nothing below has run)

1. Owner provisions signing: upload key in a hardware-backed or password-manager-held keystore, Play App Signing enabled, `*.jks`/`*.keystore` remain git-ignored (`android/.gitignore`).
2. Add `release` build type with `isMinifyEnabled = false` first (no obfuscation until crash reports can be symbolicated), signing config read from CI secrets only; never commit `local.properties` or key passwords.
3. Bump `versionCode`/`versionName` in `android/app/build.gradle.kts`; record the exact commit in the release notes.
4. Run CI (`:app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest`, sound-asset verifier, fixture verifier) on the exact head; preserve the artifact checksums.
5. Instrumented run on an emulator (API 29+ and API 26) and at least one physical device: `SwiftProjectImportTest`, export journeys, audio playback, process restart.
6. Internal testing track upload of the signed AAB; verify the Play listing, data-safety answers and content rating from the drafts below.
7. Owner approval of listing copy and screenshots (own renders only; no recovered-corpus assets).
8. Billing stays disabled until Play Billing products exist and `sdi_billing_apply_event` is wired server-side; no live charge is a test.
9. Push stays disabled until FCM credentials exist; `NotificationPreferences` already stores creator choices.

### Data-safety form draft (current debug build)

These answers describe the default build, which has no Supabase values and therefore no INTERNET permission. A build given `sdi.supabaseUrl`/`sdi.supabasePublishableKey` (see "Connected client" below) declares INTERNET and collects account identifiers (email, user ID), feed interactions (likes, follows, blocks, reports), room membership requests and shared-room edit commands, War Room and challenge submissions, votes, reports and appeals, server notification preferences, account export and deletion requests and, if used, Spatter questions; every row below must be re-answered for it.

| Question | Answer for this build | Basis |
| --- | --- | --- |
| Does the app collect or share user data? | No data collected, no data shared | No INTERNET permission in the default build; nothing leaves the device |
| Location, contacts, calendar, SMS, call logs | Not collected | No permissions requested |
| Files and docs | Accessed only through the system document picker when the creator imports or exports; stored in app-private storage | `ActivityResultContracts.OpenDocument/CreateDocument`, `FileProvider` limited to `cache/studio-share/` |
| Audio | Imported audio files are embedded in the local project; no microphone use | No `RECORD_AUDIO` permission |
| Photos/videos | Imported stills and one video frame are embedded in the local project | `ImageDecoder`, `MediaMetadataRetriever`; originals untouched |
| App activity, diagnostics | Crash reports are written locally, redacted, kept 30 days / five files, never uploaded | `LocalCrashReporter` |
| Encryption in transit | Not applicable (no network) | Revisit when providers are configured |
| Data deletion | Uninstall removes all app data; in-app "Delete local crash reports" | `allowBackup="false"` |
| Account creation | None in this build | `AccountState.NotConfigured` / `AndroidIdentity.currentState()` report not configured |

This table must be re-answered before any release that adds identity, feed, Rooms, billing or push.

## Connected client (#288)

Source: `android/app/src/main/java/com/stickdeath/studio/connect/`. All network code is plain Kotlin behind one `HttpTransport` seam, so JVM tests script every reply and never open a socket.

| Piece | Behaviour | iOS counterpart |
| --- | --- | --- |
| `BackendConfig` | HTTPS origin only; publishable key only (`sb_publishable_…` or an anon HS256 JWT; service-role keys refused); OAuth provider list fails closed on unknown names; Spatter endpoint refuses model-provider hosts | `AppConfig.supabaseConfiguration`, `oauthConfiguration`, `SpatterEndpoint` |
| `GoTrueClient` / `SessionManager` | Email sign-in and sign-up (confirmation-pending reported, not signed in), anonymous guest, PKCE S256 OAuth with the `stickdeath://auth/callback` redirect (single-use in-memory verifier; `error=` callbacks reported, never exchanged; duplicate codes and fragments refused), refresh 60 s before expiry, local sign-out even when revocation fails | `AuthService` |
| Session restore | Unexpired session restored without network; expired session refreshed, never promoted; revoked refresh token clears the vault and asks for sign-in; offline refresh keeps the stored session for an explicit Retry; damaged records are discarded | `AuthService.restoreSession` |
| `KeystoreSessionVault` | AES-256-GCM with a non-exportable Android Keystore key, file in `noBackupFilesDir`; uninstall removes key and file | Keychain via the Supabase SDK |
| `CommunityGateway` | `POST /rest/v1/rpc/<name>` and RLS row reads with the member JWT plus publishable `apikey`; null parameters omitted so SQL defaults apply; 4 MiB body bound; server `error` → `Server(message, code)`; 401/403 → signed out; other HTTP failures never shown verbatim; replies for an earlier account → `Stale` | `CommunityGateway`, `SupabaseCommunityTransport` |
| `FeedClient`, `ProfileClient`, `RoomsClient` | Same RPC names, actions and response checks as iOS (25-post keyset pages via `sdi_feed_page` cursor + `as_of` snapshot, poster thumbnails; complete own records; 64-hex invitation codes, explicit consent, owner approval) | `FeedClient`, `ProfileClient`, `RoomsClient` |
| `WarRoomClient`, `WarMatchPresentation`, `WarVoteMachine` | `sdi_war_action` / `sdi_war_report` / `sdi_war_notices`. Voter identity is the JWT, never a parameter; negative tallies rejected; a tap stays pending until `confirmed` and a refusal keeps the previous server vote; winners shown only from a completed match's server `outcome` | `WarRoomClient`, `WarMatchPresentation`, `WarVoteMachine` |
| `ChallengeClient` | `sdi_challenge_action` list/entries/submit/withdraw/vote; phase from `server_time` plus elapsed device time; votes hidden until the server returns them | `ChallengeLifecycleClient` |
| `RoomCommandClient`, `RoomCommandSync`, `RoomSessionCoordinator` | `sdi_room_command` since/append with op ids, base-revision fencing, `rebased`/`duplicate`/`conflict` handling, held overlapping conflicts (keep mine / discard mine), own-edit undo only, access-ended and view-only refusals; Studio handoff only when the room's `device-project:` reference names the open project; blocked remote edits wait with a reason and can be skipped explicitly; unshared local changes are counted. Network calls never hold the state lock | `RoomsClient.commands/append`, `RoomCommandSync`, `RoomSessionCoordinator` |
| `StudioSharedEdit`, `StudioRoomBridge` | `studio.apply` payloads in the iOS command vocabulary (renameProject, updateLayer, setFrameHold, deleteElements, updateAudioTrack, draw with iOS pen/pencil/line strokes) or `studio.android.apply` with Android-native strokes; published only when replaying the commands on the previous document reproduces the committed one exactly; replays need every reference present and every new identity unused, otherwise they are refused as divergent; replay waits for gestures, playback, fills and imports | `StudioSharedEdit`, `StudioRoomBridge` |
| `RoomsClient.summary/members/setRole/decline`, `ChallengeClient` moderator actions, `CalendarClient` | `sdi_room_manage` summary/set_role, `sdi_room_members` rows, `sdi_room_action` approve/remove(decline)/block/revoke_invites/invite/close/leave; `sdi_challenge_action` create/schedule/cancel/remove_entry (server requires moderation permission with MFA); `sdi_calendar_range` one month within the 62-day bound | `RoomsClient`, `ChallengeLifecycleClient`, `CalendarClient` |
| `AccountLifecycleClient`, `NotificationsClient` | `sdi_account_lifecycle` status/request_deletion/cancel_deletion(revision)/export; `sdi_notify_action` preferences/set_preferences/inbox/mark_read. No device token is registered (no FCM) | `AuthService` account lifecycle; web notification settings |
| `SpatterClient` | schemaVersion 1 payload with the member JWT to the owner's backend; legacy `choices` replies accepted; future schemas refused; 128 KiB limits; budget shown only when sane. Replies are guidance text and never edit the project | `SpatterBackendClient` |

UI: the Account panel shows the real `AccountState`, sign-in/sign-up/guest/provider buttons, the video wall, own records and join-a-room-by-code, plus tabs for War Room (matchups, favourite vote, propose/accept from own approved videos, report, notices/appeal), Challenges (phases, entries, submit/withdraw, favourite), Shared rooms (start/stop sync, check for edits, honest queued-not-applied state), Notifications (server preferences and announcements inbox) and Account data (status, export, deletion request/cancel). Guests and unconfigured builds see an explanation and send nothing. The Spatter panel gains a cloud guidance box.

### Owner-supplied configuration (public values only)

Pass at build time, never commit: `-Psdi.supabaseUrl=https://<project>.supabase.co -Psdi.supabasePublishableKey=sb_publishable_… [-Psdi.oauthProviders=google,github,microsoft,apple] [-Psdi.spatterBackendUrl=https://…]` (or the `SDI_SUPABASE_URL`, `SDI_SUPABASE_PUBLISHABLE_KEY`, `SDI_OAUTH_PROVIDERS`, `SDI_SPATTER_BACKEND_URL` environment variables). Only when both Supabase values are present does Gradle merge `src/connected/AndroidManifest.xml`, which adds INTERNET, `singleTask` and the OAuth redirect filter. The owner must also add `stickdeath://auth/callback` to the Supabase redirect allow-list, enable each OAuth provider (and anonymous sign-ins, if guests are wanted) in Supabase, and apply the `backend/sql` candidates the clients call.

### Verification state

- JVM: the `connect` sources plus `BackendContract` were compiled with Kotlin 2.0.21 and their 40 JUnit tests (`BackendConfigTest`, `SessionManagerTest`, `CommunityClientsTest`, `SpatterClientTest`, `BackendContractTest`) passed in a standalone JVM Gradle project on the Linux host (2026-10-14), using a stand-in for the generated `BuildConfig`. This is not the Android Gradle build.
- Android (2026-10-14 batch): `AccountViewModel`, `ConnectedPanels`, `KeystoreSessionVault` and the `MainActivity` wiring had not compiled at that time; they compiled in the unconnected debug build recorded below. The connected-flavour manifest switch (Supabase values supplied) is still not built here.
- War Room / challenges / room command sync / account lifecycle / notifications / quick share batch (2026-10-18): `gradle --project-dir android :app:testDebugUnitTest :app:assembleDebug` (Gradle 8.14.3, AGP 8.7.3, a scratch SDK with `platforms;android-35` and `build-tools;34.0.0`, no Supabase values) completed with BUILD SUCCESSFUL on the Linux host: the whole app including `CommunityViewModel`, `CommunityPanels`, `QuickShareControls` and the `MainActivity` share wiring compiled, and all 136 JVM unit tests passed (new: `ContestClientsTest`, `AccountServicesTest`, `RoomCommandSyncTest`, `QuickShareTest`). The debug APK was not installed or run; no emulator, device, connected-flavour build or backend was exercised, so UI behaviour, intents to destination apps and the document picker remain unverified.
- Shared-room Studio sync / room owner screens / challenge moderation / calendar batch (2026-10-18): `gradle --project-dir android --no-daemon :app:testDebugUnitTest :app:assembleDebug` (same scratch SDK, no Supabase values) completed with BUILD SUCCESSFUL; all 150 JVM unit tests passed (new: `StudioSharedEditTest`, `RoomOwnerAndScheduleTest`). The APK was not installed or run; the editor gesture/playback hooks, the 3-second sync loop and every new screen remain unverified on a device, and no backend was contacted.
- Live: no request has been sent to any backend. Authenticated end-to-end journeys against a test backend remain open (#288).

### Store listing copy draft (owner approval required)

- Title: StickDeath Studio
- Short description: Draw frame-by-frame stick animations with layers, brushes, audio tracks and honest exports.
- Full description (draft): "StickDeath Studio is a native animation studio. Sketch with pencils, markers, crayons and textured brushes, stack layers with blend modes and locks, time frames with exposure holds, place sound effects on four tracks, and export MP4, GIF, PNG sequences or spritesheets with timing manifests. Projects stay on your device; nothing uploads without your explicit action. This release has no account, feed or messaging features."
- Category: Art & Design. Content rating: to be completed by the owner with the questionnaire; the app contains no user-generated sharing in this build.
- Screenshots: owner-approved renders of the Studio canvas, layers panel, audio timeline and export panel. No third-party or recovered artwork.

### Debug build install guide

1. Open the latest successful "SDI Android Compile" run in GitHub Actions and download the `sdi-android-debug-<sha>` artifact; `android-build-evidence/apk-sha256.txt` lists the APK checksum, `sound-assets.json` the packaged-sound verification.
2. On the device, enable Developer options and USB debugging (Settings → About → tap Build number seven times; Settings → System → Developer options).
3. Verify the checksum (`sha256sum app-debug.apk`) matches the evidence file.
4. Install with `adb install -r app-debug.apk` (or copy the APK to the device and open it; allow installs from your file manager when asked). The debug build is signed with a debug key: it is not a store release and will not update a store install.
5. Optional instrumented tests: `gradle :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.stickdeath.studio.SwiftProjectImportTest` from `android/` with the device attached.
6. Report problems with the APK checksum, device model, Android version and the redacted crash report shown in Account → Diagnostics; never share project files you do not own.

Build and runtime evidence belongs to the exact commit and CI run. Pending physical-device, lifecycle, accessibility, sharing and cross-platform acceptance is not a pass. #287 owns Studio delivery; #288 owns connected-client parity; #289 owns Android billing/push/store release. #286 remains open until its interchange and cross-platform evidence requirements are satisfied.
