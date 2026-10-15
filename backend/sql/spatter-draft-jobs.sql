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
declare j sdi_private.spatter_draft_jobs; review uuid; creator uuid;
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
  creator:=(p_review->>'creator')::uuid;
  insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,
   destinations,spatter_generated,storyboard,source_project_digest)
  values(creator,left(coalesce(p_review->>'title','Spatter daily draft '||j.target_date::text),200),coalesce(p_review->>'source_revision','draft:'||j.target_date::text),
   p_sha,p_review->>'preview_url',coalesce((p_review->>'preview_expires_at')::timestamptz,clock_timestamp()+interval '7 days'),
   coalesce(p_review->>'consent_version','spatter-draft-v1'),coalesce(p_review->>'rights_summary','Independently generated stick-figure content; no external source material.'),
   coalesce((p_review->>'rights_cleared')::boolean,true),'{}'::text[],true,p_storyboard,p_review->>'source_project_digest')
  returning id into review;
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
--   server never spends anything for a Free account. Every Free request is
--   refused with the stable code 'upgrade_required' (plan 'free', upgrade
--   'creator_or_pro') before any counter, reservation or provider call. The
--   former Free allowance (5 suggested prompts per calendar month, column
--   free_prompts and 'month:'/'free' buckets) is retired; this file was never
--   applied, so the column and buckets are removed rather than left unused.
-- * Creator (USD 4.99/month): prompts a member sends with their own AI key go
--   device-to-provider and never reach this meter. The server-funded allowance
--   per billing period is a cost model that keeps the plan within break-even:
--   limit = floor(creator_period_budget_microusd / prompt_cost_estimate_microusd).
--   The budget defaults to 3490000 (USD 4.99 net of a 30% store commission,
--   rounded down) and may never exceed the gross price 4990000; the per-prompt
--   estimate defaults to 20000 (USD 0.02), a conservative owner-editable figure.
--   Defaults give 174 prompts per period, keyed to the subscription's
--   paid_through so a renewal starts a new period.
-- * Pro (USD 9.99/month): no plan allowance, but still obeys the per-user daily
--   safety cap, the per-minute rate, the global daily ceiling and the agent
--   emergency stop.
-- A 'trialing' subscription maps to its own tier through
-- sdi_private.entitlements. The global ceiling defaults to 0 (closed) so
-- nothing can be spent until the owner sets it. One unit is one prompt;
-- provider-reported usage units (tokens, not money) are recorded on the
-- reservation when the handler commits it. Actual provider cost is not
-- recorded: the provider contract returns usage units only, so the
-- per-prompt estimate stays the owner's control on spend.
create table sdi_private.spatter_usage_controls (
 singleton boolean primary key default true check(singleton),
 global_daily_cap integer not null default 0 check(global_daily_cap between 0 and 10000000),
 user_daily_safety_cap integer not null default 100 check(user_daily_safety_cap between 0 and 10000),
 user_per_minute_cap integer not null default 6 check(user_per_minute_cap between 1 and 600),
 creator_period_budget_microusd integer not null default 3490000 check(creator_period_budget_microusd between 0 and 4990000),
 prompt_cost_estimate_microusd integer not null default 20000 check(prompt_cost_estimate_microusd between 1 and 4990000),
 revision bigint not null default 1, updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default clock_timestamp()
);
insert into sdi_private.spatter_usage_controls(singleton) values(true);
-- One row per (account, bucket). Buckets: 'period:<paid_through>' (creator
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
 plan text not null check(plan in('creator','pro')),
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

-- The app's suggested-prompt chips. Ids only: the labels and text live in
-- backend/spatter/suggested_prompts.py. A paid request may name one; an id not
-- on this list is refused. Free accounts are refused regardless (upgrade_required).
create function sdi_private.spatter_suggested_prompt_ids() returns text[] language sql immutable set search_path='' as $$
 select array['animation_tips','scene_ideas','fight_choreography','style_advice']::text[]
$$;

-- Creator's server-funded prompts per billing period: the break-even budget
-- divided by the owner's per-prompt cost estimate, rounded down.
create function sdi_private.spatter_creator_period_limit(c sdi_private.spatter_usage_controls) returns integer
 language sql immutable set search_path='' as $$select (c.creator_period_budget_microusd/c.prompt_cost_estimate_microusd)::integer$$;

-- The account's current plan and allowance, without consuming anything.
create function sdi_private.spatter_usage_plan(p_user uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c sdi_private.spatter_usage_controls; v_tier text; v_paid timestamptz; v_bucket text; v_limit integer; v_used integer;
begin
 select * into c from sdi_private.spatter_usage_controls;
 select tier,paid_through into v_tier,v_paid from sdi_private.entitlements where user_id=p_user
  order by case tier when 'pro' then 0 else 1 end,paid_through desc limit 1;
 if v_tier='pro' then
  return jsonb_build_object('plan','pro','unlimited',true,'limit',null,'used',null,'remaining',null,'period','none','resets_at',null);
 elsif v_tier='creator' then
  v_bucket:='period:'||to_char(v_paid at time zone 'utc','YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_limit:=sdi_private.spatter_creator_period_limit(c);
  select u.used into v_used from sdi_private.spatter_usage_counters u where u.user_id=p_user and u.bucket=v_bucket;
  v_used:=coalesce(v_used,0);
  return jsonb_build_object('plan','creator','unlimited',false,'limit',v_limit,'used',v_used,'remaining',greatest(v_limit-v_used,0),
   'period','billing_period','resets_at',to_jsonb(v_paid),'bucket',v_bucket);
 end if;
 -- Free: Spatter is visible but not served; nothing is ever allotted or counted.
 return jsonb_build_object('plan','free','unlimited',false,'limit',0,'used',0,'remaining',0,'period','none','resets_at',null,
  'available',false,'upgrade','creator_or_pro');
end $$;

-- Service-only atomic reservation of one prompt. Every refusal carries a
-- stable code the handler maps to an HTTP status and an honest client message.
create function sdi_private.spatter_usage_reserve(p_user uuid,p_suggested_prompt text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare c sdi_private.spatter_usage_controls; p jsonb; v_day date:=(clock_timestamp() at time zone 'utc')::date;
 v_minute text:=to_char(date_trunc('minute',clock_timestamp() at time zone 'utc'),'YYYY-MM-DD"T"HH24:MI');
 g integer; d integer; m integer; v_buckets text[]; b text; rid uuid;
begin
 if p_user is null or not exists(select 1 from auth.users where id=p_user) then
  return jsonb_build_object('allowed',false,'code','unauthorized'); end if;
 if exists(select 1 from sdi_private.account_controls where user_id=p_user and state<>'active') then
  return jsonb_build_object('allowed',false,'code','account_restricted'); end if;
 -- Free (owner decision 2026-10-15): Spatter is visible but never served, so
 -- nothing is spent; refused before any counter or reservation.
 if not exists(select 1 from sdi_private.entitlements where user_id=p_user and tier in('creator','pro')) then
  return jsonb_build_object('allowed',false,'code','upgrade_required','plan','free','upgrade','creator_or_pro'); end if;
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
 p:=sdi_private.spatter_usage_plan(p_user);
 if not (p->>'unlimited')::boolean and (p->>'remaining')::integer<=0 then
  return jsonb_build_object('allowed',false,'code','plan_allowance_exhausted','plan',p->>'plan','period',p->>'period','resets_at',p->'resets_at',
   'upgrade','pro'); end if;
 v_buckets:=array['minute:'||v_minute,'day:'||v_day::text];
 if p->>'bucket' is not null then v_buckets:=v_buckets||(p->>'bucket'); end if;
 foreach b in array v_buckets loop
  insert into sdi_private.spatter_usage_counters as u(user_id,bucket,used) values(p_user,b,1)
   on conflict(user_id,bucket) do update set used=u.used+1,updated_at=clock_timestamp();
 end loop;
 update sdi_private.spatter_usage_global set used=used+1,updated_at=clock_timestamp() where day=v_day;
 insert into sdi_private.spatter_usage_reservations(user_id,plan,buckets,day) values(p_user,p->>'plan',v_buckets,v_day) returning id into rid;
 return jsonb_build_object('allowed',true,'reservation',rid,'plan',p->>'plan','period',p->>'period',
  'remaining',case when (p->>'unlimited')::boolean then null else to_jsonb((p->>'remaining')::integer-1) end,'resets_at',p->'resets_at');
end $$;

-- Settle a reservation exactly once: 'commit' records provider units after a
-- delivered reply; 'release' refunds every counter after a provider failure.
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

-- Signed-in account's own allowance for Settings ("remaining prompts").
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
   'creator_period_limit',sdi_private.spatter_creator_period_limit(c),
   'global_used_today',coalesce((select g.used from sdi_private.spatter_usage_global g where g.day=v_day),0),
   'committed_units_today',coalesce((select sum(r.units) from sdi_private.spatter_usage_reservations r where r.day=v_day and r.state='committed'),0),
   'emergency_stop',(select a.emergency_stop from sdi_private.agent_global a));
 elsif action='set' then
  if not coalesce(is_owner,false) then return jsonb_build_object('error','Only the owner can change Spatter limits.'); end if;
  if spatter_usage_admin.revision is distinct from c.revision then return jsonb_build_object('error','Limits changed elsewhere; reload.','revision',c.revision); end if;
  if length(trim(coalesce(spatter_usage_admin.reason,''))) not between 1 and 2000 then return jsonb_build_object('error','A reason is required.'); end if;
  if payload is null or jsonb_typeof(payload)<>'object' or exists(select 1 from jsonb_object_keys(payload) k
   where k not in('global_daily_cap','user_daily_safety_cap','user_per_minute_cap','creator_period_budget_microusd','prompt_cost_estimate_microusd')) then
   return jsonb_build_object('error','Unknown limit.'); end if;
  begin
   update sdi_private.spatter_usage_controls u set
    global_daily_cap=coalesce((payload->>'global_daily_cap')::integer,u.global_daily_cap),
    user_daily_safety_cap=coalesce((payload->>'user_daily_safety_cap')::integer,u.user_daily_safety_cap),
    user_per_minute_cap=coalesce((payload->>'user_per_minute_cap')::integer,u.user_per_minute_cap),
    creator_period_budget_microusd=coalesce((payload->>'creator_period_budget_microusd')::integer,u.creator_period_budget_microusd),
    prompt_cost_estimate_microusd=coalesce((payload->>'prompt_cost_estimate_microusd')::integer,u.prompt_cost_estimate_microusd),
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

revoke all on function sdi_private.spatter_suggested_prompt_ids(),sdi_private.spatter_creator_period_limit(sdi_private.spatter_usage_controls),sdi_private.spatter_usage_plan(uuid),sdi_private.spatter_usage_reserve(uuid,text),sdi_private.spatter_usage_settle(uuid,text,integer),
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
commit;
