-- Unapplied candidate. Install after agent-controls.sql (needs admin-approval.sql,
-- admin-permissions.sql, admin-users.sql). Adds step-up (recent MFA) checks for
-- sensitive administration, per-administrator rate limits with a denial audit, a
-- service-only owner provisioning function that takes no password, worker heartbeats
-- and an authenticated health view that exposes queue state but no host details.
begin;
-- Step-up: the JWT 'amr' claims carry the time of each authentication method. A
-- sensitive action needs an MFA method verified within the window; the client
-- performs an MFA challenge/verify to refresh it. No client-supplied flag is trusted.
create function sdi_private.recently_authenticated(max_age interval default interval '15 minutes') returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr','[]'::jsonb)) e
  where e->>'method' in('totp','webauthn','phone','mfa/totp','mfa/phone','mfa/webauthn')
  and (e->>'timestamp') ~ '^[0-9]{1,12}$' and to_timestamp((e->>'timestamp')::bigint)>clock_timestamp()-max_age)
$$;
revoke all on function sdi_private.recently_authenticated(interval) from public,anon;
grant execute on function sdi_private.recently_authenticated(interval) to authenticated;
create table sdi_private.admin_budget (
 user_id uuid primary key references auth.users(id) on delete cascade, window_start timestamptz not null, attempts integer not null
);
create table sdi_private.admin_access_audit (
 id uuid primary key default gen_random_uuid(), actor uuid, operation text not null, allowed boolean not null,
 detail text not null default '' check(length(detail)<=200), created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.admin_budget enable row level security;
alter table sdi_private.admin_access_audit enable row level security;
revoke all on sdi_private.admin_budget,sdi_private.admin_access_audit from public,anon,authenticated;
create index admin_access_audit_recent on sdi_private.admin_access_audit(created_at desc);
create function sdi_private.admin_rate_ok(limit_per_minute integer default 60) returns boolean language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if auth.uid() is null then return false; end if;
 insert into sdi_private.admin_budget values(auth.uid(),clock_timestamp(),1)
 on conflict(user_id) do update set
 attempts=case when admin_budget.window_start<clock_timestamp()-interval '1 minute' then 1 else admin_budget.attempts+1 end,
 window_start=case when admin_budget.window_start<clock_timestamp()-interval '1 minute' then clock_timestamp() else admin_budget.window_start end
 returning attempts into n;
 return n<=limit_per_minute;
end $$;
revoke all on function sdi_private.admin_rate_ok(integer) from public,anon;
grant execute on function sdi_private.admin_rate_ok(integer) to authenticated;
-- One gate for administrative RPCs: capability + MFA + live session, optional
-- step-up, rate limit, and an audit row for every denial. Returns null when allowed.
create function sdi_private.admin_gate(operation text,capability text,sensitive boolean default false,limit_per_minute integer default 60) returns jsonb
language plpgsql security definer set search_path='' as $$
declare problem text; code text;
begin
 if not sdi_private.admin_can(capability) or not sdi_private.account_active() then
  problem:='Current administrator permission and MFA session required.'; code:='forbidden';
 elsif sensitive and not sdi_private.recently_authenticated(interval '15 minutes') then
  problem:='Re-verify your second factor to continue.'; code:='step_up_required';
 elsif not sdi_private.admin_rate_ok(limit_per_minute) then
  problem:='Too many administrative requests. Wait a minute.'; code:='rate_limited';
 end if;
 if problem is null then return null; end if;
 insert into sdi_private.admin_access_audit(actor,operation,allowed,detail) values(auth.uid(),left(operation,100),false,code);
 return jsonb_build_object('error',problem,'code',code);
end $$;
revoke all on function sdi_private.admin_gate(text,text,boolean,integer) from public,anon;
grant execute on function sdi_private.admin_gate(text,text,boolean,integer) to authenticated;

-- Role changes are sensitive: step-up and a tighter rate limit now apply.
create or replace function sdi_private.admin_permissions(action text,subject uuid default null,capabilities text[] default '{}',
 enabled boolean default false,reason text default '',revision bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare role_record sdi_private.admin_roles; items jsonb; denial jsonb;
begin
 if not sdi_private.admin_authorized() or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA session required.');end if;
 if action='mine' then
  select * into role_record from sdi_private.admin_roles where user_id=auth.uid();
  return jsonb_build_object('owner',role_record.owner,'capabilities',case when role_record.owner
   then array['users','reviews','moderation','publishing','overview','finance'] else role_record.permissions end,
   'step_up_current',sdi_private.recently_authenticated(interval '15 minutes'));
 end if;
 if not exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and owner and admin_roles.enabled) then
  return jsonb_build_object('error','Owner permission required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select user_id,owner,admin_roles.enabled,permissions,admin_roles.revision from sdi_private.admin_roles order by user_id limit 100
  ) item;
  return jsonb_build_object('roles',items);
 end if;
 denial:=sdi_private.admin_gate('admin_permissions.save','users',true,20);
 if denial is not null then return denial; end if;
 if action is null or action<>'save' or subject is null or subject=auth.uid() or capabilities is null or enabled is null
 or reason is null or length(trim(reason)) not between 1 and 2000
 or not capabilities <@ array['users','reviews','moderation','publishing','overview','finance'] or cardinality(capabilities)>6 then
  return jsonb_build_object('error','Valid subject, explicit permissions and reason required.');end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('sdi-admin-permissions',0));
 perform 1 from auth.users where id=subject for update;
 if not found then return jsonb_build_object('error','Account unavailable.');end if;
 select * into role_record from sdi_private.admin_roles where user_id=subject for update;
 if coalesce(role_record.revision,0) is distinct from revision then return jsonb_build_object('error','Role changed. Refresh before saving.');end if;
 if found and role_record.owner then return jsonb_build_object('error','Owner accounts require the separate recovery procedure.');end if;
 insert into sdi_private.admin_permission_audit(actor,subject,previous_permissions,new_permissions,previous_enabled,new_enabled,reason)
 values(auth.uid(),subject,coalesce(role_record.permissions,'{}'),capabilities,coalesce(role_record.enabled,false),enabled,trim(reason));
 insert into sdi_private.admin_roles(user_id,enabled,permissions) values(subject,enabled,capabilities)
 on conflict(user_id) do update set enabled=excluded.enabled,permissions=excluded.permissions,revision=admin_roles.revision+1;
 delete from auth.sessions where user_id=subject;
 insert into sdi_private.admin_access_audit(actor,operation,allowed,detail) values(auth.uid(),'admin_permissions.save',true,subject::text);
 return jsonb_build_object('status','confirmed');
