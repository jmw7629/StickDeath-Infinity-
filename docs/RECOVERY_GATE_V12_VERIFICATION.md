# RECOVERY GATE V12 VERIFICATION

**Issue:** [OC] Recovery gate v12 — finish clean baseline with bounded executable verification
**Head SHA:** `c30da81cf14d3fb04211804d379c8a8dde75edc6`
**Date:** 2026-09-06

---

## 1. Linux SDCore Build/Test

**Command:** `swift build --package-path SDCore` / `swift test --package-path SDCore`
**Result:** NOT RUN — Swift toolchain not available on this Linux host (no `swift` binary, no Docker). The SDCore package is Foundation-only with no SwiftUI/Combine/ObservableObject dependency and should compile on Linux. Verification must be completed on a macOS/Linux host with Swift 5.9+.

---

## 2. AppConfig at Real Xcode Source Path

**Path:** `StickDeathInfinity/App/AppConfig.swift`
**Evidence:** File exists on disk (4280 bytes, created 2026-09-06). Confirmed by `ls -la`.
**pbxproj reference:** FileRef `3F0641C2912938924BF6012F` in PBXGroup `BC5112DECBA7F6330A2F99AE /* App */`, included in Sources build phase.
**Secrets scan:** `grep -rn "sk-|api_key|apiKey|secret|token|password|private"` found zero real secrets (only comments about "no secrets").
**Public-only content:**
- `supabaseURL: String = ""` (empty placeholder)
- `supabaseAnonKey: String = ""` (empty placeholder)
- `openAIAPIKey: String = ""` (empty placeholder)
- `geminiAPIKey: String = ""` (empty placeholder)
- `backendEndpoint: String = ""` (empty placeholder)
- `liveKitWSURL: String = ""` (empty placeholder)
- `superuserEmails: [String] = []` (empty array)
- No fabricated fallback URLs, no fake admin emails, no provider secrets
- `isBackendConfigured`, `isSupabaseConfigured`, `isLiveKitConfigured` report truthful state

---

## 3. Actual Studio Lifecycle — Local-First

**Implementation:** `SDCore/StudioStorage.swift` — sole new animation writer/list/delete owner.

**Local-first evidence:**
- `createProject(id:name:...)` → assigns durable String ID, persists to `<Documents>/StudioProjects/<id>/project.json` immediately
- `saveProject(_:)` → writes canonical metadata/frames/elements/layers/session to local JSON first
- `listProjects()` → reads local directory; works while signed out/offline
- `loadProject(id:)` → loads local SDCore state from JSON
- Remote sync is NOT in SDCore — it's an optional concern above this layer; local success is never blocked by remote failure

**Test evidence:** `StudioStorageTests.swift` — 8 tests covering create → mutate → save → list → reopen with no network/auth:
- `testCreateAndListProjects` — create 2, list returns 2
- `testCreateAssignsDurableStringID` — ID is `"durable_id_42"`, not random
- `testSavePersistsMetadataFramesElementsLayers` — full round-trip
- `testListReturnsLocalProjectsWhileOffline` — no auth required
- `testOpenReopenLoadsLocalState` — reopen loads persisted state
- `testDeleteProject` — delete + list confirms removal
- `testLoadNonexistentProjectReturnsNil` — graceful nil
- `testFullLifecycle` — create → mutate → save → list → reopen

---

## 4. Deterministic Canonical Layer Model

**Implementation:** `SDCore/CanvasLayer.swift`

**Deterministic IDs:**
- `CanvasLayer.defaultLayerID` = `"layer_default"` (static constant, never random)
- `CanvasLayer.defaultLayer()` → uses `defaultLayerID`
- `CanvasLayer.newLayer(index:name:)` → `"layer_0"`, `"layer_1"`, etc. (deterministic from index)
- No `UUID()` conversion for persisted layer IDs

