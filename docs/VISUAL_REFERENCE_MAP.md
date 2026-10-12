# Visual reference map (#127) — skeleton

Maps the owner-supplied reference screens named in #292, #293, #294 and #127 to
the capture names that the native UI suite already produces
(`capture(app, name:)` in `Tests/NativeUI/StudioSmokeUITests.swift` at `e48e789`).
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
| 8 | Studio Back arrow returns to projects (#293) | `StudioHeaderBar` (`studio.back`) | `rooms-back-to-studio` (Rooms → Studio only); no dedicated Back capture | `testRoomsReplaceMessagingWithoutClaimingConnectedServices` | deferred — add a capture after Back in the project journey |
| 9 | Guest Profile matching the reference, device project count, Settings (#294) | `ProfileView` | `owner-guest-profile-reference`, `owner-guest-profile-settings` | `testGuestProfileProjectsAndSettingsNavigation` | deferred |
| 10 | Studio portrait with white floating primary toolbar (Sept 19/22) | `StudioView`, `StudioToolStrip` | `studio-portrait`, `toolbar-docked-<side>` (left/right), `toolbar-floating-popup` | `testGuestStudioPortraitLandscapeAndPersistedGuideControls`, `testFloatingToolbarDockingAndPopupDismissal` | deferred |
| 11 | Studio landscape (Sept 19/22; #127 orientation requirement) | `StudioView` | landscape journey captures within `testGuestStudioPortraitLandscapeAndPersistedGuideControls` (no separate landscape capture name) | `testGuestStudioPortraitLandscapeAndPersistedGuideControls` | deferred — add a named landscape capture |
| 12 | Top menus / Studio menu sheet typography (#294) | `StudioMenuSheet` | none named | — | deferred — add capture |
| 13 | Tool options popup (brush, gradient, shape, selection, blur) typography and compact height (#294, Sept 22) | `FloatingToolSettingsPanel` | `brush-round-settings`, `brush-stipple-settings`, `gradient-family-sole-popup` (shared `drawNativeGradient` helper), `shape-fill-and-radius-popup`, `selection-scale-rotate-popup`, `blur-size-opacity-popup`, `editable-text-typography-popup` (shared `verifyEditableText` helper), `soft-eraser-strength-popup` | `testBrushLibrarySettingsUndoAndPersistence`, `testGradientBrushPixelsUndoAndColdReopen`, `testShapeFillRadiusUndoSaveReopenAndPNG`, `testSelectionScaleRotateUndoAndColdReopen`, `testBlurPixelsUndoAndColdReopen`, `testEditableTextUndoRedo`, `testEraserSettingsPersistAndResetAfterColdLaunch` | deferred |
| 14 | Layer and frame controls (#294) | `LayerPanel`, `StudioTimeline`, `FramesViewerPanel` | `layer-glow-real-controls`, `layer-rename-draft`, `layer-row-drag-real-order`, `frames-viewer-reordered-stable-selection`, `onion-range-tint-controls`, `grid-spacing-opacity-tint-controls` | `testLayerGlowColorRadiusStrengthUndoAndColdReopen`, `testLayerRenameCancelUndoAndColdReopen`, `testNativeLayerDragReordersPixelsUndoRedoAndColdReopen`, `testFramesViewerStableSelectionAfterReorderAndColdReopen`, `testGuestStudioPortraitLandscapeAndPersistedGuideControls` | deferred |
| 15 | Audio library (owner library screenshot) with tags, counts, preview (#294, Sept 19 audio reference) | `AudioPanels` library | `audio-expanded-aac-library`, `audio-bundled-library-two-clips`, `sound-library-no-match-query`, `audio-tag-search-preview-stopped`, `optional-micro-pack-downloaded-library` | `testExpandedAACLibrarySoundPlaybackAndOfflineReopen`, `testBundledSoundLibraryMixAndOfflineReopen`, `testSoundLibraryTagsCountsPreviewStopAndColdReopen`, `testOptionalMicroPackImportRemovalAndColdReopen` | deferred |
| 16 | Audio timeline (owner timeline screenshot) with measured waveforms, clip edits (Sept 19 audio reference) | `StudioAudioWorkspace` | `audio-empty-real-timeline`, `audio-real-mix-selected-clip`, `audio-fades-applied`, `audio-numeric-trim-applied`, `audio-split-right-half-selected`, `audio-duplicate-timing-at-four-times-zoom` | `testAudioFilesPickerCancellationPreservesBlankProject`, `testBundledSoundLibraryMixAndOfflineReopen`, `testAudioFadesCancelApplyUndoAndColdReopen`, `testAudioNumericTrimCancelApplyUndoAndColdReopen`, `testAudioClipSplitUndoAndColdReopen`, `testAudioClipDuplicateUndoAndColdReopen` | deferred |
| 17 | Export sheets: PNG, GIF, MP4 and native share (#294) | `ExportPanel`, `StudioGIFExportControls`, `StudioMovieExportControls` | `png-export-drawn-preview`, `png-native-share-sheet`, `gif-native-share-sheet`, `mp4-native-share-sheet`, `mp4-bundled-audio-native-share` | `testPNGExportPreviewAndNativeShareCancellation`, `testGIFExportFramesAndNativeShareCancellation`, `testMP4ExportReceiptAndNativeShareCancellation`, `testBundledAudioMP4AndNativeShareCancellation` | deferred |
| 18 | Image import panel and pickers (Sept 22 media reference) | `StudioImageImportPanel` | `image-native-photos-fixture-picker`, `image-native-files-picker`, `image-decoded-photos-preview`, `licensed-image-library-search` | `testPhotoImportUndoPersistenceAndRealPNGExport`, `testImagePhotosAndFilesCancellationPreserveProject`, `testLicensedImageLibraryUndoAndColdReopen` | deferred |
| 19 | Rooms screen replacing messaging (Sept 19) | `CollabRoomView` | `rooms-back-to-studio` | `testRoomsReplaceMessagingWithoutClaimingConnectedServices` | deferred |
| 20 | iPad / reference-size layouts (#127, #264) | all of the above | none; CI runs iPhone 16 Pro only (`scripts/native-smoke/select_simulator.py`) | — | deferred — needs an iPad destination |

Gaps to close before any row can leave "deferred": the ten original September 19
and 22 images must be enumerated by the owner against rows 1–20 (this skeleton
groups them by screen, not by file), rows 8, 11, 12 and 20 need new named
captures, and every comparison needs the same viewport size as its reference.
Historical references that show messaging/calls or unapproved prices are
excluded from comparison by scope.
