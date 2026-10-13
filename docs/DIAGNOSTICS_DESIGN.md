# Crash reporting and product diagnostics design (#291)

Status 2026-10-13: **design only**. Nothing in this document is implemented; no diagnostics are
collected by the iOS, Android or web source today, and no vendor SDK is added by this design
(owner policy: no new paid services, no third-party analytics, nothing that can capture drawings,
prompts, credentials or project contents).

## Principles

1. Opt-in per device, off by default, revocable in Settings; the choice is stored in
   `sdi_private.notification_preferences` (a `diagnostics` boolean to be added with the
   implementation) so it is included in the account export and deleted with the account.
2. Minimal payloads: crash signature, symbolicated frames of app code only, OS/app/build
   identifiers, device class (not identifier), and coarse counters. Never: screen contents,
   canvas or stroke data, prompt text, file names, email, user id in the payload (the server
   derives the account from the authenticated session and stores only a one-way salted hash
   for spike grouping).
3. Bounded retention: raw reports 90 days, aggregates 13 months, deletion on account deletion
   (`account-lifecycle.sql` phase two) and on opt-out (next sweep).
4. The admin command center shows real counts or an explicit "not configured" state; no
   estimated crash-free rate.

## Sources per platform

| Platform | Mechanism | Symbolication | Notes |
| --- | --- | --- | --- |
| iOS | `MetricKit` (`MXMetricManager`, `MXDiagnosticPayload`) delivered by the OS, batched daily; app forwards only when opted in | server-side with the dSYM archived per build (`docs/RELEASE_CHECKLIST.md`) | no in-process crash handler, so nothing interferes with the Studio's save path |
| Android | `ApplicationExitInfo` (tombstone reason + trace for app code) when opted in; Play Console vitals remain the owner's dashboard | mapping file archived per build | no Firebase; FCM is only considered for push in #290 |
| Web | `window.onerror` / `unhandledrejection` counts only (message, stack of site scripts, page); no replay, no cookies | n/a (unminified site) | counted in the private analytics allowlist (`docs/WEBSITE_INVENTORY.md`) |

## Server side

- Intake RPC (service role via a small edge function with the member's session): validates the
  payload shape, caps size (64 KB) and rate (10 per device per day), strips unknown keys, stores
  into `sdi_private.diagnostic_reports(id, platform, app_version, build, os_version, kind,
  signature_hash, frames jsonb, received_at, account_hash)`.
- Aggregation sweep (added to `backend/ops/sweeps.py`): daily counts per signature, build and
  platform into `diagnostic_daily`; raw rows older than 90 days deleted.
- Health: `sdi_admin_health` gains `crash_signatures_24h` and `agent_runs_failed_24h`; a spike is
  a signature whose 24-hour count exceeds 5× its 7-day daily mean, surfaced in the admin shell
  with the build it started in. Alerts go to the admin inbox (`announcements`, category
  transactional, audience administrators) and never to members.
- Agent failures already exist in `agent_runs.state='failed'`; the same spike rule applies.

## Product analytics (consent-aware, minimal)

- Event allowlist only: `app_open`, `project_created`, `export_completed(format)`,
  `publish_submitted`, `subscription_viewed`. Each event carries platform, app version and a
  day bucket; no durations below one minute, no sequences, no identifiers.
- Stored as daily counters (`analytics_daily(day, platform, event, count)`); no per-user rows,
  so there is nothing to export or delete beyond the opt-in flag.
- The command center shows counts with the date range and the number of opted-in devices;
  conversion or revenue figures are not derived here (finance reads provider records only).

## Verification plan (deferred)

- Unit tests for payload validation and stripping with fixtures that contain forbidden fields.
- A native test that a MetricKit payload is dropped when the opt-in is off.
- Rehearsal in `docs/LAUNCH_REHEARSAL.md`: trigger a sandbox crash on a test device, confirm the
  report arrives symbolicated, confirm opt-out stops delivery, confirm deletion removes rows.
