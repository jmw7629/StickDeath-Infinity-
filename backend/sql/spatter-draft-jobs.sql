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
commit;
