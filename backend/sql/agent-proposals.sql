-- Unapplied candidate. Install after spatter-draft-jobs.sql (needs agent-controls.sql
-- and admin-users.sql). Approval inbox for actions an agent proposes above its caps
-- (#284): a running agent with the `propose` permission files a proposal instead of
-- acting; only the owner approves or rejects it, with a reason and an audit row; the
-- service worker executes approved proposals and records the outcome; a pending
-- proposal expires after fourteen days. Nothing executes when a proposal is filed.
begin;
create table sdi_private.agent_proposals (
 id uuid primary key default gen_random_uuid(),
 agent_key text not null references sdi_private.agents(key) on delete cascade,
 run_id uuid references sdi_private.agent_runs(id) on delete set null,
 kind text not null check(kind ~ '^[a-z0-9_]{1,40}$'),
 summary text not null check(length(summary) between 1 and 500),
 payload jsonb not null default '{}' check(jsonb_typeof(payload)='object' and length(payload::text)<=16384),
 estimated_cost_minor bigint not null default 0 check(estimated_cost_minor>=0),
 cap_reason text not null check(length(cap_reason) between 1 and 200),
 state text not null default 'pending' check(state in('pending','approved','rejected','expired','executed','failed')),
 proposed_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default clock_timestamp()+interval '14 days',
 decided_by uuid references auth.users(id) on delete set null, decided_at timestamptz,
 decision_note text not null default '' check(length(decision_note)<=2000),
 executed_run uuid references sdi_private.agent_runs(id) on delete set null,
 outcome text not null default '' check(length(outcome)<=2000),
 revision bigint not null default 1
);
alter table sdi_private.agent_proposals enable row level security;
revoke all on sdi_private.agent_proposals from public,anon,authenticated;
create index agent_proposals_inbox on sdi_private.agent_proposals(state,proposed_at desc);
create index agent_proposals_agent on sdi_private.agent_proposals(agent_key,state);

-- Service: a live run files a proposal. Idempotent for an identical pending proposal.
create function sdi_private.agent_propose(run uuid,kind text,summary text,payload jsonb default '{}',
 estimated_cost_minor bigint default 0,cap_reason text default 'cap') returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare r sdi_private.agent_runs; a sdi_private.agents; p sdi_private.agent_proposals;
begin
 select * into r from sdi_private.agent_runs where id=run and state='running';
 if not found then return jsonb_build_object('error','A running agent run is required to propose.'); end if;
 select * into a from sdi_private.agents where key=r.agent_key;
 if a.paused or (select emergency_stop from sdi_private.agent_global) then return jsonb_build_object('error','Agent is paused.'); end if;
 if not ('propose' = any(a.permissions)) then return jsonb_build_object('error','This agent may not propose actions.'); end if;
 if kind is null or kind !~ '^[a-z0-9_]{1,40}$' or summary is null or length(trim(summary)) not between 1 and 500
  or payload is null or jsonb_typeof(payload)<>'object' or length(payload::text)>16384
  or estimated_cost_minor is null or estimated_cost_minor<0 or cap_reason is null or length(trim(cap_reason)) not between 1 and 200 then
  return jsonb_build_object('error','Proposal needs a kind, a summary, an object payload, a non-negative estimate and the cap it exceeds.'); end if;
 select * into p from sdi_private.agent_proposals where agent_key=a.key and state='pending' and agent_proposals.kind=agent_propose.kind
  and agent_proposals.payload=agent_propose.payload and expires_at>clock_timestamp() limit 1;
 if found then return jsonb_build_object('proposal',p.id,'state','pending','expires_at',p.expires_at,'duplicate',true); end if;
 if (select count(*) from sdi_private.agent_proposals where agent_key=a.key and state='pending' and expires_at>clock_timestamp())>=50 then
  return jsonb_build_object('error','This agent already has fifty pending proposals. Wait for owner decisions.'); end if;
 insert into sdi_private.agent_proposals(agent_key,run_id,kind,summary,payload,estimated_cost_minor,cap_reason)
  values(a.key,r.id,kind,trim(summary),payload,estimated_cost_minor,trim(cap_reason)) returning * into p;
 return jsonb_build_object('proposal',p.id,'state','pending','expires_at',p.expires_at);
end $$;

-- Service: expire stale proposals, then hand approved ones to the worker (oldest first).
create function sdi_private.agent_proposals_due(agent text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare items jsonb;
begin
 update sdi_private.agent_proposals set state='expired',revision=revision+1 where state='pending' and expires_at<=clock_timestamp();
 if (select emergency_stop from sdi_private.agent_global) then return jsonb_build_object('proposals','[]'::jsonb,'reason','Emergency stop is active.'); end if;
 select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
  select p.id,p.agent_key,p.kind,p.summary,p.payload,p.estimated_cost_minor,p.decided_at,p.decision_note,p.revision
  from sdi_private.agent_proposals p join sdi_private.agents a on a.key=p.agent_key
  where p.state='approved' and not a.paused and (agent is null or p.agent_key=agent)
  order by p.decided_at,p.id limit 20) item;
 return jsonb_build_object('proposals',items);
end $$;

-- Service: the executing run records the outcome of an approved proposal.
create function sdi_private.agent_proposal_finish(proposal uuid,run uuid,state text,outcome text default '') returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if state not in('executed','failed') then return false; end if;
 update sdi_private.agent_proposals p set state=agent_proposal_finish.state,executed_run=run,outcome=left(coalesce(agent_proposal_finish.outcome,''),2000),revision=p.revision+1
  where p.id=proposal and p.state='approved'
  and exists(select 1 from sdi_private.agent_runs r where r.id=run and r.state='running' and r.agent_key=p.agent_key);
 return found;
end $$;
revoke all on function sdi_private.agent_propose(uuid,text,text,jsonb,bigint,text),sdi_private.agent_proposals_due(text),
 sdi_private.agent_proposal_finish(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function sdi_private.agent_propose(uuid,text,text,jsonb,bigint,text),sdi_private.agent_proposals_due(text),
 sdi_private.agent_proposal_finish(uuid,uuid,text,text) to service_role;

-- Administrators read the inbox; only the owner decides, with a reason, audited.
create function sdi_private.agent_proposal_admin(action text,proposal uuid default null,revision bigint default null,
 reason text default '',agent text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare p sdi_private.agent_proposals; items jsonb; is_owner boolean;
begin
 if not sdi_private.admin_can('overview') or not sdi_private.account_active() then return jsonb_build_object('error','Current administrator MFA session required.'); end if;
 if action='inbox' then
  update sdi_private.agent_proposals set state='expired',revision=revision+1 where state='pending' and expires_at<=clock_timestamp();
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select pr.id,pr.agent_key,pr.kind,pr.summary,pr.payload,pr.estimated_cost_minor,pr.cap_reason,pr.state,pr.proposed_at,pr.expires_at,
    pr.decided_by,pr.decided_at,pr.decision_note,pr.outcome,pr.revision
   from sdi_private.agent_proposals pr where (agent is null or pr.agent_key=agent)
   order by case pr.state when 'pending' then 0 when 'approved' then 1 else 2 end,pr.proposed_at desc,pr.id limit 100) item;
  return jsonb_build_object('proposals',items,'pending',(select count(*) from sdi_private.agent_proposals where state='pending'));
 end if;
 select owner into is_owner from sdi_private.admin_roles where user_id=auth.uid() and enabled;
 if not coalesce(is_owner,false) then return jsonb_build_object('error','Owner permission required for proposal decisions.'); end if;
 if reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','A reason is required.'); end if;
 if action not in('approve','reject') then return jsonb_build_object('error','Unsupported proposal operation.'); end if;
 select * into p from sdi_private.agent_proposals where id=proposal for update;
 if not found or revision is distinct from p.revision then return jsonb_build_object('error','Proposal changed. Refresh before deciding.'); end if;
 if p.state<>'pending' then return jsonb_build_object('error','Only a pending proposal can be decided.'); end if;
 if p.expires_at<=clock_timestamp() then
  update sdi_private.agent_proposals set state='expired',revision=revision+1 where id=p.id;
  return jsonb_build_object('error','This proposal expired before a decision.'); end if;
 update sdi_private.agent_proposals set state=case action when 'approve' then 'approved' else 'rejected' end,
  decided_by=auth.uid(),decided_at=clock_timestamp(),decision_note=trim(reason),revision=revision+1 where id=p.id;
 insert into sdi_private.agent_audit(actor,agent_key,action,reason) values(auth.uid(),p.agent_key,'proposal_'||action||' '||p.id,trim(reason));
 return jsonb_build_object('status','confirmed','state',case action when 'approve' then 'approved' else 'rejected' end,'revision',p.revision+1);
end $$;
revoke all on function sdi_private.agent_proposal_admin(text,uuid,bigint,text,text) from public,anon;
grant execute on function sdi_private.agent_proposal_admin(text,uuid,bigint,text,text) to authenticated;

create function public.sdi_agent_propose(run uuid,kind text,summary text,payload jsonb default '{}',estimated_cost_minor bigint default 0,cap_reason text default 'cap') returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.agent_propose(run,kind,summary,payload,estimated_cost_minor,cap_reason)$$;
create function public.sdi_agent_proposals_due(agent text default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.agent_proposals_due(agent)$$;
create function public.sdi_agent_proposal_finish(proposal uuid,run uuid,state text,outcome text default '') returns boolean
language sql security invoker set search_path='' as $$select sdi_private.agent_proposal_finish(proposal,run,state,outcome)$$;
revoke all on function public.sdi_agent_propose(uuid,text,text,jsonb,bigint,text),public.sdi_agent_proposals_due(text),
 public.sdi_agent_proposal_finish(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.sdi_agent_propose(uuid,text,text,jsonb,bigint,text),public.sdi_agent_proposals_due(text),
 public.sdi_agent_proposal_finish(uuid,uuid,text,text) to service_role;
create function public.sdi_agent_proposal_admin(action text,proposal uuid default null,revision bigint default null,reason text default '',agent text default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.agent_proposal_admin(action,proposal,revision,reason,agent)$$;
revoke all on function public.sdi_agent_proposal_admin(text,uuid,bigint,text,text) from public,anon;
grant execute on function public.sdi_agent_proposal_admin(text,uuid,bigint,text,text) to authenticated;
commit;
