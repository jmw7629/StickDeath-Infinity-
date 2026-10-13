-- Local assertions for billing.sql (idempotent events, entitlements, no invented prices)
-- and agent-controls.sql (pause, emergency stop, caps, instruction versions).
begin;
do $$
declare member uuid; owner uuid; finance uuid; r jsonb; ev jsonb; sub uuid; paid timestamptz:=clock_timestamp()+interval '30 days';
begin
 member:=sdi_test.user('subscriber'); owner:=sdi_test.admin('bill-owner',true,array[]::text[]); finance:=sdi_test.admin('bookkeeper',false,array['finance']);
 perform sdi_test.check(not exists(select 1 from information_schema.columns where table_schema='sdi_private' and table_name='billing_products' and column_name ~ 'price|amount'),'no price column on products');

 -- Product approval is owner-only; annual requires explicit configuration first.
 perform sdi_test.login(finance,'aal2');
 r:=sdi_private.finance_admin('set_product',product=>'sdi.creator.monthly',provider=>'apple',tier=>'creator',period=>'monthly',approved=>true,reason=>'Owner price point USD 4.99.');
 perform sdi_test.check(r->>'error'='Owner permission required.','finance admin cannot approve products');
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.finance_admin('set_product',product=>'sdi.creator.monthly',provider=>'apple',tier=>'creator',period=>'monthly',approved=>true,reason=>'Owner price point USD 4.99.');
 perform sdi_test.check(r->>'status'='confirmed','monthly product approved: '||r::text);
 r:=sdi_private.finance_admin('set_product',product=>'sdi.pro.annual',provider=>'apple',tier=>'pro',period=>'annual',approved=>true,reason=>'Trying annual.');
 perform sdi_test.check(r->>'error' like 'Annual offers need%','annual cannot be approved without owner configuration');
 r:=sdi_private.finance_admin('set_product',product=>'sdi.pro.annual',provider=>'apple',tier=>'pro',period=>'annual',approved=>false,reason=>'Placeholder identifier only.');
 perform sdi_test.check(r->>'status'='confirmed','unapproved annual identifier recorded');

 -- Events: duplicate ids ignored, unapproved product grants nothing, order respected.
 ev:=sdi_private.billing_apply_event('apple','evt-1','SUBSCRIBED',clock_timestamp()-interval '2 minutes','{"environment":"Sandbox"}',member,'orig-1','sdi.creator.monthly','active',paid);
 perform sdi_test.check(ev->>'outcome'='applied' and ev->>'subscription' is not null,'subscription applied: '||ev::text); sub:=(ev->>'subscription')::uuid;
 ev:=sdi_private.billing_apply_event('apple','evt-1','SUBSCRIBED',clock_timestamp(),'{}',member,'orig-1','sdi.creator.monthly','active',paid);
 perform sdi_test.check((ev->>'duplicate')::boolean,'duplicate event id recorded once');
 ev:=sdi_private.billing_apply_event('apple','evt-2','SUBSCRIBED',clock_timestamp(),'{}',member,'orig-2','sdi.pro.annual','active',paid);
 perform sdi_test.check(ev->>'outcome'='ignored' and not exists(select 1 from sdi_private.subscriptions where provider_subscription_id='orig-2'),'unapproved product grants nothing');
 ev:=sdi_private.billing_apply_event('apple','evt-0','DID_FAIL_TO_RENEW',clock_timestamp()-interval '1 hour','{}',member,'orig-1','sdi.creator.monthly','past_due',paid-interval '30 days');
 perform sdi_test.check(ev->>'outcome'='ignored' and (select status from sdi_private.subscriptions where id=sub)='active','older event cannot move the subscription backwards');
 perform sdi_test.login(member);
 r:=sdi_private.my_entitlement();
 perform sdi_test.check(r->>'tier'='creator' and r->>'status'='active','member reads entitlement from provider events: '||r::text);
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_billing_apply_event(''apple'',''x'',''t'',now(),''{}'')'),'clients cannot apply billing events');
 ev:=sdi_private.billing_apply_event('apple','evt-3','REFUND',clock_timestamp(),'{}',member,'orig-1','sdi.creator.monthly','refunded',clock_timestamp()-interval '1 second',
  ledger=>'[{"ref":"txn-1","kind":"refund","amount_minor":-499,"currency":"USD"}]');
 perform sdi_test.check(ev->>'outcome'='applied','refund applied');
 r:=sdi_private.my_entitlement();
 perform sdi_test.check(r->>'tier'='free','refund ends entitlement');
 perform sdi_test.check((select count(*) from sdi_private.finance_ledger where provider_ref='txn-1')=1,'ledger row recorded once');
 ev:=sdi_private.billing_apply_event('apple','evt-4','REFUND',clock_timestamp(),'{}',ledger=>'[{"ref":"txn-1","kind":"refund","amount_minor":-499,"currency":"USD"}]');
 perform sdi_test.check((select count(*) from sdi_private.finance_ledger where provider_ref='txn-1')=1,'duplicate ledger ref ignored');
 perform sdi_test.login(finance,'aal2');
 r:=sdi_private.finance_admin('summary');
 perform sdi_test.check(r->>'label' like '%not shown here%' and jsonb_array_length(r->'totals')=1,'finance summary labelled as provider records');
 r:=sdi_private.billing_reconcile();
 perform sdi_test.check(r ? 'expired_now' and r ? 'unprocessed_events','reconciliation report');
