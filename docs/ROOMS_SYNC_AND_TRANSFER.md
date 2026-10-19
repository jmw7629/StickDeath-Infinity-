# Rooms: shared edits, asset transfer and Studio handoff

Scope: issues #232 (versioned shared edits), #233 (bounded asset transfer) and
#234 (room browser, join flow, active-project handoff). Rooms are invitation-based
collaboration on one explicitly shared Studio project. There is no chat, calling,
camera, microphone, screen sharing or call billing anywhere in this path.

Status: implemented in source; SQL verified on local PostgreSQL 16 with stubbed
Supabase pieces; Swift suites and native two-client journeys are **deferred** to
macOS CI and device acceptance (#124, #265). Nothing here is applied to the live
project.

## Shared edits (`sdi_room_command`, rooms-v2.sql)

- Every edit has an idempotent operation id, a base revision and a per-room
  sequence number (`revision`, strictly increasing, 100,000 per room).
- An edit may name the entity it touches in `payload.target`
  (`frame:<id>`, `layer:<id>`, `audio:<id>`). An edit without a target touches
  the whole document.
- Stale base revision:
  - the server **rebases** (status `rebased`) when the edit has a target, the
    gap is at most 200 revisions and no intervening edit touched the same
    target or the whole document; the reply carries the intervening edits;
  - otherwise it returns `conflict` with `missing` edits and the `overlap` op ids.
- The client (`RoomCommandSync`) applies remote edits in order, skips its own
  rebased revision once everything below it is applied, and **holds** an edit
  that overlaps another creator's edit until the creator chooses *Keep mine on
  top* or *Discard mine*. Nothing is overwritten silently.
- Undo ownership: `kind = "undo"` with `payload.undo_op`; only the author of the
  undone edit may undo it, once; an undo inherits the undone edit's target.
- Revocation: a removed member, a closed room or a withdrawn edit role stops
  appends immediately; local edits stay on the device.

### Studio connection (#232, 2026-10-18)

`StudioRoomBridge` (`ViewModels/StudioViewModel+Rooms.swift`) starts when *Open
shared project in Studio* records the handoff and runs while the handoff lasts:

- **Publish.** `StudioViewModel.applyStudioCommands` and the touch commit path
  report each commit through `StudioEditObservers` (`Models/StudioCommands.swift`).
  `StudioSharedEdit.share` turns the committed batch into replayable commands
  (cuts become deletions; selection, guides and clipboard copies are view-only).
  Each edit is one `studio.apply` record whose payload carries the commands as
  one JSON array, a `target` (`frame:<id>`, `layer:<id>`, `audio:<clip id>` or
  `audio:track-<n>`; anything structural or mixed has no target and therefore
  overlaps every other edit) and the frame, layer and element identities the
  author's device created. Touch drawings are shared as `draw` commands only
  when replaying them on the earlier document reproduces the committed document
  exactly.
- **Replay.** `applyRemote` rebuilds the record through
  `StudioSharedEdit.request(from:)` — the same strict wire decoder as any
  untrusted input, replayable commands only, target must match — and applies it
  through `applyStudioCommands` with `sharedIdentities`, so new frames, layers
  and elements keep the author's IDs. A replay that creates a different number of
  objects, or whose IDs already exist, is refused (the copies diverged) instead
  of guessed. The creator's own active frame, layer and valid selection are kept.
- **Conflicts.** Appends stay fenced on the head; overlapping edits are held for
  *Keep mine on top* / *Discard mine*. While the held local edit is still the
  latest change in Studio's history (the document is at the revision that edit
  produced), the other creator's edit waits for the decision, and *Discard mine*
  reverts it through Studio's own Undo (`RoomSessionCoordinator.discardHeldConflict`
  → `StudioRoomBridge.revertLocalEdit`) before their edit applies. Otherwise
  discarding only stops sending, and Studio and Rooms say plainly that the edit
  could not be reverted automatically and stays in the device copy. A remote record that cannot be
  applied yet (playback, a touch in progress, a room undo, a malformed or
  diverged edit) blocks later remote records in order and is shown with its
  reason; the creator may explicitly skip it, which is recorded.
- **Not shared, said so.** Fills, pastes from the device clipboard,
  selected-drawing erasures, Undo/Redo and any revision change made without a
  shared command are reported as "not shared" in Studio and counted in the room.
- `drain()`/`catchUp()` run every 3 seconds (`RoomSessionCoordinator.synchronise`)
  and a push follows each published edit.
- **Status in Studio.** While the handoff lasts, the Studio top bar shows a small
  room indicator (`studio.room-sync`: in sync, N to sync, waiting, paused, view
  only, decide) from `RoomSessionCoordinator.studioSyncStatus`. Tapping it lists
  the counts and reason; a held conflict offers *Keep mine on top* / *Discard mine*
  there too. It sits beside the project info, adds no toolbar and never blocks
  the canvas.

