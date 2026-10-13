-- Local assertions for worker-configuration.sql: presence booleans only, masked reads.
begin;
do $$
declare admin uuid; member uuid; r jsonb;
begin
 admin:=sdi_test.admin('config-admin',false,array['overview']); member:=sdi_test.user('config-member');
 perform sdi_test.check(sdi_private.worker_configuration_report('publishing-worker','{"youtube_client":true,"youtube_refresh_token":false,"stripe_webhook_secret":true}'),'presence report accepted');
 perform sdi_test.check(not sdi_private.worker_configuration_report('publishing-worker','{"youtube_client":"ya29.secret-looking-value"}'),'string value refused');
 perform sdi_test.check(not sdi_private.worker_configuration_report('publishing-worker','{"count":3}'),'number value refused');
 perform sdi_test.check(not sdi_private.worker_configuration_report('publishing-worker','{"nested":{"ok":true}}'),'nested object refused');
 perform sdi_test.check(not sdi_private.worker_configuration_report('publishing-worker','{"Bad Key":true}'),'key format enforced');
 perform sdi_test.check(not sdi_private.worker_configuration_report('bad worker!','{"a":true}'),'worker name format enforced');
 perform sdi_test.check((select settings from sdi_private.worker_configuration where worker='publishing-worker')='{"youtube_client":true,"youtube_refresh_token":false,"stripe_webhook_secret":true}'::jsonb,'refused reports left the last good presence in place');
 perform sdi_test.check(sdi_private.worker_configuration_report('publishing-worker','{"youtube_client":true,"youtube_refresh_token":true,"stripe_webhook_secret":true}'),'report replaces presence');
 update sdi_private.worker_configuration set reported_at=clock_timestamp()-interval '2 days' where worker='publishing-worker';
 perform sdi_test.check(sdi_private.worker_configuration_report('mail-sender','{"sender_domain":false,"smtp_credentials":false}'),'second worker reports');
 perform sdi_test.login(member);
 r:=sdi_private.admin_configuration();
 perform sdi_test.check(r->>'code'='forbidden','members cannot read configuration presence: '||r::text);
 perform sdi_test.login(admin,'aal2');
 r:=sdi_private.admin_configuration();
 perform sdi_test.check(jsonb_array_length(r->'workers')=2,'both workers listed: '||r::text);
 perform sdi_test.check((r->'workers'->0->>'worker')='mail-sender' and (r->'workers'->0->'missing')='["sender_domain","smtp_credentials"]'::jsonb and not (r->'workers'->0->>'stale')::boolean,'missing settings named, fresh report not stale');
 perform sdi_test.check((r->'workers'->1->>'worker')='publishing-worker' and (r->'workers'->1->>'stale')::boolean and (r->'workers'->1->'missing')='[]'::jsonb,'old report flagged stale');
 perform sdi_test.check(position('secret-looking-value' in r::text)=0,'no value text reaches the reader');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_worker_configuration(''x'',''{}'')'),'clients cannot report configuration');
end $$;
rollback;