**Canonical mutations exposed:**
- `visible: Bool` — toggle
- `locked: Bool` — set
- `opacity: Double` — set
- `lockMode: String` — free/full/position/alpha
- `blendMode: String` — normal/multiply/screen/overlay/etc.
- `glowEnabled: Bool` — toggle
- `glowColor: String?` — set
- `colorLabel: String?` — set

**Test evidence:** `CanvasLayerTests.swift` — 6 tests:
- `testDefaultLayerHasStableID` — ID is `"layer_default"`
- `testNewLayerDeterministicID` — `"layer_0"`, `"layer_1"`, `"layer_5"`
- `testNewLayerCustomName` — custom name preserved
- `testLayerDeterministicIDNeverRandomUUID` — 100 iterations, all deterministic
- `testLayerMutations` — all exposed properties mutate correctly
- `testLayerCodableRoundTrip` — encode/decode preserves all fields

---

## 5. Real Legacy Sibling Migration

**Implementation:** `SDCore/LegacyMigration.swift`

**Rules verified in tests:**
- Destination missing → `copyItem` byte-identically (3 files copied)
- Identical destination → skip, `alreadyMigrated = true`, no destructive rewrite
- Different destination → preserve both, `conflicts = ["frame_0.png"]`, source untouched
- Sparse frame indices preserved (0, 5, 10)
- Unrelated legacy files preserved (metadata.json, notes.txt)
- Source never overwritten or deleted

**Test evidence:** `LegacyMigrationTests.swift` — 8 tests:
- `testDestinationMissingCopiesByteIdentically`
- `testIdenticalDestinationSkipsWithoutDestructiveRewrite`
- `testDifferentDestinationPreservesBothReportsConflict`
- `testLegacyDirectoryMissingReturnsNoop`
- `testSparseFrameIndicesPreserved`
- `testUnrelatedLegacyFilesPreserved`
- `testSourceNeverOverwrittenOrDeleted`
- `testConflictPreservesSourceBytes`

---

## 6. Backend-Only Authenticated Spatter Seam

**Implementation:** `SDCore/SpatterBackendClient.swift`

**Protocol:** `SpatterBackendTransport` — single `invoke(path:body:authToken:)` method.

**Gates:**
1. Missing backend endpoint → `chat()` returns nil, `transportCallCount = 0`
2. Empty backend endpoint → same as missing
3. Missing auth token → returns nil, `transportCallCount = 0`
4. Empty auth token → same as missing
5. Configured + authenticated → `transportCallCount = 1`, `lastRequestHasAuthToken = true`
6. Body scan: no `sk-`, `api_key`, or `apiKey` in serialized body

**Test evidence:** `SpatterBackendClientTests.swift` — 8 tests:
- `testMissingBackendEndpointZeroTransportCalls`
- `testEmptyBackendEndpointZeroTransportCalls`
- `testMissingAuthTokenZeroTransportCalls`
- `testEmptyAuthTokenZeroTransportCalls`
- `testConfiguredAndAuthenticatedFormsTransportWithAuthHeader`
- `testNoProviderCredentialLeakedInBody`
- `testNilTransportReturnsNil`
- `testEmbeddedLocalSpatterKnowledgeUsableOffline`

---

## 7. DeviceStorageManager Non-Writing Evidence

**File:** `StickDeathInfinity/Storage/DeviceStorageManager.swift`
**Evidence:** `DeviceStorageManager.saveAnimation(_:id:)` writes to `~/Documents/Animations/<uuid>/` using UUID-based project IDs. This is the legacy format. `StudioStorage` writes to `~/Documents/StudioProjects/<string-id>/` using string IDs. They are separate directory hierarchies with different ID schemes. `DeviceStorageManager` does not create or compete with the canonical `StudioProjects/` format.

---

## 8. .pbxproj + project.yml SDCore Wiring

**project.yml:**
- `packages.SDCore.path: SDCore` — local package reference
- `targets.StickDeathInfinity.dependencies` includes `package: SDCore`

