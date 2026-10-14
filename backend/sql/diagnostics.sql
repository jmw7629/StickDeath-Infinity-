-- Unapplied candidate. Install after users-profiles.sql (needs admin-users.sql for
-- account_active, admin-hardening.sql for admin_gate, agent-controls.sql for agent_runs
-- and pgcrypto in extensions). First-party, opt-in diagnostics intake for #291.
--
-- Contract v1 (shared by iOS DiagnosticsReport.swift and Android DiagnosticsReport.kt):
--   {"v":1,"platform":"ios"|"android","app_version":"1.2.3"|"unknown","build":"123"|"unknown",
--    "os_major":0..99,"day":"YYYY-MM-DD","counters":{"<allowlisted>":1..10000,...}}
-- Only completed UTC days within the last 30 are accepted. Unknown keys, unknown counters,
-- free text, identifiers and precise times are refused, not stored. Stored rows carry no
-- account id: the account is used only for the opt-in assertion, a per-account rate limit
-- and duplicate suppression (diagnostic_receipts, deleted with the account and after 35 days).
-- Raw day rows are kept 90 days. No third-party SDK or service receives any of this.
begin;
create table sdi_private.diagnostic_reports (
 id uuid primary key default gen_random_uuid(),
 platform text not null check(platform in('ios','android')),
 app_version text not null check(app_version ~ '^([0-9]{1,4}(\.[0-9]{1,4}){0,2}|unknown)$'),
 build text not null check(build ~ '^([0-9]{1,9}|unknown)$'),
 os_major smallint not null check(os_major between 0 and 99),
 day date not null,
 counters jsonb not null check(jsonb_typeof(counters)='object' and length(counters::text)<=512),
 received_day date not null default (clock_timestamp() at time zone 'utc')::date
);
create table sdi_private.diagnostic_receipts (
 user_id uuid not null references auth.users(id) on delete cascade,
 bucket text not null check(bucket ~ '^[0-9a-f]{64}$'),
 received_at timestamptz not null default clock_timestamp(),
 primary key(user_id,bucket)
);
alter table sdi_private.diagnostic_reports enable row level security;
alter table sdi_private.diagnostic_receipts enable row level security;
revoke all on sdi_private.diagnostic_reports,sdi_private.diagnostic_receipts from public,anon,authenticated;
create index diagnostic_reports_day on sdi_private.diagnostic_reports(day,platform,build);
create index diagnostic_receipts_recent on sdi_private.diagnostic_receipts(user_id,received_at);

create function sdi_private.diagnostic_counters() returns text[] language sql immutable set search_path='' as $$
 select array['app_launch','crash','hang','cpu_exception','disk_write_exception','memory_limit_exit','watchdog_exit','uncaught_exception']
$$;
revoke all on function sdi_private.diagnostic_counters() from public,anon;
grant execute on function sdi_private.diagnostic_counters() to authenticated,service_role;

create function sdi_private.diagnostics_submit(report jsonb,consent boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); today date:=(clock_timestamp() at time zone 'utc')::date; report_day date; key text; value jsonb;
 clean jsonb:='{}'::jsonb; bucket_key text;
begin
 if actor is null or not sdi_private.account_active() then
  return jsonb_build_object('error','Sign in to send diagnostics.','code','signed_out'); end if;
 if consent is distinct from true then
  return jsonb_build_object('error','Diagnostics consent is required.','code','consent_required'); end if;
 if report is null or jsonb_typeof(report)<>'object' or length(report::text)>2048
  or (select array_agg(k order by k) from jsonb_object_keys(report) k)<>array['app_version','build','counters','day','os_major','platform','v']
  or report->'v'<>'1'::jsonb
  or jsonb_typeof(report->'platform')<>'string' or report->>'platform' not in('ios','android')
  or jsonb_typeof(report->'app_version')<>'string' or report->>'app_version' !~ '^([0-9]{1,4}(\.[0-9]{1,4}){0,2}|unknown)$'
  or jsonb_typeof(report->'build')<>'string' or report->>'build' !~ '^([0-9]{1,9}|unknown)$'
  or jsonb_typeof(report->'os_major')<>'number' or report->>'os_major' !~ '^[0-9]{1,2}$'
  or jsonb_typeof(report->'day')<>'string' or report->>'day' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  or jsonb_typeof(report->'counters')<>'object' then
  return jsonb_build_object('error','Diagnostics report does not match the contract.','code','invalid'); end if;
 begin report_day:=(report->>'day')::date;
 exception when others then return jsonb_build_object('error','Diagnostics report does not match the contract.','code','invalid'); end;
 if to_char(report_day,'YYYY-MM-DD')<>report->>'day' or report_day>=today or report_day<today-30 then
  return jsonb_build_object('error','Only completed days from the last 30 days are accepted.','code','invalid'); end if;
 for key,value in select * from jsonb_each(report->'counters') loop
  if not key=any(sdi_private.diagnostic_counters()) or jsonb_typeof(value)<>'number' or value::text !~ '^[0-9]{1,5}$'
   or value::text::integer not between 1 and 10000 then
   return jsonb_build_object('error','Diagnostics report does not match the contract.','code','invalid'); end if;
  clean:=clean||jsonb_build_object(key,value::text::integer);
 end loop;
 if clean='{}'::jsonb then return jsonb_build_object('error','Diagnostics report does not match the contract.','code','invalid'); end if;
 bucket_key:=encode(extensions.digest(concat_ws('|',report->>'platform',report->>'day',report->>'app_version',report->>'build',report->>'os_major'),'sha256'),'hex');
 -- One row per account and bucket: serialize this account's submissions.
 perform pg_advisory_xact_lock(hashtextextended('sdi.diagnostics.'||actor::text,0));
 if exists(select 1 from sdi_private.diagnostic_receipts r where r.user_id=actor and r.bucket=bucket_key) then
  return jsonb_build_object('status','duplicate'); end if;
 if (select count(*) from sdi_private.diagnostic_receipts r where r.user_id=actor and r.received_at>clock_timestamp()-interval '1 day')>=20 then
  return jsonb_build_object('error','Daily diagnostics limit reached.','code','rate_limited'); end if;
 insert into sdi_private.diagnostic_receipts(user_id,bucket) values(actor,bucket_key);
 insert into sdi_private.diagnostic_reports(platform,app_version,build,os_major,day,counters)
 values(report->>'platform',report->>'app_version',report->>'build',(report->>'os_major')::smallint,report_day,clean);
 return jsonb_build_object('status','accepted');
