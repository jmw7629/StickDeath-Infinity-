# Recovery Gate V15 Verification

## PR Head SHA
`PENDING` — awaiting final head after bridge commit

## Actions Run
`PENDING` — awaiting GitHub Actions execution

## Docker Swift CI

| Check | Status | Evidence |
|-------|--------|----------|
| Swift version (Docker) | NOT RUN | Docker requires elevated permissions on VPS; will execute in GitHub Actions |
| `swift build --package-path SDCore` | NOT RUN | Same Docker limitation; CI workflow configured with `swift:5.9.2` |
| `swift test --package-path SDCore` | NOT RUN | Same; 4 test files covering lifecycle, layers, migration, transport |

## Security/Source Scan (local execution)

| Check | Status | Evidence |
|-------|--------|----------|
| Forbidden client identifiers (`openAIAPIKey`, `geminiAPIKey`) | PASS | `grep -rn` found zero matches in `StickDeathInfinity/` |
| Admin email allowlists (`superuserEmails`) | PASS | `grep -rn` found zero matches |
| Known secret patterns (`sk-`, `AIza`, `ghp_`) | PASS | `grep -rn` found zero matches |
| Fabricated fallback URLs | PASS | `grep -rn` found zero matches |
| Legacy writers in DeviceStorageManager | PASS | `saveAnimation`/`deleteAnimation` removed; only `loadAnimation`/`listAnimations` retained |
| AppConfig tracked | PASS | `StickDeathInfinity/App/AppConfig.swift` exists, tracked (removed from .gitignore) |
| project.yml SDCore | PASS | `SDCore` local package with `path: SDCore` present |
| pbxproj SDCore | PASS | `XCLocalSwiftPackageReference`, `XCSwiftPackageProductDependency`, and `PBXBuildFile` for SDCore added |
| Direct provider hosts | PASS | `api.openai.com` not present in `SpatterService.swift` |
| Whitespace (`git diff --check`) | PASS | Clean — no trailing whitespace |

## AppConfig Evidence
- Path: `StickDeathInfinity/App/AppConfig.swift`
- Contains: `openAIModel` (public model name), `supabaseURL` (empty string), `supabaseAnonKey` (empty string), `liveKitWSURL` (empty string), `SubscriptionTier` enum, `CallRateTier` enum
- **No** `openAIAPIKey`, `geminiAPIKey`, `anthropicAPIKey`, `superuserEmails`, provider key fields, or OAuth/signing secrets
- Empty Supabase/LiveKit URLs produce truthful nil/unavailable state at runtime

## StudioViewModel → Production Coordinator

| Call site | SDCore seam | Status |
|-----------|------------|--------|
| `loadProjects()` | `coordinator.loadProjects()` local first, optional remote reconciliation after local success | Implemented |
| `createProject(...)` | `coordinator.createProject(name:width:height:fps:)` — durable UUID String ID, persists canonical state locally | Implemented |
| `save()` | `coordinator.save()` — canonical local save first; remote sync only after local success; remote failure preserves local state | Implemented |
| `openProject(...)` | `coordinator.openProject(id:)` — loads canonical local state | Implemented |
| `reopenProject(...)` | `coordinator.reopenProject(id:legacyDir:)` — invokes migration, consumes result | Implemented |

## Offline Lifecycle Tests

| Test | File | Expected |
|------|------|----------|
| `testCreateProject` | `ProjectLifecycleTests.swift` | Project created with correct name/dimensions/fps, durable UUID ID |
| `testCreateProjectReturnsDurableID` | `ProjectLifecycleTests.swift` | Two projects have distinct, valid UUID string IDs |
| `testSaveAndList` | `ProjectLifecycleTests.swift` | Saved project appears in list |
| `testOpenProject` | `ProjectLifecycleTests.swift` | Reopened project matches original |
| `testOfflineCreateSaveListReopen` | `ProjectLifecycleTests.swift` | Full offline round-trip |
| `testFramesElementsLayersRoundTrip` | `ProjectLifecycleTests.swift` | Frames, elements, layers persist correctly |
| `testSessionMetadataRoundTrip` | `ProjectLifecycleTests.swift` | activeLayerID and activeFrameIndex preserved |
| `testLocalCreateFailureZeroRemoteCalls` | `ProjectLifecycleTests.swift` | Failing store produces error, zero remote calls |
| `testLocalSaveFailureZeroRemoteCalls` | `ProjectLifecycleTests.swift` | Failing store produces error, zero remote calls |
| `testLocalSuccessRemoteFailureReopensIntact` | `ProjectLifecycleTests.swift` | Local state intact after simulated remote failure |

## Canonical Layer Command Tests

