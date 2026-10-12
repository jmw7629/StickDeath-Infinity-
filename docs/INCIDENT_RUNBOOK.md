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

- **Credential or token exposure**: revoke/rotate server-side (owner action); search the repository and CI logs for the value; confirm no `Info.plist` build setting was committed with a real value (`SUPABASE_*`, `SPATTER_BACKEND_URL`, `SDI_*` must remain `$(...)` substitutions). Do not paste the secret into an issue.
- **Unapproved publication**: cancel the job in the admin command center, record the render digest, and follow the publishing contract's takedown handling (`docs/PRODUCT_SCOPE_2026_09_19.md`). Do not promise third-party copies are gone.
- **Bad release build**: follow `docs/ROLLBACK.md` (revert PR with CI, previous simulator archive, TestFlight owner decision).
- **Review site serving wrong bytes**: republish the retained rollback version and re-run the authenticated HTTPS checks (#126 pattern).

## 3. Diagnose without weakening gates

- A failing assertion is not fixed by changing the assertion. Use the original recording (for example the #292 rename-helper diagnosis from the video at 36.8s) to narrow the defect; propose a change only when the cause is identified.
- Use `docs/control-evidence-map.csv` to find which test(s) reference the control involved and whether the operation reaches the document command path.
- For storage failures, check `DeviceStorageManager` preflight messages before suspecting the UI; the app refuses to lower disk floors.

## 4. Communicate

- Update the GitHub issue with passed / failed / not run / owner-gated sections and the exact commit. Keep private infrastructure details and credentials out of the issue.
- Support wording for users comes from `docs/SUPPORT_RUNBOOK.md`; say what is known, not what is hoped.

## 5. Close

An incident closes when the fix is verified at the exact head by the normal gates, the original evidence is still retained, and the limitation list or runbooks were updated if behaviour changed. Reopening is normal when new evidence appears; closing to reduce a count is not.
