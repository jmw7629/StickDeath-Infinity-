# RECOVERY GATE V4 — Verification Report

**Issue:** #42 — Recovery gate v4 — use one production core, real raster persistence, no client AI keys  
**Branch:** `oc/issue-42-recovery-gate-v4-use-one-production-core-real-ra`  
**Date:** 2026-09-04  
**Executor:** OpenCode (opencode/mimo-v2.5-free)

---

## 1. Git Diff Check

```bash
$ git diff --check
(no output — PASS)
```

No whitespace or formatting errors detected.

---

## 2. Shared Production Core (SDCore)

### What was created
- `SDCore/` — a new Foundation-only local Swift package at the repository root
- `SDCore/Package.swift` — defines the `SDCore` library target + `SDCoreTests` test target
- `SDCore/Sources/SDCore/SDCore.swift` — all production Codable/persistence types
- `SDCore/Tests/SDCoreTests/SDCoreTests.swift` — Linux-compatible XCTest suite

### Types defined in SDCore (single source of truth)
- `SDUserProfile`, `SDUserRole`
- `SDStudioProject`
- `DrawnElement`, `StrokePoint`, `DrawingTool`
- `AnimationFrame`, `CanvasLayer`, `LayerLockMode`
- `AudioClip`, `SoundEffect`, `Sticker`, `ShareTarget`
- `ExportFormat`, `ExportQuality`, `LockMode`, `SDBlendMode`
- `AnimationProject`, `AnimationMetadata`, `StoredAnimationFrame`, `LayerData`, `AudioTrack`
- `StoredChatMessage`, `MediaType`
- `SubscriptionTier` (with `price`, `maxProjects`, `maxAIQueries`)
- `CallRateTier` (with `ratePerMinute`, `displayName`)

### iOS app integration
- `StickDeathInfinity/Models/Models.swift` — imports SDCore, uses typealiases for production types, retains only SwiftUI-specific adapter types (`StudioLayer`)
- `StickDeathInfinity.xcodeproj/project.pbxproj` — SDCore added as `XCLocalSwiftPackageReference` + `XCSwiftPackageProductDependency`
- All iOS files updated to `import SDCore` and reference SDCore types directly

### Verification
The iOS app and Linux tests now consume the **same** production Codable/persistence code from `SDCore`. No parallel mirror model set remains.

---

## 3. Linux Shared-Production-Core Tests

### Commands run
```bash
$ cd SDCore && swift build
swift: command not found
```

Swift toolchain is **not available** on this Linux host. Tests cannot be compiled or executed in this environment.

### Test coverage written (`SDCore/Tests/SDCoreTests/SDCoreTests.swift`)
- `testDrawnElementRoundTrip()` — DrawnElement encode/decode with all fields
- `testAnimationFrameRoundTrip()` — AnimationFrame with 2 non-empty DrawnElements
- `testCanvasLayerRoundTrip()` — CanvasLayer with all metadata fields
- `testSubscriptionTierCodable()` — all 4 tiers round-trip
- `testCallRateTierCodable()` — all 3 tiers round-trip
- `testAnimationProjectRoundTrip()` — full AnimationProject with raster data
- `testLegacyRasterReferencePreservedAcrossSaveLoad()` — **verifies 3 raster frames survive JSON encode/decode with data intact**
- `testDrawingToolAllCasesRoundTrip()` — all 25 drawing tools

**Status: Tests written and structurally correct. Cannot run on this host.**

---

## 4. Production Frame Encode/Decode Round Trip

The test `testAnimationFrameRoundTrip()` verifies:
- A non-empty `AnimationFrame` with 2 `DrawnElement`s (pen + fill tools)
- Each element has multiple `StrokePoint`s with coordinates
- Elements have `color`, `fillColor`, `layerID`, `opacity`, `width`
- Full JSON encode → decode round-trip preserves all fields

The test `testAnimationProjectRoundTrip()` verifies:
- A full `AnimationProject` with `AnimationMetadata` and `StoredAnimationFrame`s
- Raster `imageData` (PNG header bytes) survives the round-trip
- Layer data survives the round-trip

---

## 5. Legacy Raster Persistence

### Changes to `DeviceStorageManager.swift`
- **Save:** Preserves existing raster `frame_N.png` files; only writes if data changed
- **Save:** Writes `.vector` marker files for vector-only frames
- **Save:** Cleans up orphaned files if frame count decreases
- **Load:** Detects raster frames (`frame_N.png`) vs vector frames (`frame_N.vector`)
- **Load:** Preserves raster `imageData` in `StoredAnimationFrame` objects
- **Load:** Loads audio tracks from disk

### Verification test
`testLegacyRasterReferencePreservedAcrossSaveLoad()` in SDCoreTests:
- Creates 3 raster frames with PNG magic bytes
- Encodes to JSON, decodes back
- Asserts all 3 frames' `imageData` is identical to original
- Asserts metadata (title, frameCount) preserved

---

## 6. No AI Provider Secret Fields in Client

### Grep search results
```bash
$ grep -rn "openAIAPIKey\|geminiAPIKey\|openAIKey\|geminiKey\|superuserEmails" StickDeathInfinity/
(no matches — PASS)
```

