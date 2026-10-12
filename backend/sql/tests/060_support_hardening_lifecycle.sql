-- Local assertions for support-requests.sql, admin-hardening.sql and account-lifecycle.sql.
begin;
do $$
declare member uuid; other uuid; agent uuid; r jsonb; key uuid:=gen_random_uuid(); first uuid; receipt text; i integer;
begin
 member:=sdi_test.user('customer'); other:=sdi_test.user('other-customer'); agent:=sdi_test.admin('support-agent',false,array['users']);
 perform sdi_test.login(member);
 r:=sdi_private.support_action('create',category=>'studio',platform=>'ios',app_version=>'1.0 (12)',subject=>'Export stalls',body=>'MP4 export stops at 90%.',idempotency=>key);
 perform sdi_test.check(r->>'status'='created' and r->>'receipt' ~ '^SDI-[A-Z0-9]{10}$','request created with receipt: '||r::text);
 first:=(r->>'request_id')::uuid; receipt:=r->>'receipt';
 r:=sdi_private.support_action('create',category=>'studio',platform=>'ios',subject=>'Export stalls',body=>'MP4 export stops at 90%.',idempotency=>key);
 perform sdi_test.check(r->>'status'='duplicate' and r->>'receipt'=receipt,'idempotency key returns the same receipt');
 for i in 2..5 loop
  r:=sdi_private.support_action('create',category=>'bug',platform=>'android',subject=>'Issue '||i,body=>'Details.',idempotency=>gen_random_uuid());
  perform sdi_test.check(r->>'status'='created','request '||i||' created');
 end loop;
 r:=sdi_private.support_action('create',category=>'bug',platform=>'android',subject=>'Issue 6',body=>'Details.',idempotency=>gen_random_uuid());
 perform sdi_test.check(r->>'error' like 'Daily support request limit%','sixth request in a day refused');
 r:=sdi_private.support_action('list_mine');
 perform sdi_test.check(jsonb_array_length(r->'requests')=5,'member lists own requests');
 perform sdi_test.login(other);
 r:=sdi_private.support_action('withdraw',first);
 perform sdi_test.check(r->>'error'='Request unavailable.','another member cannot touch the request');
 r:=sdi_private.support_action('list');
 perform sdi_test.check(r->>'code'='forbidden','member cannot read the admin queue');
 perform sdi_test.login(agent);
 r:=sdi_private.support_action('list');
 perform sdi_test.check(r->>'code'='forbidden','admin without aal2 denied');
 perform sdi_test.check((select count(*) from sdi_private.admin_access_audit where actor=agent and not allowed)=1,'denial audited');
 perform sdi_test.login(agent,'aal2');
 r:=sdi_private.support_action('list');
 perform sdi_test.check(jsonb_array_length(r->'requests')=5 and r->'requests'->0->>'receipt'=receipt,'admin queue oldest first');
 r:=sdi_private.support_action('update_status',first,status=>'resolved',note=>'Fixed in 1.0 (13).',revision=>1);
 perform sdi_test.check(r->>'status'='confirmed','status updated');
 r:=sdi_private.support_action('update_status',first,status=>'open',note=>'Reopen.',revision=>1);
 perform sdi_test.check(r->>'error' like 'Request changed%','stale revision refused');
 perform sdi_test.login(member);
 r:=sdi_private.support_action('list_mine');
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'requests') e where e->>'receipt'=receipt and e->>'status'='resolved')=1,'member sees resolution');
 r:=sdi_private.support_action('delete',first);
 perform sdi_test.check(r->>'status'='confirmed' and (select body from sdi_private.support_requests where id=first)='[deleted by member]','member deletion scrubs content');
end $$;

