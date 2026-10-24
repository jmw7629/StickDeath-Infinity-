-- Unapplied candidate. Install after agent-proposals.sql (needs admin-hardening.sql;
-- the provider health view also reads billing.sql, publishing-jobs.sql,
-- notifications.sql and spatter-draft-jobs.sql tables).
-- Masked provider-configuration health (#248): each service worker reports which of
-- its named settings are present as booleans only; the function refuses any other
-- value type, so no key, URL or identifier can ever be stored, and administrators
-- read presence, staleness and nothing else. The provider health view below groups
-- that presence per integration (Spatter, APNs, FCM, email, Stripe, YouTube) and adds
-- the last success/failure time with a closed error class, from durable records and
-- service-reported outcomes. No value, message or identifier is ever returned.
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

-- Provider health (#248). Error classes are a closed vocabulary so no provider
-- message, token or address can be stored in or returned from this table.
create function sdi_private.provider_error_classes() returns text[] language sql immutable set search_path='' as $$
 select array['configuration','authentication','rate_limited','network','timeout','rejected','provider_error',
  'invalid_response','event_error','job_failed','render_failed','other']
$$;
revoke all on function sdi_private.provider_error_classes() from public,anon;
grant execute on function sdi_private.provider_error_classes() to authenticated,service_role;
-- The lower-cased setting names each integration needs (the names workers report).
create function sdi_private.provider_settings() returns jsonb language sql immutable set search_path='' as $$
 select jsonb_build_array(
  jsonb_build_object('provider','spatter','title','Spatter draft renderer','settings',jsonb_build_array('sdi_draft_renderer_cli')),
  jsonb_build_object('provider','apns','title','Apple push (APNs)','settings',jsonb_build_array('sdi_apns_key_id','sdi_apns_team_id','sdi_apns_key_file','sdi_apns_topic')),
  jsonb_build_object('provider','fcm','title','Android push (FCM)','settings',jsonb_build_array('sdi_fcm_project_id','sdi_fcm_service_account_file')),
  jsonb_build_object('provider','email','title','Email sender','settings',jsonb_build_array('sdi_mail_sender_domain','sdi_mail_credentials_file')),
  jsonb_build_object('provider','stripe','title','Stripe billing','settings',jsonb_build_array('sdi_stripe_webhook_secret_file')),
  jsonb_build_object('provider','youtube','title','YouTube channel','settings',jsonb_build_array('sdi_youtube_client_file','sdi_youtube_token_file')))
$$;
revoke all on function sdi_private.provider_settings() from public,anon,authenticated;

create table sdi_private.provider_outcomes (
 provider text primary key check(provider in('spatter','apns','fcm','email','stripe','youtube')),
 last_success_at timestamptz, last_failure_at timestamptz,
 last_error_class text check(last_error_class is null or last_error_class=any(sdi_private.provider_error_classes())),
 consecutive_failures integer not null default 0 check(consecutive_failures between 0 and 1000000),
 updated_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.provider_outcomes enable row level security;
revoke all on sdi_private.provider_outcomes from public,anon,authenticated;

-- Service: a worker records one provider outcome (success, or failure with a class).
create function sdi_private.provider_outcome_report(provider text,succeeded boolean,error_class text default null) returns boolean
language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
begin
 if provider is null or provider not in('spatter','apns','fcm','email','stripe','youtube') or succeeded is null then return false; end if;
 if succeeded then
  if coalesce(error_class,'')<>'' then return false; end if;
  insert into sdi_private.provider_outcomes as o(provider,last_success_at) values(provider,clock_timestamp())
  on conflict on constraint provider_outcomes_pkey do update set last_success_at=clock_timestamp(),consecutive_failures=0,updated_at=clock_timestamp();
 else
  if error_class is null or not error_class=any(sdi_private.provider_error_classes()) then return false; end if;
  insert into sdi_private.provider_outcomes as o(provider,last_failure_at,last_error_class,consecutive_failures) values(provider,clock_timestamp(),error_class,1)
  on conflict on constraint provider_outcomes_pkey do update set last_failure_at=clock_timestamp(),last_error_class=excluded.last_error_class,
   consecutive_failures=least(o.consecutive_failures+1,1000000),updated_at=clock_timestamp();
 end if;
 return true;
end $$;
revoke all on function sdi_private.provider_outcome_report(text,boolean,text) from public,anon,authenticated;
grant execute on function sdi_private.provider_outcome_report(text,boolean,text) to service_role;

-- Push delivery reasons (backend/notifications/push.py) mapped to the closed classes.
-- A device that unregistered is the member's device, not a provider failure (null).
create function sdi_private.push_error_class(reason text) returns text language sql immutable set search_path='' as $$
 select case
  when reason in('Unregistered','BadDeviceToken','unregistered','invalid_token') then null
  when reason='transport not configured' then 'configuration'
  when reason='transport error' then 'network'
  when reason ~ ' status (401|403)' then 'authentication'
  when reason ~ ' status 429' then 'rate_limited'
  when reason ~ ' status 5[0-9][0-9]' then 'provider_error'
  when reason ~ ' status [0-9]+' then 'rejected'
  else 'other' end
$$;
revoke all on function sdi_private.push_error_class(text) from public,anon,authenticated;

-- Administrators (overview capability, MFA) read per-integration presence and outcomes.
create function sdi_private.admin_provider_health() returns jsonb language plpgsql security definer set search_path='' as $$
declare denial jsonb; entry jsonb; items jsonb:='[]'::jsonb; p text; keys text[]; k text; present boolean;
 missing text[]; reported integer; reported_at timestamptz; configured text; ok_at timestamptz; fail_at timestamptz; fail_class text;
 d_ok timestamptz; d_fail timestamptz; d_class text; o sdi_private.provider_outcomes; health text; push_platform text;
begin
 denial:=sdi_private.admin_gate('admin_provider_health','overview',false,120);
 if denial is not null then return denial; end if;
 for entry in select value from jsonb_array_elements(sdi_private.provider_settings()) loop
  p:=entry->>'provider'; keys:=array(select jsonb_array_elements_text(entry->'settings'));
  missing:='{}'; reported:=0;
  foreach k in array keys loop
   select bool_or((c.settings->>k)::boolean) into present from sdi_private.worker_configuration c where c.settings ? k;
   if present is not null then reported:=reported+1; end if;
   if present is not true then missing:=missing||k; end if;
  end loop;
  select max(c.reported_at) into reported_at from sdi_private.worker_configuration c where c.settings ?| keys;
  configured:=case when reported=0 then 'unreported' when cardinality(missing)=0 then 'yes' else 'no' end;
  -- Outcomes from durable records the integration already writes.
  d_ok:=null; d_fail:=null; d_class:=null;
  if p='stripe' then
   select max(e.processed_at) filter(where e.outcome in('applied','ignored')),max(coalesce(e.processed_at,e.received_at)) filter(where e.outcome='error')
    into d_ok,d_fail from sdi_private.provider_events e where e.provider='stripe';
   if d_fail is not null then d_class:='event_error'; end if;
  elsif p='youtube' then
   select max(j.updated_at) filter(where j.state='published'),max(j.updated_at) filter(where j.state='failed')
    into d_ok,d_fail from sdi_private.publish_jobs j where j.destination='youtube';
   if d_fail is not null then d_class:='job_failed'; end if;
  elsif p='spatter' then
   select max(j.updated_at) filter(where j.state in('review_pending','approved','rejected')),max(j.updated_at) filter(where j.state='failed')
    into d_ok,d_fail from sdi_private.spatter_draft_jobs j;
   if d_fail is not null then d_class:='render_failed'; end if;
  elsif p in('apns','fcm') then
   push_platform:=case p when 'apns' then 'ios' else 'android' end;
   select max(d.updated_at) filter(where d.state in('sent','read')),
    max(d.updated_at) filter(where d.state='failed' and sdi_private.push_error_class(d.reason) is not null)
    into d_ok,d_fail from sdi_private.announcement_deliveries d join sdi_private.device_tokens t on t.id=d.device_id
    where d.channel='push' and t.platform=push_platform;
   if d_fail is not null then
    select sdi_private.push_error_class(d.reason) into d_class from sdi_private.announcement_deliveries d join sdi_private.device_tokens t on t.id=d.device_id
     where d.channel='push' and t.platform=push_platform and d.state='failed' and sdi_private.push_error_class(d.reason) is not null
     order by d.updated_at desc,d.id limit 1;
   end if;
  end if;
  -- Outcomes reported by service workers (email has no durable record in the database).
  o:=null;
  select * into o from sdi_private.provider_outcomes po where po.provider=p;
  ok_at:=greatest(d_ok,o.last_success_at);
  fail_at:=greatest(d_fail,o.last_failure_at);
  fail_class:=case when fail_at is null then null
   when o.last_failure_at is not null and o.last_failure_at>=coalesce(d_fail,'-infinity'::timestamptz) then o.last_error_class else d_class end;
  health:=case when configured='no' then 'unconfigured'
   when fail_at is not null and fail_at>coalesce(ok_at,'-infinity'::timestamptz) then 'failing'
   when ok_at is not null then 'healthy'
   when configured='unreported' then 'unreported'
   else 'no_activity' end;
  items:=items||jsonb_build_array(jsonb_build_object('provider',p,'title',entry->>'title','configured',configured,
   'missing',to_jsonb(missing),'configuration_reported_at',reported_at,
   'configuration_stale',coalesce(reported_at<clock_timestamp()-interval '1 day',false),
   'last_success_at',ok_at,'last_failure_at',fail_at,'last_error_class',fail_class,
   'consecutive_failures',coalesce(o.consecutive_failures,0),'health',health));
 end loop;
 return jsonb_build_object('providers',items,'measured_at',clock_timestamp(),
  'note','Presence and outcome times only. Keys, tokens, URLs and provider messages are never stored or shown; the secret store keeps no fingerprint, so no masked suffix is shown.');
end $$;
revoke all on function sdi_private.admin_provider_health() from public,anon;
grant execute on function sdi_private.admin_provider_health() to authenticated;
create function public.sdi_provider_outcome(provider text,succeeded boolean,error_class text default null) returns boolean language sql security invoker set search_path='' as $$select sdi_private.provider_outcome_report(provider,succeeded,error_class)$$;
revoke all on function public.sdi_provider_outcome(text,boolean,text) from public,anon,authenticated;
grant execute on function public.sdi_provider_outcome(text,boolean,text) to service_role;
create function public.sdi_admin_provider_health() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.admin_provider_health()$$;
revoke all on function public.sdi_admin_provider_health() from public,anon;
grant execute on function public.sdi_admin_provider_health() to authenticated;
commit;
