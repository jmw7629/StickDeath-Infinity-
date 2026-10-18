# Server publishing adapter

`youtube_upload.py` is a callable, standard-library adapter. No CLI, scheduled job
or live upload is enabled. The worker supplies current owner OAuth, expected channel
ID and an approval-lease renewal callback. Checkpoints (including sensitive upload
session URLs) require a private server directory and must never enter logs or Git.

It verifies the owner channel, stages bounded real bytes, verifies SHA256 against
approval, persists the resumable session, probes provider progress before resuming,
and sends bounded binary chunks. It refuses redirects/untrusted provider hosts,
ambiguous initiation/reconciliation, changed metadata and expired authorization.
The original file is never deleted. Uploads are private; completion does not mean
processing or public publication succeeded. See Google's protocol:
https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol

Remaining: connect the secure secret store and owner consent route, quota-aware
retry scheduling, cancellation/removal compensation, ingestion and bounded
retention. Keep private-upload completion separate from `published` in the job
model; never complete a publishing job using a private-upload-only result.
Owner directed deferred compilation/tests/integration; no provider calls were run.

`finish_processing_and_publish` is a separate bounded step: it checks the saved
upload's identity/channel/digest, queries owner-only processing state, waits without
busy-polling if incomplete, requires fresh release authorization, persists release
intent, changes visibility, and reads back real public/processed state. Unknown or
externally changed visibility requires reconciliation. Only its `published` receipt
may complete the SQL publishing job. Nothing invokes this method automatically.
References: https://developers.google.com/youtube/v3/docs/videos/list and
https://developers.google.com/youtube/v3/docs/videos/update .

`worker.PublishingWorker.run_once()` now connects server-role queue RPCs to the
adapter. It claims only YouTube jobs, resolves registered artifacts within owned
storage, records private upload completion separately, and defers processing for
60seconds rather than holding a busy loop. Public completion requires confirmed
provider processing/visibility. Uncertain outcomes enter reconciliation instead of
automatic duplicate uploads. Artifact/OAuth/backend locations are injected by the
deployer; no credentials or host-specific paths are embedded. No scheduler is
installed or worker invocation performed. Provider-removal worker, operational
deployment and final integration verification remain outstanding.

`owner_oauth.OwnerTokenProvider` implements the injected worker token callback.
Deployment supplies a server-only encrypted secret-store reader returning
`OwnerGrant`, a revision-conditional connection-state writer, and the expected
channel ID. It reads connection state on every call, caches access tokens only in
memory, refreshes with bounded HTTPS requests to Google's fixed token endpoint,
refuses redirects, and treats invalid grants as requiring owner reconnection.
Transient refresh failures use a cooldown rather than a request loop. A change
or disconnect during refresh invalidates that result. The uploader invalidates
cached tokens after HTTP401 without automatically replaying a mutation.

The grant reader must enforce server-side owner authorization and disable revoked
connections. Increment revision whenever credentials or consent change. Never
populate this callback from a mobile payload, job metadata, public table or Git.
The state writer must persist `reconnect_required` only if its revision still
matches; its failure does not enable the blocked in-memory connection. Restarted
workers rely on the persistent connection status. Deployment must use one worker
owner and keep secret-bearing objects out of exception/HTTP debug logs.

No owner authorization browser route, credential provisioning, encrypted storage
adapter or token revocation endpoint is claimed by this component. These remain
integration work. No live token request or verification was run. Protocol source:
https://developers.google.com/identity/protocols/oauth2/web-server#offline

`publishing-withdrawal.sql` adds an unapplied service-only withdrawal lease and
bounded backoff (five claims before administrator reconciliation). Install after
the publishing jobs candidate. Render review changes invalidate outstanding jobs
and enqueue known uploaded videos for withdrawal. Cancelling a processing upload
also preserves the need for provider cleanup. Unknown upload outcomes remain in
reconciliation rather than being labelled deleted.

`run_once` prioritizes a due withdrawal before a new upload. The adapter requires
matching private upload provenance and owner channel identity, changes visibility
to private, removes scheduled publication, then reads visibility back. It uses a
separate removal lease so withdrawal does not depend on still having release
permission. A grace interval follows any prior publishing lease. Receipts describe
withdrawal from public view, not permanent deletion. Neither user originals nor
the channel's private copy are deleted by this operation.