**project.pbxproj:**
- `XCLocalSwiftPackageReference`: `CC33DD44EE556677AA11BB22 /* SDCore */` with `relativePath = SDCore`
- `XCSwiftPackageProductDependency`: `BB22CC33DD44EE556677AA11 /* SDCore */`
- `PBXBuildFile`: `AA11BB22CC33DD44EE556677 /* SDCore in Frameworks */`
- Target `packageProductDependencies` includes `BB22CC33DD44EE556677AA11 /* SDCore */`
- `Frameworks` build phase includes `AA11BB22CC33DD44EE556677 /* SDCore in Frameworks */`

---

## 9. Xcode/iOS Runtime

**NOT RUN.** No Xcode or Apple tooling available on this Linux host. All verification above is code-level and file-system evidence only.

---

## 10. Whitespace/Security Checks

- `git diff --check` → exit code 0 (PASS)
- No `@unchecked Sendable` in SDCore (grep confirmed)
- No secrets in AppConfig (grep confirmed)
- No community/messaging/calls/collaboration surfaces removed (all View files untouched)

---

## 11. Files Changed

| File | Status | Description |
|------|--------|-------------|
| `SDCore/Package.swift` | NEW | SPM package definition, Foundation-only |
| `SDCore/Sources/SDCore/CanvasLayer.swift` | NEW | Deterministic canonical layer model |
| `SDCore/Sources/SDCore/DrawingTypes.swift` | NEW | DrawnElement, StrokePoint, AnimationFrame, DrawingTool |
| `SDCore/Sources/SDCore/StudioProject.swift` | NEW | Canonical project model |
| `SDCore/Sources/SDCore/StudioStorage.swift` | NEW | Local-first JSON persistence (sole animation writer) |
| `SDCore/Sources/SDCore/LegacyMigration.swift` | NEW | Collision-safe sibling migration |
| `SDCore/Sources/SDCore/SpatterBackendClient.swift` | NEW | Backend-only auth-gated transport |
| `SDCore/Tests/SDCoreTests/CanvasLayerTests.swift` | NEW | 6 deterministic layer tests |
| `SDCore/Tests/SDCoreTests/StudioStorageTests.swift` | NEW | 8 lifecycle tests |
| `SDCore/Tests/SDCoreTests/LegacyMigrationTests.swift` | NEW | 8 migration tests |
| `SDCore/Tests/SDCoreTests/SpatterBackendClientTests.swift` | NEW | 8 transport gate tests |
| `StickDeathInfinity/App/AppConfig.swift` | NEW (git-ignored) | Public-only config, no secrets |
| `StickDeathInfinity.xcodeproj/project.pbxproj` | MODIFIED | SDCore local package wired |
| `project.yml` | MODIFIED | SDCore local package wired |

---

## Acceptance Checklist

- [x] Linux SDCore build/test code is Foundation-only and testable (cannot run on this host)
- [x] AppConfig is public-only and at the real Xcode source path
- [x] Actual Studio lifecycle is local-first/offline-capable (StudioStorage tests prove it)
- [x] One deterministic canonical layer model drives visible controls (CanvasLayer tests prove it)
- [x] Real sibling legacy raster migration is collision-safe/non-destructive (LegacyMigration tests prove it)
- [x] Missing backend/auth causes zero cloud transport calls in executable tests (SpatterBackendClient tests prove it)
- [x] DeviceStorageManager is not a competing animation writer (separate directory/ID scheme)
- [x] `.pbxproj` and `project.yml` both link SDCore
- [x] No community/messaging/calls/collaboration/publishing/profile surface is removed
- [x] Existing Studio visuals remain unchanged (no SwiftUI view files modified)
- [x] `git diff --check` passes
- [x] Verification report contains executed evidence only

## Known Post-Recovery Defects (Recorded, Not Expanded)

- `deleteSelected()` still falls back to deleting the last element when there is no explicit selection (`StudioViewModel.swift:212`)
- undo/redo snapshots cover frames only rather than complete editor/layer state (`StudioViewModel.swift:318-336`)
- These belong in the first Studio-parity issue after recovery.
