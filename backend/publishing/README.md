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