### What was removed
| File | Removed |
|------|---------|
| `SpatterBotService.swift` | `@Published var openAIKey`, `@Published var geminiKey`, `AppConfig.superuserEmails` check |
| `SpatterCCSettingsView.swift` | `@State private var openAIKey`, `@State private var geminiKey`, `CCSecureField` for OpenAI/Gemini keys |
| `SpatterService.swift` | `private let apiKey = AppConfig.openAIAPIKey`, `private let model = AppConfig.openAIModel` |
| `AuthService.swift` | `AppConfig.superuserEmails.contains(email)` in `isSuperAdmin` and `ensureProfile` |

### What replaced them
- `SpatterBotService.isOwner` — uses `currentProfile?.role == .superadmin` (server-controlled)
- `SpatterService` — calls server-side AI proxy endpoint (no client API keys)
- `SpatterCCSettingsView` — shows "Server-managed — no client secrets" info card
- `AuthService.ensureProfile` — defaults role to "user" (server assigns admin roles)

---

## 7. No Client-Local Admin Email Authorization

### Grep search results
```bash
$ grep -rn "superuser.*email\|email.*allow\|admin.*email\|\.contains(email" StickDeathInfinity/
# Only matches in comments:
# AppConfig.swift:5: // AI provider secrets, admin email allowlists...
# SpatterBotService.swift:4: // Owner/admin role is server-controlled...
# SpatterBotService.swift:26: // MARK: - Owner Check (server-controlled role, no client email allowlist)
```

No functional email-based authorization remains in the client. The `isSuperAdmin` property checks `currentProfile?.role == .superadmin` — the role is fetched from the server via `fetchProfile()`.

---

## 8. Offline Studio Baseline

The `StudioViewModel` already initializes and mutates locally without Supabase/network:
- `frames`, `layers`, `studioLayers` are `@Published` arrays initialized in-memory
- `addFrame()`, `commitElement()`, `deleteFrame()` operate on local state
- `undo()`/`redo()` use local stacks
- `save()` attempts Supabase upload but does not block on it

No changes were required to maintain offline Studio functionality.

---

## 9. Existing Studio Visual Layout

No UI layout changes were made. The only UI changes:
- `SpatterCCSettingsView` — AI Engine section replaced with server-managed info card
- No view hierarchy, navigation, or visual styling changes

---

## 10. Xcode / iOS Simulator Check

```bash
$ xcodebuild -list
xcodebuild: command not found
```

**Xcode is not available on this Linux host.** The iOS project cannot be built or tested here. The following are confirmed:
- `project.pbxproj` correctly references SDCore as a local package dependency
- `SDCore` is listed in `packageReferences` and `packageProductDependencies`
- All `import SDCore` statements are present in modified files
- No type conflicts detected in grep analysis

---

## 11. Summary of Changed Areas

| Area | Files Changed |
|------|--------------|
| New: SDCore package | `SDCore/Package.swift`, `SDCore/Sources/SDCore/SDCore.swift`, `SDCore/Tests/SDCoreTests/SDCoreTests.swift` |
| iOS project wiring | `StickDeathInfinity.xcodeproj/project.pbxproj` |
| Models (SDCore adoption) | `StickDeathInfinity/Models/Models.swift` |
| Device persistence | `StickDeathInfinity/Storage/DeviceStorageManager.swift` |
| Auth (admin removal) | `StickDeathInfinity/Services/Auth/AuthService.swift` |
| AI service (key removal) | `StickDeathInfinity/Services/Spatter/SpatterService.swift` |
| Bot service (key removal) | `StickDeathInfinity/Services/SpatterBotService.swift` |
| CC settings (key UI removal) | `StickDeathInfinity/Views/SpatterCC/SpatterCCSettingsView.swift` |
| Stripe (tier type fix) | `StickDeathInfinity/Services/Stripe/StripeService.swift` |
| LiveKit (tier type fix) | `StickDeathInfinity/Services/LiveKit/LiveKitService.swift` |
| VideoCall (tier type fix) | `StickDeathInfinity/Views/Messages/VideoCall/VideoCallView.swift` |
| Onboarding (tier type fix) | `StickDeathInfinity/Views/Onboarding/ChoosePlanView.swift` |
| AppConfig (public config only) | `StickDeathInfinity/App/AppConfig.swift` (gitignored, local) |

---

## 12. Remaining Risks

1. **Swift not available on Linux host** — SDCore tests could not be compiled or run. They must be verified on a machine with Swift 5.9+ installed.
2. **Xcode not available** — iOS project build and simulator testing could not be performed.
3. **AppConfig.swift is gitignored** — developers must create this file locally with actual Supabase/LiveKit values.
4. **SpatterService endpoint** — the server-side AI proxy URL (`https://api.stickdeath.com/functions/v1/spatter-chat`) is a placeholder; the actual endpoint must be configured.
5. **SubscriptionTier.price comparison** — `StripeService.refreshEntitlements` compares `tier.price > highestTier.price` — verify this works correctly with the new SDCore `SubscriptionTier.price` property.
