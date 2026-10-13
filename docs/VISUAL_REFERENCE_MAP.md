# Visual reference map (#127)

Maps the owner-supplied reference screens named in #292, #293, #294 and #127 to
the capture names that the native UI suite produces
(`capture(app, name:)` in `Tests/NativeUI/StudioSmokeUITests.swift` at `ee35143`
plus the wave-3 journeys; names marked *new* exist in source but have no
artifact yet because the suite has not run since they were added).
The reference images themselves are private and are not in this repository.
Every comparison status is **deferred**: no same-viewport comparison has been
performed yet. A capture name here means a native screenshot exists for that
screen in a passing run of the named test; it does not mean parity.

Comparison protocol (to run on the owner's Mac, never from the web gallery):
same device class and orientation as the reference, record typography, spacing,
canvas, sheet and audio-library differences as actionable defects, exclude
obsolete messaging/calls and unapproved price or sample claims from the references.

| # | Reference screen (issue) | Native screen | Existing capture name(s) | Test function | Comparison status |
| --- | --- | --- | --- | --- | --- |
| 1 | Branded splash on cold launch: skull, red glow, "StickDeath Infinity" (#293) | `SplashScreenView` | `launch-<sha12>` (launch screenshot taken by the shared `launchAtWelcome` helper) | helper `launchAtWelcome`, used by `testWelcomeGuideNavigationAndLocalCompletion` and other welcome-start journeys | deferred |
| 2 | Welcome layout (#294 / Sept 19) | `WelcomeView` | `welcome-reference-layout`, `onboarding-welcome` | `testWelcomeGuideNavigationAndLocalCompletion` | deferred |
| 3 | Login / sign-up back control hit target (#293) | `LoginView`, `SignUpView` | `login-back-hit-target`, `signup-back-hit-target` | `testWelcomeGuideNavigationAndLocalCompletion` | deferred |
| 4 | Onboarding pages, landscape controls (Sept 19) | `OnboardingView` | `onboarding-collaboration-status`, `onboarding-landscape-controls` | `testWelcomeGuideNavigationAndLocalCompletion` | deferred |
| 5 | Project creation card: name, background, presets (Portrait/TikTok 1080×1920, Landscape/YouTube 1920×1080, Square, Instagram, SD, HD), FPS 6–30 default 12 (#292) | `StudioProjectLibrary` creation card | `owner-project-create-reference-card` | `testProjectConfigurationCardApplyUndoAndColdReopen` | deferred |
| 6 | Project settings card for an existing project, Apply/Cancel (#292) | `ProjectSettingsPanel` / library settings card | `owner-project-settings-reference-card`, `owner-project-settings-cold-reopen` | `testProjectConfigurationCardApplyUndoAndColdReopen` | deferred |
| 7 | Long library scrolls to the last project, creation expanded, keyboard shown/dismissed (#292) | `StudioProjectLibrary` | `owner-project-library-scroll`, `library-last-row-expanded-creation`, `library-last-row-opened-artwork`, `saved-project-library` | `testProjectConfigurationCardApplyUndoAndColdReopen`, `testProjectLibraryLastRowWithExpandedCreation`, `testRealCanvasStrokeUndoRedo` | deferred |
| 8 | Studio Back arrow returns to projects (#293) | `StudioHeaderBar` (`studio.back`) | `journey-library-after-back` (*new*: library after Back with the saved project visible), `rooms-back-to-studio` | `testCompleteProjectJourneyCreateDrawLayerAudioExportPNGAndColdReopen`, `testRoomsReplaceMessagingWithoutClaimingConnectedServices` | deferred — capture exists in source, not yet produced |
| 9 | Guest Profile matching the reference, device project count, Settings (#294) | `ProfileView` | `owner-guest-profile-reference`, `owner-guest-profile-settings` | `testGuestProfileProjectsAndSettingsNavigation` | deferred |
| 10 | Studio portrait with white floating primary toolbar (Sept 19/22) | `StudioView`, `StudioToolStrip` | `studio-portrait`, `toolbar-docked-<side>` (left/right), `toolbar-floating-popup` | `testGuestStudioPortraitLandscapeAndPersistedGuideControls`, `testFloatingToolbarDockingAndPopupDismissal` | deferred |
| 11 | Studio landscape (Sept 19/22; #127 orientation requirement) | `StudioView` | `studio-landscape-accessibility-xl` (*new*, at the accessibility text size), `audio-landscape-scroll`; the default-size landscape journey in `testGuestStudioPortraitLandscapeAndPersistedGuideControls` still has no named capture | `testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize`, `testBundledSoundLibraryMixAndOfflineReopen` | deferred — default-size named landscape capture still missing |
| 12 | Top menus / Studio menu sheet typography (#294) | `StudioMenuSheet` | none named | — | deferred — add capture |
| 13 | Tool options popup (brush, gradient, shape, selection, blur) typography and compact height (#294, Sept 22) | `FloatingToolSettingsPanel` | `brush-round-settings`, `brush-stipple-settings`, `gradient-family-sole-popup` (shared `drawNativeGradient` helper), `shape-fill-and-radius-popup`, `selection-scale-rotate-popup`, `blur-size-opacity-popup`, `editable-text-typography-popup` (shared `verifyEditableText` helper), `soft-eraser-strength-popup` | `testBrushLibrarySettingsUndoAndPersistence`, `testGradientBrushPixelsUndoAndColdReopen`, `testShapeFillRadiusUndoSaveReopenAndPNG`, `testSelectionScaleRotateUndoAndColdReopen`, `testBlurPixelsUndoAndColdReopen`, `testEditableTextUndoRedo`, `testEraserSettingsPersistAndResetAfterColdLaunch` | deferred |
| 14 | Layer and frame controls (#294) | `LayerPanel`, `StudioTimeline`, `FramesViewerPanel` | `layer-glow-real-controls`, `layer-rename-draft`, `layer-row-drag-real-order`, `frames-viewer-reordered-stable-selection`, `onion-range-tint-controls`, `grid-spacing-opacity-tint-controls` | `testLayerGlowColorRadiusStrengthUndoAndColdReopen`, `testLayerRenameCancelUndoAndColdReopen`, `testNativeLayerDragReordersPixelsUndoRedoAndColdReopen`, `testFramesViewerStableSelectionAfterReorderAndColdReopen`, `testGuestStudioPortraitLandscapeAndPersistedGuideControls` | deferred |
| 15 | Audio library (owner library screenshot) with tags, counts, preview (#294, Sept 19 audio reference) | `AudioPanels` library | `audio-expanded-aac-library`, `audio-bundled-library-two-clips`, `sound-library-no-match-query`, `audio-tag-search-preview-stopped`, `optional-micro-pack-downloaded-library` | `testExpandedAACLibrarySoundPlaybackAndOfflineReopen`, `testBundledSoundLibraryMixAndOfflineReopen`, `testSoundLibraryTagsCountsPreviewStopAndColdReopen`, `testOptionalMicroPackImportRemovalAndColdReopen` | deferred |
| 16 | Audio timeline (owner timeline screenshot) with measured waveforms, clip edits (Sept 19 audio reference) | `StudioAudioWorkspace` | `audio-empty-real-timeline`, `audio-real-mix-selected-clip`, `audio-fades-applied`, `audio-numeric-trim-applied`, `audio-split-right-half-selected`, `audio-duplicate-timing-at-four-times-zoom` | `testAudioFilesPickerCancellationPreservesBlankProject`, `testBundledSoundLibraryMixAndOfflineReopen`, `testAudioFadesCancelApplyUndoAndColdReopen`, `testAudioNumericTrimCancelApplyUndoAndColdReopen`, `testAudioClipSplitUndoAndColdReopen`, `testAudioClipDuplicateUndoAndColdReopen` | deferred |
| 17 | Export sheets: PNG, GIF, MP4 and native share (#294) | `ExportPanel`, `StudioGIFExportControls`, `StudioMovieExportControls` | `png-export-drawn-preview`, `png-native-share-sheet`, `gif-native-share-sheet`, `mp4-native-share-sheet`, `mp4-bundled-audio-native-share` | `testPNGExportPreviewAndNativeShareCancellation`, `testGIFExportFramesAndNativeShareCancellation`, `testMP4ExportReceiptAndNativeShareCancellation`, `testBundledAudioMP4AndNativeShareCancellation` | deferred |
| 18 | Image import panel and pickers (Sept 22 media reference) | `StudioImageImportPanel` | `image-native-photos-fixture-picker`, `image-native-files-picker`, `image-decoded-photos-preview`, `licensed-image-library-search` | `testPhotoImportUndoPersistenceAndRealPNGExport`, `testImagePhotosAndFilesCancellationPreserveProject`, `testLicensedImageLibraryUndoAndColdReopen` | deferred |
| 19 | Rooms screen replacing messaging (Sept 19) | `CollabRoomView` | `rooms-back-to-studio` | `testRoomsReplaceMessagingWithoutClaimingConnectedServices` | deferred |
| 20 | iPad / reference-size layouts (#127, #264) | all of the above | none; CI runs iPhone 16 Pro only (`scripts/native-smoke/select_simulator.py`) | — | deferred — needs an iPad destination (`docs/ACCESSIBILITY_DYNAMIC_TYPE.md` §3) |
| 21 | Accessibility text size: library and Studio must not collapse (#264) | `StudioProjectLibrary`, `StudioView` | `library-accessibility-xl`, `studio-portrait-accessibility-xl`, `studio-landscape-accessibility-xl` (*new*) plus `touch-targets-accessibility-xl-<orientation>` text attachments | `testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize` | deferred — not yet run |

## Preview-site screens → native captures

The product website's preview screens are illustrations of the native app;
they are never evidence. Each row names the native capture that shows the same
screen and the identifiers that anchor it, so a reviewer compares a real
attachment (byte-identical, labelled with its `sourceCommit`, see
`docs/NATIVE_SIMULATOR_REVIEW.md`) and not the web render.

| Preview-site screen | Native screen | Capture name(s) | Anchoring identifiers | Status |
| --- | --- | --- | --- | --- |
| Home (landing / "start creating") | `WelcomeView` → `StudioProjectLibrary` | `welcome-reference-layout`, `owner-project-library-scroll`, `library-last-row-expanded-creation`, `library-accessibility-xl` (*new*) | `welcome.guest`, `welcome.content`, `studio.library`, `studio.library.scroll`, `studio.new-project`, `studio.project-name`, `studio.create-project` | captures exist for the library; the signed-in community feed (`HomeFeedView`) has **no capture** — it shows "Sign in to view the community feed." without a backend |
| Studio (canvas + white floating toolbar) | `StudioView`, `StudioToolStrip`, `StudioHeaderBar` | `studio-portrait`, `toolbar-docked-left` / `toolbar-docked-right`, `toolbar-floating-popup`, `stroke-drawn`, `journey-drawn-stroke` (*new*), `studio-portrait-accessibility-xl` (*new*) | `studio.canvas`, `studio.toolbar`, `studio.toolbar.grip`, `studio.toolbar.toggle`, `studio.undo`, `studio.redo`, `studio.save`, `studio.back`, `studio.export.open` | captures exist; same-viewport comparison deferred |
| Tool popup (sole dismissible options popup) | `FloatingToolSettingsPanel` | `gradient-family-sole-popup`, `brush-round-settings`, `brush-stipple-settings`, `shape-fill-and-radius-popup`, `selection-scale-rotate-popup`, `blur-size-opacity-popup`, `editable-text-typography-popup`, `soft-eraser-strength-popup`, `bucket-fill-existing-popup-settings` | `studio.tool-settings`, `studio.tool-settings.close`, `studio.setting.size`, `studio.setting.opacity`, `studio.brush-library`, `studio.brush-family.*`, `studio.shape.fill`, `studio.setting.corner-radius` | captures exist; comparison deferred |
| Layers | `LayerPanel` | `layer-row-drag-real-order`, `layer-glow-real-controls`, `layer-rename-draft`, `layer-renamed-after-redo`, `layer-name-cold-reopened`, `journey-layer-added` (*new*) | `studio.layers.open`, `studio.layers.close`, `studio.layers.list`, `studio.add-layer`, `studio.layer.rename.*` | captures exist; comparison deferred |
| Audio (library + timeline) | `StudioAudioWorkspace`, sound library | `audio-numeric-trim-applied`, `audio-real-mix-selected-clip`, `audio-bundled-library-two-clips`, `audio-expanded-aac-library`, `audio-fades-applied`, `audio-split-right-half-selected`, `audio-landscape-scroll`, `journey-audio-clip-added` (*new*) | `studio.audio.open`, `studio.audio.library.open`, `studio.audio.search`, `studio.audio.catalogue.add.<sha>`, `studio.audio.clip-count`, `studio.audio.timelinePlay`, `studio.audio.volume`, `studio.audio.lanes`, `studio.audio.track-labels`, `studio.audio.trim.*` | captures exist; comparison deferred |
| Export | `ExportPanel`, `StudioGIFExportControls`, `StudioMovieExportControls` | `png-export-drawn-preview`, `png-native-share-sheet`, `png-share-cancelled-files-retained`, `gif-native-share-sheet`, `mp4-native-share-sheet`, `mp4-bundled-audio-native-share`, `journey-png-export-preview` (*new*) | `studio.export.open`, `studio.export.format.png`, `studio.export.start`, `studio.export.preview`, `studio.export.status`, `studio.export.share` | captures exist; comparison deferred |
| Spatter assistant | `SpatterChatView`, `SpatterMotionRecipePanel` | `spatter-real-local-guidance`, `spatter-unconfigured-cloud-local-fallback`, `spatter-motion-real-spritesheet-preview`, `spatter-selected-audio-placement-receipt` | `spatter.*` rows in `docs/control-evidence-map.csv` | captures exist; the preview site must not show cloud answers the unconfigured build cannot give |
| Rooms / War Room / Watch Together / Calendar | `CollabRoomView` and children | `rooms-back-to-studio` only | `rooms.*`, `warRoom.*`, `watchTogether.*`, `calendar.*` | **no capture** beyond the Rooms entry; connected states need services that are not configured (deferred) |
| Studio menu sheet, iPad layouts | `StudioMenuSheet`, all | none | `studio.menu.scroll` | **no capture yet** |

Gaps to close before any row can leave "deferred": the ten original September 19
and 22 images must be enumerated by the owner against rows 1–21 (this table
groups them by screen, not by file); rows 12 and 20 and the default-size
landscape capture (row 11) still need new named captures; the *new* captures
need their first artifact; and every comparison needs the same viewport size as
its reference. Historical references that show messaging/calls or unapproved
prices are excluded from comparison by scope.