end $$;

-- Owner provisioning: service role only, bootstrap only, no password anywhere.
-- The owner signs up through the normal identity providers, confirms email and
-- enrols a verified MFA factor first; this binds the display name and handle and
-- grants the owner role. Existing sessions are ended so the first owner session
-- is a fresh MFA sign-in. A second owner requires the separate recovery procedure.
create table sdi_private.admin_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade, display_name text not null check(length(display_name) between 1 and 50),
 handle text not null unique check(handle ~ '^[A-Za-z0-9_]{3,30}$'), created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.admin_profiles enable row level security;
revoke all on sdi_private.admin_profiles from public,anon,authenticated;
create function sdi_private.provision_owner(subject uuid,display_name text,handle text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u auth.users; existing_owner uuid;
begin
 if subject is null or display_name is null or length(trim(display_name)) not between 1 and 50 or handle is null or handle !~ '^[A-Za-z0-9_]{3,30}$' then
  return jsonb_build_object('error','Subject, display name (1-50) and handle (3-30 letters, digits, underscore) required.'); end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('sdi-admin-permissions',0));
 select * into u from auth.users where id=subject for update;
 if not found or u.is_anonymous or u.email_confirmed_at is null then return jsonb_build_object('error','The account must exist with a confirmed email.'); end if;
 if not exists(select 1 from auth.mfa_factors f where f.user_id=subject and f.status='verified') then
  return jsonb_build_object('error','Enrol and verify a second factor before owner provisioning.'); end if;
 select user_id into existing_owner from sdi_private.admin_roles where owner and enabled limit 1;
 if existing_owner is not null and existing_owner<>subject then return jsonb_build_object('error','An owner already exists; use the separate recovery procedure.'); end if;
 if existing_owner=subject then return jsonb_build_object('status','already_owner'); end if;
 insert into sdi_private.admin_roles(user_id,enabled,owner,permissions) values(subject,true,true,array['users','reviews','moderation','publishing','overview','finance'])
 on conflict(user_id) do update set enabled=true,owner=true,permissions=excluded.permissions,revision=admin_roles.revision+1;
 insert into sdi_private.admin_profiles(user_id,display_name,handle) values(subject,trim(display_name),handle)
 on conflict(user_id) do update set display_name=excluded.display_name,handle=excluded.handle;
 insert into sdi_private.admin_permission_audit(actor,subject,previous_permissions,new_permissions,previous_enabled,new_enabled,reason)
 values(subject,subject,'{}',array['users','reviews','moderation','publishing','overview','finance'],false,true,'Owner provisioned through the private server procedure.');
 delete from auth.sessions where user_id=subject;
 return jsonb_build_object('status','provisioned','handle',handle);
end $$;
revoke all on function sdi_private.provision_owner(uuid,text,text) from public,anon,authenticated;
grant execute on function sdi_private.provision_owner(uuid,text,text) to service_role;
create function public.sdi_provision_owner(subject uuid,display_name text,handle text) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.provision_owner(subject,display_name,handle)$$;
revoke all on function public.sdi_provision_owner(uuid,text,text) from public,anon,authenticated;
grant execute on function public.sdi_provision_owner(uuid,text,text) to service_role;

