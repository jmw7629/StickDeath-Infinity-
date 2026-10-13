# Launch rehearsal and operating handoff checklist (#278)

Status 2026-10-13: this is the script for the rehearsal, with each step marked as **runnable
offline now** (done in this batch, evidence noted), **sandbox** (needs provider test mode or a test
device; not run) or **owner gate**. Nothing below is a completion claim; fixtures never count as
customer traffic, no live billing, no public uploads, no customer emails.

## A. Offline rehearsal (run in this batch on Linux)

| Step | Command | Result 2026-10-13 |
| --- | --- | --- |
| SQL candidates apply and all assertions hold | `scripts/backend/run_sql_tests.sh` | 37 candidates applied, 9 test files passed (`010`–`090`) |
| Backup → restore rehearsal | `scripts/backend/verify_backup.sh` | see `REPORT.md` / `docs/OPERATING_RUNBOOK.md` for the recorded run |
| Edge-function and worker logic | `python3 -m unittest discover -s backend/tests -t .` | 102 tests passed (billing handlers, intake, publishing, feed publisher, destinations, sweeps, mail, push) |
| Help centre truth | `node scripts/website/check_help.mjs --check` | OK against guide revision from Swift source |
| Discovery files and canonical URLs | `node scripts/website/build_site.mjs --check` | OK |
| Accessibility, behaviour, no-JS, perf budgets | `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node scripts/website/a11y_perf.mjs` | see `docs/WEBSITE_INVENTORY.md` for the recorded run |

## B. End-to-end path (sandbox; not run here)

1. Public site → identity: open `index.html`, follow Account; with `account-config.js` set to the
   verified portal, sign in with a test account (Apple/Google/GitHub/Microsoft or email); confirm
   `sdi_consent_action('current')` lists the published policy versions and accept them.
2. Sandbox subscription: StoreKit sandbox purchase of a monthly plan in the native app (products
   created in App Store Connect; `appAccountToken` = account id); App Store Server Notification
   (sandbox) → `appstore-notifications` → `sdi_billing_apply_event`; `sdi_my_entitlement` shows the
   tier with the provider's paid-through date. Web: `stripe-checkout` in test mode → hosted checkout
   with a test card → `stripe-webhook` events → entitlement. Expected: no entitlement from the
   redirect alone; duplicate webhook delivery answers `duplicate`.
3. Native Studio → local export → consented staging: export MP4 on device; submit for review; the
   intake registrar calls `sdi_consent_verify` (refuses without current consent/age attestation),
   validates the media and registers the render with a private preview.
4. Admin approval: reviewer approves the exact digest in the native Admin or the web command center
   (`admin.html` → `sdi_review_action`); rights cleared; creator queues the feed destination.
5. Mocked delivery: run the feed publisher against a sandbox bucket (`FeedPublisher` with a hosting
   adapter pointed at the sandbox) → `feed_posts` row visible; YouTube: publishing worker against a
   test channel in private visibility only; social: `MarketingWorker` in dry-run (request shown,
   nothing sent). Cleanup: `sdi_feed_removal_*` and `sdi_publish_removal_*` confirm removal.

## C. Failure rehearsals (sandbox; not run here)

| Scenario | Trigger | Expected evidence |
| --- | --- | --- |
| Support request | `sdi_support_action('create')` from the app; admin resolves in the command center | receipt shown to the member; audit row; retention date set |
| Cancellation / refund reconciliation | Stripe test refund; Apple sandbox refund notification | `status=refunded`, entitlement ends, ledger refund row once, `sdi_finance_report('reconciliation')` shows no discrepancy |
| Revoked marketing consent | `sdi_consent_action('withdraw','marketing')` | approved/queued marketing drafts become `invalidated` |
| Account deletion | request, wait the cooling-off (or advance in a test database), run `backend.ops.sweeps --only account_deletion_run` | phase one then purge; blockers listed while hosted copies remain |
| Provider outage | point an adapter at an unreachable host | job `failed` with a plain reason, bounded retries, no partial publication |
| Budget stop | `sdi_agent_admin('emergency_stop', payload=>'{"enabled":true}')` | running runs stopped, new runs refused, heartbeat refused |
| Backup restore | `scripts/backend/verify_backup.sh` locally; host-managed restore drill for the live project | identical row counts, RLS intact, grants intact |
| Website rollback | redeploy previous commit per `docs/WEBSITE_HOSTING.md` | preview URL serves the previous bytes; harness green |

## D. Operating handoff

- Runbooks: `docs/OPERATING_RUNBOOK.md`, `docs/INCIDENT_RUNBOOK.md`, `docs/SUPPORT_RUNBOOK.md`,
  `docs/RELEASE_CHECKLIST.md`, `docs/ROLLBACK.md`, `docs/WEBSITE_HOSTING.md`.
- Access inventory (owner keeps the filled copy privately; the template is the table below).

| System | Who holds access | MFA | Recovery | Last reviewed |
| --- | --- | --- | --- | --- |
| GitHub organisation / repository | | | | |
| Supabase project (owner + service role secret store) | | | | |
| Apple Developer / App Store Connect | | | | |
| Stripe account (test and live keys separated) | | | | |
| Google Cloud (YouTube OAuth client) | | | | |
| Domain registrar and DNS | | | | |
| Hosting (Pages/Vercel) | | | | |
| SMTP relay / sender domain | | | | |
| Social accounts used by destination adapters | | | | |

## E. Outstanding gates (owner / provider / legal)

Signing identities and TestFlight (`docs/TESTFLIGHT_DISTRIBUTION.md`), App Store Connect products
and the annual decision, Stripe account verification and test-mode products, YouTube OAuth client
and channel, policy legal review and `min_age`, domain and hosting, SMTP sender domain, APNs/FCM
credentials and test devices, the Spatter provider adapter configuration.
