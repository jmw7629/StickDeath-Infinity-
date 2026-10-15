# Local data policy — projects belong to the device (#172)

This is the release contract for where StickDeath Infinity keeps a creator's
work and what the app may do with it. It is implemented by
`StickDeathInfinity/Storage/DeviceStorageManager.swift` and the account flow in
`StickDeathInfinity/App/AppFlowView.swift`; verification of the native behavior
is deferred to the final integration phase (see "Verification").

## Ownership

- Editable projects, their originals (legacy `frame_N.png` / `audio_N.*`
  files, imported images, audio) and every saved revision live under the app's
  `Documents/Animations/<project-id>/` folder on the device. They are never
  uploaded as part of saving, opening, signing in, signing out or joining a room.
- The server stores only identity, access, vote, consent, billing and job
  metadata. A publishing or War Room submission uploads the specific rendered
  video the creator selected and approved, never the editable project.
- Guest work and signed-in work share the same local library. Projects are not
  tagged with an account, so switching accounts on a shared device neither hides
  nor deletes anyone's local projects. Account-linked data (profile, rooms,
  schedules cache) is keyed server-side or by an account digest and is cleared
  from memory on identity change.

## Sign-out

Signing out revokes the session and clears account state. `AuthViewModel.signOut`
first flushes the open project through the shared Studio editor's normal save
path, then signs out, and once the account is gone returns the editor to the
project library (`StudioViewModel.backToProjects()`, which saves a thumbnail
and refuses to leave while a stroke or text draft is still live). It deletes
nothing on the device. The Profile and Settings screens say so beside the Sign
Out button. A revoked Apple credential follows the same local sign-out and shows
a notice rather than an error.

Signing in from inside the app (Rooms, Calendar, Profile "Sign In" buttons) first
flushes the open project (`StudioViewModel.shared.flush()`), then presents Login.
Back and successful sign-in both return to the app shell with the same project.

## Deletion and recovery

- The user's only original is never deleted by the app. "Delete" in the library
  moves the entire bundle to `Documents/.sdi-recently-deleted/` (recoverable,
  no automatic expiry). Revision cleanup removes only receipted, non-selected
  history after explicit confirmation and leaves the selected revision and its
  parent in place.
- Rolling back a legacy migration (`rollbackMigration(id:)`) verifies every
  original listed in `.sdi/migration.json` is still byte-identical, then moves
  the whole `.sdi` revision store to
  `Documents/.sdi-recently-deleted/.migration-rollbacks/<id>-<uuid>/`. The legacy
  files are untouched and the project reopens through the legacy reader.
- Account deletion is a server request (`sdi_account_lifecycle`): the app files
  it, shows the seven-day cooling-off date and can cancel it while pending; the
  service worker completes it. The app never deletes server data itself, and
  nothing local is affected either way. On a server without the lifecycle
  candidate the request is refused and the UI says so.

## Budgets, eviction and leftovers (#171)

Automatic or one-tap cleanup may remove only regenerable data (waveform
summaries, encoder caches) and abandoned scratch. Project originals, saved
revisions, recovery data, Recently Deleted, managed media and user exports are
essential: `StudioEvictionPlanner` never selects them, and when essential data
alone exceeds a budget the plan reports a shortfall instead of deleting work.
Imports check free space first (`StudioStorageBudget.admit`: twice the backup
size plus 256 MB headroom); the check is advisory and never replaces handling a
real out-of-space write. The Device Storage screen shows free space, abandoned
working files and export copies left in the temporary folder, and waveform
previews; each removal is an explicit, confirmed action, re-checks every entry
before removing it and reports actual bytes. Details: `docs/DATA_LIFECYCLE.md`.

## Server-side project storage retired

The unused `ProjectService` (editable frame data in a `studio_projects` row)
and `StorageService` (project JSON and media uploads to a public bucket) were
removed. Nothing called them, and both contradicted this policy. Avatar upload
lives in `Services/Social/AvatarUploadService.swift`.

## Backup inclusion

Everything under `Documents/` (projects, revisions, Recently Deleted, imported
media) is included in iCloud and encrypted local device backups by default; the
app does not mark these files as excluded, because they are the creator's only
copy. Regenerable caches under `Library/Caches/` and the per-account calendar
cache under `Library/Application Support/StickDeathInfinity/` may be omitted or
purged by the system. Exported bundles saved outside the app are the user's own
files. Restoring a backup to a new device restores the projects; it does not
restore the account session (see "Install marker").

## File protection class

