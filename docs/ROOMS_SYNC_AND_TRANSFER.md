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

Editor integration still required (Studio owner): register
`RoomSessionCoordinator.shared.applyRemote` to apply records to the document,
call `publishLocalEdit(kind:payload:)` with a `target` from each Studio command,
and `drain()`/`catchUp()` on a timer while a handoff is active. Until then the
Rooms screen shows the server stream as recorded, never as applied.

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

Operator gate: schedule `public.sdi_room_asset_sweep(200)` (for example every
15 minutes) from the existing service-sweeps worker once rooms-v2.sql is applied.
Not scheduled here.

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
- Members without a local copy of the project are told so; project files are
  not transferred through rooms.
