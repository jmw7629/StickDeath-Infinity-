-- Unapplied candidate. Install after agent-proposals.sql (needs admin-hardening.sql).
-- Masked provider-configuration health (#248): each service worker reports which of
-- its named settings are present as booleans only; the function refuses any other
-- value type, so no key, URL or identifier can ever be stored, and administrators
-- read presence, staleness and nothing else.
begin;
create table sdi_private.worker_configuration (
 worker text primary key check(worker ~ '^[a-z0-9_-]{1,40}$'),
 reported_at timestamptz not null default clock_timestamp(),
 settings jsonb not null default '{}' check(jsonb_typeof(settings)='object' and length(settings::text)<=4096)
);
alter table sdi_private.worker_configuration enable row level security;
revoke all on sdi_private.worker_configuration from public,anon,authenticated;

create function sdi_private.worker_configuration_report(worker text,settings jsonb) returns boolean
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare entry record; n integer:=0;
begin
 if worker is null or worker !~ '^[a-z0-9_-]{1,40}$' or settings is null or jsonb_typeof(settings)<>'object' then return false; end if;
 for entry in select key,value from jsonb_each(settings) loop
  n:=n+1;
  if n>40 or entry.key !~ '^[a-z0-9_]{1,40}$' or jsonb_typeof(entry.value)<>'boolean' then return false; end if;
 end loop;
 insert into sdi_private.worker_configuration(worker,settings) values(worker,settings)
 on conflict(worker) do update set reported_at=clock_timestamp(),settings=excluded.settings;
 return true;
end $$;
revoke all on function sdi_private.worker_configuration_report(text,jsonb) from public,anon,authenticated;
grant execute on function sdi_private.worker_configuration_report(text,jsonb) to service_role;

create function sdi_private.admin_configuration() returns jsonb language plpgsql security definer set search_path='' as $$
declare denial jsonb; items jsonb;
begin
 denial:=sdi_private.admin_gate('admin_configuration','overview',false,120);
 if denial is not null then return denial; end if;
 select coalesce(jsonb_agg(jsonb_build_object('worker',c.worker,'reported_at',c.reported_at,
   'stale',c.reported_at<clock_timestamp()-interval '1 day','settings',c.settings,
   'missing',(select coalesce(jsonb_agg(e.key order by e.key),'[]'::jsonb) from jsonb_each(c.settings) e where e.value='false'::jsonb)) order by c.worker),'[]'::jsonb)
  into items from sdi_private.worker_configuration c;
 return jsonb_build_object('workers',items,'note','Presence only. Values are never stored or shown; a missing setting means the worker reported it absent.');
end $$;
revoke all on function sdi_private.admin_configuration() from public,anon;
grant execute on function sdi_private.admin_configuration() to authenticated;

create function public.sdi_worker_configuration(worker text,settings jsonb) returns boolean language sql security invoker set search_path='' as $$select sdi_private.worker_configuration_report(worker,settings)$$;
revoke all on function public.sdi_worker_configuration(text,jsonb) from public,anon,authenticated;
grant execute on function public.sdi_worker_configuration(text,jsonb) to service_role;
create function public.sdi_admin_configuration() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.admin_configuration()$$;
revoke all on function public.sdi_admin_configuration() from public,anon;
grant execute on function public.sdi_admin_configuration() to authenticated;
commit;
