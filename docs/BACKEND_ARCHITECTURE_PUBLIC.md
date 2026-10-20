# StickDeath Infinity — Backend Architecture (Public)

> **Evidence discipline note.** This document distinguishes three confidence levels:
> - **Verified source exists** — confirmed in committed source files.
> - **Runtime verified** — confirmed to be operational via executed checks or established deployment facts.
> - **Not verified** — referenced in source or design documents but not confirmed operational.
>
> Scope reference: `docs/PRODUCT_SCOPE_2026_09_19.md` and GitHub issue #116. Items that
> earlier revisions of this document described but that the owner retired on
> 2026-09-19 (user-to-user messaging, voice/video calls, call billing, creator tips,
> a "Studio" subscription tier and invented annual prices) are listed in §9 so the
> history is clear; they are not product scope and must not be rebuilt.

Sensitive infrastructure details, credential locations, private network topology, and security-specific findings are intentionally omitted from this public report. See the security note at the end of this document.

---

## 1. High-Level Architecture

StickDeath Infinity is a **native SwiftUI/iOS application** (with an Android client in progress) backed by a **Supabase-hosted backend** (Postgres, Auth, Storage, Edge Functions). There is no custom application server in this repository; two small server-side Python components (private render intake and the owner-channel publishing worker) exist as source and are not deployed.

**Key external services (current scope):**
- **Supabase** — Database, Auth (Apple, Google, GitHub, Microsoft identity), Storage, Edge Functions
- **StoreKit 2** — Apple In-App Purchases for the two monthly subscriptions
- **Stripe** — Server-side only (web checkout/portal and webhooks); test mode until the owner authorizes live activation; no client-side Stripe charges
- **YouTube Data API** — Owner-channel publication of approved renders, server-side OAuth only
- **Spatter assistant** — On-device guide plus an optional server-side generation path; the provider is a configurable server-side adapter, no provider is named in product scope and **no paid external AI calls are configured** (owner policy)

Editable projects and originals stay on the device. The server holds only identity, access, consent, votes, billing, moderation and job metadata plus bounded temporary media.

---

## 2. Supabase Integration

All client data flows route through a singleton Supabase client (`SupabaseManager.shared`) initialized from `AppConfig` (gitignored configuration, not committed to source control).

### 2.1 Auth (Verified Source Exists)

| Method | Status | Notes |
|--------|--------|-------|
| Sign In with Apple | Verified source exists | Native `ASAuthorizationController` → Supabase ID token exchange |
| Sign In with Google | Verified source exists | OAuth redirect via `stickdeath://auth/callback` URL scheme |
| GitHub / Microsoft | Not verified | Required by scope (`docs/AUTH_PROVIDER_CONFIGURATION.md`); provider configuration is an owner gate |
| Email/Password | Verified source exists | Standard Supabase Auth sign-up/sign-in |
| Guest (Anonymous) | Verified source exists | Anonymous session; anonymous accounts cannot publish, vote, join rooms or contact support |
| Session persistence | Verified source exists | Supabase auth state change listener implemented |

Administrator roles are **server-authorized** (`sdi_private.admin_roles`, MFA `aal2`, live session), never derived from an email list or profile field. Earlier builds gated the admin dashboard on a hard-coded `superuserEmails` configuration; that pattern is retired and must not be reintroduced.

### 2.2 Database (Candidate Schema, Not Applied)

The current backend design is the set of SQL candidates in `backend/sql/` (install order in `backend/sql/README.md`). They have been applied to a local PostgreSQL 16 cluster by `scripts/backend/run_sql_tests.sh` with stubbed Supabase pieces; they have **not** been applied to the live project, whose legacy tables (`users`, `posts`, `likes`, `comments`, `follows`, `challenges`, `challenge_submissions`, `studio_projects`) must be inventoried and reconciled in the integration phase.