Directories and files created by `DeviceStorageManager` (Animations, revisions,
lineage receipts, `current.json`, migration manifests, Recently Deleted, media)
and the calendar cache use `FileProtectionType.completeUntilFirstUserAuthentication`
(`NSFileProtectionCompleteUntilFirstUserAuthentication`). Data is encrypted while
the device is locked before its first unlock after boot, and readable afterwards
so background saves and launch-before-unlock restoration do not fail. Files that
existed before this policy keep the class the system assigned at creation until
they are rewritten; the policy is applied to their directories on next launch.
The class is recorded in each migration manifest (`protection`).

## Install marker

Keychain items survive app deletion. On the first launch without
`UserDefaults["sdi.installMarker"]` the auth service signs out locally before
restoring a session, so a reinstalled app starts as a clean install rather than
silently adopting the previous install's account. The marker is then written.
This also runs once when upgrading from a build that predates the marker.

## Diagnostics

User-facing storage messages come from `DeviceStorageManager.userMessage(for:)`
and `AnimationStorageError`: fixed sentences that never include filesystem
paths, file names other than the project identifier, account identifiers or
file contents. Library failure rows read "Can't open: <project id>, original
preserved — <fixed reason>". Logs intended for issues or GitHub must use the same
text, not `localizedDescription` of raw Foundation errors.

## Background saves

Studio flushes its pending save when the scene leaves the foreground. That flush
is meant to run inside `BackgroundTaskScope.run` (`App/StickDeathInfinityApp.swift`),
a `UIApplication` background-task assertion that is released when the save
finishes or expires; the helper is in place and the one-line call in
`StudioView`'s scene-phase handler is a coordinator patch in this wave. Because `saveAnimation` writes a complete revision and only
then atomically selects it, an expired assertion can leave at most an unselected
revision (shown as "Recoverable unsaved data" in Storage), never a torn document.

## Verification

Deferred (no Xcode on the implementation host): `Tests/DeviceStorage` covers
digest verification, previous-revision reads, non-identity folders, migration
manifest and rollback, the "Recoverable unsaved data" scan bucket and the
message mapping; `Tests/AuthState` covers the install marker, Apple credential
revocation and the sign-out Studio hand-off. The storage suites import CoreData
and Darwin, so they compile and run only on the macOS CI runner; on Linux they
and the auth suite were parse-checked only. File protection attributes and the
background-task assertion can only be observed on an iOS device or simulator
and remain unverified.

## Epic #14 evidence (device-first projects, crash recovery, backups)

Saves write a complete revision plus a SHA-256 lineage receipt, fsync files and
directories, then atomically replace `current.json`; reads verify the payload
against its receipt and refuse to open a mismatch (`payloadIntegrity`), and
`loadPreviousRevision(id:)` walks the receipted parent chain (#168). Legacy
`frame_N.png`/`audio_N.*` bundles migrate idempotently on first save with a
`.sdi/migration.json` manifest of byte-identical originals, non-UUID folders are
reported instead of skipped, and `rollbackMigration(id:)` restores the legacy
reader without deleting anything (#169). Portable `.sdiproject` bundles carry
the whole record with a checksum and import under a fresh identity after
staging-area validation; missing referenced audio can be dropped with a
per-clip warning list. The library checks the backup's format version first
(a newer format is refused by name), asks before re-importing a file already
imported, notes when the original project is still on the device, and after
import reopens the copy from storage and verifies every original image and
sound byte-for-byte (#170). The storage scan separates projects, recoverable
unsaved data, Recently Deleted, media and regenerable caches, and write errors
map to fixed, path-free messages (#171). File protection, the install marker,
sign-out behaviour and diagnostics rules above cover isolation (#172). Evidence:
`Tests/DeviceStorage` (34+ cases), `Tests/StudioStorageManagement`,
`Tests/StudioPortableProjects`, all deferred to the macOS runner.

## Epic #17 evidence (Studio project library and lifecycle)

`Views/Studio/StudioProjectLibrary.swift` lists real local documents with saved
first-frame thumbnails and last-modified dates, searches by title, sorts by
recently edited / name / frame count, creates with validated name, size and FPS
(`StudioProjectConfigurationCard`), and offers per-project backup, duplicate
(`storage.saveNewAnimation`, never over an existing ID), rename (through the
document editor and the normal save path: `StudioViewModel.renameSavedProject`)
and move to Recently Deleted with restore. Unreadable bundles appear as
"Can't open: <id>, original preserved" rows from `unreadableProjects`; empty,
no-match, offline and failure states are explicit. Identifiers:
`studio.library.search`, `studio.library.sort`, `studio.library.menu.rename`,
`studio.library.rename.field/confirm/cancel`, `studio.library.menu.duplicate`,
`studio.library.menu.remove`, `studio.library.unreadable`, `studio.recovery.empty`,
`studio.recovery.done`, `studio.restore.<id>`. Native UI coverage of rename,
duplicate and the unreadable rows is deferred (#167).
