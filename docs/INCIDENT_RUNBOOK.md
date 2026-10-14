# Incident runbook

For defects or security events in the delivered app, the CI pipeline, the
review site or the development host. Preserve evidence first; no deletion is
part of any step here.

## Severity

| Level | Examples | First action |
| --- | --- | --- |
| S1 — data loss or exposure | a user's only original project destroyed; credential, token or private media exposed; unapproved public upload | stop the affecting process, preserve the artifact, notify the owner immediately |
| S2 — release-blocking defect | exact-head CI red on `native-ios-build`; visible no-op control; disk-full save failure reproducible | record run id / capture, open or update the issue, no merge |
| S3 — degraded evidence | review site hash mismatch; artifact expired before retention; stale control map | re-run verification, record what is missing, do not backfill |

## 1. Preserve

- Keep the failing XCTest result bundle, PNG attachments and logs unmodified. Record the exact source commit, run id, attempt and shard. The interrupted-run and disk-full evidence in #295 is the model: failed outcomes stay recorded next to later passes.
- For a local Mac incident, capture `python3 scripts/native-smoke/disk_preflight.py ~` output (read-only) and the coordinator lease state before anything else.
- Never reset simulator data, application data or user projects to make a test pass (#293).

## 2. Contain

- **Credential or token exposure**: revoke/rotate server-side (owner action); search the repository and CI logs for the value; confirm no `Info.plist` build setting was committed with a real value (`SUPABASE_*`, `SPATTER_BACKEND_URL`, `SDI_*` must remain `$(...)` substitutions). Do not paste the secret into an issue. For a slot-held credential: `sdi_credential_revoke(slot, reason)` destroys the stored copy immediately (workers then load `configured: false` and make no provider calls), revoke at the provider, create a new key, `sdi_credential_store` it, and compare the fingerprint in `sdi_credential_status` (docs/SECURITY_CREDENTIALS.md §2). Run `python3 scripts/backend/scan_release_secrets.py` on the release commit and record its `SOURCE_COMMIT` line. A value that reached a pushed commit stays exposed after deletion; rotation is the fix.
- **Compromised member or administrator account**: suspend through the admin users surface (sessions end, `account_controls.state` blocks every RPC); for an administrator also disable the role in `admin_roles` (owner, step-up MFA) and review `admin_access_audit` / `admin_permission_audit` for the window. Audit rows are append-only; do not try to edit them.
- **Retired messaging resurfacing** (a legacy table or function reachable by clients): `sdi_legacy_communication_exposure()` lists it; run `select sdi_private.retire_legacy_communications();` in the project SQL editor (owner) to close it without deleting rows.
- **Quota exhaustion or abuse burst**: refusals carry the documented messages ("Daily upload limit reached…", "Too many requests…"); raise or lower `sdi_private.resource_quotas` only with an owner reason, never to hide a burst. Agent spend is stopped by the emergency stop below.
- **Unapproved publication**: cancel the job in the admin command center, record the render digest, and follow the publishing contract's takedown handling (`docs/PRODUCT_SCOPE_2026_09_19.md`). Do not promise third-party copies are gone.
- **Bad release build**: follow `docs/ROLLBACK.md` (revert PR with CI, previous simulator archive, TestFlight owner decision).
- **Review site serving wrong bytes**: republish the retained rollback version and re-run the authenticated HTTPS checks (#126 pattern).
- **Runaway or wrong automation**: engage the emergency stop (`sdi_agent_admin('emergency_stop', payload=>'{"enabled":true}', reason=>…)` from the native Admin or `website/admin.html`); running agent runs are marked stopped, new runs and heartbeats are refused, drafts are kept. Clear it only with a reason after the cause is known.
- **Billing event failures**: `sdi_finance_report('reconciliation')` lists `event_error` and `event_unprocessed` rows; replay the provider's events (Stripe event list since the last processed id; App Store transaction history) through the same handlers; duplicates are answered `duplicate` and never double-apply. Never edit `subscriptions` by hand; never issue a refund as a test.
- **Marketing post that should not have gone out**: cancel the draft (idempotent); if `marketing_finish` recorded "Posted before cancellation was observed", remove it at the provider by hand and record the provider's confirmation in the draft's audit reason. Withdraw the creator's marketing consent if the creator asked; approved drafts for their renders are invalidated automatically.
- **Suspected member-data exposure in logs**: provider payloads are redacted before storage; worker errors carry class names only; `sdi_email_recipients` output and push tokens exist only in worker memory. Treat any log that contains an address or token as an incident and rotate the worker's service key.

## 3. Diagnose without weakening gates

- A failing assertion is not fixed by changing the assertion. Use the original recording (for example the #292 rename-helper diagnosis from the video at 36.8s) to narrow the defect; propose a change only when the cause is identified.
- Use `docs/control-evidence-map.csv` to find which test(s) reference the control involved and whether the operation reaches the document command path.
- For storage failures, check `DeviceStorageManager` preflight messages before suspecting the UI; the app refuses to lower disk floors.

## 3a. Restore and rollback of backend records

- Rehearse first on a throwaway cluster: `scripts/backend/verify_backup.sh` must print `BACKUP RESTORE REHEARSAL PASSED`; it checks row counts, RLS, grants, the audit append-only guard, closed legacy messaging objects, credential slots as references only and a credential-free dump.
- Live restore (owner): restore the provider's managed backup into a separate, isolated project; run the same checks there (`sdi_audit_integrity_report()` → `unguarded = 0`; `sdi_legacy_communication_exposure()` → empty lists); only then repoint workers. Credential values are not in the application dump: re-store each slot from the owner's provider consoles rather than copying secrets between projects.
- Never restore over the live project to "undo" a member's deletion or a moderation decision; record the decision instead.

## 4. Communicate

- Update the GitHub issue with passed / failed / not run / owner-gated sections and the exact commit. Keep private infrastructure details and credentials out of the issue.
- Support wording for users comes from `docs/SUPPORT_RUNBOOK.md`; say what is known, not what is hoped.

## 5. Close

An incident closes when the fix is verified at the exact head by the normal gates, the original evidence is still retained, and the limitation list or runbooks were updated if behaviour changed. Reopening is normal when new evidence appears; closing to reduce a count is not.