-- Workers report liveness; health shows age, never hostnames or credentials.
create table sdi_private.worker_heartbeats (
 worker text primary key check(worker ~ '^[a-z0-9_-]{1,40}$'), seen_at timestamptz not null default clock_timestamp(),
 note text not null default '' check(length(note)<=200)
);
alter table sdi_private.worker_heartbeats enable row level security;
revoke all on sdi_private.worker_heartbeats from public,anon,authenticated;
create function sdi_private.worker_heartbeat(worker text,note text default '') returns boolean language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
begin
 if worker is null or worker !~ '^[a-z0-9_-]{1,40}$' then return false; end if;
 insert into sdi_private.worker_heartbeats(worker,note) values(worker_heartbeat.worker,left(coalesce(worker_heartbeat.note,''),200))
 on conflict(worker) do update set seen_at=clock_timestamp(),note=excluded.note;
 return true;
end $$;
revoke all on function sdi_private.worker_heartbeat(text,text) from public,anon,authenticated;
grant execute on function sdi_private.worker_heartbeat(text,text) to service_role;
create function public.sdi_worker_heartbeat(worker text,note text default '') returns boolean language sql security invoker set search_path='' as $$select sdi_private.worker_heartbeat(worker,note)$$;
revoke all on function public.sdi_worker_heartbeat(text,text) from public,anon,authenticated;
grant execute on function public.sdi_worker_heartbeat(text,text) to service_role;
-- Later candidates add tables (support requests, deletion requests); count them
-- only when installed so health never errors on a partially installed set.
create function sdi_private.count_if_exists(relation text,predicate text default 'true') returns bigint language plpgsql security definer set search_path='' as $$
declare n bigint;
begin
 if to_regclass(relation) is null then return null; end if;
 execute format('select count(*) from %s where %s',relation,predicate) into n;
 return n;
end $$;
revoke all on function sdi_private.count_if_exists(text,text) from public,anon,authenticated;
create function sdi_private.admin_health() returns jsonb language plpgsql security definer set search_path='' as $$
declare denial jsonb; workers jsonb;
begin
 denial:=sdi_private.admin_gate('admin_health','overview',false,120);
 if denial is not null then return denial; end if;
 select coalesce(jsonb_agg(jsonb_build_object('worker',w.worker,'seen_at',w.seen_at,'note',w.note,'stale',w.seen_at<clock_timestamp()-interval '10 minutes') order by w.worker),'[]'::jsonb)
  into workers from sdi_private.worker_heartbeats w;
 return jsonb_build_object(
  'queues',jsonb_build_object(
   'publish_queued',(select count(*) from sdi_private.publish_jobs where state='queued'),
   'publish_leased',(select count(*) from sdi_private.publish_jobs where state in('leased','cancel_requested')),
   'publish_attention',(select count(*) from sdi_private.publish_jobs where state in('failed','reconcile','removal_pending')),
   'removal_jobs_open',(select count(*) from sdi_private.removal_jobs where state in('pending','running','failed')),
   'render_reviews_pending',(select count(*) from sdi_private.render_reviews where state='pending'),
   'feed_reports_pending',(select count(*) from sdi_private.feed_reports where state='pending'),
   'war_reports_pending',(select count(*) from sdi_private.war_reports where state='pending'),
   'war_appeals_pending',(select count(*) from sdi_private.war_appeals where state='pending'),
   'moderation_appeals_pending',(select count(*) from sdi_private.moderation_appeals where state='pending'),
   'room_reports_pending',(select count(*) from sdi_private.room_reports where state='pending'),
   'account_appeals_pending',(select count(*) from sdi_private.account_appeals where state='pending'),
   'support_open',sdi_private.count_if_exists('sdi_private.support_requests','status in (''open'',''in_progress'',''waiting_on_member'')'),
   'deletion_requests_due',sdi_private.count_if_exists('sdi_private.deletion_requests','state in (''pending'',''processing'',''blocked'')'),
   'agent_runs_running',(select count(*) from sdi_private.agent_runs where state='running'),
   'provider_events_unprocessed',(select count(*) from sdi_private.provider_events where processed_at is null)),
  'oldest_pending',jsonb_build_object(
   'publish_queued',(select min(created_at) from sdi_private.publish_jobs where state='queued'),
   'render_review',(select min(created_at) from sdi_private.render_reviews where state='pending'),
   'feed_report',(select min(created_at) from sdi_private.feed_reports where state='pending'),
   'removal_job',(select min(created_at) from sdi_private.removal_jobs where state in('pending','running','failed'))),
  'workers',workers,
  'emergency_stop',(select emergency_stop from sdi_private.agent_global),
  'admin_denials_24h',(select count(*) from sdi_private.admin_access_audit where not allowed and created_at>clock_timestamp()-interval '24 hours'),
  'measured_at',clock_timestamp());
end $$;
revoke all on function sdi_private.admin_health() from public,anon;
grant execute on function sdi_private.admin_health() to authenticated;
create function public.sdi_admin_health() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.admin_health()$$;
revoke all on function public.sdi_admin_health() from public,anon;
grant execute on function public.sdi_admin_health() to authenticated;
commit;
