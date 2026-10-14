# Admin command center: operations, agent console and directory (wave 4)

Source mapping for #211, #247, #248, #257, #284 and #285. Everything below is
unapplied candidate SQL plus native and web clients. Native compilation, simulator
runs and live backend checks are **deferred**; the SQL was exercised only on a
throwaway local PostgreSQL 16 with stubbed Supabase pieces
(`scripts/backend/run_sql_tests.sh`).

## Server surfaces

| Surface | RPC | Who | What it enforces |
|---|---|---|---|
| Backups, restore drills, releases, rollbacks, retention | `sdi_admin_operations` | `overview` capability, MFA, live session, rate limit | Read-only. Staleness: backup 26 h, restore drill 35 days, retention sweep 2 days; never reported reads as stale. |
| Host job reports | `sdi_ops_report(kind, outcome, label, metrics)` | service role only | Kind/outcome enumerated; label is a version number or commit hash; metrics are named whole numbers. No free text, so no host, path, bucket or credential can be stored. |
| Append-only audit | trigger `audit_append_only` | everyone | Access, agent, account, moderation, permission audits and ops reports: no edits; deletion only after 400 days. |
| Agent registry extras | `sdi_agent_admin('list')` | `overview` | Adds per-run cost cap, last error, last start and pending proposal count. |
| Run log / audit search | `sdi_agent_admin('runs' or 'audit', payload {state, query, page})` | `overview` | 50 per page, pages 0–199, query ≤ 100 characters, state from the run states. |
| Per-run cost cap | `set_caps` payload `per_run_cost_cap_minor` (empty = monthly cap only) | owner, step-up | `agent_run_begin` returns `run_cost_cap_minor`; a run that reports more than its cap, or pushes the month past the monthly cap, is recorded as reported and pauses the agent for owner review. Drafts are kept. |
| Run-log retention | `sdi_agent_log_retention()` | service role only | Deletes finished runs older than 180 days and agent audit rows older than 400 days. |
| Directory plan column | `sdi_users_action('list')` | `users`; plan only with `finance` | `free` when no provider-reported entitlement exists; never inferred. |
| Account state changes | `sdi_users_action` suspend/ban/restore/signout/note | `users` | `admin_gate`: recent second factor for state changes (not for notes), 30 per minute, denial audit. |
| Moderation decisions | `sdi_moderation_action` dismiss/remove | `moderation` | `admin_gate` rate limit (60 per minute) with denial audit. |

## Clients

- Native: `Backups & releases` tab (`AdminOperationsStatusContent`: operations
  status and presence-only provider configuration) and `Agent inbox & log` tab
  (`AdminAgentInboxContent`: registry extras, proposal approve/reject with reason
  and confirmation, searchable run and audit history). Directory rows show the plan
  when the server returns it; a `step_up_required` refusal opens the authenticator
  banner. Contracts and fail-closed validation live in `AdminOperationsClient.swift`
  and are covered by `Tests/CommunityAdmin`.
- Web (`website/admin.html`): panels for operations status and the agent audit;
  forms for directory search, account actions (reason and confirmation required)
  and run/audit history search. Render approvals and moderation decisions remain
  native-only because the exact render is played before a decision.

## Owner gates and remaining work

- Apply the candidates (README order) to the real project, then regenerate
  `backend/sql/dist/sdi-backend-install.sql`.
- The host backup, restore-drill, release, rollback and retention jobs must call
  `sdi_ops_report` with the service key from the host secret store. Until they do,
  the status honestly shows "never reported" and stale.
- Schedule `sdi_agent_log_retention()` from the host sweep (for example as a step in
  `backend.ops.sweeps`); not wired in this change.
- Publication hold during an emergency stop is not yet enforced by the publishing
  worker lease; the emergency stop covers agent runs and proposals only.
- External notification of affected members (beyond the in-app restriction status
  and appeal flow) and web parity for render approvals remain open.