Verification: `Tests/CommunityRooms` (blocked/skip/counter coordinator case) and
`Tests/SpatterPlanner` (identity-preserving replay, divergence refusal, hostile
payloads, targets, faithful touch replay) pass on Linux with stub UI modules.
Two authorized devices editing frames/layers/audio, reconnect/replay and
revocation on real hardware are **deferred** to native verification.

## Asset transfer (`sdi_room_asset`, rooms-v2.sql)

| Bound | Value |
| --- | --- |
| File types | PNG, JPEG, M4A, MP3, WAV, CAF |
| Per file | 8 MiB, 32 KiB chunks (max 256) |
| Per room (live copies) | 64 MiB, 100 files |
| Per sender | 30 files per day |
| Calls | 600 per minute per account |
| Unfinished upload | expires after 1 hour |
| Finished copy | expires after 72 hours |

Flow: `declare` (editor of a room with a shared project; name, type, size,
SHA-256, licence; CC BY needs attribution) → `put` chunks (resume with `status`)
→ `finalize`, where the **server recomputes the SHA-256** of the whole file and
discards a mismatching copy → members `list` and `get` chunks; the client checks
every chunk length and the whole-file SHA-256 before saving to
`Documents/RoomTransfers/<room>/` without overwriting a different file.

Cleanup: `withdraw` (sender or owner) and `sdi_room_asset_sweep` (service role)
delete chunk bytes, confirm none remain and write `room_asset_cleanup_audit`.
The sweep removes expired copies, copies in closed rooms and copies whose sender
is no longer a member. A sender's file is hidden from others the moment their
membership ends. Device originals are only read, never moved or deleted.

Operator gate: `room_asset_sweep` is now one of the named sweeps in
`backend/ops/sweeps.py` (`--all` or `--only room_asset_sweep`); the host timer
that runs the sweeps worker (for example every 15 minutes) must exist once
rooms-v2.sql is applied. Not scheduled by this repository.

## Browser, join and handoff (#234)

- Browser lists owned and approved rooms with sharing mode, plus the member's
  own pending admission requests with expiry.
- Join: paste a 64-hex code → preview → explicit consent → request; the owner
  must approve. A code alone never exposes a project.
- *Open shared project in Studio* opens the exact device project and records a
  handoff; leaving Rooms for Studio keeps synchronisation alive, returning to
  Rooms (or posting `.sdiCommunityReturnToRoom`) re-opens that room, and *Back*
  or *Leave* ends the session. Losing access ends the session with a notice that
  the device copy is unchanged.
- A member without a local copy opens the copy imported from the owner's
  project handoff (below) when one exists; otherwise they are told to download it.

## Owner-approved project handoff (`sdi_room_snapshot`, rooms-v2.sql v2.2)

Owner decision 2026-10-18: a room owner may send the shared project to room
members when they join, using temporary server storage that is deleted afterwards.

| Bound | Value |
| --- | --- |
| Format | The portable `.sdiproject` backup (`SDIPROJECT000001` header), as produced by *Save Project Backup* |
| Per snapshot | 32 MiB, 256 KiB chunks (max 128) |
| Live snapshots | one per room; a new offer replaces the old one |
| Per owner | 20 offers per day; 600 handoff calls per minute per account |
| Unfinished upload | expires after 1 hour |
| Finished copy | expires after 72 hours |

- **Owner** (*Send project to members*, confirmation dialog): the app builds the
  saved project's portable backup (the device project is only read), then
  `offer` (size, SHA-256) → `put` chunks (resumable) → `finalize`, where the
  server recomputes the SHA-256 and discards a mismatching copy. The owner sees
  how many members imported it and how many are still waiting, and can
  *Withdraw sent project* (verified deletion).
- **Member** (*Download shared project*): `current` → `get` each chunk (only
  approved, non-revoked members of that room; never the owner, a pending
  requester, an outsider or another room) → the client checks every chunk
  length, the whole-file SHA-256 and the backup header → `importPortableProject`
  creates a **new** project with a fresh identity (an existing project is never
  overwritten) → a local link (`Application Support/Rooms/room-project-links.json`)
  remembers which project the room's copy became → `receipt` with the verified
  digest. A newer version creates another new project; the earlier import is kept.
- **Deletion**: the server copy is deleted, with verified chunk counts and an
  append-only `room_snapshot_audit` row, when every current approved member holds
  a receipt, on owner withdrawal, on replacement, when the room's shared project
  changes, when the room closes, after a corrupt upload, or on expiry. The
  service sweep (`room_asset_sweep`) also performs these deletions. Copies
  members already imported stay on their devices; revocation cannot erase them.
- Status: SQL verified on local PostgreSQL 16 (`backend/sql/tests/160_room_project_handoff.sql`);
  the Foundation client logic is verified by `Tests/CommunityRooms`. The SwiftUI
  card, the real backup/import path on device and a two-client journey are
  **deferred** to native CI and device acceptance. Nothing is applied to the live project.
