# Operating runbook

Day-to-day operation of the StickDeath Infinity delivery pipeline under the
owner's current directions (`AGENTS.md`, 2026-10-09 update). Everything here is
read-only or reversible; deletion of any kind is a separate owner-reviewed step.

## Before expensive native work (owner's Mac)

1. Confirm the coordinator lease and that no compiler is running (#295 checklist).
2. Run the read-only disk preflight on the internal volume:
   `python3 scripts/native-smoke/disk_preflight.py ~` — exit 0 means at least 1.85 GiB free, exit 2 means between the 1.4 GiB floor and the start threshold (finish or checkpoint current work only), exit 3 means at or below the floor (stop and record). The script prints JSON, never deletes and refuses lowered thresholds.
3. If headroom is missing, do **not** clean automatically. Record the measurement in #295 and let the owner decide which SDI-generated artifacts to retire, following the archive-verify-then-retire pattern recorded there (full SHA-256, byte counts, CRC, no open handles, retained originals).

## Daily queue maintenance (#128)

1. Export issues offline: `gh issue list --state all --limit 1000 --json number,title,state,labels,body,url > /path/outside/repo/issues.json` (or the REST `issues` endpoint pages concatenated).
2. Run `python3 scripts/backlog/audit_queue.py issues.json` (or `--json`). It reports the count of open `sdi:next` items against the 50–100 target, dependency cycles (`depends on`, `after`, `Dependencies:` and `Part of` patterns), duplicate normalized titles, open items whose blocking dependencies are all closed, and references to issues missing from the export. Exit 1 marks a cycle.
3. Post the facts in #128/#116. Reuse existing issues; never create issues to inflate the count or close issues to shrink it.

## Control inventory (#125)

- After any Swift change that adds, renames or removes an `accessibilityIdentifier`, or any UI-test change: `python3 scripts/verify_control_index.py --write` regenerates `docs/control-evidence-map.csv` (curated `issue` cells survive), then `python3 scripts/verify_control_index.py` must print `CONTROL_EVIDENCE_MAP=PASS`.
- Review the summary counters: `uiTestDeferred`, `issueUnmapped`, `operationUnresolved`, and `history` yes/no/n-a. A control with `history=no` that is supposed to edit the document is a defect candidate.
- CI: the harness step in `.github/workflows/spatter-client-verify.yml` (`source-security` job, "Verify simulator fixture orchestration guards") already runs `Tests/NativeSmokeHarness/test_control_index.py`, which fails on a stale map. The coordinator should add an explicit step `python3 scripts/verify_control_index.py` beside it so the failure message names the stale rows.

## CI runs

- Required job is `native-ios-build`; it is green only when both native shards and every production gate succeeded for the same head and attempt (`scripts/native-smoke/shard_receipt.py`).
- Download artifacts within 3 days (`docs/RELEASE_CHECKLIST.md` section 3). Verify the simulator app archive with `docs/NATIVE_SIMULATOR_REVIEW.md` before any local install.
- Never re-run a single failed shard and report the suite as passed; the aggregate requires one attempt's complete receipts.

## Review site (#126)

Publish only from a labelled source commit; keep the previous version as the rollback and record the authenticated HTTPS checks (metadata, provenance, PNG hashes, root HTML). The site displays native captures and does not execute SwiftUI; say so in every checkpoint.

## Backend candidates, sweeps and workers (2026-10-13)

- Before touching `backend/sql`: `scripts/backend/run_sql_tests.sh` must print `9 passed, 0 failed`; a new candidate goes at the end of the README apply-order block and gets a `tests/NNN_*.sql` file; a new service-role function must be added to the list in `tests/080_rls_review.sql` consciously.
- Backup rehearsal: `scripts/backend/verify_backup.sh` (local throwaway cluster). For the live project the owner runs the host's restore drill into an isolated database and applies the same three checks: identical row counts, RLS on every table, `anon` executes nothing.
- Sweeps: `python3 -m backend.ops.sweeps --all` (or `--only name,…`) with `SDI_BACKEND_URL` and `SDI_SERVICE_KEY` from the host secret store; schedule hourly from the host timer, never from a client. It records one `sdi_worker_heartbeat('service-sweeps')`; `sdi_admin_health` flags it stale after 10 minutes. It also reports which of its named settings are present (`sdi_worker_configuration`, booleans only, never values) so `sdi_admin_configuration` and the command centre's "Provider configuration (presence only)" panel can show what is still unconfigured.
- Sweeps include `room_asset_sweep` (#233): expired room asset copies, closed rooms and senders whose membership ended are discarded in bounded batches and the run log carries the verified counts.
- Operations reporting (#257): outcomes reach the command centre's operations panel (`sdi_admin_operations`) only through the service-only `sdi_ops_report` RPC, which accepts a known kind (`backup`, `restore_drill`, `release`, `rollback`, `retention_sweep`), `succeeded`/`failed`, a version-or-commit label and named whole-number metrics; no host name, path, bucket or credential can be stored.
  - Each sweeps run records one `retention_sweep` report with `sweeps_run` and `sweeps_failed` (failed when any sweep failed). A refused or failed report is printed in the run's JSON under `_ops_report` and never changes the exit status.
  - `scripts/backend/verify_backup.sh --report` records the rehearsal as `restore_drill`, labelled with the source commit and carrying `local_rehearsal=1`, `tables`, `nonempty_tables` and `dump_bytes`. It is a rehearsal of the procedure on a throwaway cluster, not a drill of the live project; the metric keeps the two apart.
  - Host jobs report their own outcomes with `python3 -m backend.ops.report <kind> <succeeded|failed> [--label 1.4.0|<commit>] [--metric name=N …]`, e.g. after the managed backup (`backup`, `--metric bytes=…`), after the owner's live restore drill (`restore_drill`), after a release or rollback.
  - All three read `SDI_BACKEND_URL` and `SDI_SERVICE_KEY` from the environment (host secret store); nothing is in source. When either is missing the report is skipped with "Operations reporting is not configured" (`backend.ops.report` exits 3) and nothing is sent. Until real reports arrive the panel shows backups and drills as stale, which is the truthful state.
- `PublishingWorker` concurrency (#263): each executor takes a slot lock in its private checkpoint directory; the default is one concurrent upload per host, `max_concurrent` may raise it to at most 4, and an executor that finds every slot held returns `busy` without claiming a job.
- Workers run one job per invocation from the host timer: `FeedPublisher` (hosting adapter injected), `PublishingWorker` (YouTube), `MarketingWorker` (dry-run until the owner enables a destination), `PushBatchWorker` (sink transport until APNs/FCM credentials exist), `EmailWorker` (loopback SMTP sink until the sender domain is verified; `allow_remote` is the owner's switch).
- Staging volume: the intake root must be a private directory on an encrypted volume; the code enforces ownership and 0600/0700 modes, the host provides the encryption. Record the volume and its key custody in the private access inventory (`docs/LAUNCH_REHEARSAL.md` §D).
- Design-reference preservation (#269): the owner keeps the recovered reference on the Mac SSD with a private manifest (relative path, SHA-256, byte count, capture date, missing remote dependency notes). Historical screens, pricing and metrics in it are reference only; nothing from it is copied into this public repository.

## Documentation upkeep

- `docs/KNOWN_LIMITATIONS.md` cites file:line at a named commit; regenerate the grep and update citations with each release candidate.
- `docs/THIRD_PARTY_NOTICES.md` changes whenever `Resources/Licenses`, `Resources/StudioSounds/CREDITS.txt` or an image catalogue license entry changes.
- `docs/VISUAL_REFERENCE_MAP.md` rows leave `deferred` only with a same-viewport comparison recorded by the owner.

## What this runbook never does

No paid external AI calls, no capacity purchases, no live charges, no public uploads, no automated deletion, no fabricated acceptance, no issue-count padding.