do $$
declare boss uuid; admin uuid; member uuid; candidate uuid; r jsonb; i integer; ok integer:=0;
begin
 boss:=sdi_test.admin('hard-owner',true,array[]::text[]); admin:=sdi_test.admin('hard-admin',false,array['overview']); member:=sdi_test.user('plain-member');
 candidate:=sdi_test.user('owner-candidate');
 -- Step-up: role changes need a recent MFA verification in the token.
 perform sdi_test.login(boss,'aal2');
 perform sdi_test.check(not sdi_private.recently_authenticated(),'no amr means no recent MFA');
 r:=sdi_private.admin_permissions('save',member,array['reviews'],true,'Trusted reviewer.',0);
 perform sdi_test.check(r->>'code'='step_up_required','role change requires step-up: '||r::text);
 perform sdi_test.login(boss,'aal2',3600);
 r:=sdi_private.admin_permissions('save',member,array['reviews'],true,'Trusted reviewer.',0);
 perform sdi_test.check(r->>'code'='step_up_required','old MFA verification is not recent');
 perform sdi_test.login(boss,'aal2',60);
 r:=sdi_private.admin_permissions('save',member,array['reviews'],true,'Trusted reviewer.',0);
 perform sdi_test.check(r->>'status'='confirmed','recent MFA allows the role change: '||r::text);
 -- Rate limit.
 for i in 1..20 loop perform sdi_private.admin_rate_ok(20); end loop;
 perform sdi_test.check(not sdi_private.admin_rate_ok(20),'admin rate limit trips after the cap');
 -- Owner provisioning: service only, needs confirmed email and verified MFA, no password anywhere.
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_provision_owner(gen_random_uuid(),''JWS'',''J_Willy_Style'')'),'clients cannot provision owners');
 perform sdi_test.check(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='sdi_private' and p.proname='provision_owner' and pg_get_function_arguments(p.oid) ilike '%password%'),'provisioning takes no password');
 r:=sdi_private.provision_owner(candidate,'JWS','J_Willy_Style');
 perform sdi_test.check(r->>'error' like 'Enrol and verify%','unverified MFA refused');
 insert into auth.mfa_factors(user_id,factor_type,status) values(candidate,'totp','verified');
 r:=sdi_private.provision_owner(candidate,'JWS','J_Willy_Style');
 perform sdi_test.check(r->>'error' like 'An owner already exists%','bootstrap only while no owner exists');
 update sdi_private.admin_roles set enabled=false where user_id=boss;
 r:=sdi_private.provision_owner(candidate,'JWS','J_Willy_Style');
 perform sdi_test.check(r->>'status'='provisioned','owner provisioned once no enabled owner exists: '||r::text);
 perform sdi_test.check((select owner and enabled from sdi_private.admin_roles where user_id=candidate),'owner role granted');
 perform sdi_test.check((select handle from sdi_private.admin_profiles where user_id=candidate)='J_Willy_Style','handle bound');
 perform sdi_test.check((sdi_private.provision_owner(candidate,'JWS','J_Willy_Style')->>'status')='already_owner','provisioning is idempotent');
 perform sdi_test.check((select count(*) from auth.sessions where user_id=candidate)=0,'existing sessions ended for fresh MFA sign-in');
 -- Health: overview capability, worker heartbeats, no host details.
 perform sdi_test.check(sdi_private.worker_heartbeat('publishing-worker','ok'),'worker heartbeat recorded');
 insert into sdi_private.worker_heartbeats(worker,seen_at) values('intake-retention',clock_timestamp()-interval '1 hour');
 perform sdi_test.login(member);
 perform sdi_test.check((sdi_private.admin_health()->>'code')='forbidden','member cannot read health');
 perform sdi_test.login(admin,'aal2');
 r:=sdi_private.admin_health();
 perform sdi_test.check(r ? 'queues' and r ? 'oldest_pending' and (r->'queues') ? 'support_open' and (r->'queues') ? 'deletion_requests_due','health has queue counts: '||r::text);
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'workers') w where w->>'worker'='intake-retention' and (w->>'stale')::boolean)=1,'stale worker flagged');
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'workers') w where w->>'worker'='publishing-worker' and not (w->>'stale')::boolean)=1,'fresh worker not stale');
 perform sdi_test.check(r::text !~* 'host|password|secret','health leaks no host or secret fields');
end $$;

