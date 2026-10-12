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

Signing out revokes the session and clears account state. It closes the open
project through the shared Studio editor's normal flush/save path and returns to
the project library. It deletes nothing on the device. The Settings sheet says so
beside the Sign Out button.

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
- Account deletion is not available in this build. The service refuses it and
  the UI says so; nothing local is affected either way.

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

## Verification

Deferred (no Xcode on the implementation host): `Tests/DeviceStorage` covers
digest verification, previous-revision reads, non-identity folders, migration
manifest and rollback, the "Recoverable unsaved data" scan bucket and the
message mapping; `Tests/AuthState` covers the install marker. Both were
parse-checked only. File protection attributes can only be observed on an iOS
device or simulator and remain unverified.