end $$;

do $$
declare owner uuid; viewer uuid; r jsonb; rev bigint; run uuid;
begin
 owner:=sdi_test.admin('agent-owner',true,array[]::text[]); viewer:=sdi_test.admin('agent-viewer',false,array['overview']);
 r:=sdi_private.agent_run_begin('spatter_daily_video','2026-10-12');
 perform sdi_test.check((r->>'allowed')::boolean=false and r->>'reason'='Agent is paused.','agents start paused');
 perform sdi_test.login(viewer,'aal2');
 r:=sdi_private.agent_admin('list');
 perform sdi_test.check(jsonb_array_length(r->'agents')=5,'overview admin lists agents');
 select revision into rev from sdi_private.agents where key='spatter_daily_video';
 r:=sdi_private.agent_admin('resume','spatter_daily_video',rev,'{}','Go.');
 perform sdi_test.check(r->>'error' like 'Owner permission%','non-owner cannot change agents');
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.agent_admin('resume','spatter_daily_video',rev,'{}','Enable drafts.');
 perform sdi_test.check(r->>'error' like 'Publish instructions%','cannot resume without instructions');
 r:=sdi_private.agent_admin('publish_instructions','spatter_daily_video',rev,'{"body":"Produce one private draft per day. Never publish."}','Initial instructions.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check(r->>'status'='confirmed','instructions v1 published');
 r:=sdi_private.agent_admin('publish_instructions','spatter_daily_video',rev,'{"body":"Draft v2."}','Second version.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('rollback_instructions','spatter_daily_video',rev,'{"version":1}','Revert to v1.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check((select active_instruction_version from sdi_private.agents where key='spatter_daily_video')=1,'rollback restores version 1');
 r:=sdi_private.agent_admin('set_caps','spatter_daily_video',rev,'{"daily_run_cap":"1","per_run_item_cap":"1","monthly_cost_cap_minor":"500"}','Tight caps.'); rev:=(r->>'revision')::bigint;
 r:=sdi_private.agent_admin('resume','spatter_daily_video',rev,'{}','Enable drafts.'); rev:=(r->>'revision')::bigint;
 perform sdi_test.check(r->>'status'='confirmed','agent resumed');
 r:=sdi_private.agent_run_begin('spatter_daily_video','2026-10-12');
 perform sdi_test.check((r->>'allowed')::boolean and r->>'instructions' like 'Produce one private draft%' and (r->>'instruction_version')::integer=1,'run allowed with active instructions: '||r::text);
 run:=(r->>'run')::uuid;
 perform sdi_test.check((sdi_private.agent_run_begin('spatter_daily_video','again')->>'reason')='A run is already in progress.','concurrent run refused');
 perform sdi_test.check(sdi_private.agent_run_heartbeat(run),'heartbeat accepted');
 perform sdi_test.check(sdi_private.agent_run_finish(run,'succeeded',1,120,''),'run finished');
 perform sdi_test.check((sdi_private.agent_run_begin('spatter_daily_video','x')->>'reason')='Daily run cap reached.','daily cap enforced');
 r:=sdi_private.agent_admin('emergency_stop',payload=>'{"enabled":true}',reason=>'Stop everything.');
 perform sdi_test.check(r->>'status'='confirmed','emergency stop set');
 perform sdi_test.check((select reason from sdi_private.agent_global)='Stop everything.','emergency reason recorded');
 perform sdi_test.check((sdi_private.agent_run_begin('finance_reconcile','x')->>'reason')='Emergency stop is active.','emergency stop blocks every agent');
 perform sdi_test.check(not sdi_private.agent_run_heartbeat(run),'heartbeat refused under emergency stop');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_agent_run_begin(''support_triage'')'),'clients cannot start agent runs');
end $$;
rollback;
