# Daily original-draft queue contract (`spatter_draft_jobs`)

Status: **contract only**. No table is applied, no worker is deployed, no
schedule exists and no render capacity has been approved or purchased. This
document fixes the shape so the deterministic planner, the owner review queue
(`render_reviews` / `admin-approval.sql`) and a future worker agree before any
capacity decision. It makes no claim about how many drafts per day can be
produced.

## Table (deployment candidate, not an applied migration)

```sql
create table if not exists public.spatter_draft_jobs (
  id uuid primary key default gen_random_uuid(),
  target_date date not null unique,            -- one durable job per calendar day (UTC)
  state text not null default 'planned'
    check (state in ('planned','claimed','rendering','review_pending','approved','rejected','failed','missed','cancelled')),
  attempts integer not null default 0 check (attempts >= 0 and attempts <= 3),
  planner_seed bigint not null,                -- deterministic brief/recipe seed; replayable
  brief_version text not null,                 -- Tests/SpatterEval/briefs.v1.json schema the brief came from
  brief jsonb not null,                        -- the exact local instruction(s) the planner emitted
  quality_report jsonb,                        -- SpatterQualityReport findings for the rendered document
  review_id uuid references public.render_reviews(id),
  artifact_sha256 text,                        -- of the private draft MP4; never a public URL
  error text,                                  -- last failure reason, public-safe
  lease_owner text, lease_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.spatter_draft_jobs enable row level security;
-- Owner/admin read only through the existing admin authorization; worker writes with the service role.
```

## State machine

```
planned → claimed → rendering → review_pending → approved | rejected
   │          │          │
   │          │          └── failed (attempts < 3 → back to planned by the next run)
   │          └── lease expiry → planned
   └── target_date passed without review_pending → missed   (shown, never hidden)
cancelled: owner action from any non-terminal state
```

* `target_date unique` is the deduplication rule: a restarted or doubly scheduled
  worker cannot create a second job for the same day. Missed days are recorded as
  `missed`, not back-filled silently.
* `attempts ≤ 3` and a lease (`lease_owner`, `lease_expires_at`, 15 minutes)
  bound retries and concurrency to one active render per job.
* `review_pending` is the only path to visibility: the worker inserts a
  `render_reviews` row (`review_id`) and stops. Approval, feed and channel
  release stay owner actions gated by `release_allowed(…)`.
* `approved`/`rejected` are copied from the review outcome; the job never flips
  them itself.

## Worker responsibilities (not implemented)

1. Claim today's `planned` job (or create it with a deterministic `planner_seed`
   derived from `target_date`), take the lease.
2. Run the deterministic local planner (the same `SpatterSceneBrief` /
   `SpatterTwoActorBrief` / stick-figure grammars the app executes) against a
   fresh document; no provider call is involved in planning.
3. Render through the real export service, record `artifact_sha256` and a
   `SpatterQualityReport`; a report with blank/frozen/out-of-canvas findings marks
   the job `failed` with the finding as `error` rather than submitting it.
4. Insert the review row and set `review_pending`.

## Explicit non-claims

* No "one completed draft per day" promise: that depends on render capacity the
  owner has not approved. The queue shows `missed`/`failed` days truthfully.
* No spend: planning is local and deterministic; rendering uses existing
  infrastructure only. Nothing here purchases capacity.
* No storage policy yet: draft retention follows the bounded temporary-media
  rules once the worker exists.
