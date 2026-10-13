# Accessibility, Dynamic Type and adaptive layout strategy (#264)

Source baseline: branch head `ee35143` plus the wave-3 QA changes described
here. Everything in this document is a source contract or an offline
measurement. **No native run has executed the new audit journey yet**; its
result is deferred until the exact-source CI shards run (#124).

## 1. What exists in source today

| Area | Count at `ee35143` | Source of the number |
| --- | ---: | --- |
| `accessibilityIdentifier` (static, unique) | 506 identifiers / 518 rows | `python3 scripts/verify_control_index.py` |
| `accessibilityLabel` | 107 | `grep -rc accessibilityLabel StickDeathInfinity --include=*.swift` |
| Fonts declared relative to a text style (`relativeTo:`) | 110 | same grep pattern |
| Fixed-size system fonts `.font(.system(size:))` | 309 in 40 files | same grep pattern (top: `SubscriptionView` 26, `SpatterCCSettingsView` 20, `SpatterDashboardView` 19, `SpatterAnalyticsView` 18, `SpatterBotConfigView` 16, `ChallengeDetailView` 16, `StudioView` 15, `LayerPanel` 9, `StudioMovieExportControls` 9, `StudioTimeline` 6) |
| `@ScaledMetric` | 0 before this change; 2 property wrappers in `Font+SD.swift` now | `grep -rn @ScaledMetric` |
| `dynamicTypeSize` caps | 0 before; one helper (`sdStudioDynamicTypeRange`) now, not yet applied | `grep -rn dynamicTypeSize` |
| `horizontalSizeClass` / `userInterfaceIdiom` checks | 0 | `grep -rn horizontalSizeClass` |
| `accessibilityReduceMotion` | Splash, Welcome, Onboarding only | `grep -rln accessibilityReduceMotion` |
| Landscape journeys in the UI suite | `testGuestStudioPortraitLandscapeAndPersistedGuideControls`, `testFloatingToolbarDockingAndPopupDismissal`, `testBundledSoundLibraryMixAndOfflineReopen`, and now `testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize` | `Tests/NativeUI/StudioSmokeUITests.swift` |
| CI simulator | iPhone 16 Pro only (`scripts/native-smoke/select_simulator.py:18`) | — |

## 2. Dynamic Type contract

1. **Typewriter headings already scale.** `Font.specialElite(_:relativeTo:)`
   uses `Font.custom(_:size:relativeTo:)`, so every heading follows the user's
   text size.
2. **System fonts must stop being fixed.** `StickDeathInfinity/Extensions/Font+SD.swift`
   now provides:
   - `.sdScaledSystemFont(size, weight:, design:, relativeTo:)` — a
     `ViewModifier` with `@ScaledMetric(relativeTo:)`, so a 16 pt label becomes
     roughly 21 pt at the first accessibility size instead of staying 16 pt;
   - `.sdScaledFrame(width:height:relativeTo:)` — icon boxes and thumbnails
     that grow with the text next to them;
   - `.sdMinimumTouchTarget()` — `frame(minWidth: 44, minHeight: 44)` plus
     `contentShape(Rectangle())` for icon-only controls;
   - `.sdStudioDynamicTypeRange()` — `dynamicTypeSize(...accessibility2)` for
     dense Studio chrome (toolbar, layer rows, timeline) so the canvas never
     collapses; it caps growth above the standard sizes, never below them, and
     it is **not** for reading surfaces (Spatter, help, settings).
3. **First adopter:** `Views/Components/SDTextField.swift` (icon and field use
   `sdScaledSystemFont(16)`, the icon box uses `sdScaledFrame`, the decorative
   icon is hidden from VoiceOver). Every sign-in and profile form inherits it.
4. **Migration recipe for the other 307 fixed fonts** (owners of each view, see
   the counts above; mechanical and reviewable per file):
   - `.font(.system(size: N))` → `.sdScaledSystemFont(N)`;
   - `.font(.system(size: N, weight: W))` → `.sdScaledSystemFont(N, weight: W)`;
   - `.font(.system(size: N, weight: W, design: D))` → `.sdScaledSystemFont(N, weight: W, design: D)`;
   - pick `relativeTo:` by role: `.caption2`/`.caption` for ≤ 12 pt, `.footnote` 13 pt,
     `.subheadline` 15 pt, `.body` 16–17 pt, `.headline`/`.title3` ≥ 18 pt;
   - fixed `.frame(width: W, height: H)` around glyphs → `.sdScaledFrame(width: W, height: H)`;
   - do **not** convert canvas-space measurements (brush previews, rulers,
     thumbnails sized in canvas pixels) — those are geometry, not type.
5. **What must not happen:** no `.minimumScaleFactor` as a substitute for
   scaling, no `lineLimit(1)` on labels whose text can wrap, no hard-coded
   44 pt replaced by smaller values to make a row fit.

## 3. Size classes and iPad

- `TARGETED_DEVICE_FAMILY` is `1,2` (`project.yml`), so the app installs on
  iPad, but no view reads `horizontalSizeClass`. The Studio layout is a single
  phone layout stretched; the floating toolbar snaps to either canvas edge and
  the single options popup keeps working, which is the owner's layout contract
  (`docs/STUDIO_TOOLBAR_VERIFICATION.md`, `docs/STUDIO_POPUP_CONTENT_FIT_VERIFICATION.md`).
- Recommended, not implemented: read `@Environment(\.horizontalSizeClass)` in
  `StudioView` and `StudioAudioWorkspace` to let the layer and audio panels sit
  beside the canvas in `.regular` width instead of covering it; keep the
  compact behaviour byte-identical on iPhone. Needs an iPad destination in CI
  (`select_simulator.py` creates one `iPhone 16 Pro`; an `iPad (A16)` or
  `iPad Pro 11-inch (M4)` device type would be a second owned simulator and a
  second budget line, not a change to the existing one).
- Until that exists, iPad evidence is **owner-gated/deferred**: rows 20 of
  `docs/VISUAL_REFERENCE_MAP.md` stay `deferred`.

## 4. The new audit journey

`testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize` (`Tests/NativeUI/StudioSmokeUITests.swift`):

- launches with `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL`
  (the shared `launchAtWelcome`/`launchGuestStudio` helpers gained an
  `extraLaunchArguments:` parameter; the default call sites are unchanged);
- on the project library, the Studio in portrait and the Studio in landscape:
  captures `library-accessibility-xl`, `studio-portrait-accessibility-xl`,
  `studio-landscape-accessibility-xl`;
- asserts the canvas is wider and taller than 80 pt and inside the app
  bounds, that `studio.back`, `studio.toolbar.toggle`, `studio.export.open`,
  `studio.save`, `studio.undo`, `studio.redo`, `studio.layers.open`,
  `studio.audio.open` exist and are hittable, that the three header controls
  which declare 44 pt minimums in source really measure ≥ 44 pt, and attaches
  every measured frame (`touch-targets-accessibility-xl-<orientation>`);
- runs `performAccessibilityAudit(for: .all)`. **Enforced** (a finding fails
  the test): `sufficientElementDescription` (VoiceOver labels) and `hitRegion`.
  **Recorded** (returned as handled, written to
  `accessibility-audit-recorded-<screen>` with the detailed text and counted in
  `accessibility-audit-summary-<screen>`): `contrast`, `dynamicType`,
  `textClipped`, `elementDetection`, `trait`, `parentChild`. Recording is not
  waiving: each attachment is a defect list to triage, and the migration in
  section 2 is what closes the `dynamicType`/`textClipped` entries.
- iOS 17 is required for the audit API; the CI runtime is iOS 18. On an older
  runtime the test fails explicitly rather than skipping (skips are rejected by
  the shard receipt).

Budget: the case runs at the 180 s default; the suite inventory is now 110
cases (`scripts/native-smoke/test_budget.py`), the source pin in
`run_recorded_test.py` was recomputed, and the shard ceilings become 224/203
minutes (`docs/ci-candidates/spatter-client-verify.yml`).

## 5. Reduce Motion

Honoured in Splash, Welcome and Onboarding. Not yet honoured for: toolbar
snap animation (`StudioToolStrip`), popup presentation, Spatter orb pulse
(`SpatterOrbView`), timeline playhead scrubbing. Recommended: read
`@Environment(\.accessibilityReduceMotion)` and pass `nil` animation (or a
0.0 s linear one) in those four places; cross-fade instead of slide for the
popup. Deferred; file-owners' change.

## 6. Status

| Check | Status |
| --- | --- |
| Contrast tokens (`sdTextMuted`, `textFaint`) | measured offline, see `docs/STUDIO_CONTROL_CONTRAST_VERIFICATION.md` section "Token re-measurement 2026-10-12" |
| Dynamic Type helpers | DONE in source (`Font+SD.swift`), first adopter `SDTextField.swift`; `swiftc -parse` only — native compilation deferred |
| Audit journey | DONE in source; **DEFERRED (not run)** — needs the exact-source shard run |
| VoiceOver manual pass, iPad captures, Reduce Motion in Studio | deferred / owner-gated |
