# Device data lifecycle: portable backups, budgets and cleanup (#170, #171)

Companion to `docs/LOCAL_DATA_POLICY.md`. Everything here runs on the device;
nothing is uploaded.

## Portable backups (#170)

| Concern | Implementation |
| --- | --- |
| Bundle contents | `DeviceStorageManager.portableBundle(for:)` embeds the whole stored record: normalized frames, every imported image's original bytes and catalogue attribution, every audio track's original bytes, the editable document archive. `StudioPortableBundleInventory` measures it (counts, bytes, SHA-256 per asset). |
| Video | A project keeps imported video as grabbed frames (image sources) and extracted sound (audio tracks). The source movie file is never part of a project, so it is not in a backup; `StudioPortableBundleInventory.videoNote` says so. |
| Version | Header `SDIPROJECT000001\n`. `StudioPortableBundleFormat` reads the version before decoding: a newer version is refused as "made by a newer version", a malformed header as "not a backup". Version 1 is the first published format; `migrations` is empty and a future format registers a step there. |
| Reading | `StudioPortableBundleFile.read` — local regular file only, no links, bounded size, unchanged during the read, cancellable. |
| Free space | `StudioStorageBudget.admit` refuses when free space is below twice the backup size plus 256 MB, with the numbers. Unknown free space never invents a refusal. |
| Conflicts | `StudioPortableImportLedger` (Application Support, digest → project ID, 256 entries, no titles or paths). Re-importing the same file asks first ("Import as a separate copy" / Cancel). A backup of a project still on the device is noted after import. Every import gets a fresh identity; nothing is replaced or merged. Stale ledger entries are ignored. |
| Missing audio | Existing path: the retry offers "Import without missing sounds" and lists each dropped clip. |
| Restore verification | After import the library reloads the new copy from device storage and `StudioPortableRestoreVerifier` checks every original image and sound byte-for-byte, catalogue attribution, canvas, frame rate and frame count. The result is shown under the import notice (`studio.library.import.verification`). |

## Budgets and eviction (#171)

`StudioStorageRole` classifies data. Essential: project originals, selected,
previous and recoverable revisions, Recently Deleted, managed media, user
exports. Evictable: regenerable caches and scratch. `StudioEvictionPlanner`
removes least-recently-used unpinned regenerable entries until the budget fits
and includes unpinned scratch older than the minimum age. It never selects an
essential or pinned item; a randomized test over 500 inventories asserts that.
When what is left is pinned it reports `shortfallBytes` rather than reaching for
essential data.

Disk executors (`StudioStorageCleanup.swift`) act only inside one owned folder,
only on names the producer creates, never follow links, and re-check inode,
type, size and modification time immediately before each removal; anything
changed since review is kept and counted.

- Waveform previews (`Caches/StudioWaveforms`, `<sha256>.json`):
  `trim(toBudget:)` removes least recently used records down to a byte budget
  (32 MB standard); the storage screen clears them on request. Running the
  budget trim at launch is a one-line coordinator hook (not yet wired). The
  cache's own 512-entry LRU limit still applies. Records are re-measured from
  the project's own audio. Unknown files in the folder stay.
- Temporary folder: `sdi-project-validation-*`, `sdi-voice-*`, `.sdi-mux-*`
  older than one hour are abandoned working files. `SDI-*`, `SDI-Movie-*` and
  `sdi-export-*` are export copies: reported separately and removed only by
  their own confirmed action, never while a share sheet holds an export.

## Device Storage screen

Adds free space with low/critical wording (or "did not report free space"),
leftover temporary files and waveform previews, each with an explicit confirmed
removal and a receipt of actual removed file bytes, changed-and-kept and failed
counts. Existing revision cleanup and the working-memory cache are unchanged.

## Verification

Standalone: `Tests/StudioStorageManagement/DeviceDataLifecycle.swift`, run from
that suite's `main.swift`: header versions, inventory, restore verification
after a production cold read, ledger bounds/damage/links, conflict detection,
budget thresholds and admission, the planner invariant, LRU disk trim and
leftover review/removal with change detection. Deferred to the macOS runner (no
Swift toolchain on the implementation host); the workflow step must compile the
new sources (see the wave report). Native UI coverage of the new controls is
deferred (`docs/control-evidence-map.csv`). Physical low-disk, device-to-device
transfer and interrupted-import acceptance remain open on #170/#171.
