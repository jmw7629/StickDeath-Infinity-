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

## October 12 batch: integrity, publication, rooms v2, challenges, achievements, billing, agents, lifecycle, hardening, support

All files below are unapplied deployment candidates. They were applied, in the order
listed at the end of this document, to a throwaway local PostgreSQL 16 cluster with
stubbed Supabase pieces (see "Local harness"); that proves the SQL is coherent on
vanilla PostgreSQL and that the assertions in `tests/` hold there. It proves nothing
about the live project, which has not been touched.

Two existing candidates were corrected because the harness could not apply or run
them: `upload-preview.sql` referenced the `creator`/`upload`/`digest` parameters
unqualified inside a SQL-language body (ambiguous with column names, a hard error at
apply time); `publishing-jobs.sql` `publish_action` used `on conflict(...,destination)`
with a parameter of the same name (runtime error on every enqueue). Signatures and
RPC names are unchanged.

`feed-integrity.sql` closes the cross-cutting gaps: self-likes are refused; suspended
or banned creators disappear from feed listings, reactions, follows, War Room lists,
proposals and votes (`creator_restricted`); a repeat report is `do nothing` and a
decided report can no longer be reopened by reason changes; War Room proposals expire
seven days after creation (`expired` status, service sweep `sdi_war_expire_proposals`)
and stop counting toward the five-active limit; private render artifacts registered
for 24 hours are retained seven days while under review and thirty days once approved,
so approval and publishing leases no longer race the intake expiry (problem 6).
Rejected renders keep their registered expiry.

`feed-publication.sql` is the missing feed path (problem 1). `sdi_feed_publish_claim`/
`sdi_feed_publish_finish` are service-role only and re-check
`release_allowed(review, version, digest, 'feed')` on claim and finish: owner/admin
approval of the exact digest, consent, cleared rights, active account, retained
artifact and the owner flag for Spatter renders. Finish inserts the approved
`sdi_watch_media` row (owner, digest, HTTPS URL) and a visible `feed_posts` row in one
transaction; if approval lapsed or cancellation raced the copy, the job becomes
`removal_pending` and `sdi_feed_removal_claim/finish` remove the hosted copy. Creator
export permission is the new `render_reviews.allow_export` field with the
`sdi_export_consent` setter (default off, not part of approval evidence). Creators
queue the feed destination through `sdi_creator_review('publish_feed', ...)`.

`rooms-v2.sql` adds the shared project reference, title and `view`/`edit` permissions
to `sdi_rooms` (owner-set, revisioned), `editor`/`viewer` member roles with an
owner-only `set_role`, the member's own pending-request list, room reports with an
admin queue (`sdi_room_moderate`: dismiss/close, uninvolved administrator, no reporter
identity returned), and `room_commands` for versioned shared edits: unique operation
id per room (idempotent replay), strictly increasing room revision, explicit conflict
responses carrying the missing commands, bounded payloads and rate. It also supplies
the feed-removal appeal RPC for `moderation_appeals` (problem 9): owner-only
submission within 30 days, uninvolved-admin decision, restoration only while the
hosted copy still exists.

`challenges.sql` implements challenge create/schedule/cancel (moderation capability
with MFA), member submit/withdraw/vote with the War Room digest-eligibility rule, one
entry per creator, one mutable favorite vote per nonparticipant, server-time phases
(upcoming/active/voting/completed), a service finalizer (ties record no winner) and
`sdi_calendar_range(start, end, limit<=500)` for Calendar month views over a range of
at most 62 days. `reward_text` is descriptive; no coins, prizes or money exist.

`achievements.sql` adds versioned `achievement_criteria`, an idempotency ledger keyed
on the finalized source event, service award functions for War Room and challenge
results (`sdi_award_achievements` sweep) and a member catalogue of earned/locked
badges for the caller only. Visibility to others still follows profile-records
preferences (default off).

`billing.sql` stores product identifiers, provider events (unique provider+event id),
subscriptions with a provider-reported paid-through date, an entitlements view, a
finance ledger of provider-reported amounts and an audit table. No price is stored;
the approved offers are the two monthly tiers at USD 4.99 and USD 9.99 and annual
periods cannot be approved until the owner records explicit configuration. Events are
applied only by the service role from verified provider payloads; out-of-order events
never move a subscription backwards; unapproved products grant nothing. Clients read
`sdi_my_entitlement` and write nothing. Edge-function contracts are in
`backend/billing/README.md` (unimplemented).

`agent-controls.sql` is the owner's agent console backend: registry (paused by
default), global emergency stop, per-agent run/item/cost caps and permissions,
versioned instructions with rollback, run log with heartbeats, and the service
contract `agent_run_begin/heartbeat/finish` that refuses work when stopped, paused,
over cap or without published instructions. Caps are configuration; nothing spends.

