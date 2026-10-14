-- Local assertions for diagnostics.sql (#291): contract validation, consent, no account
-- id in stored rows, duplicate suppression, rate limit, admin gate, spike rule and
-- retention. Throwaway cluster only.
begin;
do $$
declare member uuid; other uuid; viewer uuid; r jsonb; today date:=(clock_timestamp() at time zone 'utc')::date;
 good jsonb; bad jsonb; i integer; spike jsonb;
begin
 member:=sdi_test.user('diag-member'); other:=sdi_test.user('diag-other');
 viewer:=sdi_test.admin('diag-viewer',false,array['overview']);
 good:=jsonb_build_object('v',1,'platform','ios','app_version','1.4.2','build','317','os_major',17,
  'day',to_char(today-1,'YYYY-MM-DD'),'counters',jsonb_build_object('crash',2,'app_launch',9));

 -- Signed out and without consent nothing is stored.
 r:=sdi_private.diagnostics_submit(good,true);
 perform sdi_test.check(r->>'code'='signed_out','signed-out submission refused: '||r::text);
 perform sdi_test.login(member);
 r:=sdi_private.diagnostics_submit(good,false);
 perform sdi_test.check(r->>'code'='consent_required','missing consent refused: '||r::text);
 perform sdi_test.check((select count(*) from sdi_private.diagnostic_reports)=0,'nothing stored before an accepted call');

 -- Contract violations: extra keys, free text, unknown counters, bad bounds, today/future/old days.
 foreach bad in array array[
  good||jsonb_build_object('user_id',member::text),
  good||jsonb_build_object('app_version','1.4.2 (Joe''s iPhone)'),
  good||jsonb_build_object('build','317-joe'),
  good||jsonb_build_object('platform','web'),
  good||jsonb_build_object('os_major',140),
  good||jsonb_build_object('os_major','17'),
  good||jsonb_build_object('v',2),
  good||jsonb_build_object('day',to_char(today,'YYYY-MM-DD')),
  good||jsonb_build_object('day',to_char(today+3,'YYYY-MM-DD')),
  good||jsonb_build_object('day',to_char(today-31,'YYYY-MM-DD')),
  good||jsonb_build_object('day','2025-02-30'),
  good||jsonb_build_object('day','2025-10-09T08:53:20Z'),
  good||jsonb_build_object('counters',jsonb_build_object('crash','2')),
  good||jsonb_build_object('counters',jsonb_build_object('crash',0)),
  good||jsonb_build_object('counters',jsonb_build_object('crash',10001)),
  good||jsonb_build_object('counters',jsonb_build_object('crash',1.5)),
  good||jsonb_build_object('counters',jsonb_build_object('project_name',1)),
  good||jsonb_build_object('counters','{}'::jsonb),
  good-'counters',
  '[]'::jsonb]
 loop
  r:=sdi_private.diagnostics_submit(bad,true);
  perform sdi_test.check(r->>'code'='invalid','contract violation refused: '||bad::text||' -> '||r::text);
 end loop;
 perform sdi_test.check((select count(*) from sdi_private.diagnostic_reports)=0,'no invalid payload stored');

 r:=sdi_private.diagnostics_submit(good,true);
 perform sdi_test.check(r->>'status'='accepted','valid report accepted: '||r::text);
 r:=sdi_private.diagnostics_submit(good,true);
 perform sdi_test.check(r->>'status'='duplicate','same bucket from the same account is a duplicate');
 perform sdi_test.check((select count(*) from sdi_private.diagnostic_reports)=1,'duplicate not stored twice');
 perform sdi_test.check((select counters from sdi_private.diagnostic_reports)='{"crash":2,"app_launch":9}'::jsonb,'counters stored as sent');
 -- The stored row has no column that could hold an account, device or free text.
 perform sdi_test.check((select array_agg(column_name::text order by column_name::text) from information_schema.columns
  where table_schema='sdi_private' and table_name='diagnostic_reports')
  =array['app_version','build','counters','day','id','os_major','platform','received_day'],'report columns are coarse only');
 perform sdi_test.login(other);
 r:=sdi_private.diagnostics_submit(good,true);
 perform sdi_test.check(r->>'status'='accepted','another account may send the same bucket');

 -- Rate limit: 20 accepted buckets per account per day.
 perform sdi_test.login(member);
 for i in 2..20 loop
  r:=sdi_private.diagnostics_submit(good||jsonb_build_object('day',to_char(today-i,'YYYY-MM-DD')),true);
  perform sdi_test.check(r->>'status'='accepted','bucket '||i||' accepted: '||r::text);
 end loop;
 r:=sdi_private.diagnostics_submit(good||jsonb_build_object('day',to_char(today-21,'YYYY-MM-DD')),true);
 perform sdi_test.check(r->>'code'='rate_limited','21st bucket in a day refused: '||r::text);
 update sdi_private.diagnostic_receipts set received_at=received_at-interval '2 days' where user_id=member;
 r:=sdi_private.diagnostics_submit(good||jsonb_build_object('day',to_char(today-21,'YYYY-MM-DD')),true);
 perform sdi_test.check(r->>'status'='accepted','window expiry admits again: '||r::text);

 -- Privileges: clients reach the tables only through the RPCs.
 perform sdi_test.check(not has_table_privilege('authenticated','sdi_private.diagnostic_reports','select'),'members cannot read reports');
 perform sdi_test.check(not has_table_privilege('authenticated','sdi_private.diagnostic_receipts','select'),'members cannot read receipts');
 perform sdi_test.check(not has_function_privilege('anon','public.sdi_diagnostics_submit(jsonb,boolean)','execute'),'anon cannot submit');
 perform sdi_test.check(not has_function_privilege('authenticated','public.sdi_diagnostics_retention()','execute'),'members cannot run retention');

 -- Admin read model: overview capability with MFA only.
 r:=sdi_private.diagnostics_admin('summary');
 perform sdi_test.check(r->>'code'='forbidden','member denied the summary');
 perform sdi_test.login(viewer);
 r:=sdi_private.diagnostics_admin('summary');
 perform sdi_test.check(r->>'code'='forbidden','admin without aal2 denied');
 perform sdi_test.login(viewer,'aal2');
 delete from sdi_private.diagnostic_reports;
 -- Build 400 spikes (12 vs a mean of 1); build 401 is steady (6 vs a mean of 7).
 insert into sdi_private.diagnostic_reports(platform,app_version,build,os_major,day,counters)
 select 'ios','1.5.0','400',17,today-1,'{"crash":10,"uncaught_exception":2}'::jsonb
 union all select 'ios','1.5.0','400',17,today-1-g,'{"crash":1}'::jsonb from generate_series(1,7) g
 union all select 'android','1.5.0','401',34,today-1,'{"uncaught_exception":6}'::jsonb
 union all select 'android','1.5.0','401',34,today-1-g,'{"uncaught_exception":7}'::jsonb from generate_series(1,7) g
 union all select 'ios','1.0.0','100',16,today-120,'{"crash":3}'::jsonb;
 r:=sdi_private.diagnostics_admin('summary',14);
 perform sdi_test.check(r->>'error' is null,'summary allowed: '||r::text);
 perform sdi_test.check((r->>'reports')::integer=16,'old row outside the window not counted: '||(r->>'reports'));
 perform sdi_test.check(jsonb_array_length(r->'crash_spikes')=1,'exactly one spike: '||(r->'crash_spikes')::text);
 spike:=r->'crash_spikes'->0;
 perform sdi_test.check(spike->>'build'='400' and (spike->>'latest_total')::integer=12 and (spike->>'prior_daily_mean')::numeric=1,'spike details: '||spike::text);
 perform sdi_test.check((r->>'agent_runs_failed_24h')::integer>=0 and (r->>'retention_days')::integer=90,'agent failures and retention reported');
 perform sdi_test.check(exists(select 1 from jsonb_array_elements(r->'totals') t where t->>'counter'='crash' and t->>'build'='400'
  and (t->>'total')::integer=10 and t->>'day'=to_char(today-1,'YYYY-MM-DD')),'daily totals per counter');
 r:=sdi_private.diagnostics_admin('summary',0);
 perform sdi_test.check(r->>'error'='Choose between 1 and 90 days.','day range bounded');
 r:=sdi_private.diagnostics_admin('export');
 perform sdi_test.check(r->>'error'='Unsupported diagnostics operation.','unknown action refused');

 -- Retention: rows older than 90 days and receipts older than 35 days go; account deletion cascades.
 update sdi_private.diagnostic_receipts set received_at=clock_timestamp()-interval '40 days' where user_id=other;
 r:=sdi_private.diagnostics_retention();
 perform sdi_test.check((r->>'reports_deleted')::integer=1 and (r->>'receipts_deleted')::integer=1,'retention sweep: '||r::text);
 perform sdi_test.check(not exists(select 1 from sdi_private.diagnostic_reports where day<today-90),'old rows gone');
 delete from auth.users where id=member;
 perform sdi_test.check(not exists(select 1 from sdi_private.diagnostic_receipts where user_id=member),'receipts deleted with the account');
 perform sdi_test.check((select count(*) from sdi_private.diagnostic_reports)=16,'coarse day rows are not linked to the account and stay');
end $$;
rollback;
