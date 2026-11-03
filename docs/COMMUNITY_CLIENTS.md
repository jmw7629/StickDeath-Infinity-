# Community native clients (feed, Rooms, War Room, challenges, Calendar, profile, admin)

Source revision: wave 3 on branch `claude/studio-sdi-overhaul-kurekj` (base ee35143).
Everything below is implemented in source and verified only as far as a Linux host
allows: four Foundation-only suites run against scripted fake transports, every
SwiftUI file passes `swiftc -parse`, and the repository verifiers pass. Native
compilation, simulator journeys and any call against a live project are **DEFERRED
(not run)**. The server contracts are the unapplied candidates in `backend/sql`;
nothing has been deployed.

## Architecture

- `StickDeathInfinity/Models/CommunityModels.swift` — request/response contracts and
  pure logic (feed timeline, room invitation/share/quota rules, command-sync records,
  War Room presentation and vote machine, challenge phases and schedule rules,
  Calendar placement, records/achievements, admin step-up policy, health/agent/finance
  DTOs, deterministic ISO 8601 parsing, protected offline cache, server clock estimator).
- `Services/Social/CommunityTransport.swift` — the one network seam (`rpc`, `rows`,
  `hasSession`) and `CommunityGateway` (bounded decoding, server-error surfacing,
  clock samples). `SupabaseCommunityTransport.swift` is the production adapter over
  the existing `SupabaseManager`; without configuration every call fails with
  `notConfigured`, without a session with `signedOut`.
- Domain clients: `FeedClient`, `ProfileClient`, `AdminOperationsClient`
  (Services/Social), `RoomsClient` + `RoomCommandSync` + `RoomSessionCoordinator`
  (Services/Rooms), `WarRoomClient` (Services/WarRoom), `ChallengeLifecycleClient` +
  `CalendarClient` (Services/Challenge). All Foundation-only, all exercised by tests.
- Screens: `Views/Home/HomeFeedView`, `Views/Collab/CollabRoomView`,
  `WarRoomView`, `LeaderboardView`, `WatchTogetherView`, `CommunityChrome` (shared dark
  chrome, production client instances), `Views/Challenges/*`,
  `Views/Messages/CalendarView`, `Views/Profile/ProfileView` + `EditProfileView`,
  `Views/Admin/AdminDashboardView`. Every state is explicit: not configured, signed
  out, loading, empty, error, success. No counts, matches, viewers, badges or balances
  are shown unless a server reply carried them.
- Retired: `Services/Social/SocialService.swift` (legacy posts/likes/comments client,
  unreferenced, contradicted the no-comment-thread rule).

## Tests run here (Linux, Swift 5.10.1, `-O`)

| Suite | Cases | Covers |
| --- | --- | --- |
| `Tests/CommunityFeed` | 12 | timestamp parsing, page merge/dedupe/client memory bound, keyset cursor requests, poster thumbnails and placeholder, optimistic like/follow rollback, page-0 offline cache, server-confirmed reactions, signed-out refusal, export policy, handle rules, avatar bounds, records completeness, achievement grouping, portfolio filtering |
| `Tests/CommunityRooms` | 9 | invitation code rules and share text, project share payload (no content), consent-gated creation and partial-share reporting, preview/admission/mint, lifecycle/roles/report/browser decoding, command fencing/idempotency/conflicts/access end, catch-up gaps, conflict replies keep `head`/`missing`, session coordinator drain/catch-up |
| `Tests/CommunityContests` | 6 | matchup presentation without computed winners, one mutable vote machine, War Room client confirmations, challenge phases on the server clock and schedule rules, Calendar range ≤ 62 days with DST-safe placement (America/New_York spring and fall transitions) and offline cache, server clock estimator |
| `Tests/CommunityAdmin` | 7 | recent re-authentication policy, access/step-up parsing and refusal handling, health fail-closed validation, agent caps/emergency-stop payloads, finance reads/mutations, room-report and removal-appeal decisions, decision history across pages |

Toolchain note: the `-Onone` build of an async `@main` hangs on this Linux toolchain
for ordinary generic collection code (reproduced in isolation); the suites are compiled
with `-O`, the release configuration. See `docs/ci-candidates/community-clients-verify.yml`.

## Evidence by epic

### #117 — Social video wall and challenge lifecycle (client half)

