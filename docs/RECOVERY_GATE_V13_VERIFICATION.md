# Recovery Gate v13 — Verification Report

## PR Head SHA
- Branch: `oc/issue-61-recovery-gate-v13-wire-the-real-app-to-sdcore-an`
- Base: `main` (c30da81)
- **Final head SHA: PENDING** (not committed by OpenCode per bridge rules)

## Swift Version / Build / Test

### SDCore Package (Linux)
- **Command:** `swift --version` — **NOT RUN** (Swift not available on this Linux host)
- **Command:** `swift build --package-path SDCore` — **NOT RUN** (Swift not available)
- **Command:** `swift test --package-path SDCore` — **NOT RUN** (Swift not available)
- **Status:** Must be verified via GitHub Actions (see below)

### GitHub Actions
- **Workflow:** `.github/workflows/ci.yml`
- **Run ID:** PENDING (triggers on PR creation)
- **Expected steps:**
  1. `swift --version`
  2. `swift build --package-path SDCore`
  3. `swift test --package-path SDCore`
  4. `git diff --check`
  5. Forbidden secrets scan (no direct provider hosts in client)
  6. AppConfig forbidden fields scan
  7. DeviceStorageManager write-api scan

## AppConfig Evidence
- **File tracked:** `StickDeathInfinity/App/AppConfig.swift` (removed from `.gitignore`)
- **Contents:** Public-only config — `supabaseURL`, `supabaseAnonKey`, `liveKitWSURL`, `liveKitURL`, `backendBaseURL`, `SubscriptionTier` enum, `CallRateTier` enum
- **Forbidden fields:** No API keys, OAuth secrets, signing identities, admin email allowlists, or provider credential fields
- **Empty strings produce unavailable state:** `SupabaseManager` checks for empty config and returns `nil` client

## StudioViewModel Local-First Evidence
- **File:** `StickDeathInfinity/ViewModels/StudioViewModel.swift`
- `createProject()` — assigns UUID String ID, persists via `StudioStorage.shared.createProject()` immediately
- `save()` — writes to `StudioStorage.shared.saveProject()` FIRST, then optional `syncRemote()`
- `loadProjects()` — calls `StudioStorage.shared.listProjects()` first, then optional Supabase merge (never removes local-only)
- `openProject()` / `reopenProject()` — loads from `StudioStorage.shared.loadProject()`, invokes `LegacyMigrationManager`
- Remote sync uses `currentProjectID` (real UUID), never `AnyJSON.null`
- Remote failure does NOT roll back local save

## Canonical Layer Model Evidence
- **File:** `StickDeathInfinity/Views/Studio/Panels/LayerPanel.swift`
- Uses `SDCore.CanvasLayer` (String ID) as sole truth
- LayerRow selects layer on tap (`vm.selectLayer(layer.id)`)
- LayerDetailView: functional opacity slider, functional lock mode buttons, functional blend mode picker, functional glow toggle with color picker, functional duplicate/delete/move up/move down
- No `.constant(false)` glow toggle — uses real binding
- Delete button present (disabled when only 1 layer)
- `studioLayers` (UUID-based) eliminated; all references replaced with `layers` (String-based)

## DeviceStorageManager Evidence
- **File:** `StickDeathInfinity/Storage/DeviceStorageManager.swift`
- `saveAnimation()` — marked `@available(*, deprecated, message: "Use StudioStorage for new animation writes")`
- `deleteAnimation()` — marked `@available(*, deprecated, message: "Use StudioStorage for new animation deletes")`
- `loadAnimation()` and `listAnimations()` — retained as read-only discovery/migration adapters

## Legacy Migration Evidence
- **File:** `SDCore/Sources/SDCore/LegacyMigrationManager.swift`
- `discoverLegacyIDs()` — scans `Documents/Animations/` for directories
- `migrateLegacyAnimation()` — copies byte-identically when dest missing; reports `alreadyMigrated` when identical; reports `conflict` preserving both when different; NEVER deletes source
- Invoked by `StudioViewModel.openProject()` and `reopenProject()`
- **Tests:** `SDCoreTests.testMigrateLegacyAnimationCopiesBytes()`, `testMigrateAlreadyMigrated()`, `testMigrateConflictPreservesBoth()`

## Production Spatter Backend Seam Evidence
- **File:** `SDCore/Sources/SDCore/SpatterBackendClient.swift`
  - `BackendConfig` (public, non-secret): `baseURL`, `isEnabled`
  - `AuthTokenProvider` protocol: `currentAuthToken`, `isAuthenticated`
  - `SpatterBackendClient.chat()`: returns `nil` when config disabled or auth missing (zero transport calls)
  - `transportCallCount` for test assertions
- **File:** `StickDeathInfinity/Services/Spatter/SpatterService.swift`
  - Uses `SpatterBackendClient` (injected, not direct provider host)
  - No direct OpenAI/Gemini/Anthropic endpoints in client code
  - Offline fallback when backend unavailable
- **Tests:** `testBackendNoTransportWhenDisabled()`, `testBackendNoTransportWhenNotAuthenticated()`, `testBackendNoTransportWhenTokenMissing()`, `testBackendConfiguredAndAuthenticatedAllowsTransport()`

## .pbxproj + project.yml Package Wiring Evidence
- **project.yml:** Added `SDCore` local package with `path: SDCore`
- **project.pbxproj:**
  - `XCLocalSwiftPackageReference` section added for SDCore
  - `XCSwiftPackageProductDependency` added for SDCore
  - Added to `packageReferences` and `packageProductDependencies`
- **Package.swift:** Added `.package(path: "SDCore")` dependency

## Xcode/iOS Runtime
- **Status:** `NOT RUN` — Swift toolchain not available on this Linux host
- iOS build requires Xcode on macOS
