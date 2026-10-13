-- Unapplied candidate. Install after billing.sql (needs admin-approval.sql, admin-users.sql).
-- Owner controls for automated agents (Spatter daily drafts, moderation sweeps,
-- support triage, finance reconciliation, marketing proposals): registry, pause,
-- global emergency stop, per-agent caps and permissions, versioned instructions
-- with rollback, and a run log with heartbeats. Agents call the service functions
-- before and after each run; a refused run must not do any work. Spending caps
-- are configuration in minor currency units, not charges; nothing here spends.
begin;
create table sdi_private.agents (
 key text primary key check(key ~ '^[a-z0-9_]{1,40}$'), title text not null check(length(title) between 1 and 100),
 paused boolean not null default true, permissions text[] not null default array['read'] check(permissions <@ array['read','write','propose']),
 daily_run_cap integer not null default 24 check(daily_run_cap between 0 and 1440), per_run_item_cap integer not null default 10 check(per_run_item_cap between 0 and 10000),
 monthly_cost_cap_minor bigint not null default 0 check(monthly_cost_cap_minor>=0), active_instruction_version integer,
 revision bigint not null default 1, updated_at timestamptz not null default clock_timestamp()
);
create table sdi_private.agent_global (
 singleton boolean primary key default true check(singleton), emergency_stop boolean not null default false,
 reason text not null default '', updated_by uuid references auth.users(id), updated_at timestamptz not null default clock_timestamp()
);
insert into sdi_private.agent_global(singleton) values(true);
create table sdi_private.agent_instructions (
 id uuid primary key default gen_random_uuid(), agent_key text not null references sdi_private.agents(key) on delete cascade,
 version integer not null check(version>0), body text not null check(length(body) between 1 and 20000),
 author uuid not null references auth.users(id), created_at timestamptz not null default clock_timestamp(), unique(agent_key,version)
);
create table sdi_private.agent_runs (
 id uuid primary key default gen_random_uuid(), agent_key text not null references sdi_private.agents(key),
 instruction_version integer, source_ref text not null default '' check(length(source_ref)<=200),
 started_at timestamptz not null default clock_timestamp(), heartbeat_at timestamptz not null default clock_timestamp(), finished_at timestamptz,
 state text not null default 'running' check(state in('running','succeeded','failed','stopped')),
 items integer not null default 0 check(items>=0), cost_minor bigint not null default 0 check(cost_minor>=0), error text not null default '' check(length(error)<=2000)
);
create table sdi_private.agent_audit (
 id uuid primary key default gen_random_uuid(), actor uuid not null references auth.users(id), agent_key text,
 action text not null, reason text not null check(length(reason) between 1 and 2000), created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.agents enable row level security;
alter table sdi_private.agent_global enable row level security;
alter table sdi_private.agent_instructions enable row level security;
alter table sdi_private.agent_runs enable row level security;
alter table sdi_private.agent_audit enable row level security;
revoke all on sdi_private.agents,sdi_private.agent_global,sdi_private.agent_instructions,sdi_private.agent_runs,sdi_private.agent_audit from public,anon,authenticated;
create index agent_runs_recent on sdi_private.agent_runs(agent_key,started_at desc);
-- Registry rows start paused; the owner enables each agent deliberately.
insert into sdi_private.agents(key,title) values
 ('spatter_daily_video','Spatter daily draft generation'),('moderation_sweep','Moderation queue summaries'),
 ('support_triage','Support request triage'),('finance_reconcile','Billing reconciliation'),('marketing_proposals','Marketing proposals (approval only)');

create function sdi_private.agent_admin(action text,agent text default null,revision bigint default null,payload jsonb default '{}',reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare a sdi_private.agents; items jsonb; is_owner boolean; next_version integer; target_version integer;
begin
 if not sdi_private.admin_can('overview') or not sdi_private.account_active() then return jsonb_build_object('error','Current administrator MFA session required.'); end if;
 select owner into is_owner from sdi_private.admin_roles where user_id=auth.uid() and enabled;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item) order by item.key),'[]'::jsonb) into items from (
   select ag.key,ag.title,ag.paused,ag.permissions,ag.daily_run_cap,ag.per_run_item_cap,ag.monthly_cost_cap_minor,ag.active_instruction_version,ag.revision,
    (select count(*) from sdi_private.agent_runs r where r.agent_key=ag.key and r.state='running') as running,
    (select max(r.finished_at) from sdi_private.agent_runs r where r.agent_key=ag.key) as last_finished,
    (select count(*) from sdi_private.agent_runs r where r.agent_key=ag.key and r.state='failed' and r.started_at>clock_timestamp()-interval '7 days') as failures_7d,
    (select coalesce(sum(r.cost_minor),0) from sdi_private.agent_runs r where r.agent_key=ag.key and r.started_at>=date_trunc('month',clock_timestamp())) as cost_month_minor,
    (select count(*) from sdi_private.agent_runs r where r.agent_key=ag.key and r.started_at>=date_trunc('day',clock_timestamp())) as runs_today
   from sdi_private.agents ag) item;
  return jsonb_build_object('agents',items,'emergency_stop',(select emergency_stop from sdi_private.agent_global),'emergency_reason',(select reason from sdi_private.agent_global));
 elsif action='runs' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select r.id,r.agent_key,r.instruction_version,r.source_ref,r.started_at,r.heartbeat_at,r.finished_at,r.state,r.items,r.cost_minor,r.error
   from sdi_private.agent_runs r where agent is null or r.agent_key=agent order by r.started_at desc,r.id limit 100) item;
  return jsonb_build_object('runs',items);
 elsif action='instructions' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select i.version,i.body,i.author,i.created_at from sdi_private.agent_instructions i where i.agent_key=agent order by i.version desc limit 50) item;
  return jsonb_build_object('instructions',items,'active',(select active_instruction_version from sdi_private.agents where key=agent));
 end if;
 if not coalesce(is_owner,false) then return jsonb_build_object('error','Owner permission required for agent changes.'); end if;
 if reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','A reason is required.'); end if;
 if action='emergency_stop' then
  if payload->>'enabled' is null then return jsonb_build_object('error','Specify enabled true or false.'); end if;
  update sdi_private.agent_global set emergency_stop=(payload->>'enabled')::boolean,reason=trim(agent_admin.reason),updated_by=auth.uid(),updated_at=clock_timestamp();
  if (payload->>'enabled')::boolean then
   update sdi_private.agent_runs set state='stopped',finished_at=clock_timestamp(),error='Emergency stop.' where state='running';
  end if;
  insert into sdi_private.agent_audit(actor,action,reason) values(auth.uid(),'emergency_stop '||(payload->>'enabled'),trim(agent_admin.reason));
  return jsonb_build_object('status','confirmed');
 end if;
 select * into a from sdi_private.agents where key=agent for update;
 if not found or revision is distinct from a.revision then return jsonb_build_object('error','Agent changed. Refresh before saving.'); end if;
 if action='pause' then update sdi_private.agents set paused=true where key=a.key;
  update sdi_private.agent_runs set state='stopped',finished_at=clock_timestamp(),error='Paused by owner.' where agent_key=a.key and state='running';
 elsif action='resume' then
  if (select emergency_stop from sdi_private.agent_global) then return jsonb_build_object('error','Clear the emergency stop first.'); end if;
  if a.active_instruction_version is null then return jsonb_build_object('error','Publish instructions before resuming this agent.'); end if;
  update sdi_private.agents set paused=false where key=a.key;
 elsif action='set_caps' then
  if (payload->>'daily_run_cap') !~ '^[0-9]{1,4}$' or (payload->>'per_run_item_cap') !~ '^[0-9]{1,5}$' or (payload->>'monthly_cost_cap_minor') !~ '^[0-9]{1,12}$' then
   return jsonb_build_object('error','Provide numeric daily run, per-run item and monthly cost caps.'); end if;
  update sdi_private.agents set daily_run_cap=(payload->>'daily_run_cap')::integer,per_run_item_cap=(payload->>'per_run_item_cap')::integer,
   monthly_cost_cap_minor=(payload->>'monthly_cost_cap_minor')::bigint where key=a.key;
 elsif action='set_permissions' then
  if jsonb_typeof(payload->'permissions')<>'array' or not (select coalesce(array_agg(v),'{}') from jsonb_array_elements_text(payload->'permissions') v) <@ array['read','write','propose'] then
   return jsonb_build_object('error','Permissions must be a subset of read, write, propose.'); end if;
  update sdi_private.agents set permissions=(select coalesce(array_agg(distinct v order by v),'{}') from jsonb_array_elements_text(payload->'permissions') v) where key=a.key;
 elsif action='publish_instructions' then
  if length(coalesce(payload->>'body',''))not between 1 and 20000 then return jsonb_build_object('error','Instruction text of at most 20000 characters is required.'); end if;
  select coalesce(max(version),0)+1 into next_version from sdi_private.agent_instructions where agent_key=a.key;
  insert into sdi_private.agent_instructions(agent_key,version,body,author) values(a.key,next_version,payload->>'body',auth.uid());
  update sdi_private.agents set active_instruction_version=next_version where key=a.key;
 elsif action='rollback_instructions' then
  target_version:=(payload->>'version')::integer;
  if not exists(select 1 from sdi_private.agent_instructions where agent_key=a.key and version=target_version) then return jsonb_build_object('error','Unknown instruction version.'); end if;
  update sdi_private.agents set active_instruction_version=target_version where key=a.key;
 else return jsonb_build_object('error','Unsupported agent operation.'); end if;
 update sdi_private.agents set revision=revision+1,updated_at=clock_timestamp() where key=a.key;
 insert into sdi_private.agent_audit(actor,agent_key,action,reason) values(auth.uid(),a.key,agent_admin.action,trim(agent_admin.reason));
 return jsonb_build_object('status','confirmed','revision',a.revision+1);