do $$
declare member uuid; friend uuid; admin uuid; media uuid; the_post uuid; room uuid; review uuid; sub uuid; r jsonb; req bigint;
begin
 member:=sdi_test.user('leaver'); friend:=sdi_test.user('friend'); admin:=sdi_test.admin('life-admin',false,array['users']);
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest) values('Leaver clip','https://cdn.example.test/l.mp4',5,true,member,repeat('f',64)) returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,visible) values(media,member,'leaver',true) returning id into the_post;
 insert into sdi_private.war_matches(creator,opponent,left_media,left_digest) values(member,friend,media,repeat('f',64));
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,destinations)
 values(member,'Leaver clip','rev',repeat('f',64),'https://intake.example.test/l',clock_timestamp()+interval '1 day','terms-v1','Mine',true,array['feed']) returning id into review;
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,made_for_kids,expires_at)
 values(review,1,repeat('f',64),'l.mp4',10,'Leaver clip',false,clock_timestamp()+interval '1 day');
 insert into sdi_private.upload_registrations(upload_id,creator,review_id,metadata,object_key) values(gen_random_uuid(),member,review,'{}','l.mp4');
 insert into sdi_private.billing_products(product_id,provider,tier,period,approved,owner_configured_at) values('sdi.pro.monthly','stripe','pro','monthly',true,clock_timestamp());
 insert into sdi_private.subscriptions(user_id,provider,provider_subscription_id,product_id,status,paid_through,last_event_at) values(member,'stripe','sub_1','sdi.pro.monthly','active',clock_timestamp()+interval '20 days',clock_timestamp()) returning id into sub;
 perform sdi_test.login(member);
 r:=sdi_private.room_action('create',title=>'Leaver room',consent=>true); room:=(r->>'room_id')::uuid;
 r:=sdi_private.support_action('create',category=>'account',platform=>'ios',subject=>'Delete me',body=>'Please delete.',idempotency=>gen_random_uuid());

 -- Export includes own rows only and is rate limited.
 r:=sdi_private.account_lifecycle('export');
 perform sdi_test.check(jsonb_array_length(r->'feed_posts')=1 and jsonb_array_length(r->'war_matches')=1 and jsonb_array_length(r->'rooms_owned')=1
  and jsonb_array_length(r->'subscriptions')=1 and jsonb_array_length(r->'support_requests')=1 and r->>'note' like 'Editable projects%','export has own records: '||left(r::text,300));
 perform sdi_test.check(r::text !~ 'Account deletion in progress' and (r->'account_state'->>'state')='active','export excludes internal reasons');
 perform sdi_private.account_lifecycle('export'); perform sdi_private.account_lifecycle('export');
 perform sdi_test.check((sdi_private.account_lifecycle('export')->>'error') like 'Three exports%','export limit');

 -- Request, cancel, request again; admins are refused.
 perform sdi_test.login(admin);
 perform sdi_test.check((sdi_private.account_lifecycle('request_deletion')->>'error') like 'Administrator accounts%','admin deletion uses separate procedure');
 perform sdi_test.login(member);
 r:=sdi_private.account_lifecycle('request_deletion'); req:=(r->>'revision')::bigint;
 perform sdi_test.check(r->>'status'='pending' and (r->>'scheduled_for')::timestamptz>clock_timestamp()+interval '6 days','deletion scheduled after cooling-off');
 perform sdi_test.check((sdi_private.member_notices('list')->>'unread')::integer=1,'member notified');
 perform sdi_test.check((sdi_private.account_lifecycle('cancel_deletion',req)->>'status')='cancelled','deletion cancelled');
 perform sdi_test.check((sdi_private.account_deletion_run()->>'action')='idle','nothing due');
 r:=sdi_private.account_lifecycle('request_deletion');
 perform sdi_test.check(r->>'status'='pending','re-requested');
 update sdi_private.deletion_requests set scheduled_for=clock_timestamp()-interval '1 minute' where user_id=member;
 r:=sdi_private.account_deletion_run();
 perform sdi_test.check(r->>'action'='prepared','phase one ran: '||r::text);
 perform sdi_test.check((select count(*) from auth.sessions where user_id=member)=0,'sessions ended');
 perform sdi_test.check(not (select approved from public.sdi_watch_media where id=media) and not (select visible from sdi_private.feed_posts where id=the_post),'media unapproved, post hidden');
 perform sdi_test.check((select state from sdi_private.removal_jobs where media_id=media)='pending','hosted copy queued for removal');
 perform sdi_test.check((select status from sdi_private.war_matches where creator=member)='withdrawn','matches withdrawn');
 perform sdi_test.check((select closed from public.sdi_rooms where id=room),'room closed');
 perform sdi_test.check((select consent_version from sdi_private.render_reviews where id=review)='','publishing consent withdrawn');
 perform sdi_test.check((select body from sdi_private.support_requests where user_id=member)='[deleted by member]','support text scrubbed');
 perform sdi_test.check((sdi_private.account_deletion_run()->>'action')='idle','purge waits for its window');
 update sdi_private.deletion_requests set purge_after=clock_timestamp()-interval '1 minute' where user_id=member;
 r:=sdi_private.account_deletion_run();
 perform sdi_test.check(r->>'action'='waiting' and (r->'reasons') @> '["hosted copies not yet removed"]'::jsonb and (r->'reasons') @> '["intake renders not yet retired"]'::jsonb,'blockers reported: '||r::text);
 perform sdi_test.check(exists(select 1 from auth.users where id=member),'no partial purge while blocked');
 update sdi_private.removal_jobs set state='complete' where media_id=media;
 update sdi_private.upload_registrations set retirement_authorized_at=clock_timestamp() where review_id=review;
 r:=sdi_private.account_deletion_run();
 perform sdi_test.check(r->>'action'='purged','purge completed: '||r::text);
 perform sdi_test.check(not exists(select 1 from auth.users where id=member),'auth user deleted');
 perform sdi_test.check((select owner_id is null and not approved and title='Removed' from public.sdi_watch_media where id=media),'rendition anonymised');
 perform sdi_test.check((select user_id is null from sdi_private.subscriptions where id=sub),'billing record retained without account link');
 perform sdi_test.check((select state from sdi_private.deletion_requests where id=(select id from sdi_private.deletion_requests where completed_at is not null limit 1))='completed','request completed');
 perform sdi_test.check(exists(select 1 from auth.users where id=friend),'other members untouched');
end $$;
rollback;