`HomeFeedView` lists approved renditions through `sdi_feed_action` with the four
server rankings (`FeedCategory.explanation` states each rule), bounded 25 × 40 pages
merged by identity (`FeedTimeline.merge`), a page-0 per-account protected cache shown
only with "Offline · last updated", HTTPS-only playback, link sharing, and file export
only when `allow_export` is true (`FeedExportPolicy`, bounded 200 MB download to a
temporary file removed after the share sheet). Likes/follows are server-idempotent;
the client changes only the tapped card by ±1 and rolls back when the server does not
confirm (`FeedTimeline.beginLike/finish`); repeat taps while in flight are ignored.
Blocks remove the creator immediately and reports record a reason. Creators grant
export per render from Profile → Publishing (`sdi_export_consent`) and queue the feed
destination (`sdi_creator_review publish_feed`). Challenges use `sdi_challenge_action`:
phases come from `server_time` (`ChallengeSummary.phase(at:)`), entries play real
renditions, one entry per creator from the creator's approved media, one mutable
favourite vote for non-participants, results only from the finalised record, reward
text only when configured, and the moderator lifecycle (create, schedule with the
1 h/1 h/60-day rules, cancel) sits in Admin → Challenges. Paging is snapshot-stable:
page 0 returns an `as_of` instant that `FeedTimeline` keeps and `FeedClient.page`
sends with every later page, so posts published meanwhile shift nothing until the
member refreshes (a snapshot older than a day is refused with "Refresh the feed";
Trending's like-based rank is still computed per request). Later pages are never
cached.

### #10 — Profiles, ownership and optional public achievements (client half)

`EditProfileView` applies `CreatorHandle` rules before the existing username/bio save
and adds a Photos-picked avatar downscaled on device (≤ 512 px, ≤ 300 KB JPEG) and
uploaded to `avatars/<account>/avatar.jpg`, persisted through the existing profile
update only after the server confirms. `ProfileView` shows the creator's approved
renditions as a portfolio (`sdi_watch_media` filtered by owner), reports device
project and published counts, and states that follower/like totals have no service
contract. Records & badges keeps both public displays off by default, saves
preferences with revision checks (`sdi_profile_records`), and shows the earned/locked
achievement catalogue by category (`sdi_achievement_catalog`); awards are server-side
and keyed on finalised events. The leaderboard labels creators who hide badges instead
of inferring any.

### #118 — Invitation-based Studio collaboration rooms (client half)

`CollabRoomView` creates a room only after the owner picks a specific device project
and permissions and confirms the share (`RoomsClient.createRoom`: `sdi_room_action
create` then `sdi_room_manage set_project`; a failed share is reported, never hidden).
Invitation codes are server-minted 64-hex secrets with a 24 h / 20-use life, shared
through the system share sheet or copied, and revocable; the recipient reviews the
room, consents explicitly, and the owner approves before any room data is visible
(`sdi_room_action preview/request/approve`). Roles (`set_role`), remove, block,
leave and close are wired; pending requests list with expiry. `RoomCommandSync`
implements versioned shared edits: idempotent operation ids, base-revision fencing,
explicit conflicts carrying the missing commands, contiguous catch-up and access
termination; `RoomSessionCoordinator` drains local edits and hands remote ones to an
editor hook. Room reports go to the admin queue (`sdi_room_manage report`,
`sdi_room_moderate`). The quota panel shows the server bounds and states that binary
asset transfer has no service. Gaps: the Studio editor hook is not connected (owner of
`StudioViewModel`), so remote commands are shown as recorded, not applied; members
without a local copy are told so; the tab host needs the one-line
`.sdiCommunityOpenStudio` observer (see REPORT).

### #119 — War Room video matchups and trustworthy results (client half)

`WarRoomView` proposes a matchup only from the creator's approved renditions with an
explicit agreement to the visible rules, accepts with the opponent's own approved
video, plays both renditions on tap (side by side on wide layouts, one at a time on
phones, per-device mute), and casts one mutable vote that stays pending until the
server confirms and reverts to the previous server vote on refusal
(`WarVoteMachine`). `WarMatchPresentation` shows tallies only while the server
supplies them and a result only from `completed` + `outcome`; an ended but
unfinalised match says so. Withdraw, report, block, participant notices and appeals
are wired; Admin keeps the report and appeal queues. Nothing invents opponents,
viewers or scores.

### Retained scope (#296 Watch Together, #297 Calendar)

Watch Together now estimates the server clock from reply `Date` headers
(`ServerClockEstimator`, lowest round trip, ±uncertainty shown) and derives the shared
position from server time; participants remain the room members, there is no chat
field, and guests get the sign-in prompt. Calendar fetches only the visible month
through `sdi_calendar_range` (≤ 62 days), places milestones on the civil day in the
user's calendar (DST-tested), caches per account with the offline label, and opens the
challenge when it is still listed. It creates nothing and sends nothing.

### Admin (#210, #211/#214, #247, #248, #255, #257)

Privileged actions check `AdminStepUpPolicy` before sending and show a re-verify
banner that opens the authenticator; `step_up_current` from access and
`step_up_required` refusals feed the policy. Video approvals show the per-render
decision history and state that the review service supplies no storyboard. New
panels: Service health (`sdi_admin_health`, fail-closed validation, no hosts), Agents
(`sdi_agent_admin` registry, caps, permissions, instructions, runs, emergency stop),
Finance (`sdi_finance_admin` provider-reported reads; owner product configuration;
the two monthly tiers stated), Room reports and Feed removal appeals. The former
placeholder cards for challenges, bots, analytics, settings and billing are gone;
Spatter and analytics now state exactly what is and is not connected.
