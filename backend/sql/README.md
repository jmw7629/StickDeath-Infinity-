# Collaboration / Watch Together deployment candidate

`collaboration-watch.sql` is implementation source, not an applied migration.
Do not execute against production before the integration phase inventories the
existing schema and reconciles its room identities. No backend was changed.

The shared room tables separate owner approval, member acceptance and revocation.
Only accepted members read sessions; host writes use revision checks. Playback
positions are timestamped on the database. Client failures pause playback and
refresh membership. Only service-curated approved public renditions enter the
media catalogue; never insert a private draft URL or bearer credential here.
Native media playback uses HTTPS without forwarding account tokens.

Remaining implementation: expiring hashed invitation redemption, consent RPCs,
room creation and membership management UI, quotas/rate limits, project command
sync, media catalogue ingestion from approved publishing, host transfer, and
server-clock offset estimation for cross-device playback. Current client polls
every two seconds while the room is active. No camera, microphone or messaging.

Verification and deployment are deferred by owner instruction. Before release:
reconcile existing backend, generate its normal migration, verify RLS for both
users and revoked users, review private function grants, run SQL advisors, and
exercise two-client playback/late join/reconnect. No tests or deployment claimed.

API reference: https://supabase.com/docs/reference/swift/rpc
Database security reference: https://supabase.com/docs/guides/database/functions

`room-invitations.sql` extends this candidate with the shared admission workflow:
server-created 256-bit codes hashed at rest, 24-hour/20-request limits, 30 account
operations per minute, explicit recipient consent followed by owner approval,
invite rotation/revocation, block/removal, and bounded room/member counts.
Requires pgcrypto in the `extensions` schema. Gateway access logs must redact
RPC bodies; do not log codes. The native Rooms UI calls this operation boundary.
Project synchronization and approved-media ingestion remain separate work.

`war-room.sql` adds approved-render matchup proposals, explicit opponent acceptance,
24-hour voting, immutable submission digests, participant withdrawal, creator blocks,
and one mutable vote per authenticated nonparticipant. It returns only authorized,
currently approved matches and server-counted votes. No fake counts or optimistic
permanent votes. Native UI includes real video playback, selection and errors.
Still required: moderation/appeals UI, finalized records/badges, publication service
integration, account directory picker, abuse analysis and final service verification.

`video-feed.sql` implements an approved-video wall, bounded25-item pages (40-page
cap), Recent/Following/Featured/Trending ranking, idempotent likes/follows, creator
blocks and categorized reports. Only the publishing service inserts feed posts;
metadata and media ownership/approval/digest are checked on reads and reactions.
Trending uses7-day likes; pages use offset ranking and native identity deduplication,
so concurrent ranking changes require refresh rather than a snapshot guarantee.
Native UI uses actual AVPlayer playback and public URL sharing; no text post/comment
composer is exposed. Creator-permitted file export, moderation processing and
publication ingestion remain implementation work. Nothing has been deployed.

`admin-approval.sql` implements a private review queue and append-only-by-client
review decision history. Administrator access requires a server-provisioned role,
MFA aal2 and a still-present auth session. Spatter approval additionally requires
the owner role. Decisions bind to the current SHA256, version, consent and exact
destination list. Render/rights/consent changes return the record to pending.
The native Admin Video Approvals tab plays the supplied expiring HTTPS rendition
with audio and submits approve/reject/request-changes decisions.

Not deployed or verified. Pending work: secure role provisioning/MFA enrollment,
private authorized preview URL delivery, audit retention, ingestion from render
jobs, publication-worker enforcement of the matching approval, and web command
center parity. A decision does not itself publish any content.

`admin-users.sql` adds a paginated role-redacted directory and reason-required
suspend/ban/restore/sign-out/internal-note operations with audit records. Self and
enabled-admin accounts cannot be modified through this path. App service access
checks a current auth session and account controls; suspension/ban/sign-out deletes
sessions so issued tokens fail these service checks immediately. Restoration allows
a fresh sign-in; it never recreates a revoked session. This is app-service suspension,
not a claim that identity-provider sign-in itself is disabled.