Missing checkpoints, unknown provider IDs, exhausted attempts and uncertain
readback require reconciliation. The separate moderation removal queue still
needs destination mapping; this worker only processes registered publishing jobs.
Consent/account/admin change integration, other destinations, administrative
reconciliation UI and permanent-retention deletion remain outstanding. No SQL
was applied and no provider calls or tests ran. YouTube status update semantics:
https://developers.google.com/youtube/v3/docs/videos/update

## Feed publisher, destination adapters and marketing worker (2026-10-13)

`feed_publisher.FeedPublisher.run_once()` is the host adapter for `feed-publication.sql`:
removals first (`sdi_feed_removal_claim/finish`, success only when the hosting adapter
confirms the copy is gone), then one `sdi_feed_publish_claim`; it resolves the registered
artifact inside owned storage, verifies size and the SHA-256 of the actual bytes against
the approved digest, measures the duration with the injected probe, copies through the
injected `HostingAdapter` and calls `sdi_feed_publish_finish`. A lease lost after the copy
removes the orphaned hosted file. `JobAPI` now carries its RPC prefix and allowlist as
class attributes so each worker has its own narrow surface.

`destinations.py` holds the social adapters (Discord webhook, Facebook Page, X) and
`UnavailableDestination` for YouTube community posts, Instagram, TikTok and email, each
answering `unavailable`, `dry_run` (exact request with credentials redacted, nothing
sent), `published` (provider id and link) or `failed`. `MarketingWorker` binds them to
`sdi_marketing_claim/finish`; a dry run is recorded as a failure with a plain reason so a
draft is never marked published without a provider receipt. Platform terms must be
confirmed by the owner before any adapter is enabled; the module notes what each needs.

Tests: `backend/tests/test_workers.py` (fake RPC clients, fake hosting, fake transports).
No upload, post or deployment has run.

`marketing_scheduler.py` (#283) is the cadence job: it calls `sdi_marketing_cadence_due`
(queues only drafts the owner already approved for the exact render, re-checking
consent), and in live mode claims leased drafts: social ones go through
`MarketingWorker.process`, an `email` draft becomes a blast queued with
`EmailQueue.enqueue_blast` (seven-day per-address cadence, recipient cap) to
`sdi_email_recipients('marketing')` (opted in, active, unsuppressed) under the draft id
as campaign key, finished as `email-queue:<campaign count>`
(`marketing_finish` accepts that only for email drafts and never a zero count). Dry run
is the default; live needs `--live` plus `SDI_MARKETING_LIVE=1`. Tests:
`backend/tests/test_marketing_scheduler.py`. No post or email has been sent.

## Post-publication release, creator status and failure hygiene (2026-10-14)

`cleanup.py` (`python3 -m backend.publishing.cleanup --execute [--limit N]`) removes
the intake host's temporary render once publication is verified (#190). The
database decides (`sdi_publication_release_candidates`, `sdi_release_published_upload`
in `upload-retention.sql`): every destination of the current approved render must hold
a `published` job with a provider receipt; nothing may be queued, leased, failed,
reconciling, cancelling or awaiting removal; the last lease must be past the 60-second
grace interval; renders with social/marketing reuse and feed copies with a pending
appeal are kept. Release fences every artifact version (so `release_allowed` refuses
new leases) before the host unlinks, is idempotent and is repeated for two days so a
host that stops between the two steps finishes later. Any refusal or error keeps the
file; expiry (`backend/ingestion/retention.py`) remains the fallback. The creator's
original and editable project stay on the device. Nothing schedules the command.

`sdi_publish_status(page)` (#245) is the creator's single read: review state
(`awaiting_review`, `changes_requested`, `approved`, `rejected`), whether owner approval
is required, each destination job's stage (`queued`, `transferring`,
`provider_processing`, `releasing`, `published` with its confirmed link, `failed` with
`can_retry`, `cancelling`, `removal_in_progress`, `removed`, `cancelled`,
`needs_reconciliation`) and the staging copy (`retained` with expiry, `expired`,
`deleted`). A trigger in `publishing-admin.sql` strips links, bearer values and
credential parameters from every stored failure reason.

Tests: `backend/tests/test_workers.py::PostPublicationCleanupTests`,
`backend/sql/tests/130_publication_release_status.sql`. No provider call, upload or
deletion on a real host has run. Native and admin screens still read
`sdi_publish_action('list')` / `sdi_publishing_admin('list')`; wiring the status RPC
into `ProfileView` is outstanding (see docs/PUBLISHING_WAVE4.md).
