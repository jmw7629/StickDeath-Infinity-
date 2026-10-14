# Provider credentials and account-lifecycle security

Scope: #238 (credentials), #256 (restore drill, audit integrity, release checks),
#260 (retired communications), #262 (export, deletion, consent retention),
#263 (quotas). Everything below is source and local-cluster evidence. Nothing has
been applied to a live project; each owner step is marked **owner**.

## 1. Where credentials live

| Credential | Store | Who reads it | Never in |
| --- | --- | --- | --- |
| Owner YouTube OAuth client + refresh token | `credential_slots.youtube_owner_grant` → Supabase Vault | publishing worker via `sdi_credential_load` | app bundles, issues, job rows, logs |
| Stripe restricted key, webhook signing secret | `stripe_api`, `stripe_webhook` slots → Vault | billing worker / webhook function | app bundles, website, logs |
| App Store Server API key | `appstore_server` slot → Vault | billing worker | app bundles |
| APNs key, FCM credential | `push_apns`, `push_fcm` slots → Vault | notification worker | app bundles, Android build |
| Mail provider key | `mail_provider` slot → Vault | mail worker | everywhere else |
| App-owned AI provider key | `ai_provider` slot → Vault | Spatter service | app bundles; never sent to a client |
| Service-role key for workers | host secret store (outside the database) | worker processes only | source, CI logs, clients |
| A member's own AI key (BYO, owner decision 2026-10-07) | iOS Keychain / Android Keystore on the member's device | the member's device only | server, logs, analytics, crash reports, support attachments |

`backend/sql/security-credentials.sql` keeps only the slot's state
(`unconfigured`, `active`, `reconnect_required`, `revoked`), a revision, a
12-hex SHA-256 fingerprint for rotation checks, the Vault reference and an
append-only `credential_audit`. Store, rotate, load, compare-and-set state and
revoke are executable by `service_role` only; administrators read presence,
fingerprint and "rotation due" through `sdi_credential_status` (overview
capability, MFA session). Clients have no grant on any of it
(`tests/130_security_lifecycle.sql`, `tests/080_rls_review.sql`).

Missing configuration is a first-class state: without Vault, `credential_store`
returns "Server secret store is not enabled. Nothing was stored." and
`credential_load` returns `configured: false`, so a worker makes zero provider
calls. A load after revocation, after `reconnect_required`, or when the Vault row
vanished returns no value (`store_missing` is audited).

## 2. Rotation and revocation

1. **owner** Create the new key at the provider (do not revoke the old one yet).
2. Service operator calls `sdi_credential_store(slot, value, reason)` from the host
   with the service key. The new Vault secret is created first, then the previous
   one is deleted; the revision increases and the fingerprint changes.
3. Workers pick up the new revision on their next `sdi_credential_load`; the
   owner OAuth provider (`backend/publishing/owner_oauth.py`) already re-reads the
   grant on every call and clears cached access tokens on a revision change.
4. **owner** Revoke the old key at the provider after one worker cycle succeeds.
5. On `invalid_grant` or a 401, the worker records `reconnect_required` with
   `sdi_credential_record_state(slot, revision, 'reconnect_required')`; a stale
   revision cannot overwrite a newer link.
6. Emergency: `sdi_credential_revoke(slot, reason)` destroys the stored copy at
   once; then revoke at the provider.

Default rotation reminder is 90 days per slot (`rotate_after_days`); it is a
reminder in the status view, not an automatic rotation.

## 3. Release checks on the exact source

- `python3 scripts/backend/scan_release_secrets.py` scans every tracked file at
  `HEAD` for credential formats (Stripe, webhook, PEM private keys, AWS, GitHub,
  Google, Slack, OpenAI-style, Supabase secret keys, JWTs), requires Info.plist
  provider settings to stay `$(...)` build substitutions, refuses server-only
  setting names in the iOS bundle and Android build, and flags tracked `.env`
  files. Output carries `SOURCE_COMMIT=` and masks every match. It is a pattern
  scan, not a proof of absence. Tests: `python3 -I scripts/backend/test_scan_release_secrets.py`.
- `python3 scripts/verify_retired_communications.py` covers the client and
  backend sources for retired messaging and calling (§5).
