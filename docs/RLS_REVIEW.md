# Object-level authorization and minimum server data (#187, #122)

Status 2026-10-13: the invariants below are enforced by `backend/sql/tests/080_rls_review.sql`,
which runs against the whole candidate set in `scripts/backend/run_sql_tests.sh` on a local
PostgreSQL 16 cluster with stubbed Supabase pieces. They are source-level facts about the
candidates; nothing here has been applied to or verified against the live project, whose legacy
tables (`users`, `posts`, `likes`, `comments`, `follows`, `challenges`, `challenge_submissions`,
`studio_projects`) still need an inventory in the integration phase.

## Invariants the test asserts

1. Every table in `sdi_private` has row level security enabled and **no** table or column grant to
   `anon`, `authenticated` or `PUBLIC`. Clients reach data only through RPCs.
2. Every function in `sdi_private` and every public `sdi_*` wrapper pins `search_path = ''`.
3. Public `sdi_*` wrappers are `security invoker`; the `security definer` bodies live in
   `sdi_private` and bind every action to `auth.uid()`.
4. No public `sdi_*` function is executable by `PUBLIC`. Exactly three are executable by `anon`: `sdi_merch_totals`, `sdi_merch_vote` and `sdi_merch_suggest` (merch interest, 2026-10-15), pinned by `backend/sql/tests/080_rls_review.sql`.
5. Each public `sdi_*` function is executable by exactly one of `authenticated` (client surface)
   or `service_role` (worker surface). The service-only set is listed verbatim in the test; adding
   a worker function means reviewing and extending that list.
6. No column is named like a password, secret or key, and `token` appears only as a hash
   (`room_invites.token_hash`) or as the member-registered push `device_tokens.device_token`,
   which is readable by the service role only.
7. The four public tables (`sdi_rooms`, `sdi_room_members`, `sdi_watch_media`,
   `sdi_watch_sessions`) have RLS, no `anon` grants, and `authenticated` cannot `DELETE`,
   `TRUNCATE`, `REFERENCES` or `TRIGGER` on them.

## Cross-user denial coverage (per object, existing tests)

| Object | Test |
| --- | --- |
| Rooms, invites, member roles, commands | `030_rooms_v2.sql` |
| Feed posts, likes, reports, restricted creators | `010_feed_integrity.sql` |
| Render reviews, publishing jobs, feed publication | `020_feed_publication.sql` |
| Challenges, votes, achievements | `040_challenges_achievements.sql` |
| Billing events (service-only), entitlement reads | `050_billing_agents.sql`, `070_billing_lifecycle_finance.sql` |
| Finance reports and mutations (capability + step-up) | `070_billing_lifecycle_finance.sql` |
| Support requests ("another member cannot touch the request") | `060_support_hardening_lifecycle.sql` |
| Admin step-up, rate limit, owner provisioning, health | `060_support_hardening_lifecycle.sql` |
| Account export (own rows only), deletion phases | `060_support_hardening_lifecycle.sql` |
| Consent records, policy publication (owner + step-up) | `090_consent_notifications_marketing.sql` |
| Notification preferences, devices, announcements | `090_consent_notifications_marketing.sql` |
| Marketing drafts (publishing capability; owner approval) | `090_consent_notifications_marketing.sql` |

## Minimum persisted server metadata

| Area | Tables | Retained | Never stored |
| --- | --- | --- | --- |
| Identity | `auth.users`, `auth.sessions`, `auth.identities`, `auth.mfa_factors` (Supabase) | account lifetime | passwords in app tables |
| Admin | `admin_roles`, `admin_profiles`, `admin_access_audit`, `admin_budget` | account lifetime; audit bounded by retention policy | role flags on profiles |
| Rooms | `sdi_rooms`, `sdi_room_members`, `room_invites` (hashed code), `room_commands` | while room open + retention | project files; only versioned edit commands |
| War Room / challenges | `war_matches`, `war_votes`, `war_results`, `challenge_*` | contest lifetime + results | invented scores or viewers |
| Feed | `feed_posts`, `feed_likes`, `feed_follows`, `feed_blocks`, `feed_reports` | until removal/deletion | drafts, unapproved renders |
| Review and publishing | `render_reviews`, `render_decisions`, `render_artifacts` (object key + digest), `publish_jobs`, `removal_jobs` | artifact 7/30 days; job history | the creator's original |
| Billing | `billing_products`, `provider_events`, `subscriptions`, `finance_ledger`, `finance_audit` | provider events and ledger for accounting | prices, card data, customer contact (redacted in `provider_events.payload`) |
| Consent | `policy_versions`, `consent_records`, `consent_audit` | account lifetime | free-text age or identity documents |
| Notifications | `notification_preferences`, `device_tokens`, `announcements`, `announcement_deliveries`, `email_suppressions` (hash) | tokens until revoked; deliveries bounded | email bodies per member |
| Support | `support_requests`, `support_audit` | 180 days open / 90 resolved / 30 withdrawn | attachments, project uploads |
| Agents | `agents`, `agent_runs`, `agent_instructions`, `agent_audit` | run log bounded | provider credentials |

Editable projects, drawings, prompts and originals stay on the device (`AGENTS.md`); the server
holds the render artifact bytes only transiently in private staging (`backend/ingestion`).

## Deferred

- Live-project legacy tables: RLS state unknown until inventoried; do not expose endpoints until
  the full candidate set is installed (see `backend/sql/README.md`).
- Signed-URL and cache behaviour (preview links, CDN copies) is exercised only through the
  private-preview adapter contracts in `backend/ingestion`; runtime verification is deferred.
- Staging encryption at rest: `UploadStore` enforces a private, owner-only directory and 0600
  files; disk encryption is the host volume's responsibility and is recorded in the deployment
  checklist (`docs/OPERATING_RUNBOOK.md`), not claimed by code.
