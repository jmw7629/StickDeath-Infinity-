# First-party diagnostics (#291, QA05)

Status 2026-10-14: **implemented in source, verification partly deferred.** Opt-in, first-party,
no third-party SDK. This document is the contract; `docs/DIAGNOSTICS_DESIGN.md` keeps the
original design notes.

## What is collected

One **report** = one UTC day of allowlisted counters for one platform, app version, build and
OS major version. Nothing else is queued, stored or sent.

```json
{"app_version":"1.4.2","build":"317","counters":{"app_launch":9,"crash":2},
 "day":"2025-10-08","os_major":17,"platform":"ios","v":1}
```

| Field | Rule |
| --- | --- |
| `v` | `1` |
| `platform` | `ios` or `android` |
| `app_version` | `1`, `1.2` or `1.2.3` (1–4 digit parts) or `unknown` |
| `build` | 1–9 digits or `unknown` |
| `os_major` | 0–99 (iOS major version; Android API level) |
| `day` | `YYYY-MM-DD`, UTC, a completed day within the last 30 |
| `counters` | 1–8 keys from the allowlist, each an integer 1–10 000 |

Counter allowlist: `app_launch`, `crash`, `hang`, `cpu_exception`, `disk_write_exception`,
`memory_limit_exit`, `watchdog_exit`, `uncaught_exception`. Adding one means changing
`DiagnosticsCounter` (Swift and Kotlin) and `sdi_private.diagnostic_counters()` together.

Never collected: stack frames or call-stack trees, exception messages, thread names, file
paths, project names or contents, drawings, prompts, account or device identifiers, IP-derived
data, precise timestamps, screen contents. Malformed bundle strings collapse to `unknown`, so no
free text can reach the payload.

## Sources

| Platform | Source | Code |
| --- | --- | --- |
| iOS | MetricKit (`MXMetricManager`): `MXDiagnosticPayload` crash/hang/CPU/disk-write counts and `MXMetricPayload.applicationExitMetrics` memory-limit and watchdog exits. Only `count`s are read; the payload's `timeStampEnd` is rounded to its UTC day. The subscriber is registered only while opted in. No in-process crash handler. | `StickDeathInfinity/Services/Diagnostics/DiagnosticsMetricKit.swift` |
| iOS | `app_launch` counted once per process start (`DiagnosticsRuntime.start()`). | `DiagnosticsSettingsView.swift` (`DiagnosticsRuntime`) |
| Android | Uncaught-exception breadcrumb: chained default handler adds one to `uncaught_exception`, then defers to the existing `LocalCrashReporter` handler. The throwable is never stored by this path. | `android/.../diagnostics/DiagnosticsRuntime.kt` |
| Android | `app_launch` from `StudioApplication.onCreate` (wiring below). | same |
| Web | Not collected. The website has zero third-party requests and no telemetry endpoint. A future web source would send the same contract with `platform` extended server-side first; until then there is nothing to document beyond this sentence. | — |

The Android redacted local crash reports (`CrashReporting.kt`, five files / 30 days) are a
separate, local-only feature and are never uploaded.

## On the device

- **Off by default.** iOS: `UserDefaults` key `sdi.diagnostics.optIn.v1`; Android:
  `SharedPreferences("sdi_diagnostics")` key `optIn.v1`. Missing or unreadable means off.
- **Bounded queue:** at most 14 day-buckets, nothing older than 30 days, future-dated buckets
  (clock skew) dropped. iOS `Application Support/Diagnostics/queue.json` (excluded from backup);
  Android `files/diagnostics/queue.txt`. A damaged file reads as empty.
- **View what will be sent:** the settings screen shows the exact JSON the uploader sends.
- **Delete:** "Delete queued" removes the file immediately. **Turning diagnostics off deletes the
  queue**, and a queue found at launch while off is deleted.
- **Upload:** completed days only (today is still accumulating), oldest first, one RPC per report;
  only buckets the server acknowledges (`accepted` or `duplicate`) are removed. Network errors,
  rate limits and refusals keep the rest queued and are shown verbatim.
- **Truthful disabled states:** off → "Diagnostics are off. Nothing is collected or sent."; no
  backend configuration (iOS without validated Supabase config; Android, which has no INTERNET
  permission) → "Diagnostics upload is not available in this build…". No upload is attempted.

## Server (`backend/sql/diagnostics.sql`)

- `public.sdi_diagnostics_submit(report jsonb, consent boolean)` (authenticated): requires an
  active session and `consent = true`; refuses any extra key, wrong type, unknown counter,
  out-of-range count, today/future/older-than-30-day day. Stores into
  `sdi_private.diagnostic_reports(platform, app_version, build, os_major, day, counters,
  received_day)` — **no account column**.
- Duplicate suppression and rate limit (20 buckets per account per rolling day) use
  `sdi_private.diagnostic_receipts(user_id, sha256(bucket), received_at)`; receipts cascade on
  account deletion and are swept after 35 days. Account deletion therefore removes every link
  between an account and diagnostics; the day rows are coarse aggregates with no account link.
- Both tables have RLS and no client grants; clients reach them only through the RPCs.
- `public.sdi_diagnostics_admin('summary', days)` (overview capability, MFA aal2, rate-limited,
  denials audited): daily totals per platform/build/counter, report count, crash spikes and
  `agent_runs_failed_24h`. A **spike** is a (platform, build) whose `crash + uncaught_exception`
  on the latest completed day is ≥ 5 and more than five times its mean over the previous seven
  days. Real counts only; no estimated crash-free rate.
- `public.sdi_diagnostics_retention()` (service role): deletes day rows older than 90 days and
  receipts older than 35 days. Schedule it with the other sweeps (`backend/ops/sweeps.py`).

## Retention summary

| Data | Where | Kept |
| --- | --- | --- |
| Opt-in flag | device | until changed or app deleted |
| Queue | device | ≤ 14 buckets, ≤ 30 days; deleted on opt-out or request |
| Day rows | server | 90 days; no account link |
| Receipts | server | 35 days; deleted with the account |

## Verification

| Check | Result |
| --- | --- |
| `scripts/backend/run_sql_tests.sh` incl. `backend/sql/tests/130_diagnostics.sql` (with the README apply-order and `080_rls_review.sql` service-list hunks applied) | passed locally on PostgreSQL 16, 14/14 files |
| Kotlin `DiagnosticsTest` (5 tests) compiled with kotlinc 2.0.21 against `Diagnostics.kt` + `SdiJson.kt` and run with JUnit 4.13.2 on the JVM | passed locally |
| Android Gradle build / `DiagnosticsRuntime.kt` (Compose, SharedPreferences) | **deferred** (no Android SDK on the Linux host) |
| Swift `Tests/Diagnostics/main.swift` | **deferred to macOS CI** (no swiftc on the Linux host) |
| MetricKit delivery on a device, opt-out stops delivery, upload against a deployed backend | **deferred**; needs a device and the owner's backend deployment |

## Not done here / owner decisions

- **Symbolication and release tagging of stack traces** are deliberately out of this payload:
  only counts leave the device. Symbolicated crash triage remains Xcode Organizer / App Store
  Connect (iOS) and Play Console vitals (Android), which require the owner's developer accounts
  and archived dSYMs / mapping files (`docs/RELEASE_CHECKLIST.md`). Sending stacks to the
  first-party backend would need an owner decision on scope and retention first.
- **Command-center surfacing:** the summary RPC exists; adding a "Diagnostics" card to the admin
  dashboard (#277) is separate UI work.
- **Deployment:** like every `backend/sql` candidate this is unapplied; the owner applies it with
  the install bundle.
