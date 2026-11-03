-- Local assertions for the provider health view in worker-configuration.sql (#248):
-- per-integration presence, last success/failure with a closed error class, no values.
begin;
do $$
declare admin uuid; member uuid; r jsonb; item jsonb; ann uuid; ios uuid; droid uuid;
begin
 admin:=sdi_test.admin('provider-admin',false,array['overview']); member:=sdi_test.user('provider-member');

 -- Nothing reported and no activity: every integration reads unreported, nothing invented.
 perform sdi_test.login(admin,'aal2');
 r:=sdi_private.admin_provider_health();
 perform sdi_test.check(jsonb_array_length(r->'providers')=6,'six integrations listed: '||r::text);
 perform sdi_test.check((select bool_and(e->>'health'='unreported' and e->>'configured'='unreported' and e->'last_success_at'='null'::jsonb
   and e->'last_failure_at'='null'::jsonb) from jsonb_array_elements(r->'providers') e),'empty backend reports nothing as healthy');
 perform sdi_test.logout();

 -- Presence comes from worker_configuration; a partial set is unconfigured with the missing names.
 perform sdi_test.check(sdi_private.worker_configuration_report('service-sweeps',
  '{"sdi_mail_sender_domain":true,"sdi_mail_credentials_file":false,"sdi_stripe_webhook_secret_file":true,"sdi_youtube_client_file":true,"sdi_youtube_token_file":true,
    "sdi_apns_key_id":true,"sdi_apns_team_id":true,"sdi_apns_key_file":true,"sdi_apns_topic":true,"sdi_fcm_project_id":true,"sdi_fcm_service_account_file":true}'),'presence reported');

 -- Service-reported outcomes: closed vocabulary only, no free text.
 perform sdi_test.check(not sdi_private.provider_outcome_report('email',false,'smtp said: 535 bad password for owner@example.test'),'free-text error refused');
 perform sdi_test.check(not sdi_private.provider_outcome_report('email',false,null),'failure needs a class');
 perform sdi_test.check(not sdi_private.provider_outcome_report('email',true,'network'),'success carries no class');
 perform sdi_test.check(not sdi_private.provider_outcome_report('openai',true),'unknown provider refused');
 perform sdi_test.check(sdi_private.provider_outcome_report('email',false,'authentication'),'email failure recorded');
 perform sdi_test.check(sdi_private.provider_outcome_report('email',false,'network'),'second email failure recorded');
 perform sdi_test.check((select consecutive_failures from sdi_private.provider_outcomes where provider='email')=2,'consecutive failures counted');

 -- Durable records: Stripe events, push deliveries per platform, Spatter draft jobs.
 insert into sdi_private.provider_events(provider,event_id,event_type,occurred_at,payload,processed_at,outcome)
  values('stripe','evt_ok','invoice.paid',clock_timestamp()-interval '2 hours','{}',clock_timestamp()-interval '2 hours','applied'),
        ('stripe','evt_bad','invoice.paid',clock_timestamp()-interval '1 hour','{}',clock_timestamp()-interval '1 hour','error');
 insert into sdi_private.announcements(title,body,category,audience,channels,created_by,state)
  values('T','B','product','all',array['push'],admin,'sent') returning id into ann;
 insert into sdi_private.device_tokens(user_id,platform,environment,device_token) values(member,'ios','production',repeat('a',64)) returning id into ios;
 insert into sdi_private.device_tokens(user_id,platform,environment,device_token) values(admin,'android','production',repeat('b',64)) returning id into droid;
 insert into sdi_private.announcement_deliveries(announcement_id,user_id,channel,device_id,state,reason,updated_at)
  values(ann,member,'push',ios,'sent','',clock_timestamp()-interval '3 hours'),
        (ann,admin,'push',droid,'failed','fcm status 401 UNAUTHENTICATED',clock_timestamp()-interval '30 minutes');
 insert into sdi_private.spatter_draft_jobs(target_date,state,planner_seed,brief_version,brief,updated_at)
  values(current_date-1,'review_pending',1,'v3','{}',clock_timestamp()-interval '5 hours');

 perform sdi_test.login(member);
 r:=sdi_private.admin_provider_health();
 perform sdi_test.check(r->>'code'='forbidden','members cannot read provider health: '||r::text);
 perform sdi_test.login(admin,'aal2');
 r:=sdi_private.admin_provider_health();
 select e into item from jsonb_array_elements(r->'providers') e where e->>'provider'='email';
 perform sdi_test.check(item->>'configured'='no' and item->'missing'='["sdi_mail_credentials_file"]'::jsonb and item->>'health'='unconfigured'
  and item->>'last_error_class'='network' and (item->>'consecutive_failures')::integer=2,'email: missing credential named, latest class: '||item::text);
 select e into item from jsonb_array_elements(r->'providers') e where e->>'provider'='stripe';
 perform sdi_test.check(item->>'configured'='yes' and item->>'health'='failing' and item->>'last_error_class'='event_error'
  and item->'last_success_at'<>'null'::jsonb,'stripe: later event error is failing: '||item::text);
 select e into item from jsonb_array_elements(r->'providers') e where e->>'provider'='apns';
 perform sdi_test.check(item->>'health'='healthy' and item->'last_failure_at'='null'::jsonb,'apns: sent delivery is healthy: '||item::text);
 select e into item from jsonb_array_elements(r->'providers') e where e->>'provider'='fcm';
 perform sdi_test.check(item->>'health'='failing' and item->>'last_error_class'='authentication','fcm: 401 classed as authentication: '||item::text);
 select e into item from jsonb_array_elements(r->'providers') e where e->>'provider'='youtube';
 perform sdi_test.check(item->>'configured'='yes' and item->>'health'='no_activity','youtube: configured, no activity yet: '||item::text);
 select e into item from jsonb_array_elements(r->'providers') e where e->>'provider'='spatter';
 perform sdi_test.check(item->>'configured'='unreported' and item->>'health'='healthy' and item->'missing'='["sdi_draft_renderer_cli"]'::jsonb,'spatter: render outcome without presence report: '||item::text);
 perform sdi_test.check(position('UNAUTHENTICATED' in r::text)=0 and position('535' in r::text)=0 and position(repeat('a',64) in r::text)=0,'no provider message or token reaches the reader');

 -- A device that unregistered is not a provider failure.
 update sdi_private.announcement_deliveries set reason='unregistered' where device_id=droid;
 r:=sdi_private.admin_provider_health();
 select e into item from jsonb_array_elements(r->'providers') e where e->>'provider'='fcm';
 perform sdi_test.check(item->'last_failure_at'='null'::jsonb and item->>'health'='no_activity','device rejection ignored: '||item::text);

 -- A later success clears the failing state and resets the run of failures.
 perform sdi_test.logout();
 perform sdi_test.check(sdi_private.provider_outcome_report('stripe',true),'stripe success reported');
 perform sdi_test.login(admin,'aal2');
 r:=sdi_private.admin_provider_health();
 select e into item from jsonb_array_elements(r->'providers') e where e->>'provider'='stripe';
 perform sdi_test.check(item->>'health'='healthy' and (item->>'consecutive_failures')::integer=0,'stripe healthy after success: '||item::text);
 perform sdi_test.logout();
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_provider_outcome(''email'',true)'),'clients cannot report outcomes');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_admin_provider_health()'),'anonymous cannot read provider health');
end $$;
rollback;