end $$;
revoke all on function sdi_private.diagnostics_submit(jsonb,boolean) from public,anon;
grant execute on function sdi_private.diagnostics_submit(jsonb,boolean) to authenticated;
create function public.sdi_diagnostics_submit(report jsonb,consent boolean default false) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.diagnostics_submit(report,consent)$$;
revoke all on function public.sdi_diagnostics_submit(jsonb,boolean) from public,anon;
grant execute on function public.sdi_diagnostics_submit(jsonb,boolean) to authenticated;

-- Command-center read model (overview capability, MFA). Real counts only; a spike is a
-- (platform, build) whose crash+uncaught_exception total on the latest completed day is at
-- least 5 and more than five times its mean over the seven days before. Failed agent runs
-- in the last 24 hours come from agent_runs. Nothing is estimated or extrapolated.
create function sdi_private.diagnostics_admin(action text,days integer default 14) returns jsonb
language plpgsql security definer set search_path='' as $$
declare denial jsonb; today date:=(clock_timestamp() at time zone 'utc')::date; latest date; totals jsonb; spikes jsonb;
begin
 denial:=sdi_private.admin_gate('diagnostics_admin.'||coalesce(action,'?'),'overview',false,60);
 if denial is not null then return denial; end if;
 if action is distinct from 'summary' then return jsonb_build_object('error','Unsupported diagnostics operation.'); end if;
 if days is null or days not between 1 and 90 then return jsonb_build_object('error','Choose between 1 and 90 days.'); end if;
 latest:=today-1;
 select coalesce(jsonb_agg(row_to_json(t) order by t.day desc,t.platform,t.build,t.counter),'[]'::jsonb) into totals from (
  select d.day,d.platform,d.app_version,d.build,c.key as counter,sum(c.value::text::bigint) as total,count(*) as reports
  from sdi_private.diagnostic_reports d cross join lateral jsonb_each(d.counters) c
  where d.day>=today-days group by d.day,d.platform,d.app_version,d.build,c.key) t;
 select coalesce(jsonb_agg(row_to_json(s) order by s.latest_total desc),'[]'::jsonb) into spikes from (
  select x.platform,x.build,
   sum(x.n) filter(where x.day=latest) as latest_total,
   round(coalesce(sum(x.n) filter(where x.day between latest-7 and latest-1),0)/7.0,2) as prior_daily_mean
  from (select d.day,d.platform,d.build,coalesce((d.counters->>'crash')::bigint,0)+coalesce((d.counters->>'uncaught_exception')::bigint,0) as n
        from sdi_private.diagnostic_reports d where d.day between latest-7 and latest) x
  group by x.platform,x.build
  having coalesce(sum(x.n) filter(where x.day=latest),0)>=5
   and coalesce(sum(x.n) filter(where x.day=latest),0)>5*coalesce(sum(x.n) filter(where x.day between latest-7 and latest-1),0)/7.0) s;
 return jsonb_build_object('since',today-days,'latest_complete_day',latest,
  'reports',(select count(*) from sdi_private.diagnostic_reports d where d.day>=today-days),
  'totals',totals,'crash_spikes',spikes,
  'agent_runs_failed_24h',(select count(*) from sdi_private.agent_runs r where r.state='failed' and r.started_at>clock_timestamp()-interval '24 hours'),
  'retention_days',90);
end $$;
revoke all on function sdi_private.diagnostics_admin(text,integer) from public,anon;
grant execute on function sdi_private.diagnostics_admin(text,integer) to authenticated;
create function public.sdi_diagnostics_admin(action text,days integer default 14) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.diagnostics_admin(action,days)$$;
revoke all on function public.sdi_diagnostics_admin(text,integer) from public,anon;
grant execute on function public.sdi_diagnostics_admin(text,integer) to authenticated;

-- Retention sweep for the service scheduler: day rows after 90 days, receipts after 35.
create function sdi_private.diagnostics_retention() returns jsonb language plpgsql security definer set search_path='' as $$
declare reports integer; receipts integer;
begin
 delete from sdi_private.diagnostic_reports where day<(clock_timestamp() at time zone 'utc')::date-90;
 get diagnostics reports=row_count;
 delete from sdi_private.diagnostic_receipts where received_at<clock_timestamp()-interval '35 days';
 get diagnostics receipts=row_count;
 return jsonb_build_object('reports_deleted',reports,'receipts_deleted',receipts);
end $$;
revoke all on function sdi_private.diagnostics_retention() from public,anon,authenticated;
grant execute on function sdi_private.diagnostics_retention() to service_role;
create function public.sdi_diagnostics_retention() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.diagnostics_retention()$$;
revoke all on function public.sdi_diagnostics_retention() from public,anon,authenticated;
grant execute on function public.sdi_diagnostics_retention() to service_role;
commit;
