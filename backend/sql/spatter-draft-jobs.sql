-- Unapplied deployment candidate (#212, #214). Install after agent-controls.sql
-- and admin-approval.sql. Spatter's daily original-draft queue: one durable job
-- per calendar day, bounded retries and leases, private drafts only, and the
-- review row that binds the storyboard and the exact source-project digest.
-- Nothing here schedules a worker, approves capacity or publishes anything;
-- the owner enables the `spatter_daily_video` agent deliberately and approves
-- every render in the existing review queue.
begin;

-- Reviews carry the plan and the source digest (#214). Changing either
-- invalidates a prior approval exactly like a render-digest change.
alter table sdi_private.render_reviews
 add column storyboard jsonb,
 add column source_project_digest text check(source_project_digest is null or source_project_digest ~ '^[a-f0-9]{64}$');
create or replace function sdi_private.invalidate_render_approval() returns trigger language plpgsql set search_path='' as $$
begin
 if row(new.render_digest,new.source_revision,new.consent_version,new.rights_cleared,new.destinations,new.spatter_generated,new.creator,new.rights_summary,new.storyboard,new.source_project_digest)
 is distinct from row(old.render_digest,old.source_revision,old.consent_version,old.rights_cleared,old.destinations,old.spatter_generated,old.creator,old.rights_summary,old.storyboard,old.source_project_digest) then
  new.version=old.version+1; new.state='pending';
 end if;
 return new;
end $$;

create table sdi_private.spatter_draft_jobs (
 id uuid primary key default gen_random_uuid(),
 target_date date not null unique,                      -- one durable job per UTC day: restarted or double-scheduled workers cannot duplicate it
 state text not null default 'planned'
  check(state in('planned','claimed','rendering','review_pending','approved','rejected','failed','missed','cancelled')),
 attempts integer not null default 0 check(attempts between 0 and 3),
 planner_seed bigint not null,                          -- deterministic brief seed derived from target_date; replayable
 brief_version text not null check(length(brief_version) between 1 and 40),
 brief jsonb not null,                                   -- the exact local instruction(s) the planner emitted
 storyboard jsonb,
 quality_report jsonb,
 review_id uuid references sdi_private.render_reviews(id) on delete set null,
 artifact_sha256 text check(artifact_sha256 is null or artifact_sha256 ~ '^[a-f0-9]{64}$'),
 error text not null default '' check(length(error)<=2000),
 lease_owner text check(lease_owner is null or length(lease_owner) between 1 and 120),
 lease_expires_at timestamptz,
 agent_run uuid references sdi_private.agent_runs(id) on delete set null,
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.spatter_draft_jobs enable row level security;
revoke all on sdi_private.spatter_draft_jobs from public,anon,authenticated;
create index spatter_draft_jobs_state on sdi_private.spatter_draft_jobs(state,target_date);

-- Days that passed without reaching review are recorded as missed, never
-- back-filled or hidden. Expired leases return the job to the claimable pool.
create function sdi_private.spatter_draft_sweep() returns integer language plpgsql security definer set search_path='' as $$
declare touched integer:=0; n integer;
begin
 update sdi_private.spatter_draft_jobs set state='missed',error=case when error='' then 'Target date passed without a review-ready draft.' else error end,
  lease_owner=null,lease_expires_at=null,updated_at=clock_timestamp()
  where state in('planned','claimed','rendering','failed') and target_date<(clock_timestamp() at time zone 'utc')::date;
 get diagnostics n=row_count; touched:=touched+n;
 update sdi_private.spatter_draft_jobs set state='planned',lease_owner=null,lease_expires_at=null,
  error='Lease expired before the render finished.',updated_at=clock_timestamp()
  where state in('claimed','rendering') and lease_expires_at<clock_timestamp();
 get diagnostics n=row_count; touched:=touched+n;
 -- Review outcomes are copied, never decided here.
 update sdi_private.spatter_draft_jobs j set state=r.state,updated_at=clock_timestamp()
  from sdi_private.render_reviews r where r.id=j.review_id and j.state='review_pending' and r.state in('approved','rejected');
 get diagnostics n=row_count; touched:=touched+n;
 return touched;
end $$;

-- Claim today's job (or create it) behind the owner's agent gate. Returns
-- {claimed:boolean, reason?, job?, attempt?, run?, brief?}. The planner seed and
-- brief are supplied by the worker and stored once; later claims reuse them.
create function sdi_private.spatter_draft_claim(p_date date,p_owner text,p_seed bigint,p_brief_version text,p_brief jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j sdi_private.spatter_draft_jobs; gate jsonb; run uuid;
begin
 if p_date is null or p_owner is null or length(p_owner) not between 1 and 120 or p_brief is null or p_brief_version is null then
  return jsonb_build_object('claimed',false,'reason','Invalid claim request.'); end if;
 if p_date<(clock_timestamp() at time zone 'utc')::date then
  perform sdi_private.spatter_draft_sweep();
  return jsonb_build_object('claimed',false,'reason','The target date has passed; it is recorded as missed, not back-filled.'); end if;
 perform sdi_private.spatter_draft_sweep();
 insert into sdi_private.spatter_draft_jobs(target_date,planner_seed,brief_version,brief) values(p_date,p_seed,p_brief_version,p_brief)
  on conflict(target_date) do nothing;
 select * into j from sdi_private.spatter_draft_jobs where target_date=p_date for update;
 if j.state not in('planned','failed') then return jsonb_build_object('claimed',false,'reason','Job is '||j.state||'.','job',j.id); end if;
 if j.attempts>=3 then return jsonb_build_object('claimed',false,'reason','Retry limit reached (3 attempts).','job',j.id); end if;
 gate:=sdi_private.agent_run_begin('spatter_daily_video',p_date::text);
 if not (gate->>'allowed')::boolean then return jsonb_build_object('claimed',false,'reason',gate->>'reason','job',j.id); end if;
 run:=(gate->>'run')::uuid;
 update sdi_private.spatter_draft_jobs set state='claimed',attempts=attempts+1,lease_owner=p_owner,
  lease_expires_at=clock_timestamp()+interval '15 minutes',agent_run=run,error='',updated_at=clock_timestamp() where id=j.id;
 return jsonb_build_object('claimed',true,'job',j.id,'attempt',j.attempts+1,'run',run,'brief',j.brief,'planner_seed',j.planner_seed,
  'instructions',gate->>'instructions','per_run_item_cap',gate->'per_run_item_cap');
end $$;

-- Worker progress. Only the lease holder may move a job, and only forward:
-- claimed→rendering, rendering→failed, rendering→review_pending (which inserts
-- the private review row and finishes the agent run). Approval stays with the
-- owner in the review queue.
create function sdi_private.spatter_draft_progress(p_job uuid,p_owner text,p_state text,p_storyboard jsonb default null,
 p_quality jsonb default null,p_sha text default null,p_error text default '',p_review jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j sdi_private.spatter_draft_jobs; review uuid; creator uuid; retained timestamptz; preview_until timestamptz;
begin
 select * into j from sdi_private.spatter_draft_jobs where id=p_job for update;
 if not found or j.lease_owner is distinct from p_owner or j.lease_expires_at<clock_timestamp() then
  return jsonb_build_object('status','refused','reason','Not the current lease holder.'); end if;
 if p_state='rendering' and j.state='claimed' then
  update sdi_private.spatter_draft_jobs set state='rendering',storyboard=coalesce(p_storyboard,storyboard),
   lease_expires_at=clock_timestamp()+interval '15 minutes',updated_at=clock_timestamp() where id=j.id;
  perform sdi_private.agent_run_heartbeat(j.agent_run);
  return jsonb_build_object('status','confirmed','state','rendering');
 elsif p_state='failed' and j.state in('claimed','rendering') then
  update sdi_private.spatter_draft_jobs set state='failed',error=left(coalesce(p_error,'Render failed.'),2000),quality_report=coalesce(p_quality,quality_report),
   lease_owner=null,lease_expires_at=null,updated_at=clock_timestamp() where id=j.id;
  perform sdi_private.agent_run_finish(j.agent_run,'failed',0,0,left(coalesce(p_error,''),2000));
  return jsonb_build_object('status','confirmed','state','failed','attempts',j.attempts);
 elsif p_state='review_pending' and j.state='rendering' then
  if p_sha is null or p_sha !~ '^[a-f0-9]{64}$' or p_storyboard is null or p_quality is null or p_review is null
   or (p_review->>'creator') is null or (p_review->>'preview_url') is null or (p_review->>'source_project_digest') !~ '^[a-f0-9]{64}$' then
   return jsonb_build_object('status','refused','reason','A review needs the render digest, storyboard, quality report, source digest, creator and private preview URL.'); end if;
  if coalesce((p_quality->>'passes')::boolean,false) is not true then
   return jsonb_build_object('status','refused','reason','The quality report did not pass; mark the job failed with the finding instead.'); end if;
  -- Optional retained private copy (backend/spatter/draft_preview.py): object_key
  -- <upload>.mp4, byte_count and artifact_expires_at (at most 14 days). Without it
  -- the draft can be reviewed but not approved or have its preview renewed.
  if p_review ? 'object_key' then
   if (p_review->>'object_key') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.mp4$'
    or jsonb_typeof(p_review->'byte_count') is distinct from 'number' or (p_review->>'byte_count') !~ '^[0-9]{1,10}$'
    or (p_review->>'byte_count')::bigint not between 1 and 2147483648 or (p_review->>'artifact_expires_at') is null then
    return jsonb_build_object('status','refused','reason','The retained draft copy needs an object key, byte count and expiry.'); end if;
   retained:=(p_review->>'artifact_expires_at')::timestamptz;
   if retained<=clock_timestamp() or retained>clock_timestamp()+interval '14 days' then
    return jsonb_build_object('status','refused','reason','The retained draft copy expiry must be within 14 days.'); end if;
  end if;
  preview_until:=coalesce((p_review->>'preview_expires_at')::timestamptz,clock_timestamp()+interval '7 days');
  if retained is not null then preview_until:=least(preview_until,retained); end if;
  creator:=(p_review->>'creator')::uuid;
  insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,
   destinations,spatter_generated,storyboard,source_project_digest)
  values(creator,left(coalesce(p_review->>'title','Spatter daily draft '||j.target_date::text),200),coalesce(p_review->>'source_revision','draft:'||j.target_date::text),
   p_sha,p_review->>'preview_url',preview_until,
   coalesce(p_review->>'consent_version','spatter-draft-v1'),coalesce(p_review->>'rights_summary','Independently generated stick-figure content; no external source material.'),
   coalesce((p_review->>'rights_cleared')::boolean,true),'{}'::text[],true,p_storyboard,p_review->>'source_project_digest')
  returning id into review;
  if retained is not null then
   insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,made_for_kids,expires_at)
   values(review,1,p_sha,p_review->>'object_key',(p_review->>'byte_count')::bigint,
    left(coalesce(p_review->>'title','Spatter daily draft '||j.target_date::text),100),false,retained);
  end if;
  update sdi_private.spatter_draft_jobs set state='review_pending',storyboard=p_storyboard,quality_report=p_quality,artifact_sha256=p_sha,review_id=review,
   lease_owner=null,lease_expires_at=null,updated_at=clock_timestamp() where id=j.id;
  perform sdi_private.agent_run_finish(j.agent_run,'succeeded',1,0,'');
  return jsonb_build_object('status','confirmed','state','review_pending','review',review);
 end if;
 return jsonb_build_object('status','refused','reason','Transition '||j.state||' → '||coalesce(p_state,'?')||' is not allowed.');
end $$;

-- Owner/admin view: every day in the range with its real state, so missed and
-- failed days are visible rather than a daily-success claim.
create function sdi_private.spatter_draft_status(p_from date,p_to date) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not sdi_private.admin_can('reviews') then return jsonb_build_object('error','Current video-review permission and MFA are required.'); end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>62 then return jsonb_build_object('error','Choose a range of at most 62 days.'); end if;
 perform sdi_private.spatter_draft_sweep();
 select coalesce(jsonb_agg(jsonb_build_object('date',d::date,'state',coalesce(j.state,case when d::date<(clock_timestamp() at time zone 'utc')::date then 'missed' else 'unplanned' end),
  'attempts',coalesce(j.attempts,0),'error',coalesce(j.error,''),'review',j.review_id,'sha256',j.artifact_sha256,'seed',j.planner_seed) order by d),'[]'::jsonb)
  into result from generate_series(p_from,p_to,interval '1 day') d left join sdi_private.spatter_draft_jobs j on j.target_date=d::date;
 return jsonb_build_object('days',result,'capacity','owner-gated: no render capacity is approved or purchased by this queue');
end $$;

revoke all on function sdi_private.spatter_draft_sweep(),sdi_private.spatter_draft_claim(date,text,bigint,text,jsonb),
 sdi_private.spatter_draft_progress(uuid,text,text,jsonb,jsonb,text,text,jsonb),sdi_private.spatter_draft_status(date,date) from public,anon,authenticated;
grant execute on function sdi_private.spatter_draft_sweep(),sdi_private.spatter_draft_claim(date,text,bigint,text,jsonb),
 sdi_private.spatter_draft_progress(uuid,text,text,jsonb,jsonb,text,text,jsonb) to service_role;
grant execute on function sdi_private.spatter_draft_status(date,date) to authenticated;
create function public.sdi_spatter_draft_claim(p_date date,p_owner text,p_seed bigint,p_brief_version text,p_brief jsonb) returns jsonb
 language sql security invoker set search_path='' as $$select sdi_private.spatter_draft_claim(p_date,p_owner,p_seed,p_brief_version,p_brief)$$;
create function public.sdi_spatter_draft_progress(p_job uuid,p_owner text,p_state text,p_storyboard jsonb default null,p_quality jsonb default null,
 p_sha text default null,p_error text default '',p_review jsonb default null) returns jsonb
 language sql security invoker set search_path='' as $$select sdi_private.spatter_draft_progress(p_job,p_owner,p_state,p_storyboard,p_quality,p_sha,p_error,p_review)$$;
create function public.sdi_spatter_draft_status(p_from date,p_to date) returns jsonb
 language sql security invoker set search_path='' as $$select sdi_private.spatter_draft_status(p_from,p_to)$$;
revoke all on function public.sdi_spatter_draft_claim(date,text,bigint,text,jsonb),public.sdi_spatter_draft_progress(uuid,text,text,jsonb,jsonb,text,text,jsonb),
 public.sdi_spatter_draft_status(date,date) from public,anon,authenticated;
grant execute on function public.sdi_spatter_draft_claim(date,text,bigint,text,jsonb),public.sdi_spatter_draft_progress(uuid,text,text,jsonb,jsonb,text,text,jsonb) to service_role;
grant execute on function public.sdi_spatter_draft_status(date,date) to authenticated;

-- ── Spatter cloud-advice metering (#209) ─────────────────────────────────
-- Server-side prompt accounting for backend/spatter/handler.py. The device never
-- counts its own allowance. Owner decisions (2026-10-07, revised 2026-10-14
-- and 2026-10-15, issue #209):
-- * Free: Spatter and its suggested prompts are visible in the app, but the
--   server never funds a Free prompt. A Free account with no Spatter credits
--   is refused with the stable code 'upgrade_required' (plan 'free', upgrade
--   'creator_or_pro', buy_credits true) before any counter, reservation or
--   provider call; with credits it pays as it goes (see credits below). The
--   former Free allowance (5 suggested prompts per calendar month, column
--   free_prompts and 'month:'/'free' buckets) is retired; this file was never
--   applied, so the column and buckets are removed rather than left unused.
-- * Paid tiers (owner decision 2026-10-20; rank unlimited > pro > creator):
--   creator (USD 4.99/month) 250, pro (USD 9.99/month) 500 server-funded
--   prompts per billing period (owner-editable creator_period_prompts /
--   pro_period_prompts), keyed to the subscription's paid_through so a renewal
--   starts a new period; unlimited (USD 19.99/month) has no plan allowance.
--   Prompts a member sends with their own AI key go device-to-provider and
--   never reach this meter. Every tier, unlimited included, still obeys the
--   per-user daily safety cap, the per-minute rate, the global daily ceiling
--   (spatter_usage_controls.global_daily_cap) and the agent emergency stop.
-- * Free trial (owner decision 2026-10-20): each paid tier starts with a 3-day
--   free trial (App Store introductory offer). The Studio is unlocked, but
--   Spatter is preview-only: an account whose only current entitlements are in
--   a free-trial period (entitlements.in_trial) is refused with
--   'upgrade_required' (plan = the trial tier, trial true, upgrade
--   'after_trial', buy_credits false) before any counter, reservation, credit
--   or provider call. The first paid period clears in_trial and opens the
--   tier's normal allowance (a new paid_through, so a new period bucket).
-- * Spatter credits (owner decision 2026-10-15, later): consumable store packs
--   (sdi_private.spatter_credit_packs, no prices: the store owns them) credit
--   an append-only ledger. 1 credit = 1 prompt. A reservation spends the plan
--   allowance first (creator/pro period allowance; unlimited never spends
--   credits), then one credit. Safety, rate and global caps and the emergency
--   stop apply before either. A released reservation refunds its credit.
--   Purchases and refunds are granted only by verified provider events through
--   the service-only spatter_credits_grant/_refund functions. Credits are never
--   spent during a free trial.
-- The global ceiling defaults to 0 (closed) so
-- nothing can be spent until the owner sets it. One unit is one prompt;
-- provider-reported usage units (tokens, not money) are recorded on the
-- reservation when the handler commits it. Actual provider cost is not
-- recorded: the provider contract returns usage units only, so the per-tier
-- period counts and the global ceiling stay the owner's control on spend.
create table sdi_private.spatter_usage_controls (
 singleton boolean primary key default true check(singleton),
 global_daily_cap integer not null default 0 check(global_daily_cap between 0 and 10000000),
 user_daily_safety_cap integer not null default 100 check(user_daily_safety_cap between 0 and 10000),
 user_per_minute_cap integer not null default 6 check(user_per_minute_cap between 1 and 600),
 creator_period_prompts integer not null default 250 check(creator_period_prompts between 0 and 1000000),
 pro_period_prompts integer not null default 500 check(pro_period_prompts between 0 and 1000000),
 revision bigint not null default 1, updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default clock_timestamp()
);
insert into sdi_private.spatter_usage_controls(singleton) values(true);
-- One row per (account, bucket). Buckets: 'period:<paid_through>' (creator/pro
-- billing period), 'day:<utc date>' (safety cap) and 'minute:<utc minute>'
-- (rate). Free accounts never get a row. No prompt text is ever stored.
create table sdi_private.spatter_usage_counters (
 user_id uuid not null references auth.users(id) on delete cascade,
 bucket text not null check(bucket ~ '^(period:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z|day:[0-9]{4}-[0-9]{2}-[0-9]{2}|minute:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2})$'),
 used integer not null default 0 check(used>=0),
 updated_at timestamptz not null default clock_timestamp(),
 primary key(user_id,bucket)
);
create table sdi_private.spatter_usage_global (
 day date primary key, used integer not null default 0 check(used>=0), updated_at timestamptz not null default clock_timestamp()
);
create table sdi_private.spatter_usage_reservations (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 plan text not null check(plan in('free','creator','pro','unlimited')),
 -- What paid for the prompt: the plan allowance, the unlimited plan, or one credit.
 funding text not null check(funding in('allowance','unlimited','credit')),
 check(plan<>'free' or funding='credit'),
 buckets text[] not null, day date not null,
 state text not null default 'reserved' check(state in('reserved','committed','released')),
 units integer not null default 0 check(units between 0 and 1000000000),
 created_at timestamptz not null default clock_timestamp(), settled_at timestamptz
);
alter table sdi_private.spatter_usage_controls enable row level security;
alter table sdi_private.spatter_usage_counters enable row level security;
alter table sdi_private.spatter_usage_global enable row level security;
alter table sdi_private.spatter_usage_reservations enable row level security;
revoke all on sdi_private.spatter_usage_controls,sdi_private.spatter_usage_counters,sdi_private.spatter_usage_global,
 sdi_private.spatter_usage_reservations from public,anon,authenticated;
create index spatter_usage_reservations_open on sdi_private.spatter_usage_reservations(state,created_at);

-- Spatter credit packs: consumable store products the owner approves. No price
-- is stored; App Store Connect, Google Play and the Stripe dashboard own prices.
create table sdi_private.spatter_credit_packs (
 product_id text primary key check(length(product_id) between 1 and 200),
 provider text not null check(provider in('apple','stripe','google')),
 credits integer not null check(credits between 1 and 100000),
 approved boolean not null default false,
 updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default clock_timestamp()
);
-- Append-only credit ledger; the balance is sum(delta) and never negative.
-- Purchases and refunds are unique per (provider, provider_ref) so verified
-- provider events grant and claw back exactly once. livemode=false marks a
-- sandbox/test-mode grant; those never create finance_ledger rows.
create table sdi_private.spatter_credit_ledger (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 delta integer not null check(delta between -100000 and 100000),
 kind text not null check(kind in('purchase','spend','release','refund','admin_grant')),
 provider text check(provider in('apple','stripe','google')),
 provider_ref text check(provider_ref is null or length(provider_ref) between 1 and 200),
 product_id text check(product_id is null or length(product_id) between 1 and 200),
 reservation_id uuid references sdi_private.spatter_usage_reservations(id) on delete cascade,
 livemode boolean not null default true,
 shortfall integer not null default 0 check(shortfall between 0 and 100000),
 -- The owner who made an admin_grant. No foreign key: the ledger is append-only
 -- and an FK set-null would be an update.
 actor uuid,
 created_at timestamptz not null default clock_timestamp(),
 check(kind not in('purchase','refund') or (provider is not null and provider_ref is not null)),
 check(kind<>'purchase' or delta>0), check(kind<>'spend' or delta=-1), check(kind<>'release' or delta=1),
 check(kind<>'refund' or delta<=0), check(kind<>'admin_grant' or delta<>0),
 check(kind not in('spend','release') or reservation_id is not null),
 check(kind='refund' or shortfall=0)
);
create unique index spatter_credit_ledger_provider_once on sdi_private.spatter_credit_ledger(provider,provider_ref,kind) where kind in('purchase','refund');
create unique index spatter_credit_ledger_reservation_once on sdi_private.spatter_credit_ledger(reservation_id,kind) where reservation_id is not null;
create index spatter_credit_ledger_user on sdi_private.spatter_credit_ledger(user_id,created_at desc);
alter table sdi_private.spatter_credit_packs enable row level security;
alter table sdi_private.spatter_credit_ledger enable row level security;
revoke all on sdi_private.spatter_credit_packs,sdi_private.spatter_credit_ledger from public,anon,authenticated;
create function sdi_private.spatter_credit_balance(p_user uuid) returns integer language sql stable security definer set search_path='' as $$
 select coalesce(sum(l.delta),0)::integer from sdi_private.spatter_credit_ledger l where l.user_id=p_user
$$;
-- Append-only: no update; delete only through the account purge cascade (the
-- account row is already gone). Every insert must leave the balance >= 0.
create function sdi_private.spatter_credit_ledger_guard() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='UPDATE' then raise exception 'spatter_credit_ledger is append-only'; end if;
 if tg_op='DELETE' then
  if exists(select 1 from auth.users where id=old.user_id) then raise exception 'spatter_credit_ledger is append-only'; end if;
  return old;
 end if;
 if sdi_private.spatter_credit_balance(new.user_id)<0 then raise exception 'spatter credit balance cannot be negative'; end if;
 return new;
end $$;
create trigger spatter_credit_ledger_no_change before update or delete on sdi_private.spatter_credit_ledger
 for each row execute function sdi_private.spatter_credit_ledger_guard();
create trigger spatter_credit_ledger_non_negative after insert on sdi_private.spatter_credit_ledger
 for each row execute function sdi_private.spatter_credit_ledger_guard();

-- The app's suggested-prompt chips. Ids only: the labels and text live in
-- backend/spatter/suggested_prompts.py. A paid request may name one; an id not
-- on this list is refused. Free accounts are refused regardless (upgrade_required).
create function sdi_private.spatter_suggested_prompt_ids() returns text[] language sql immutable set search_path='' as $$
 select array['animation_tips','scene_ideas','fight_choreography','style_advice']::text[]
$$;

-- Server-funded prompts per billing period for a paid tier; null = no plan
-- allowance (unlimited) or no plan (anything else).
create function sdi_private.spatter_plan_period_limit(c sdi_private.spatter_usage_controls,p_tier text) returns integer
 language sql immutable set search_path='' as $$
 select case p_tier when 'creator' then c.creator_period_prompts when 'pro' then c.pro_period_prompts else null end
$$;

-- The account's current plan and allowance, without consuming anything. A paid
-- (non-trial) entitlement wins over a trial one; then the highest tier.
create function sdi_private.spatter_usage_plan(p_user uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c sdi_private.spatter_usage_controls; v_tier text; v_paid timestamptz; v_trial boolean; v_bucket text; v_limit integer; v_used integer;
 v_credits integer:=sdi_private.spatter_credit_balance(p_user);
begin
 select * into c from sdi_private.spatter_usage_controls;
 select e.tier,e.paid_through,e.in_trial into v_tier,v_paid,v_trial from sdi_private.entitlements e where e.user_id=p_user
  order by e.in_trial,sdi_private.billing_tier_rank(e.tier) desc,e.paid_through desc limit 1;
 if v_trial then
  -- Free trial only: Spatter is preview-only; nothing is funded and credits are not spent.
  return jsonb_build_object('plan',v_tier,'trial',true,'unlimited',false,'limit',0,'used',0,'remaining',0,'period','trial','resets_at',to_jsonb(v_paid),
   'credits',v_credits,'available',false,'upgrade','after_trial');
 elsif v_tier='unlimited' then
  return jsonb_build_object('plan','unlimited','trial',false,'unlimited',true,'limit',null,'used',null,'remaining',null,'period','none','resets_at',null,
   'credits',v_credits,'available',true);
 elsif v_tier in('creator','pro') then
  v_bucket:='period:'||to_char(v_paid at time zone 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_limit:=sdi_private.spatter_plan_period_limit(c,v_tier);
  select u.used into v_used from sdi_private.spatter_usage_counters u where u.user_id=p_user and u.bucket=v_bucket;
  v_used:=coalesce(v_used,0);
  return jsonb_build_object('plan',v_tier,'trial',false,'unlimited',false,'limit',v_limit,'used',v_used,'remaining',greatest(v_limit-v_used,0),
   'period','billing_period','resets_at',to_jsonb(v_paid),'credits',v_credits,'available',v_limit>v_used or v_credits>0,'bucket',v_bucket);
 end if;
 -- Free: no server-funded allowance; Spatter works only on purchased credits.
 return jsonb_build_object('plan','free','trial',false,'unlimited',false,'limit',0,'used',0,'remaining',0,'period','none','resets_at',null,
  'credits',v_credits,'available',v_credits>0,'upgrade','creator_or_pro');
end $$;

-- Service-only atomic reservation of one prompt. Every refusal carries a
-- stable code the handler maps to an HTTP status and an honest client message.
create function sdi_private.spatter_usage_reserve(p_user uuid,p_suggested_prompt text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare c sdi_private.spatter_usage_controls; p jsonb; v_day date:=(clock_timestamp() at time zone 'utc')::date;
 v_minute text:=to_char(date_trunc('minute',clock_timestamp() at time zone 'utc'),'YYYY-MM-DD"T"HH24:MI');
 g integer; d integer; m integer; v_buckets text[]; b text; rid uuid; v_funding text; v_credits integer;
begin
 if p_user is null or not exists(select 1 from auth.users where id=p_user) then
  return jsonb_build_object('allowed',false,'code','unauthorized'); end if;
 if exists(select 1 from sdi_private.account_controls where user_id=p_user and state<>'active') then
  return jsonb_build_object('allowed',false,'code','account_restricted'); end if;
 -- Free without credits (owner decisions 2026-10-15): nothing is funded, so
 -- the request is refused before any counter or reservation.
 if not exists(select 1 from sdi_private.entitlements where user_id=p_user and tier in('creator','pro','unlimited'))
  and sdi_private.spatter_credit_balance(p_user)<=0 then
  return jsonb_build_object('allowed',false,'code','upgrade_required','plan','free','upgrade','creator_or_pro','buy_credits',true,'credits',0); end if;
 -- Free trial only (owner decision 2026-10-20): the same refusal shape, before
 -- any counter, reservation or credit spend. Purchased credits wait for the trial to end.
 if exists(select 1 from sdi_private.entitlements where user_id=p_user and in_trial)
  and not exists(select 1 from sdi_private.entitlements where user_id=p_user and not in_trial) then
  p:=sdi_private.spatter_usage_plan(p_user);
  return jsonb_build_object('allowed',false,'code','upgrade_required','plan',p->>'plan','trial',true,'upgrade','after_trial',
   'resets_at',p->'resets_at','buy_credits',false,'credits',(p->>'credits')::integer); end if;
 if (select emergency_stop from sdi_private.agent_global) then
  return jsonb_build_object('allowed',false,'code','emergency_stop'); end if;
 if p_suggested_prompt is not null and not (p_suggested_prompt=any(sdi_private.spatter_suggested_prompt_ids())) then
  return jsonb_build_object('allowed',false,'code','unknown_suggested_prompt'); end if;
 select * into c from sdi_private.spatter_usage_controls;
 -- Serialize per account first, then lock the global day row; the order is fixed.
 perform pg_advisory_xact_lock(hashtextextended('sdi_spatter_usage:'||p_user::text,0));
 insert into sdi_private.spatter_usage_global(day) values(v_day) on conflict(day) do nothing;
 select used into g from sdi_private.spatter_usage_global where day=v_day for update;
 if g>=c.global_daily_cap then return jsonb_build_object('allowed',false,'code','global_limit'); end if;
 select coalesce((select used from sdi_private.spatter_usage_counters where user_id=p_user and bucket='minute:'||v_minute),0) into m;
 if m>=c.user_per_minute_cap then
  return jsonb_build_object('allowed',false,'code','rate_limited',
   'retry_after_seconds',greatest(1,60-floor(extract(second from clock_timestamp() at time zone 'utc'))::integer)); end if;
 select coalesce((select used from sdi_private.spatter_usage_counters where user_id=p_user and bucket='day:'||v_day::text),0) into d;
 if d>=c.user_daily_safety_cap then
  return jsonb_build_object('allowed',false,'code','daily_safety_limit','resets_at',(v_day+1)::timestamp at time zone 'utc'); end if;
 -- Funding order: plan allowance (unlimited, or the creator/pro period), then one credit.
 p:=sdi_private.spatter_usage_plan(p_user);
 v_credits:=(p->>'credits')::integer;
 if (p->>'trial')::boolean then
  return jsonb_build_object('allowed',false,'code','upgrade_required','plan',p->>'plan','trial',true,'upgrade','after_trial',
   'resets_at',p->'resets_at','buy_credits',false,'credits',v_credits);
 elsif (p->>'unlimited')::boolean then v_funding:='unlimited';
 elsif (p->>'remaining')::integer>0 then v_funding:='allowance';
 elsif v_credits>0 then v_funding:='credit';
 elsif p->>'plan'='free' then
  return jsonb_build_object('allowed',false,'code','upgrade_required','plan','free','upgrade','creator_or_pro','buy_credits',true,'credits',0);
 else
  return jsonb_build_object('allowed',false,'code','plan_allowance_exhausted','plan',p->>'plan','period',p->>'period','resets_at',p->'resets_at',
   'upgrade',case p->>'plan' when 'creator' then 'pro' else 'unlimited' end,'buy_credits',true,'credits',0); end if;
 v_buckets:=array['minute:'||v_minute,'day:'||v_day::text];
 if v_funding='allowance' then v_buckets:=v_buckets||(p->>'bucket'); end if;
 foreach b in array v_buckets loop
  insert into sdi_private.spatter_usage_counters as u(user_id,bucket,used) values(p_user,b,1)
   on conflict(user_id,bucket) do update set used=u.used+1,updated_at=clock_timestamp();
 end loop;
 update sdi_private.spatter_usage_global set used=used+1,updated_at=clock_timestamp() where day=v_day;
 insert into sdi_private.spatter_usage_reservations(user_id,plan,funding,buckets,day) values(p_user,p->>'plan',v_funding,v_buckets,v_day) returning id into rid;
 if v_funding='credit' then
  insert into sdi_private.spatter_credit_ledger(user_id,delta,kind,reservation_id) values(p_user,-1,'spend',rid);
  v_credits:=v_credits-1;
 end if;
 return jsonb_build_object('allowed',true,'reservation',rid,'plan',p->>'plan','period',p->>'period','funding',v_funding,
  'remaining',case v_funding when 'unlimited' then null when 'allowance' then to_jsonb((p->>'remaining')::integer-1) else to_jsonb((p->>'remaining')::integer) end,
  'credits',v_credits,'resets_at',p->'resets_at');
end $$;

-- Settle a reservation exactly once: 'commit' records provider units after a
-- delivered reply; 'release' refunds every counter (and a spent credit, as a
-- 'release' ledger row) after a provider failure.
create function sdi_private.spatter_usage_settle(p_reservation uuid,p_outcome text,p_units integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.spatter_usage_reservations; b text;
begin
 if p_outcome is null or p_outcome not in('commit','release') or p_units is null or p_units<0 then
  return jsonb_build_object('status','refused','reason','Invalid settlement.'); end if;
 select * into r from sdi_private.spatter_usage_reservations where id=p_reservation for update;
 if not found then return jsonb_build_object('status','refused','reason','Unknown reservation.'); end if;
 if r.state<>'reserved' then return jsonb_build_object('status','refused','reason','Reservation is already '||r.state||'.'); end if;
 if p_outcome='release' then
  foreach b in array r.buckets loop
   update sdi_private.spatter_usage_counters set used=greatest(used-1,0),updated_at=clock_timestamp() where user_id=r.user_id and bucket=b;
  end loop;
  update sdi_private.spatter_usage_global set used=greatest(used-1,0),updated_at=clock_timestamp() where day=r.day;
  if r.funding='credit' then
   insert into sdi_private.spatter_credit_ledger(user_id,delta,kind,reservation_id) values(r.user_id,1,'release',r.id);
  end if;
  update sdi_private.spatter_usage_reservations set state='released',settled_at=clock_timestamp() where id=r.id;
 else
  update sdi_private.spatter_usage_reservations set state='committed',units=p_units,settled_at=clock_timestamp() where id=r.id;
 end if;
 return jsonb_build_object('status','confirmed','state',case p_outcome when 'commit' then 'committed' else 'released' end);
end $$;

-- Expired rate buckets are pruned; day buckets are kept 400 days for audit.
-- Unsettled reservations older than 15 minutes stay counted (never refunded
-- silently) and are marked committed with zero units.
create function sdi_private.spatter_usage_sweep() returns integer language plpgsql security definer set search_path='' as $$
declare touched integer:=0; n integer;
begin
 delete from sdi_private.spatter_usage_counters where bucket like 'minute:%' and updated_at<clock_timestamp()-interval '2 hours';
 get diagnostics n=row_count; touched:=touched+n;
 delete from sdi_private.spatter_usage_counters where bucket like 'day:%' and updated_at<clock_timestamp()-interval '400 days';
 get diagnostics n=row_count; touched:=touched+n;
 update sdi_private.spatter_usage_reservations set state='committed',settled_at=clock_timestamp()
  where state='reserved' and created_at<clock_timestamp()-interval '15 minutes';
 get diagnostics n=row_count; touched:=touched+n;
 return touched;
end $$;

-- One service-only entry point for the handler: reserve | settle | sweep.
create function sdi_private.spatter_usage_meter(action text,p_user uuid default null,p_reservation uuid default null,
 p_outcome text default null,p_units integer default 0,p_suggested_prompt text default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if action='reserve' then return sdi_private.spatter_usage_reserve(p_user,p_suggested_prompt);
 elsif action='settle' then return sdi_private.spatter_usage_settle(p_reservation,p_outcome,p_units);
 elsif action='sweep' then return jsonb_build_object('touched',sdi_private.spatter_usage_sweep());
 end if;
 return jsonb_build_object('error','Unknown action.');
end $$;

-- Signed-in account's own allowance and credit balance for Settings.
create function sdi_private.spatter_my_usage() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Sign in to view your Spatter allowance.'); end if;
 return (sdi_private.spatter_usage_plan(auth.uid())-'bucket')
  ||jsonb_build_object('service',case when (select emergency_stop from sdi_private.agent_global) then 'paused' else 'metered' end);
end $$;

-- Owner/admin controls with audit. Reading needs overview; changing needs the owner.
create function sdi_private.spatter_usage_admin(action text,revision bigint default null,payload jsonb default '{}',reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare c sdi_private.spatter_usage_controls; is_owner boolean; v_day date:=(clock_timestamp() at time zone 'utc')::date; next_rev bigint;
begin
 if not sdi_private.admin_can('overview') or not sdi_private.account_active() then return jsonb_build_object('error','Current administrator MFA session required.'); end if;
 select r.owner into is_owner from sdi_private.admin_roles r where r.user_id=auth.uid() and r.enabled;
 select * into c from sdi_private.spatter_usage_controls;
 if action='get' then
  return jsonb_build_object('controls',to_jsonb(c)-'singleton'-'updated_by',
   'period_limits',jsonb_build_object('creator',sdi_private.spatter_plan_period_limit(c,'creator'),
    'pro',sdi_private.spatter_plan_period_limit(c,'pro'),'unlimited',null),
   'global_used_today',coalesce((select g.used from sdi_private.spatter_usage_global g where g.day=v_day),0),
   'committed_units_today',coalesce((select sum(r.units) from sdi_private.spatter_usage_reservations r where r.day=v_day and r.state='committed'),0),
   'emergency_stop',(select a.emergency_stop from sdi_private.agent_global a));
 elsif action='set' then
  if not coalesce(is_owner,false) then return jsonb_build_object('error','Only the owner can change Spatter limits.'); end if;
  if spatter_usage_admin.revision is distinct from c.revision then return jsonb_build_object('error','Limits changed elsewhere; reload.','revision',c.revision); end if;
  if length(trim(coalesce(spatter_usage_admin.reason,''))) not between 1 and 2000 then return jsonb_build_object('error','A reason is required.'); end if;
  if payload is null or jsonb_typeof(payload)<>'object' or exists(select 1 from jsonb_object_keys(payload) k
   where k not in('global_daily_cap','user_daily_safety_cap','user_per_minute_cap','creator_period_prompts','pro_period_prompts')) then
   return jsonb_build_object('error','Unknown limit.'); end if;
  begin
   update sdi_private.spatter_usage_controls u set
    global_daily_cap=coalesce((payload->>'global_daily_cap')::integer,u.global_daily_cap),
    user_daily_safety_cap=coalesce((payload->>'user_daily_safety_cap')::integer,u.user_daily_safety_cap),
    user_per_minute_cap=coalesce((payload->>'user_per_minute_cap')::integer,u.user_per_minute_cap),
    creator_period_prompts=coalesce((payload->>'creator_period_prompts')::integer,u.creator_period_prompts),
    pro_period_prompts=coalesce((payload->>'pro_period_prompts')::integer,u.pro_period_prompts),
    revision=c.revision+1,updated_by=auth.uid(),updated_at=clock_timestamp()
   returning u.revision into next_rev;
  exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
   return jsonb_build_object('error','A limit is outside its allowed range.');
  end;
  insert into sdi_private.agent_audit(actor,agent_key,action,reason)
   values(auth.uid(),'spatter_advice','set_usage_limits '||payload::text,trim(spatter_usage_admin.reason));
  return jsonb_build_object('status','confirmed','revision',next_rev);
 end if;
 return jsonb_build_object('error','Unknown action.');
end $$;

revoke all on function sdi_private.spatter_suggested_prompt_ids(),sdi_private.spatter_plan_period_limit(sdi_private.spatter_usage_controls,text),sdi_private.spatter_usage_plan(uuid),sdi_private.spatter_usage_reserve(uuid,text),sdi_private.spatter_usage_settle(uuid,text,integer),
 sdi_private.spatter_usage_sweep(),sdi_private.spatter_usage_meter(text,uuid,uuid,text,integer,text),sdi_private.spatter_my_usage(),
 sdi_private.spatter_usage_admin(text,bigint,jsonb,text) from public,anon,authenticated;
grant execute on function sdi_private.spatter_usage_meter(text,uuid,uuid,text,integer,text) to service_role;
grant execute on function sdi_private.spatter_my_usage(),sdi_private.spatter_usage_admin(text,bigint,jsonb,text) to authenticated;
create function public.sdi_spatter_usage_meter(action text,p_user uuid default null,p_reservation uuid default null,p_outcome text default null,p_units integer default 0,
 p_suggested_prompt text default null)
 returns jsonb language sql security invoker set search_path='' as $$select sdi_private.spatter_usage_meter(action,p_user,p_reservation,p_outcome,p_units,p_suggested_prompt)$$;
create function public.sdi_spatter_my_usage() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.spatter_my_usage()$$;
create function public.sdi_spatter_usage_admin(action text,revision bigint default null,payload jsonb default '{}',reason text default '') returns jsonb
 language sql security invoker set search_path='' as $$select sdi_private.spatter_usage_admin(action,revision,payload,reason)$$;
revoke all on function public.sdi_spatter_usage_meter(text,uuid,uuid,text,integer,text),public.sdi_spatter_my_usage(),
 public.sdi_spatter_usage_admin(text,bigint,jsonb,text) from public,anon,authenticated;
grant execute on function public.sdi_spatter_usage_meter(text,uuid,uuid,text,integer,text) to service_role;
grant execute on function public.sdi_spatter_my_usage(),public.sdi_spatter_usage_admin(text,bigint,jsonb,text) to authenticated;

-- ── Spatter credits: verified grants, refunds and owner administration ──────
-- Service-only. Called by backend/billing after a verified provider purchase
-- (Apple signed transaction, Stripe checkout.session.completed). Only approved
-- packs grant; a repeated transaction is a duplicate, never a second grant; a
-- transaction already refunded never grants. livemode=false (sandbox / Stripe
-- test mode) grants are allowed for testing and flagged on the ledger row.
create function sdi_private.spatter_credits_grant(p_user uuid,p_provider text,p_product_id text,p_transaction_ref text,p_livemode boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare pk sdi_private.spatter_credit_packs; v_id uuid;
begin
 if p_user is null or not exists(select 1 from auth.users where id=p_user) then
  return jsonb_build_object('status','refused','reason','Unknown account.'); end if;
 if p_provider is null or p_provider not in('apple','stripe','google') or p_transaction_ref is null
  or length(p_transaction_ref) not between 1 and 200 or p_livemode is null then
  return jsonb_build_object('status','refused','reason','Provider, transaction reference and mode are required.'); end if;
 select * into pk from sdi_private.spatter_credit_packs k where k.product_id=p_product_id and k.provider=p_provider and k.approved;
 if not found then return jsonb_build_object('status','refused','reason','Not an approved credit pack.'); end if;
 perform pg_advisory_xact_lock(hashtextextended('sdi_spatter_usage:'||p_user::text,0));
 if exists(select 1 from sdi_private.spatter_credit_ledger l where l.provider=p_provider and l.provider_ref=p_transaction_ref and l.kind='refund') then
  return jsonb_build_object('status','refused','reason','Transaction was refunded.'); end if;
 insert into sdi_private.spatter_credit_ledger(user_id,delta,kind,provider,provider_ref,product_id,livemode)
 values(p_user,pk.credits,'purchase',p_provider,p_transaction_ref,pk.product_id,p_livemode)
 on conflict(provider,provider_ref,kind) where kind in('purchase','refund') do nothing returning id into v_id;
 if v_id is null then
  return jsonb_build_object('status','duplicate','credits',sdi_private.spatter_credit_balance(p_user)); end if;
 return jsonb_build_object('status','granted','credits_added',pk.credits,'credits',sdi_private.spatter_credit_balance(p_user),'livemode',p_livemode);
end $$;

-- Service-only. A verified provider refund claws back the pack's credits up to
-- the remaining balance (the balance never goes negative); any credits already
-- spent are recorded as the shortfall on the refund row.
create function sdi_private.spatter_credits_refund(p_provider text,p_transaction_ref text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare buy sdi_private.spatter_credit_ledger; v_balance integer; v_claw integer;
begin
 if p_provider is null or p_transaction_ref is null then return jsonb_build_object('status','refused','reason','Provider and transaction reference are required.'); end if;
 select * into buy from sdi_private.spatter_credit_ledger l where l.provider=p_provider and l.provider_ref=p_transaction_ref and l.kind='purchase';
 if not found then return jsonb_build_object('status','ignored','reason','No credit purchase for this transaction.'); end if;
 perform pg_advisory_xact_lock(hashtextextended('sdi_spatter_usage:'||buy.user_id::text,0));
 if exists(select 1 from sdi_private.spatter_credit_ledger l where l.provider=p_provider and l.provider_ref=p_transaction_ref and l.kind='refund') then
  return jsonb_build_object('status','duplicate','credits',sdi_private.spatter_credit_balance(buy.user_id)); end if;
 v_balance:=sdi_private.spatter_credit_balance(buy.user_id);
 v_claw:=least(greatest(v_balance,0),buy.delta);
 insert into sdi_private.spatter_credit_ledger(user_id,delta,kind,provider,provider_ref,product_id,livemode,shortfall)
 values(buy.user_id,-v_claw,'refund',buy.provider,buy.provider_ref,buy.product_id,buy.livemode,buy.delta-v_claw);
 return jsonb_build_object('status','refunded','clawed_back',v_claw,'shortfall',buy.delta-v_claw,'credits',sdi_private.spatter_credit_balance(buy.user_id));
end $$;

-- Finance administrators read packs and a member's credit history; only the
-- owner, with a recent MFA step-up, approves packs or grants/removes credits.
-- Every mutation is written to finance_audit with a reason.
create function sdi_private.spatter_credit_admin(action text,product text default null,provider text default null,credits integer default null,
 approved boolean default null,member uuid default null,delta integer default null,reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare denial jsonb; items jsonb; v_balance integer;
begin
 denial:=sdi_private.admin_gate('spatter_credit_admin.'||coalesce(action,'?'),'finance',action in('set_pack','grant'),30);
 if denial is not null then return denial; end if;
 if action='packs' then
  select coalesce(jsonb_agg(row_to_json(k) order by k.provider,k.product_id),'[]'::jsonb) into items from sdi_private.spatter_credit_packs k;
  return jsonb_build_object('packs',items,'label','Credits per pack; prices live in the store dashboards.');
 elsif action='balance' then
  if member is null then return jsonb_build_object('error','Select the member.'); end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select l.id,l.delta,l.kind,l.provider,l.provider_ref,l.product_id,l.livemode,l.shortfall,l.created_at from sdi_private.spatter_credit_ledger l
   where l.user_id=member order by l.created_at desc,l.id limit 50) item;
  return jsonb_build_object('credits',sdi_private.spatter_credit_balance(member),'entries',items);
 end if;
 if action not in('set_pack','grant') then return jsonb_build_object('error','Unsupported credit operation.'); end if;
 if not exists(select 1 from sdi_private.admin_roles r where r.user_id=auth.uid() and r.enabled and r.owner) then
  return jsonb_build_object('error','Owner permission required.'); end if;
 if reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','A reason of at most 2000 characters is required.'); end if;
 if action='set_pack' then
  if product is null or length(trim(product)) not between 1 and 200 or provider is null or provider not in('apple','stripe','google')
   or credits is null or credits not between 1 and 100000 or approved is null then
   return jsonb_build_object('error','Product id, provider, credits (1 to 100000) and approval required.'); end if;
  insert into sdi_private.spatter_credit_packs(product_id,provider,credits,approved,updated_by,updated_at)
  values(trim(product),provider,credits,approved,auth.uid(),clock_timestamp())
  on conflict(product_id) do update set provider=excluded.provider,credits=excluded.credits,approved=excluded.approved,
   updated_by=excluded.updated_by,updated_at=excluded.updated_at;
  insert into sdi_private.finance_audit(actor,action,reason)
  values(auth.uid(),'set_credit_pack '||trim(product)||' provider='||provider||' credits='||credits||' approved='||approved,trim(spatter_credit_admin.reason));
  return jsonb_build_object('status','confirmed');
 end if;
 -- grant: a signed owner adjustment (goodwill credit or correction).
 if member is null or not exists(select 1 from auth.users u where u.id=member) or delta is null or delta=0 or delta not between -100000 and 100000 then
  return jsonb_build_object('error','Select the member and a non-zero credit change between -100000 and 100000.'); end if;
 perform pg_advisory_xact_lock(hashtextextended('sdi_spatter_usage:'||member::text,0));
 v_balance:=sdi_private.spatter_credit_balance(member);
 if v_balance+delta<0 then return jsonb_build_object('error','The balance cannot go below zero.','credits',v_balance); end if;
 insert into sdi_private.spatter_credit_ledger(user_id,delta,kind,actor) values(member,delta,'admin_grant',auth.uid());
 insert into sdi_private.finance_audit(actor,action,reason) values(auth.uid(),'grant_spatter_credits '||member||' '||delta,trim(spatter_credit_admin.reason));
 return jsonb_build_object('status','confirmed','credits',v_balance+delta);
end $$;

revoke all on function sdi_private.spatter_credit_balance(uuid),sdi_private.spatter_credit_ledger_guard(),
 sdi_private.spatter_credits_grant(uuid,text,text,text,boolean),sdi_private.spatter_credits_refund(text,text),
 sdi_private.spatter_credit_admin(text,text,text,integer,boolean,uuid,integer,text) from public,anon,authenticated;
grant execute on function sdi_private.spatter_credits_grant(uuid,text,text,text,boolean),sdi_private.spatter_credits_refund(text,text) to service_role;
grant execute on function sdi_private.spatter_credit_admin(text,text,text,integer,boolean,uuid,integer,text) to authenticated;
create function public.sdi_spatter_credits_grant(p_user uuid,p_provider text,p_product_id text,p_transaction_ref text,p_livemode boolean) returns jsonb
 language sql security invoker set search_path='' as $$select sdi_private.spatter_credits_grant(p_user,p_provider,p_product_id,p_transaction_ref,p_livemode)$$;
create function public.sdi_spatter_credits_refund(p_provider text,p_transaction_ref text) returns jsonb
 language sql security invoker set search_path='' as $$select sdi_private.spatter_credits_refund(p_provider,p_transaction_ref)$$;
create function public.sdi_spatter_credit_admin(action text,product text default null,provider text default null,credits integer default null,
 approved boolean default null,member uuid default null,delta integer default null,reason text default '') returns jsonb
 language sql security invoker set search_path='' as $$select sdi_private.spatter_credit_admin(action,product,provider,credits,approved,member,delta,reason)$$;
revoke all on function public.sdi_spatter_credits_grant(uuid,text,text,text,boolean),public.sdi_spatter_credits_refund(text,text),
 public.sdi_spatter_credit_admin(text,text,text,integer,boolean,uuid,integer,text) from public,anon,authenticated;
grant execute on function public.sdi_spatter_credits_grant(uuid,text,text,text,boolean),public.sdi_spatter_credits_refund(text,text) to service_role;
grant execute on function public.sdi_spatter_credit_admin(text,text,text,integer,boolean,uuid,integer,text) to authenticated;
commit;