| Area | Candidate files | Client surface |
|------|-----------------|----------------|
| Rooms (invitation-based collaboration on a shared Studio project; roles; versioned commands; reports) | `collaboration-watch.sql`, `room-invitations.sql`, `rooms-v2.sql` | `sdi_room_action`, `sdi_room_manage`, `sdi_room_command` |
| War Room (favorite voting between approved renditions) | `war-room.sql`, `war-finalization.sql`, `war-moderation.sql`, `war-appeals.sql`, `profile-records.sql` | `sdi_war_action`, `sdi_war_report`, `sdi_war_notices`, `sdi_profile_records`, `sdi_war_leaderboard` |
| Feed of approved videos | `video-feed.sql`, `feed-integrity.sql`, `feed-publication.sql`, `moderation.sql` | `sdi_feed_action`, `sdi_export_consent`, `sdi_moderation_appeal` |
| Render review and publishing | `admin-approval.sql`, `review-rights.sql`, `publishing-jobs.sql`, `publishing-withdrawal.sql`, `publishing-admin.sql`, `creator-reviews.sql`, `upload-*.sql`, `preview-renewal.sql` | `sdi_creator_review`, `sdi_publish_action`, `sdi_review_action` |
| Challenges and Calendar | `challenges.sql` | `sdi_challenge_action`, `sdi_calendar_range` |
| Achievements | `achievements.sql` | `sdi_achievement_catalog` |
| Billing and entitlements | `billing.sql`, `billing-finance.sql` | `sdi_my_entitlement` (read-only); finance: `sdi_finance_admin`, `sdi_finance_report`, `sdi_finance_record` |
| Consent registry | `consent-versions.sql` | `sdi_consent_action`; service `sdi_consent_verify` |
| Notifications and email preferences | `notifications.sql` | `sdi_notify_action`, `sdi_announce_admin`; service `sdi_announcement_claim/finish`, `sdi_email_recipients`, `sdi_email_suppress` |
| Marketing workspace | `marketing-workspace.sql` | `sdi_marketing_action`; service `sdi_marketing_claim/finish`, `sdi_marketing_cadence_due` |
| Administration | `admin-users.sql`, `admin-permissions.sql`, `admin-overview.sql`, `admin-hardening.sql`, `agent-controls.sql`, `agent-proposals.sql`, `worker-configuration.sql` | `sdi_users_action`, `sdi_admin_permissions`, `sdi_admin_health`, `sdi_admin_configuration`, `sdi_agent_admin`, `sdi_agent_proposal_admin` |
| Account lifecycle and support | `account-lifecycle.sql`, `support-requests.sql` | `sdi_account_lifecycle`, `sdi_member_notices`, `sdi_support_action` |

All tables live in `sdi_private` (RLS enabled, no client grants) behind `security definer` RPCs that bind every action to `auth.uid()`, check `account_active()` (live session, not suspended) and, for administration, `admin_can(capability)` with MFA. Worker functions are granted to `service_role` only. There is no `increment_likes`-style client-callable counter; counts are computed server-side.

### 2.3 Storage

| Bucket | Purpose | Source reference |
|--------|---------|-----------------|
| `media` | Images, avatars, project thumbnails | `StorageService.swift` |

Rendered MP4s for review do not go through client-writable storage: they enter through the private intake service (§5.3) and only the publishing service inserts approved public renditions.

### 2.4 Edge Functions

| Function | Purpose | Status |
|----------|---------|--------|
| `stripe-checkout` | Server-created Checkout/Portal sessions for approved monthly products | Handler candidate `backend/billing/stripe_checkout.py`, tested offline; not deployed |
| `stripe-webhook` | Verified Stripe events → `sdi_billing_apply_event` | Handler candidate `backend/billing/stripe_webhook.py`, tested offline; not deployed |
| `appstore-notifications` | Verified App Store Server Notifications → `sdi_billing_apply_event` | Handler candidate `backend/billing/appstore_notifications.py`, tested offline; not deployed |
| Spatter generation proxy | Server-side adapter so no provider credential reaches a client | Not implemented; provider-neutral by policy |

No realtime channel is part of the design: Watch Together polls a server-stamped session row; room edits replay versioned commands.

---

## 3. Rooms, Watch Together and War Room (Verified Source Exists, Not Runtime Verified)

- **Rooms** are owner-created, invitation-based collaboration spaces for an explicitly shared Studio project. Invites are server-generated 256-bit codes, hashed at rest, expiring in 24 hours with 20 uses; the recipient consents and the owner approves (mutual agreement). Owners set `view`/`edit` permissions and `editor`/`viewer` roles; revocation ends access immediately. Shared edits are versioned commands with idempotent operation ids and explicit conflicts. There is no chat, camera, microphone, screen sharing or call billing.
- **Watch Together** synchronizes playback of an approved rendition inside a room using database-stamped positions.
- **War Room** is a contest between two approved renditions: proposal, explicit opponent acceptance, 24-hour voting, one mutable vote per authenticated nonparticipant, server-counted results, moderation with appeals, optional badges and win/loss display hidden by default. Proposals expire after seven days.

---

## 4. Spatter

### 4.1 On-Device Guide (Verified Source Exists)

