# Known limitations (#267)

Generated from the user-visible "unavailable", "unfinished", "not supported",
"not available yet" and "not connected" strings in `StickDeathInfinity/**/*.swift`
at `e48e789` (`grep -rn -iE '"[^"]*(unavailable|not yet|unfinished|not available|unsupported|not supported)[^"]*"'`),
plus the verification work that is still deferred. Line numbers are for that
commit; re-run the grep before publishing and update the citations. This is a
limitations list, not a claim that everything else is verified.

## Studio editing

| Limitation shown to the user | Source |
| --- | --- |
| "Erasing within a selection is unfinished. Deselect before erasing the active layer; nothing changed." | `Models/StudioDocument.swift:803` |
| "Canvas resizing with replayable pixel effects is unavailable. Name and FPS can still be changed." | `Models/StudioDocument.swift:589` |
| "Tween needs matching drawings and image layers in both adjacent frames. Empty, historical or unmatched endpoints are unsupported; nothing changed." | `Models/StudioDocument.swift:1966` |
| "This project version is not supported. The original has not been changed." (schema outside 1...34) | `Models/StudioDocument.swift:114`, `:5` |
| "This brush stroke exceeds the 8,192 sample limit or has an unsupported identity/tool. Draw a shorter stroke." | `Models/StudioDocument.swift:1827` |
| "Gradient endpoint transparency is unavailable. Choose an opaque end color." | `Models/Models.swift:480` |
| "Unsupported brush settings version." / "This brush document version is unavailable." | `Models/StudioBrush.swift:54`, `Models/Models.swift:472` |
| "This command batch is too large for interactive editing in this project. … very complex projects may currently be unavailable for command edits." | `ViewModels/StudioViewModel.swift:743` |
| Wand "does not yet select arbitrary vector-layer pixels" (images/canvases up to four megapixels) | `ViewModels/SpatterAIViewModel.swift:208` |
| Legacy project opened without editable data: "Imported images are flattened; metadata without image pixels stays preserved but cannot be rendered. … Audio playback is unfinished." | `ViewModels/StudioViewModel.swift:1140` |
| Studio command interface: "That capability is unavailable in this command interface. Nothing changed." / "That Studio command is not supported." | `Models/StudioCommands.swift:21-29` |

## Audio

| Limitation | Source |
| --- | --- |
| Legacy sound-list path: "Sound playback and licensed asset import are unfinished. No audio clip was added." (the bundled catalogue path in `AudioPanels.swift` is the supported route) | `ViewModels/StudioViewModel.swift:2863` |
| "This track includes historical audio with unavailable source bytes." (historical clips cannot be re-mixed) | `Models/StudioDocument.swift:667`, `ViewModels/StudioViewModel.swift:3211,3228,3248` |
| "Imported audio and its undo history are limited to 32 MB." | `ViewModels/StudioViewModel.swift:2901` |
| Spatter audio recipes accept only the documented example forms: "Additional actions are unavailable. Nothing changed." | `Models/SpatterMotionRecipe.swift:406` |

## Import, camera and export

| Limitation | Source |
| --- | --- |
| "Camera recording and whole-video timeline import are not available yet." (still photos and frame-sequence import only) | `Views/Studio/Panels/StudioImageImportPanel.swift:223` |
| "The camera is unavailable on this device. Use Photos or Files. Nothing was added." | `Views/Studio/Panels/StudioImageImportPanel.swift:460` |
| MP4 export: "Transparent (unsupported)" background option | `Views/Studio/Panels/StudioMovieExportControls.swift:44` |
| Export sheet shows "<FORMAT> UNAVAILABLE" when a format is not supported for the current document | `Views/Studio/Panels/ExportPanel.swift:123` |
| Renderer fallback text "Render unavailable: …" when a frame cannot be drawn | `Views/Studio/StudioFrameRenderer.swift:466` |
| Export creates a device file only: "Connected automatic publishing is not available yet." | `ViewModels/SpatterAIViewModel.swift:285` |

## Spatter

| Limitation | Source |
| --- | --- |
| Chat capability notice: "Advice only. Editing, saving, export and publishing through chat are unavailable. Local references can describe features still under development." | `ViewModels/SpatterAIViewModel.swift:31` |
| "Spatter cloud is unavailable." / "Cloud unavailable · local guide" when no backend is configured | `AI/SpatterBrainLoader.swift:162`, `ViewModels/SpatterAIViewModel.swift:76` |
| Local motion recipes support only the documented stick-figure, two-figure, circle and audio forms | `Models/SpatterMotionRecipe.swift:144,536,674,754-755` |
| "Personal preferences are unavailable for this account identity." | `ViewModels/SpatterAIViewModel.swift:661` |
| Rejected drafts with incomplete input cannot be retried | `ViewModels/StudioViewModel.swift:1515` |

