-- Local assertions for the admin command-center additions (#248, #257, #284, #285):
-- operations status without topology, append-only audits, searchable agent history,
-- per-run cost caps enforced on the server, run-log retention, the role-redacted plan
-- column and step-up on account-state changes.
begin;
do $$
declare owner uuid; viewer uuid; member uuid; outsider uuid; r jsonb; rev bigint; run uuid; audit_id uuid; blocked boolean;
begin
 owner:=sdi_test.admin('ops-owner',true,array[]::text[]); viewer:=sdi_test.admin('ops-viewer',false,array['overview','users']);
 member:=sdi_test.user('ops-member'); outsider:=sdi_test.user('ops-outsider');

 -- Operations status: nothing reported reads as stale/never, not healthy.
 perform sdi_test.login(viewer,'aal2');
 r:=sdi_private.admin_operations();
 perform sdi_test.check((r->'backup'->>'stale')::boolean and r->'backup'->>'last_succeeded_at' is null,'no backup report is stale: '||r::text);
 perform sdi_test.check((r->'restore_drill'->>'stale')::boolean and (r->'retention_sweep'->>'stale')::boolean and r->'release' = 'null'::jsonb,'no drill, sweep or release reported');
 perform sdi_test.logout();

 -- Host jobs report outcomes; hosts, paths and free text are refused.
 r:=sdi_private.ops_report('backup','succeeded','',jsonb_build_object('bytes',123456,'duration_seconds',42));
 perform sdi_test.check(r->>'status'='recorded','backup recorded: '||r::text);
 r:=sdi_private.ops_report('release','succeeded','1.4.0',jsonb_build_object());
 perform sdi_test.check(r->>'status'='recorded','release recorded');
 r:=sdi_private.ops_report('rollback','succeeded','3f2a9c1',jsonb_build_object());
 perform sdi_test.check(r->>'status'='recorded','commit-hash rollback recorded');
 r:=sdi_private.ops_report('backup','failed','db.internal.example.com',jsonb_build_object());
 perform sdi_test.check(r->>'error' like 'Labels are%','host-like label refused');
 r:=sdi_private.ops_report('backup','failed','',jsonb_build_object('bucket','s3://private-backups'));
 perform sdi_test.check(r->>'error' like 'Metrics are%','text metric refused');
 r:=sdi_private.ops_report('backup','failed','',jsonb_build_object('bytes',-1));
 perform sdi_test.check(r->>'error' like 'Metrics are%','negative metric refused');
 r:=sdi_private.ops_report('shell','succeeded','',jsonb_build_object());
 perform sdi_test.check(r->>'error' like 'Unknown%','unknown kind refused');
 perform sdi_test.check(not has_function_privilege('authenticated','public.sdi_ops_report(text,text,text,jsonb)','execute'),'clients cannot report operations');

 perform sdi_test.login(viewer,'aal2');
 r:=sdi_private.admin_operations();
 perform sdi_test.check(not (r->'backup'->>'stale')::boolean and r->'release'->>'label'='1.4.0' and r->'rollback'->>'label'='3f2a9c1','status reflects reports: '||r::text);
 perform sdi_test.check(jsonb_array_length(r->'recent')=3 and r->'retention' ? 'render_artifacts_expired','recent outcomes and retention counts');
 perform sdi_test.check((r - 'note')::text !~* 'host|password|secret|s3://|internal','no topology or credentials in the reply');
 -- A member without a role is refused and the refusal is audited.
 perform sdi_test.login(member,'aal2');
 r:=sdi_private.admin_operations();
 perform sdi_test.check(r->>'code'='forbidden','members cannot read operations status');
 perform sdi_test.check(exists(select 1 from sdi_private.admin_access_audit where actor=member and operation='admin_operations' and not allowed),'denial audited');

 -- Audit records are append-only within the 400-day window.
 select id into audit_id from sdi_private.admin_access_audit where actor=member limit 1;
 blocked:=false;
 begin update sdi_private.admin_access_audit set detail='edited' where id=audit_id; exception when insufficient_privilege then blocked:=true; end;
 perform sdi_test.check(blocked,'audit rows cannot be edited');
 blocked:=false;
 begin delete from sdi_private.admin_access_audit where id=audit_id; exception when insufficient_privilege then blocked:=true; end;
 perform sdi_test.check(blocked,'recent audit rows cannot be deleted');
 blocked:=false;
 begin delete from sdi_private.ops_reports; exception when insufficient_privilege then blocked:=true; end;
 perform sdi_test.check(blocked,'operations reports cannot be deleted');

 -- Agent console: per-run cost cap, enforced when the run reports its cost.
 perform sdi_test.login(owner,'aal2');
 select revision into rev from sdi_private.agents where key='support_triage';
 r:=sdi_private.agent_admin('publish_instructions','support_triage',rev,'{"body":"Triage only."}','Initial.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('set_caps','support_triage',rev,'{"daily_run_cap":"5","per_run_item_cap":"10","monthly_cost_cap_minor":"1000","per_run_cost_cap_minor":"abc"}','Caps.');
 perform sdi_test.check(r->>'error' like 'The per-run cost cap%','non-numeric per-run cap refused');
 r:=sdi_private.agent_admin('set_caps','support_triage',rev,'{"daily_run_cap":"5","per_run_item_cap":"10","monthly_cost_cap_minor":"1000","per_run_cost_cap_minor":"100"}','Caps.');
 perform sdi_test.check(r->>'status'='confirmed','per-run cap saved: '||r::text); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('resume','support_triage',rev,'{}','Enable.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.logout();
 r:=sdi_private.agent_run_begin('support_triage','batch-1');
 perform sdi_test.check((r->>'run_cost_cap_minor')::bigint=100,'run receives the tighter per-run cap: '||r::text); run:=(r->>'run')::uuid;
 perform sdi_test.check(sdi_private.agent_run_finish(run,'succeeded',3,60,''),'run within cap finishes');
 perform sdi_test.check(not (select paused from sdi_private.agents where key='support_triage'),'within cap keeps the agent enabled');
 r:=sdi_private.agent_run_begin('support_triage','batch-2'); run:=(r->>'run')::uuid;
 perform sdi_test.check((r->>'run_cost_cap_minor')::bigint=100,'remaining monthly budget is larger than the per-run cap');
 perform sdi_test.check(sdi_private.agent_run_finish(run,'succeeded',2,250,''),'overspend is recorded as reported');
 perform sdi_test.check((select paused from sdi_private.agents where key='support_triage'),'overspend pauses the agent');
 perform sdi_test.check((select cost_minor from sdi_private.agent_runs where id=run)=250 and (select error from sdi_private.agent_runs where id=run) like '%Cost cap exceeded%','true cost kept with the reason');
 r:=sdi_private.agent_run_begin('support_triage','batch-3');
 perform sdi_test.check(r->>'reason'='Agent is paused.','no further runs until the owner resumes');

 -- Registry shows last error, last start and proposal queue depth; history is searchable and paged.
 perform sdi_test.login(viewer,'aal2');
 r:=sdi_private.agent_admin('list');
 perform sdi_test.check((select (a->>'pending_proposals')::integer=0 and (a->>'per_run_cost_cap_minor')::bigint=100 and a->>'last_started' is not null
  from jsonb_array_elements(r->'agents') a where a->>'key'='support_triage'),'registry carries cap, queue depth and last start: '||r::text);
 r:=sdi_private.agent_admin('runs','support_triage',null,'{"query":"batch-2"}');
 perform sdi_test.check(jsonb_array_length(r->'runs')=1 and r->'runs'->0->>'source_ref'='batch-2' and not (r->>'has_more')::boolean,'run search by reference');
 r:=sdi_private.agent_admin('runs','support_triage',null,'{"state":"running"}');
 perform sdi_test.check(jsonb_array_length(r->'runs')=0,'state filter');
 r:=sdi_private.agent_admin('runs',null,null,'{"state":"deleted"}');
 perform sdi_test.check(r->>'error'='Invalid history filter.','unknown state refused');
 r:=sdi_private.agent_admin('runs',null,null,'{"page":"500"}');
 perform sdi_test.check(r->>'error'='Invalid history filter.','page bound');
 r:=sdi_private.agent_admin('audit','support_triage',null,'{"query":"caps"}');
 perform sdi_test.check(jsonb_array_length(r->'audit')=1 and r->'audit'->0->>'action'='set_caps','audit searchable by text: '||r::text);
 r:=sdi_private.agent_admin('audit');
 perform sdi_test.check(jsonb_array_length(r->'audit')>=3,'all agents audit');
 perform sdi_test.login(member,'aal2');
 r:=sdi_private.agent_admin('audit');
 perform sdi_test.check(r->>'error' is not null and r->'audit' is null,'members cannot read the agent audit');
 perform sdi_test.logout();

 -- Retention keeps recent runs and audit rows; old finished runs are removed.
 update sdi_private.agent_runs set started_at=clock_timestamp()-interval '200 days' where id=run;
 r:=sdi_private.agent_log_retention();
 perform sdi_test.check((r->>'runs_deleted')::integer=1 and (r->>'audit_deleted')::integer=0,'retention removes only expired runs: '||r::text);
 perform sdi_test.check(not has_function_privilege('authenticated','public.sdi_agent_log_retention()','execute'),'retention is service-only');

 -- User directory: plan is redacted without finance; state changes need a recent second factor.
 perform sdi_test.login(viewer,'aal2');
 r:=sdi_private.users_action('list',query=>'ops-member');
 perform sdi_test.check(jsonb_array_length(r->'users')=1 and r->'users'->0->'plan'='null'::jsonb,'plan hidden without finance: '||r::text);
 r:=sdi_private.users_action('suspend',member,reason=>'Spam.');
 perform sdi_test.check(r->>'code'='step_up_required','suspension without a recent second factor refused: '||r::text);
 perform sdi_test.check(not exists(select 1 from sdi_private.account_controls where user_id=member),'nothing changed on refusal');
 perform sdi_test.login(viewer,'aal2',60);
 r:=sdi_private.users_action('suspend',member,reason=>'Spam.');
 perform sdi_test.check(r->>'status'='confirmed','suspension with step-up confirmed: '||r::text);
 perform sdi_test.check((select state from sdi_private.account_controls where user_id=member)='suspended','state applied server-side');
 perform sdi_test.check(exists(select 1 from sdi_private.admin_user_audit where subject=member and action='suspend' and reason='Spam.'),'action audited');
 r:=sdi_private.users_action('note',outsider,reason=>'Watch for repeat reports.');
 perform sdi_test.check(r->>'status'='confirmed','internal note does not need step-up');
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.users_action('list',query=>'ops-member');
 perform sdi_test.check(r->'users'->0->>'plan'='free','owner sees the plan (no entitlement means free)');
 perform sdi_test.login(member,'aal2',60);
 r:=sdi_private.users_action('list');
 perform sdi_test.check(r->>'error' is not null and r->'users' is null,'suspended non-admins cannot read the directory');
end $$;
rollback;