- `scripts/backend/run_sql_tests.sh` includes `080_rls_review.sql` (RLS, grants,
  secret-shaped columns, service-only surface) and `130_security_lifecycle.sql`.

## 4. Backup restore drill and audit integrity

`scripts/backend/verify_backup.sh` applies every candidate to a throwaway
cluster, loads minimum records, dumps, restores into a second database and checks
row counts, RLS, grants, the entitlement view, the audit append-only guard on
every `*_audit` table, that no legacy messaging object is client-reachable, that
credential slots come back as references only, and that the dump holds no
credential-shaped text. Vault contents are deliberately not part of the
application dump: after a restore, slots that point at a missing Vault row load
as `store_missing`, so the owner re-stores those credentials (§2) rather than a
worker running with a stale value.

`backend/sql/security-audit-integrity.sql` makes audit tables append-only for
every application path (UPDATE only when an `ON DELETE SET NULL` clears a member
reference; DELETE/TRUNCATE only inside the account purge). It does not stop the
database owner, who can drop triggers; `sdi_audit_integrity_report` lets the
drill and the owner confirm the guard is in place.

**owner** Live drill: restore the provider's managed backup into an isolated
project and run the same checks there; record the date, backup id and outputs
in #256. Not done from this repository.

## 5. Retired messaging and calling (#260)

- No SQL candidate creates a chat, message, call, conversation, LiveKit or watch
  party object (checked by name in `verify_retired_communications.py`).
- `security-retire-communications.sql` closes legacy objects a live project
  may still hold: client privileges revoked, removed from the realtime
  publication, rows kept for the owner's retention decision. Release gate on the
  live project: `select sdi_legacy_communication_exposure()` must return empty
  lists (**owner**, after install).
- Client: retired Swift sources stay deleted, deep links are auth-only, the only
  URL scheme is `stickdeath`, no VoIP/audio background modes, no LiveKit/WebRTC
  or chat dependencies on iOS or Android, no microphone/contacts permission, and
  the Spatter prompt may not advertise calls or messenger features.
- Watch Together (approved no-chat synchronized viewing) and Calendar (read-only
  schedules, still in `Views/Messages/CalendarView.swift`) are kept.

## 6. Account export, deletion and consent retention (#262)

- Export: `sdi_account_lifecycle('export')`, three per day, own rows only; now
  also consents, notification preferences and registered push devices (platform
  and dates, never the token). Settings shows "Export my account data" and hands
  the exact JSON to the share sheet; the file is removed when the row leaves the
  screen. Projects and originals are on-device and not part of it.
- Deletion: seven-day cooling-off, cancellable. Phase one also withdraws every
  consent record, revokes push devices and turns notifications off; membership in
  other members' rooms is revoked. The purge waits for publication jobs, hosted
  copy removal and intake retirement; it never partially purges.
- Consent proof: at purge, each consent record is copied to
  `consent_retention` with only a SHA-256 digest of the former account id,
  policy, version, source and dates. The period is
  `retention_settings.consent_proof_days` (candidate default 1095 days, **owner**
  legal decision) and `sdi_consent_retention_sweep` deletes expired proof.
- Provider retention: subscriptions are not cancelled by deletion (the member
  cancels with the App Store or billing portal); the billing row is kept without
  the account link for finance records; copies on YouTube or social platforms are
  removed through the publishing withdrawal path, and third-party caches are
  outside our control.

## 7. Quotas and cost ceilings (#263)

Per-minute budgets already bound feed, challenges, War Room, rooms, room
commands, admin calls and support requests (`tests/100_burst_limits.sql`).
`rate-limits.sql` adds rolling-24-hour quotas enforced by triggers on every
insert path: 20 intake registrations and 8 GiB per creator, 30 publication jobs
per creator (a duplicate request uses none) and 50 room invitations per owner.
Agents (including Spatter's daily draft) stay bounded by `daily_run_cap` and
`monthly_cost_cap_minor`, whose default 0 refuses runs until the owner sets a
cap. Members read their own usage with `sdi_quota_status`. All values are
candidate defaults for the existing single project, not measured capacity.