| Test | File | Expected |
|------|------|----------|
| `testSetActiveLayer` | `LayerCommandsTests.swift` | Active layer ID changes |
| `testToggleVisibility` | `LayerCommandsTests.swift` | Visibility toggles |
| `testSetLockMode` | `LayerCommandsTests.swift` | Lock mode set correctly |
| `testSetOpacityClamps` | `LayerCommandsTests.swift` | Opacity clamped 0...1 |
| `testAddLayer` | `LayerCommandsTests.swift` | New layer added, becomes active |
| `testDuplicateLayer` | `LayerCommandsTests.swift` | Duplicate created with "Copy" suffix |
| `testDeleteLayer` | `LayerCommandsTests.swift` | Layer removed, activeLayerID repaired |
| `testDeleteLastLayerThrows` | `LayerCommandsTests.swift` | Error thrown for last layer |
| `testMoveLayerUp/Down` | `LayerCommandsTests.swift` | Layer reordered |
| `testLayerMutationsPersistOnReopen` | `LayerCommandsTests.swift` | All mutations survive persistence round-trip |

## Migration Tests

| Test | File | Expected |
|------|------|----------|
| `testMigrateLegacyAssets` | `MigrationTests.swift` | Assets + project.json migrated |
| `testMissingLegacyAssetCopied` | `MigrationTests.swift` | Byte-identical copy |
| `testIdenticalDestinationSkipped` | `MigrationTests.swift` | No rewrite |
| `testDifferentDestinationConflictReported` | `MigrationTests.swift` | Conflict reported, canonical preserved |
| `testSparseFrameIndicesPreserved` | `MigrationTests.swift` | Sparse frames preserved |
| `testCanonicalSaveDoesNotDeleteMigratedAssets` | `MigrationTests.swift` | Assets retained |

## Transport Tests

| Test | File | Expected |
|------|------|----------|
| `testMissingBackendThrows` | `TransportTests.swift` | `.missingBackend` error |
| `testMissingTokenThrows` | `TransportTests.swift` | `.missingAuthToken` error |
| `testConfiguredTransportCallsDelegate` | `TransportTests.swift` | Exactly 1 call, correct URL, Bearer token, no provider keys |
| `testSpatterTransportChat` | `TransportTests.swift` | Response parsed correctly |
| `testSpatterTransportNoProviderCredentials` | `TransportTests.swift` | No X-API-Key/X-Provider-Key headers |
| `testSpatterTransportRequestURL` | `TransportTests.swift` | URL = configured backend + `/v1/chat/completions` |

## DeviceStorageManager Evidence
- `saveAnimation` — removed (no implementation present)
- `deleteAnimation` — removed (no implementation present)
- `loadAnimation(id:)` — retained, read-only
- `listAnimations()` — retained, read-only
- `findLegacyAnimations()` — retained for migration discovery
- New persistence path: `studioProjectsDir` under `~/Documents/StudioProjects/`

## Spatter Production Seam Evidence
- `SpatterService.swift` uses `SDCore.AuthenticatedTransport` (injected)
- Default init: `baseURL: nil, sessionToken: nil` → zero transport calls
- Backend endpoint required: `baseURL` must be non-nil, `sessionToken` must be non-empty
- `Authorization: Bearer <token>` attached by `AuthenticatedTransport`
- No direct `api.openai.com` or any provider host in iOS production path
- Embedded `SpatterKnowledgeBase` remains usable offline

## Double/CGFloat Source Changes
- `StrokePoint.x/y/pressure`: changed from `CGFloat` to `Double` (SDCore canonical)
- `DrawnElement.width`: changed from `CGFloat` to `Double`
- `StudioCanvasView.swift`: all `CGPoint` ↔ `StrokePoint` conversions use explicit `CGFloat()` / `Double()` casts
- `FramesViewerPanel` in `StudioView.swift`: same explicit conversions
- Font sizes, line widths: `CGFloat(element.width) * scaleX` pattern used throughout
- No `Double * CGFloat` direct multiplication

## Package Wiring Evidence
- `project.yml`: `SDCore` local package with `path: SDCore`; dependency listed as `package: SDCore`
- `.pbxproj`: `XCLocalSwiftPackageReference` (CC11DD22EE33FF44AA556677) with `relativePath = SDCore`
- `.pbxproj`: `XCSwiftPackageProductDependency` (BB22CC33DD44EE55FF6677) with `productName = SDCore`
- `.pbxproj`: `PBXBuildFile` (AA11BB22CC33DD44EE55FF66) in Frameworks phase
- Root `Package.swift`: `.package(path: "SDCore")` dependency

## Xcode/iOS Build
`NOT RUN` — Linux VPS, no Xcode toolchain available. Swift Docker build/test pending GitHub Actions.

## Remaining Risks
1. Docker Swift build/test could not run locally (permission denied). CI workflow is configured and will execute in GitHub Actions.
2. Xcode iOS build cannot run on Linux. Source evidence only.
3. `StudioLayer` struct definition remains in `Models.swift` as dead code — could be cleaned up in follow-up.
4. `SpatterCCSettingsView` now has the AI Engine config section removed entirely (was showing API key inputs). If owner-only admin panel is desired, it should route through the authenticated backend seam in a follow-up.
5. Remote reconciliation in `loadProjects()` is a basic merge-by-ID; full conflict resolution deferred to known next task.