Install all candidates before exposing endpoints: room/watch → invitations → War
Room → feed → approvals → admin users. Earlier PL/pgSQL operations reference the
account-active helper defined in the final candidate. Reconcile existing schema and
generate normal migrations in the final integration phase. Do not apply a partial
set. Existing legacy APIs also require the account gate before release. Appeals,
notification delivery, plan data, admin rate limiting and
moderation processing remain incomplete. Native demo metrics and fake settings
have been replaced with explicit unconnected states; no fabricated business data.

`moderation.sql` supplies the feed-report queue, reasoned dismiss/remove decisions,
report-version conflicts, actor separation, and an audit trail. Removal revokes the
shared media approval, feed visibility, War Room eligibility and prior render review,
so Watch Together stops at its next access refresh. External provider removal is a
durable pending job, not a claimed completed takedown. Native Admin Moderation can
play/report-review the exact recorded rendition. Appeals storage is defined but its
submission/adjudication UI, room/asset report queues, removal worker, cache/CDN purge,
rate limits and final integration remain. Install after the complete earlier set.

`publishing-jobs.sql` defines exact-review/version/digest/destination jobs and a
private artifact registry. Enqueue and every worker renewal recheck approval,
consent, rights, owner approval for Spatter, account status and artifact expiry.
Unique keys deduplicate enqueue. Leases, bounded attempts/backoff, cancellation,
late-success removal-pending and real resulting links are persisted. Expired
leases enter reconciliation, not blind reupload. Worker functions are service-role
only; no credentials enter iOS. Profile Publishing displays status/retry/cancel.

Still needed: binary resumable upload adapters and existing owner OAuth, worker
reconciliation/removal execution, private artifact ingestion/retention, native
submission flow and feed publication adapter. Worker must hash actual bytes and
renew authorization immediately before irreversible provider operations; database
leases cannot atomically cancel an external provider request already in flight.
Only provider-confirmed results may call finish. No uploads/deployment/tests run.

### Admin user directory implementation update

The native Users tab now exposes a paginated private account-action history with
actor, reason, prior state and timestamp. The `history` action shares the current
users-capability, MFA and live-session gate; the audit table remains inaccessible
directly to client roles. Linked sign-in methods come from `auth.identities`, not
user-editable profile metadata. They describe current linked identities, not an
inferred original signup provider. Feed-report totals include all outcomes and are
returned only when the operator also has moderation capability; totals are not
findings of abuse. No report text or reporter identity is exposed by this directory.
Native account actions capture the target and reason in a confirmation dialog and
reject submission after session/scene generation changes. These candidates remain
unapplied and native/runtime authorization verification remains deferred.

### Account restriction appeals

`admin-users.sql` now includes a private structured appeal lifecycle. A freshly
authenticated, nonanonymous member can read only their own account state and the
latest 20 appeals, including member-visible decisions. This limited endpoint checks
the live session but deliberately does not require an active account; all product
endpoints retain their restriction checks. Internal account-control reasons and
reviewer identities are not returned to members. Submission binds to the exact
restriction timestamp shown by the server, permits one appeal per restriction and
caps submissions at three daily. The member flow is in Profile settings.

The native admin Users tab includes the oldest 50 pending appeals. Review requires
users capability, MFA, a live active admin session and a member-visible reason.
Acceptance calls the existing audited restore operation atomically. A restriction
change supersedes the old appeal instead of restoring access; rejection records an
account audit entry. Decisions are persisted in the member status view, not sent
as chat or fabricated push/email notifications. External notification delivery and
full integration/authorization verification remain pending. SQL is still unapplied.

### Native content inventory

The Content tab reads `sdi_admin_content`, a moderation-capability/MFA/current-session
metadata inventory with bounded 50-entry pages and title/creator/ID search. It
includes hidden and unapproved feed records, labels those flags separately, and
shows all-outcome and pending report totals. No private media URLs or reporter
identities are included. The tab links to the existing audited report-resolution
queue; the inventory cannot bypass approval or directly publish content. Offset
pagination is a changing view, with client identity deduplication and fresh search,
not a snapshot export. SQL deployment and native authorization/runtime checks remain
pending.

Content inventory now supports confirmed Featured placement changes with a required
reason and captured feature revision. The private RPC requires moderation/MFA/live
session authorization, locks the current post, checks eligibility before featuring,
and records previous/new flags in a client-inaccessible audit table. Removing a
feature flag does not require content to remain eligible. Neither operation changes
visibility, render approval, creator consent, export permission or publication jobs.
A stale feature revision requires refresh. This remains source-only/unapplied.