## Accounts, profile and plans

| Limitation | Source |
| --- | --- |
| Account deletion is not implemented; the service throws `accountDeletionUnavailable` | `Services/Auth/AuthService.swift:487-491` |
| "Sign-in is unavailable. Your local Studio is ready." when identity providers are not configured | `Views/Auth/WelcomeView.swift:52` |
| Profile: "Projects counts saved animations on this device. Published, followers and likes are unavailable." / "Analytics unavailable" / "Plan unavailable" | `Views/Profile/ProfileView.swift:82,131,63,102` |
| "Avatar and portfolio editing are not available here." | `Views/Profile/EditProfileView.swift:25` |
| "Uploading is unavailable until the private service and current publishing terms are configured." | `Views/Profile/ProfileView.swift:583` |
| Billing views compile but are not mounted: `ChoosePlanView` and `SubscriptionView` now show only the two approved monthly plans with Apple's display price or an honest "not configured" state (see `docs/BILLING_CONTRACT.md`), but no navigation path presents them yet and the StoreKit product identifiers are labelled placeholders until the owner configures App Store Connect. | `Views/Onboarding/ChoosePlanView.swift`, `Views/Settings/SubscriptionView.swift`, `Services/Stripe/StripeService.swift` |

## Rooms, War Room, feed, challenges, calendar

| Limitation | Source |
| --- | --- |
| "Project editing synchronization is not connected yet. Creating a room does not upload or share your device projects." | `Views/Collab/CollabRoomView.swift:46` |
| Spatter: "Collaboration rooms are planned …; connected rooms are not available yet." | `ViewModels/SpatterAIViewModel.swift:282` |
| War Room shows only genuine matchups; "No available matchups." / leaderboard "No public finalized records yet." | `Views/Collab/WarRoomView.swift:38`, `Views/Collab/LeaderboardView.swift:29` |
| Feed: "Sign in to view the community feed." / "No approved videos in this feed yet." | `Views/Home/HomeFeedView.swift:42,48` |
| Challenges: "Voting challenges are unavailable from the current service." / "Submission unavailable" alert / "Entries unavailable" / "Votes unavailable" | `Views/Challenges/ChallengesView.swift:53,176`, `Views/Challenges/ChallengeDetailView.swift:111,173` |
| Calendar: "Schedules are unavailable. Check your connection and account configuration, then retry." (`CalendarView.swift` is compiled; native Calendar is tracked in #297) | `Views/Messages/CalendarView.swift:180` |
| Retired, excluded from the native target: `WatchPartyView.swift:250` "Watch-party chat is unavailable until this room is connected." | `project.yml` excludes `Views/Messages/WatchParty` |

## Admin command center

Every admin list falls back to an honest unavailable state when the server-authorized session or MFA is missing (for example "Administrator access unavailable.", "Overview unavailable. Check administrator authorization and MFA.", "Moderation queue unavailable.", "Publishing queue unavailable.", "Appeals unavailable.") — `Views/Admin/AdminDashboardView.swift:189,194,252,420,556,662,808,984,1069,1146,1231,1509`. No data is estimated when a request fails.

## Storage

- Obsolete-revision cleanup never removes current, previous, original or unverified recovery files: "No eligible old versions. Historical and unverified recovery files are preserved." (`Views/Studio/StudioProjectLibrary.swift:455,655`).
- Disk-full saves fail visibly (#293/#295); the app does not lower floors or discard edits.

## Deferred verification (not run; never label as passed)

- Native build, simulator, device, accessibility, persistence and export verification for the October 9 implementation batch (`docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md`).
- Exact-head CI for the current branch head; the last recorded public failure is `b50033cc` run 37816602055 shard 0 (#292).
- 108 native journeys at the current head (#124, #265); #265 bullet 2 (feed, rooms, War Room, approval flows on isolated data) has no connected services to exercise.
- Accessibility and adaptive layout (#264): 421 fixed `.font(.system(size:))` uses, no `@ScaledMetric`, no size-class checks, Reduce Motion only on Splash/Welcome/Onboarding, CI simulator is iPhone 16 Pro only; `textFaint` contrast defect (see `docs/STUDIO_CONTROL_CONTRAST_VERIFICATION.md`).
- Visual reference comparison (#127): all rows in `docs/VISUAL_REFERENCE_MAP.md` are `deferred`.
- TestFlight, signing, physical-device and performance protocol (#266) are owner-gated.
- Privacy manifest target membership and bundle inclusion (`StickDeathInfinity/PrivacyInfo.xcprivacy`) need a native build.
- Live identity provider sign-in, billing and publishing flows have never been exercised against production services as tests, by policy.
