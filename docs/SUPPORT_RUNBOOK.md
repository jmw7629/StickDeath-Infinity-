# Support runbook (#267)

Truthful answers for owner and support use, grounded in source at `e48e789`.
Where the app cannot do something yet, say so; do not promise a fix date.

## Where user data lives

- **Projects are on-device.** Editable projects, their frames, imported images and audio are stored by `Storage/DeviceStorageManager.swift` inside the app's Documents directory. Nothing in the Studio uploads a project; saving, autosaving, reopening or exporting never publishes (`docs/PRODUCT_SCOPE_2026_09_19.md`).
- **Recently deleted projects** are kept in a hidden `.sdi-recently-deleted` folder (`DeviceStorageManager.swift:316`) and can be restored from the library (`studio.library.recently-deleted`, `restoreAnimation(id:)` at `DeviceStorageManager.swift:419`). Deleting the app deletes them; there is no server copy.
- **Tool preferences** (brush/eraser/fill/wand settings) are per-device `UserDefaults` under `studio.drawing-tool-preferences.v1` (`StudioViewModel.swift:115`). "Reset this tool" restores one tool's defaults.
- **Account data** (when signed in) is identity, profile name/bio and consent/billing/job metadata on the configured backend. The backend keeps no editable projects.

## Backups and transfer

Guide users to the explicit Files transfer; the app has no automatic cloud sync.

1. Save and return to the project library.
2. Open the saved project's menu and choose **Save Project Backup to Files** (`StudioProjectLibrary.swift:343`). Pick a destination; the system confirmation may read Save or Move.
3. Wait for **Project backup saved to Files** before treating the save as complete.
4. The `.sdiproject` file contains the saved editable project and its stored media. MP4, GIF and PNG exports are **not** editable backups.
5. To bring it back, choose **Import project backup** in the library (`StudioProjectLibrary.swift:124`) and select the `.sdiproject` file. Import creates a separate project with a new identity after validation; it never overwrites the original and does not restore prior-process Undo history.
6. If the file is unsupported, damaged or too large, keep the original and report the displayed error. Support cannot repair a backup or claim it was imported. Projects saved with `schemaVersion` 34 do not open on builds that only support older versions (`StudioDocument.swift:5`, `supportedSchemaVersions = 1...34`); see `docs/ROLLBACK.md`.

The same wording is what Spatter gives in-app (`SpatterAIViewModel.swift:203`).

## Deletion requests

- **Account deletion is a server-side request with a seven-day cooling-off period.** The app calls `sdi_account_lifecycle` (`request_deletion`, `status`, `cancel_deletion`; `Services/Auth/AuthService.swift`) and shows the scheduled date in Profile and Settings, where the member can cancel while the request is pending. The service worker (`backend/ops/sweeps.py`, `sdi_account_deletion_run`) prepares and later purges the account; the app deletes nothing itself and local projects are never touched. Where the lifecycle candidate is not installed the request is refused and the member sees "not configured on this server yet". Subscriptions are not cancelled by deletion; point members to the App Store or billing portal.
- **Project deletion** happens on the device only. Support cannot delete, view or recover a user's local project.
- **Published renditions**: removal/takedown requests follow the publishing contract in `docs/PRODUCT_SCOPE_2026_09_19.md`; do not promise deletion of copies already shared by third parties.

## Support queue, receipts and billing questions (backend candidates, 2026-10-13)

- When the support candidate is installed, members file requests from the app (`sdi_support_action('create')`, five per day, idempotent) and receive a receipt `SDI-XXXXXXXXXX`; administrators with the users capability and MFA work the queue (`list`, `update_status` with a revision and a note). Quote the receipt back; never quote another member's request.
- Billing: the plan a member has is whatever the provider's signed events say (`sdi_my_entitlement`: tier, status, provider, paid-through date, cancel-at-period-end). Support cannot grant, extend or refund a plan; cancellations happen in Apple's Subscriptions settings or the Stripe customer portal, refunds with the provider. Say "your access continues until <paid_through>" only when the entitlement shows it.
- Permissions: publishing and marketing permissions are separate and each can be withdrawn in the app (`sdi_consent_action('withdraw', …)`); withdrawing publishing stops jobs that have not published and queues removal of hosted copies; copies already shared by third parties are not promised gone.
- Notifications: product and marketing notices are off until the member turns them on; service notices cannot be turned off but stop when the account closes. Email unsubscribe links are one-click; a bounced address stops all email until the member updates it.
- Account deletion: the server-side candidate (`sdi_account_lifecycle`, seven-day cooling-off, phase one/two worker) exists in source; the shipped build still reports deletion unavailable until the candidate is installed and the native flow is verified. Do not tell a member their account was deleted.

## Credits and licenses

- The complete third-party inventory is `docs/THIRD_PARTY_NOTICES.md`.
- In the app, bundled font and ArtCraft notices ship in `StickDeathInfinity/Resources/Licenses/` (`SpecialElite-NOTICE.txt`, `SpecialElite-Apache-2.0.txt`, `ArtCraft-NOTICE.txt`); the sound credits are `Resources/StudioSounds/CREDITS.txt` and per-sound author/source/license fields in `Resources/StudioSounds/catalogue.json`; image credits are the `licenses` array in `Resources/StudioImages/catalogue.json` plus the three license text files beside it.
- Exports carry credits: the export sheets show image credits for licensed images used in a render (`ExportPanel.swift:141-145`, `StudioMovieExportControls.swift:105-109`). All bundled sounds and images are CC0-1.0, so attribution is optional but recorded.
- Special Elite is Apache-2.0 (Astigmatic); it is the only bundled font.

## Common questions

| Question | Answer |
| --- | --- |
| "Where is chat / calls / DMs?" | Removed on purpose. Rooms are invitation-based collaboration on a chosen Studio project; connected synchronization is not available yet (`CollabRoomView.swift:46`). Spatter remains the Studio assistant. |
| "Can Spatter edit or publish my project from chat?" | Spatter can apply typed Studio commands you confirm in the Studio; the chat screen itself is advice only (`SpatterAIViewModel.swift:31`). Nothing is published without the owner's exact-render approval. |
| "Export failed / transparent MP4?" | MP4 export rejects transparent backgrounds (`StudioMovieExportControls.swift:44`); choose a solid background or export PNG/GIF. Exports create a file on the device and never upload it. |
| "I lost work after a save error" | A failed required save keeps the dirty work visible; the app never discards it silently (#293). Ask for the exact error text and the project name; the local recovery files are preserved. |
| "What does my plan cost?" | Only USD 4.99 and USD 9.99 monthly are requested by the owner; other prices visible in unreachable or historical screens are not offers (see `docs/KNOWN_LIMITATIONS.md`). |
| "Is the web gallery the app?" | No. The review site shows labelled native captures; it does not execute SwiftUI (#126). |

## Escalation

- Reproducible crash or data loss: collect app version/build (`Info.plist` 1.0.0/1 until the owner changes it), device, iOS version, the exact message shown and whether the project still appears in the library or Recently deleted. Open or update the matching GitHub issue; never attach a user's project without consent.
- Rights or moderation complaint about a published video: route to the owner's admin command center queue; do not act in the app on the user's behalf.
- Security report (token in logs, credential exposure): treat as an incident, see `docs/INCIDENT_RUNBOOK.md`.