Bundled knowledge files and the native guide drive Studio assistance; nothing is sent off-device for the guide.

### 4.2 Server-Side Generation (Not Verified)

Daily generation, if enabled, produces **private drafts** that require the owner's approval of the exact render digest in the admin command center before any feed, channel or social release (`release_allowed` requires `owner_at_decision` for `spatter_generated` renders). The provider adapter is server-side and configurable; no provider is part of product scope and no paid provider calls are configured. The agent-control candidate (`agent-controls.sql`) supplies pause, emergency stop, caps and versioned instructions for this and other automated agents. Owner-only configuration views exist in source; their data wiring is not verified.

---

## 5. Publishing / Content System

### 5.1 Feed (Candidate)

Approved renders become visible feed posts only through the service-role feed publication path after `release_allowed(review, version, digest, 'feed')` succeeds; the host adapter is `backend/publishing/feed_publisher.py` (verifies the bytes' digest before copying, removals first). Likes (no self-likes), follows, blocks and categorized reports are idempotent; suspended creators are excluded from listings. File export of a post requires the creator's explicit export permission (default off). Paging is keyset-based (`sdi_feed_page`, opaque cursor under a snapshot instant, id tiebreak; #220). Each published copy carries a worker-extracted, digest-recorded poster thumbnail when one could be produced (#217).

### 5.2 Challenges (Candidate)

Moderators schedule challenges; members enter one approved rendition each, vote once during the voting window, and server time decides phases. Configured real rewards are descriptive text; no currency exists.

### 5.3 Render Intake and Publishing (Verified Source Exists, Not Deployed)

`backend/ingestion` is a private resumable MP4 intake (chunk checksums, quotas, bounded media validation, server-verified consent through `sdi_consent_verify`, idempotent review registration, expiring private preview links). `backend/publishing` is a one-job worker that uploads private, verifies processing and ownership, releases only on a renewed approval lease, and can withdraw to private; `destinations.py` adds honest social adapters (unavailable / dry-run / published / failed) driven by the marketing workspace. Owner YouTube OAuth lives only in the server secret store. Offline unit tests with fake transports: `python3 -m unittest discover -s backend/tests -t .` (102 tests on 2026-10-13).

### 5.4 Studio Projects

Projects are device-first. Server-side rendering of `.sdi` projects is not implemented; export happens on device.

---

## 6. Payment Architecture

### 6.1 Approved Offers

| Tier | Period | Price point (owner decision) | Status |
|------|--------|------------------------------|--------|
| Creator | Monthly | USD 4.99 | Product identifiers not yet configured |
| Pro | Monthly | USD 9.99 | Product identifiers not yet configured |
| Any | Annual | Not approved | Requires explicit owner configuration before approval (`billing_products.owner_configured_at`) |

Prices live only in App Store Connect and the Stripe dashboard. The database stores product identifiers, verified provider events, subscriptions with a provider-reported paid-through date and a provider-reported ledger; **no client writes tier or status**. Native digital entitlements use StoreKit 2; Stripe is server-side only and runs in test mode until separately authorized. No live charges are made as tests, no new paid services are added, and no coins, tips or call charges exist.

### 6.2 Reconciliation

Entitlements derive from `sdi_private.entitlements` (active/trialing/grace/past_due with `paid_through` in the future). `sdi_billing_reconcile()` expires lapsed subscriptions after a 16-day grace window and reports counts. Finance administrators read provider-reported sums that are labelled as records, not balances.

---

## 7. Admin Surface

### 7.1 Native Admin (Verified Source Exists)

Tabs for video approvals, users, content, moderation, publishing and overview call the `sdi_*` admin RPCs. Authorization is server-side: enabled `admin_roles` row, MFA `aal2`, live session, capability check, step-up (recent MFA) for sensitive changes, per-administrator rate limits and a denial audit (`admin-hardening.sql`). Health (`sdi_admin_health`) reports queue depths, oldest pending items and worker heartbeat age without host details; configuration presence (`sdi_admin_configuration`) shows which named provider settings each worker reported as present or absent, as booleans only, with the report age. Agent controls (`sdi_agent_admin`) provide pause/resume, emergency stop, caps and instruction history; the approval inbox (`sdi_agent_proposal_admin`) holds actions an agent proposed above its caps until the owner approves or rejects them with an audited reason, and the worker executes only approved proposals. Owner provisioning is a service-only procedure that requires a confirmed email and a verified MFA factor and takes no password.

### 7.2 Web Command Center

`website/admin.html` is a static, config-gated shell over the same RPCs (`admin-config.js` is `null` in the repository, so the page reports "not configured" and sends nothing). When configured it signs in through GoTrue (password + TOTP step-up, or provider redirect), keeps the session in page memory only, shows `sdi_admin_permissions('mine')` and loads each area's RPC on demand, printing `forbidden` / `step_up_required` answers verbatim; the only write is the owner's emergency stop. Not deployed; the website harness checks its unconfigured state.

---

## 8. Account Lifecycle, Support and Privacy

- Members export their own server records (`sdi_account_lifecycle('export')`, three per day). On-device projects are not server-side and are not part of the export.
- Deletion requests have a seven-day cooling-off period; the service worker then suspends, withdraws publishing consent, unapproves media and queues removals, closes rooms and finally purges server rows once hosted copies and intake renders are gone. Provider subscriptions must be cancelled through the store or portal.
- Support requests are authenticated, rate-limited, receipted and retained for a bounded period; administrators with the users capability work the queue. This is customer support, not messaging.
- Consent is versioned (`consent-versions.sql`): members accept the current terms, privacy, publishing, marketing and content-policy versions; publishing and marketing permissions are separate and separately withdrawable; the content policy carries the owner's `min_age` and the member's attestation (`docs/CONTENT_POLICY.md`).
- Notifications and email (`notifications.sql`, `backend/notifications`, `backend/mail`): service notices always, product and marketing only after opt-in with a daily cap; email suppression by address hash; deliveries go to a sink in development. No push or SMTP credentials exist in the repository.
- Temporary render media has bounded retention (seven days under review, thirty days after approval) and is deleted only after verified publication or documented expiry. The service never deletes a member's only original.

---

## 9. Retired Scope (Do Not Rebuild)

The following were described in earlier revisions of this document and remain only as source remnants scheduled for removal (#260): LiveKit voice/video calls and the `livekit-token` function, chat rooms/messages and realtime messaging, call billing rate tiers, creator tips, a USD 19.99 "Studio" tier and annual prices, client-side AI provider keys, client-written subscription status, and the `superuserEmails` admin gate. Where a remnant still compiles, it is not reachable product behaviour and must not be wired up.

---

## 10. Evidence by epic (2026-10-13, source and local checks only)

| Epic | Evidence in this repository | Not done / gated |
|------|-----------------------------|------------------|
| #32 Consented publishing | `release_allowed` gate, YouTube worker, feed publisher, destination adapters, consent registry with per-render binding and withdrawal (`020`, `090` SQL tests; `test_publishing.py`, `test_workers.py`) | provider accounts, OAuth client, any live upload |
| #117 Social wall and challenges (backend half) | feed integrity and publication, challenges, achievements, moderation and appeals (`010`, `020`, `040` SQL tests) | cursor paging, native wiring, runtime verification |
| #120 Admin command center | server roles, MFA, step-up, rate limits, denial audit, health, agent console backend, finance ops, announcements, web shell (`060`, `070`, `090` SQL tests; website harness) | owner provisioning run, deployment, native/web runtime checks |
| #121 Subscriptions | two monthly offers only, annual owner-gated, three handler candidates, lifecycle and reconciliation, finance ledger and report (`test_billing.py`; `050`, `070` SQL tests) | App Store Connect / Stripe configuration, sandbox exercises, entitlement policy |
| #122 Authorization, privacy, moderation | RLS review test over the whole set, consent registry, content policy, account export/deletion worker contract, backup/restore rehearsal (`080`, `060` SQL tests; `verify_backup.sh`) | legacy table inventory, legal review, live backup drill |
| #268 Website and business operations | help centre checker, discovery files, policy drafts, account and admin shells, support intake SQL, notifications/email candidates, marketing workspace, runbooks and rehearsal checklist (`check_help`, `build_site --check`, `a11y_perf` 333 checks) | hosting, domain, SMTP sender, real-device and WebKit checks |

## 11. Security Note

This report intentionally omits:
- Private network topology and infrastructure details
- Credential locations, API key values, and secret inventories
- Specific security vulnerabilities and attack vectors
- Private database names, hostnames, and internal URLs
- Process topology, port bindings, and service manager details
- Admin-auth internals beyond the public RPC contracts

Owner credentials are provisioned privately with MFA; no password is stored in source, issues, fixtures or logs. Release and merge claims require honest verification; nothing in this document is a claim that any candidate is deployed.

---

*Document generated from source inspection of the StickDeath Infinity repository. No remote state was modified in the creation of this document.*