end $$;
revoke all on function sdi_private.agent_admin(text,text,bigint,jsonb,text) from public,anon;
grant execute on function sdi_private.agent_admin(text,text,bigint,jsonb,text) to authenticated;
create function public.sdi_agent_admin(action text,agent text default null,revision bigint default null,payload jsonb default '{}',reason text default '') returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.agent_admin(action,agent,revision,payload,reason)$$;
revoke all on function public.sdi_agent_admin(text,text,bigint,jsonb,text) from public,anon;
grant execute on function public.sdi_agent_admin(text,text,bigint,jsonb,text) to authenticated;

-- Service contract: begin → (heartbeat)* → finish. A refusal carries the reason.
create function sdi_private.agent_run_begin(agent text,source_ref text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare a sdi_private.agents; run uuid; spent bigint; body text;
begin
 select * into a from sdi_private.agents where key=agent for update;
 if not found then return jsonb_build_object('allowed',false,'reason','Unknown agent.'); end if;
 if (select emergency_stop from sdi_private.agent_global) then return jsonb_build_object('allowed',false,'reason','Emergency stop is active.'); end if;
 if a.paused then return jsonb_build_object('allowed',false,'reason','Agent is paused.'); end if;
 if a.active_instruction_version is null then return jsonb_build_object('allowed',false,'reason','No published instructions.'); end if;
 update sdi_private.agent_runs set state='failed',finished_at=clock_timestamp(),error='Heartbeat lost.' where agent_key=a.key and state='running' and heartbeat_at<clock_timestamp()-interval '15 minutes';
 if exists(select 1 from sdi_private.agent_runs where agent_key=a.key and state='running') then return jsonb_build_object('allowed',false,'reason','A run is already in progress.'); end if;
 if (select count(*) from sdi_private.agent_runs where agent_key=a.key and started_at>=date_trunc('day',clock_timestamp()))>=a.daily_run_cap then
  return jsonb_build_object('allowed',false,'reason','Daily run cap reached.'); end if;
 select coalesce(sum(cost_minor),0) into spent from sdi_private.agent_runs where agent_key=a.key and started_at>=date_trunc('month',clock_timestamp());
 if spent>=a.monthly_cost_cap_minor then return jsonb_build_object('allowed',false,'reason','Monthly cost cap reached.'); end if;
 select i.body into body from sdi_private.agent_instructions i where i.agent_key=a.key and i.version=a.active_instruction_version;
 insert into sdi_private.agent_runs(agent_key,instruction_version,source_ref) values(a.key,a.active_instruction_version,left(coalesce(source_ref,''),200)) returning id into run;
 return jsonb_build_object('allowed',true,'run',run,'instructions',body,'instruction_version',a.active_instruction_version,
  'permissions',to_jsonb(a.permissions),'per_run_item_cap',a.per_run_item_cap,'remaining_cost_minor',a.monthly_cost_cap_minor-spent);
end $$;
create function sdi_private.agent_run_heartbeat(run uuid) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if (select emergency_stop from sdi_private.agent_global) then return false; end if;
 update sdi_private.agent_runs r set heartbeat_at=clock_timestamp() where r.id=run and r.state='running'
  and not exists(select 1 from sdi_private.agents a where a.key=r.agent_key and a.paused);
 return found;
end $$;
create function sdi_private.agent_run_finish(run uuid,state text,items integer default 0,cost_minor bigint default 0,error text default '') returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if state not in('succeeded','failed','stopped') or items is null or items<0 or cost_minor is null or cost_minor<0 then return false; end if;
 update sdi_private.agent_runs r set state=agent_run_finish.state,items=agent_run_finish.items,cost_minor=agent_run_finish.cost_minor,
  error=left(coalesce(agent_run_finish.error,''),2000),finished_at=clock_timestamp() where r.id=run and r.state='running';
 return found;
end $$;
revoke all on function sdi_private.agent_run_begin(text,text),sdi_private.agent_run_heartbeat(uuid),sdi_private.agent_run_finish(uuid,text,integer,bigint,text) from public,anon,authenticated;
grant execute on function sdi_private.agent_run_begin(text,text),sdi_private.agent_run_heartbeat(uuid),sdi_private.agent_run_finish(uuid,text,integer,bigint,text) to service_role;
create function public.sdi_agent_run_begin(agent text,source_ref text default '') returns jsonb language sql security invoker set search_path='' as $$select sdi_private.agent_run_begin(agent,source_ref)$$;
create function public.sdi_agent_run_heartbeat(run uuid) returns boolean language sql security invoker set search_path='' as $$select sdi_private.agent_run_heartbeat(run)$$;
create function public.sdi_agent_run_finish(run uuid,state text,items integer default 0,cost_minor bigint default 0,error text default '') returns boolean
language sql security invoker set search_path='' as $$select sdi_private.agent_run_finish(run,state,items,cost_minor,error)$$;
revoke all on function public.sdi_agent_run_begin(text,text),public.sdi_agent_run_heartbeat(uuid),public.sdi_agent_run_finish(uuid,text,integer,bigint,text) from public,anon,authenticated;
grant execute on function public.sdi_agent_run_begin(text,text),public.sdi_agent_run_heartbeat(uuid),public.sdi_agent_run_finish(uuid,text,integer,bigint,text) to service_role;
commit;