`admin-hardening.sql` adds the step-up check (`recently_authenticated`, based on MFA
timestamps in the token's `amr` claims), per-administrator rate limits, a denial
audit, one `admin_gate` helper, step-up on role changes, the service-only
`sdi_provision_owner` (bootstrap only; requires confirmed email and a verified MFA
factor; binds display name/handle; takes no password), worker heartbeats and
`sdi_admin_health` (queue counts, oldest pending items, worker staleness, emergency
stop; no hostnames or credentials).

`support-requests.sql` is the #272 intake: `sdi_support_action` with
`create|list_mine|withdraw|delete` for members (five per day, idempotency key,
server receipt) and `list|update_status` for administrators with the users capability
and MFA, audited, with per-request retention and a service retention sweep. No
attachments in this candidate; private projects are never uploaded.

`account-lifecycle.sql` provides member notices, the own-rows data export (three per
day; on-device projects are not server-side and the export says so), deletion requests
with a seven-day cooling-off and the service worker `sdi_account_deletion_run`: phase
one ends sessions, suspends, withdraws publishing consent, unapproves media and queues
removals, hides posts, withdraws matches and entries, closes rooms and scrubs support
text; phase two purges server rows in dependency order and deletes the auth user only
once hosted copies are removed, publishing jobs are settled and intake renders are
retired, otherwise it waits and eventually surfaces the request as blocked. Several
evidence references become nullable `on delete set null` so retained moderation
records survive the deletion of the member who filed them. Provider subscriptions are
not cancelled by this code; the notice tells the member to cancel with the store.

Known limits of this batch: `publishing_admin` withdrawal still handles only YouTube
jobs (feed copies go through the feed removal worker); nothing schedules the service
sweeps; the removal and feed workers are SQL contracts without a host adapter; the
Spatter generation and daily-draft flows live in `backend/spatter` and are out of
scope here. None of this is deployed or verified against the live project.

## October 13 batch: finance, consent, notifications, marketing, RLS review

`billing-finance.sql` (#254/#255/#258): manual and imported finance records with source
and reconciliation flags, corrections linked to the original entry, a reconciliation
report that names discrepancies (subscription without charge, charge without
subscription, refund above charges, errored/unprocessed events, possible duplicates,
unreconciled manual rows), period summaries that keep payouts (cash movements) apart
from charges/refunds/fees (recognized records) and expenses, a CSV-ready export without
member identity, and agent cost against caps. Reads need the finance capability; every
mutation needs step-up and is audited. Tested by `tests/070_billing_lifecycle_finance.sql`,
which also drives the full subscription lifecycle through `sdi_billing_apply_event`.

`consent-versions.sql` (#174/#261/#273/#262): owner-published policy versions (terms,
privacy, publishing, marketing, content with a required `min_age`), member acceptance
of exactly the current version with the surface recorded, separate publishing and
marketing withdrawal (publishing withdrawal clears consent on every render so the
existing triggers cancel or withdraw jobs), and the service check `sdi_consent_verify`
the intake registrar calls before registering a render.

`notifications.sql` (#290/#276): per-member preferences (product and marketing off by
default, daily cap), device registrations (five per member, tokens readable by the
service only), administrator announcements (compose, schedule and cancel with step-up),
service fan-out that applies audience, preferences, account state and cap and records a
reason per suppressed delivery, in-app inbox, and email suppression by address hash
(`unsubscribe` keeps service notices; `bounce`/`complaint` stop everything).

`marketing-workspace.sql` (#274/#283): campaigns, drafts per destination bound to the
exact approved render (review, version, digest) and a hash of the approved copy, owner
approval with step-up that requires `release_allowed(..., 'social')` and the creator's
current marketing consent, invalidation triggers on render change and consent
withdrawal, per-destination cadence that can only queue already approved drafts, and
the service claim/finish contract for `backend/publishing/destinations.py`.

`tests/080_rls_review.sql` asserts the authorization invariants for the whole set
(RLS on every table, no client grants, pinned search paths, invoker wrappers, no anon
execution, an explicit service-only function list, no secret-shaped columns); see
`docs/RLS_REVIEW.md`. `scripts/backend/verify_backup.sh` rehearses pg_dump/pg_restore
of the applied set with a fixture and checks counts, RLS and grants after restore.

`tests/100_burst_limits.sql` drives each per-minute cap to its documented limit
through the real RPCs (feed 60, challenges 60, War Room 60, room creation and
management 30 shared, room commands 300, administrative gate 60 with an audited
refusal) and shows that an expired window admits the member again. The 20-per-minute
publishing-admin cap counts real audit rows and is covered by the publishing tests
rather than a burst loop.

## October 15: merch interest poll (website store "coming soon")

`merch-interest.sql` backs the coming-soon store page after the owner chose not to start
Shopify (it bills from the start). It counts a store poll ("should we open the SDI merch
store?"), a thumbs up/down per gallery concept and a thumbs up/down per approved design
idea, and takes design ideas into a moderation queue. Only approved ideas are public.

* Voter: an active signed-in account votes as its user id; a browser without a session
  sends a random UUID from its own localStorage, stored only as HMAC-SHA256 under a
  32-byte salt generated at install (`sdi_private.merch_settings`). One vote per voter per
  target, changeable or cleared with value 0. Keys are free to mint, so totals report
  anonymous and member (`member_*`) counts apart and the page says anonymous votes are a
  signal, not verified people.
* Limits: 30 actions per minute per voter, 600 anonymous votes per minute globally,
  30 ideas per hour globally, 3 ideas per voter per day and at most 300 pending ideas;
  all are rows in `merch_settings`. No IP, email or device data is stored; the optional
  public handle is the only free-text personal datum. Ideas reject links, email
  addresses, angle brackets and control characters.
* Surface: `sdi_merch_totals`, `sdi_merch_vote` and `sdi_merch_suggest` are the first
  wrappers the anon role may execute (the publishable key); `tests/080_rls_review.sql`
  pins that list. Installing grants anon usage on `sdi_private`, and the candidate moves
  any earlier PUBLIC execute grant on `sdi_private` functions to `authenticated`;
  `tests/140_merch_interest.sql` asserts anon can run exactly the three bodies.
* Moderation: `sdi_merch_moderate` (`queue`, `results`, `decide`, `settings`) uses
  `admin_gate` with the moderation capability; `decide` and `settings` need step-up.
  Rejection deletes that idea's votes. `sdi_merch_retention` (service role) sweeps
  day-old budget rows and rejected ideas 30 days after the decision.

Not applied to the live project. Before enabling the website poll: install it, confirm
the anon grants with `tests/080_rls_review.sql` assertions against the project, and add
gateway-level rate limiting if traffic warrants (the database cannot see client IPs).

## Local harness

`scripts/backend/run_sql_tests.sh` starts a throwaway PostgreSQL 16 cluster
(`initdb` in a temporary directory, Unix socket only), applies
`scripts/backend/sql_test_stubs.sql`, applies every file in the apply-order block below
(and fails if a `backend/sql/*.sql` file is missing from it), then runs each
`backend/sql/tests/*.sql` file, which wrap themselves in `begin ... rollback`.
When run as root it executes the server inside a user namespace mapped to the
`postgres` (or `nobody`) account because PostgreSQL refuses to run as root.

What the stubs replace, and only for this local run: the `anon`, `authenticated` and
`service_role` roles; an `auth` schema with minimal `users`, `sessions`, `identities`
and `mfa_factors` tables; `auth.uid()`/`auth.jwt()` reading `request.jwt.claims`
exactly as Supabase does; pgcrypto in an `extensions` schema; and an `sdi_test` schema
of assertion/login helpers. Nothing else is stubbed. Supabase-specific behaviour that
the stubs cannot reproduce (GoTrue session issuance, MFA enrolment, PostgREST
parameter mapping, storage) remains deferred to the integration phase.

Python unit tests for the intake, billing, publishing, feed, destination, sweep, mail
and push modules use scripted fake transports and a local SMTP sink and never open an
outbound connection: `python3 -m unittest discover -s backend/tests -t .` from the
repository root. Service sweeps are run by an operator or host timer through
`python3 -m backend.ops.sweeps --all` (see `docs/OPERATING_RUNBOOK.md`).

## Apply order (single source of truth; the local harness reads this block)

<!-- apply-order -->
1. collaboration-watch.sql
2. room-invitations.sql
3. war-room.sql
4. video-feed.sql
5. admin-approval.sql
6. admin-users.sql
7. admin-permissions.sql
8. moderation.sql
9. publishing-jobs.sql
10. publishing-withdrawal.sql
11. publishing-admin.sql
12. creator-reviews.sql
13. review-rights.sql
14. upload-identity.sql
15. upload-registration.sql
16. upload-preview.sql
17. upload-retention.sql
18. preview-renewal.sql
19. war-finalization.sql
20. war-moderation.sql
21. war-appeals.sql
22. profile-records.sql
23. admin-overview.sql
24. feed-integrity.sql
25. feed-publication.sql
26. rooms-v2.sql
27. challenges.sql
28. achievements.sql
29. billing.sql
30. agent-controls.sql
31. admin-hardening.sql
32. support-requests.sql
33. account-lifecycle.sql
34. billing-finance.sql
35. consent-versions.sql
36. notifications.sql
37. marketing-workspace.sql
38. spatter-draft-jobs.sql
39. agent-proposals.sql
40. worker-configuration.sql
41. users-profiles.sql
42. diagnostics.sql
43. rate-limits.sql
44. security-credentials.sql
45. security-retire-communications.sql
46. security-audit-integrity.sql
47. merch-interest.sql
<!-- /apply-order -->

`rate-limits.sql` (#263): daily per-account quotas the per-minute budgets do not cover: render intake registrations and bytes, publication jobs (a duplicate request uses no quota) and room invitation codes, enforced by BEFORE INSERT triggers on every insert path and configurable in `sdi_private.resource_quotas`; members read their own usage with `sdi_quota_status`. Defaults are candidate values, not measured capacity. Tested by `tests/130_security_lifecycle.sql`.

`security-credentials.sql` (#238): credential slots for provider keys and the owner's OAuth grant. Values live only in the project's secret store (Supabase Vault); the schema keeps state, revision, a 12-hex fingerprint and an append-only audit. Store/rotate/load/compare-and-set/revoke are service-only; administrators read presence and rotation due through `sdi_credential_status`. Without Vault every call says so and stores nothing. Tested by `tests/130_security_lifecycle.sql`.

`security-retire-communications.sql` (#260): closes any legacy messaging/calling objects a live project still holds (client privileges revoked, removed from realtime, rows kept) and exposes `sdi_legacy_communication_exposure` for the release gate. On a fresh project it closes nothing.

`security-audit-integrity.sql` (#256): every `sdi_private.*_audit` table becomes append-only (no update except FK set-null, no delete or truncate outside the account purge); `sdi_audit_integrity_report` lists guarded tables for the restore drill. Install last.

`agent-proposals.sql` (#284): the approval inbox. A running agent with the `propose` permission files a proposal (`sdi_agent_propose`, idempotent for an identical pending one, fifty pending per agent) instead of acting above its caps; administrators read the inbox and only the owner approves or rejects with a reason (`sdi_agent_proposal_admin`, audited); the worker receives approved proposals (`sdi_agent_proposals_due`, nothing under emergency stop or pause) and records the outcome (`sdi_agent_proposal_finish`); pending proposals expire after fourteen days. Tested by `tests/110_agent_proposals.sql`.

`users-profiles.sql`: the `public.users` profile row the native app reads and writes (own row only; the member inserts it after sign-up and may edit username, bio, avatar, onboarding, skill level and interests; `role` and `subscription_tier` are server-owned and not client-writable; administrator authority stays in `sdi_private.admin_roles`).

`worker-configuration.sql` (#248): masked provider-configuration health. A service worker reports which of its named settings are present as booleans only (`sdi_worker_configuration`; any other value type is refused so no secret can be stored), and administrators read presence, the missing names and staleness through `sdi_admin_configuration`. `backend.ops.sweeps` reports its own settings after every run. Tested by `tests/120_worker_configuration.sql`.

`spatter-draft-jobs.sql` (#212/#214): one job per UTC day behind the `spatter_daily_video` agent gate, at most three attempts, 15-minute leases, missed days recorded; adds `render_reviews.storyboard` and `source_project_digest` and extends `invalidate_render_approval`. Unapplied; no capacity or schedule is created. Its #209 metering block applies the owner's plan rules as revised 2026-10-15: Free is never served (every Free request is refused with `upgrade_required`, upgrade `creator_or_pro`, before any counter or reservation; the former `free_prompts` column and `month:`/`free` buckets were removed because the file was never applied), Creator = `floor(creator_period_budget_microusd / prompt_cost_estimate_microusd)` server-funded prompts per billing period (defaults 3490000 / 20000 = 174; budget capped at the 4990000 gross price; both owner-editable via `sdi_spatter_usage_admin`, which also reports `creator_period_limit`), Creator's own-AI-key prompts never reach the server, Pro unlimited, trialing subscriptions metered as their own tier. Actual provider cost is not recorded: the commit path carries provider usage units only. Spatter credits (owner decision 2026-10-15, later): owner-approved consumable packs in `spatter_credit_packs` (no prices; `sdi_spatter_credit_admin` lists packs for finance, and only the owner with a recent step-up approves packs or makes a signed adjustment, audited in `finance_audit`), an append-only `spatter_credit_ledger` (balance = sum, never negative; purchases/refunds unique per provider transaction) fed only by the service-only `sdi_spatter_credits_grant` (approved packs, idempotent, sandbox flagged `livemode=false`, never a finance row) and `sdi_spatter_credits_refund` (claws back up to the balance, records the shortfall). Reservations spend caps first, then the plan allowance, then one credit (Pro never spends credits; Free with credits pays as it goes); a release refunds the credit; usage reports add `credits` and `available`.
