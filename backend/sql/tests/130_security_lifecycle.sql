-- Local assertions for security-credentials.sql (#238), security-audit-integrity.sql
-- (#256), security-retire-communications.sql (#260), the account-lifecycle consent
-- retention additions (#262) and rate-limits.sql (#263). Throwaway cluster only.
-- The Vault used here is a test double created inside this transaction: it stores
-- plaintext and proves only the call contract, not Supabase's encryption.
begin;

-- 1. Credential slots without a secret store: nothing is stored, nothing is loaded.
do $$
declare owner uuid; member uuid; r jsonb;
begin
 owner:=sdi_test.admin('cred-owner',true,array[]::text[]); member:=sdi_test.user('cred-member');
 perform sdi_test.check(not sdi_private.vault_ready(),'no vault in the plain cluster');
 r:=sdi_private.credential_store('youtube_owner_grant','{"refresh_token":"fixture-value-0001"}');
 perform sdi_test.check(r->>'error' like 'Server secret store is not enabled%','store refused without vault: '||r::text);
 r:=sdi_private.credential_load('youtube_owner_grant');
 perform sdi_test.check((r->>'configured')::boolean=false and r->>'state'='unconfigured' and not r ? 'secret','unconfigured slot loads nothing: '||r::text);
 perform sdi_test.check((sdi_private.credential_load('no_such_slot')->>'state')='unknown','unknown slot reported');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_credential_load(''stripe_api'')'),'clients cannot load credentials');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_credential_store(''stripe_api'',''x'')'),'anon cannot store credentials');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_credential_revoke(''stripe_api'')'),'clients cannot revoke credentials');
 perform sdi_test.login(member);
 perform sdi_test.check((sdi_private.credential_status()->>'code')='forbidden','member cannot read credential status');
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.credential_status();
 perform sdi_test.check((r->>'store_ready')::boolean=false and jsonb_array_length(r->'slots')=8,'owner sees eight slots and an unavailable store: '||left(r::text,200));
 perform sdi_test.logout();
end $$;

-- Test double for Supabase Vault (same function and view names).
create schema vault;
create table vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, description text not null default '', secret text not null);
create function vault.create_secret(new_secret text,new_name text default null,new_description text default '',new_key_id uuid default null) returns uuid
language sql as $$ insert into vault.secrets(name,description,secret) values(new_name,coalesce(new_description,''),new_secret) returning id $$;
create view vault.decrypted_secrets as select id,name,description,secret,secret as decrypted_secret from vault.secrets;

do $$
declare owner uuid; r jsonb; first_rev bigint; value text:='{"client_id":"fixture-client","refresh_token":"fixture-refresh-0001"}';
begin
 owner:=sdi_test.admin('cred-owner-2',true,array[]::text[]);
 perform sdi_test.check(sdi_private.vault_ready(),'vault double detected');
 r:=sdi_private.credential_store('youtube_owner_grant','short');
 perform sdi_test.check(r->>'error' like 'Credential value rejected%','short value refused');
 r:=sdi_private.credential_store('youtube_owner_grant',value,'Initial link.');
 perform sdi_test.check(r->>'status'='stored' and (r->>'revision')::bigint=1 and r->>'fingerprint' ~ '^[a-f0-9]{12}$','stored: '||r::text);
 perform sdi_test.check(r::text !~ 'fixture-refresh','store result does not echo the value');
 first_rev:=(r->>'revision')::bigint;
 perform sdi_test.check((select count(*) from vault.secrets)=1,'one stored secret');
 perform sdi_test.check(not exists(select 1 from sdi_private.credential_slots c where to_jsonb(c)::text ~ 'fixture-refresh'),'slot table never holds the value');
 r:=sdi_private.credential_load('youtube_owner_grant');
 perform sdi_test.check((r->>'configured')::boolean and r->>'secret'=value and (r->>'revision')::bigint=1,'worker loads the active value');
 -- Rotation keeps exactly one stored copy and bumps the revision.
 r:=sdi_private.credential_store('youtube_owner_grant','{"client_id":"fixture-client","refresh_token":"fixture-refresh-0002"}','Scheduled rotation.');
 perform sdi_test.check(r->>'status'='rotated' and (r->>'revision')::bigint=2,'rotated: '||r::text);
 perform sdi_test.check((select count(*) from vault.secrets)=1,'previous secret destroyed after rotation');
 perform sdi_test.check((sdi_private.credential_load('youtube_owner_grant')->>'secret') ~ 'fixture-refresh-0002','new value loaded');
 -- A worker holding the old revision cannot change the new grant's state.
 perform sdi_test.check(not sdi_private.credential_record_state('youtube_owner_grant',first_rev,'reconnect_required'),'stale revision refused');
 perform sdi_test.check(sdi_private.credential_record_state('youtube_owner_grant',2,'reconnect_required'),'current revision marks reconnect');
 r:=sdi_private.credential_load('youtube_owner_grant');
 perform sdi_test.check((r->>'configured')::boolean=false and r->>'state'='reconnect_required' and not r ? 'secret','reconnect-required slot loads nothing');
 perform sdi_test.check(not sdi_private.credential_record_state('youtube_owner_grant',2,'unconfigured'),'unsupported state refused');
 -- Status: presence only.
 perform sdi_test.login(owner,'aal2');
 r:=sdi_private.credential_status();
 perform sdi_test.check((r->>'store_ready')::boolean and r::text !~ 'fixture-refresh' and r::text !~ 'fixture-client','status carries no value');
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'slots') s where s->>'slot'='youtube_owner_grant' and s->>'state'='reconnect_required')=1,'status shows reconnect');
 perform sdi_test.logout();
 -- Revocation destroys the stored copy.
 r:=sdi_private.credential_revoke('youtube_owner_grant','Owner disconnected the channel.');
 perform sdi_test.check(r->>'status'='revoked' and (select count(*) from vault.secrets)=0,'revoke destroys the secret');
 perform sdi_test.check((sdi_private.credential_load('youtube_owner_grant')->>'state')='revoked','revoked slot loads nothing');
 perform sdi_test.check(not sdi_private.credential_record_state('youtube_owner_grant',3,'active'),'revoked slot cannot be reactivated by a worker');
 -- A slot whose stored copy vanished is reported, not crashed.
 perform sdi_private.credential_store('stripe_webhook','fixture-webhook-signing-0001');
 delete from vault.secrets;
 perform sdi_test.check((sdi_private.credential_load('stripe_webhook')->>'state')='store_missing','missing stored copy reported');
 perform sdi_test.check((select array_agg(action order by created_at,action) from sdi_private.credential_audit where slot='youtube_owner_grant')=array['store','rotate','state','revoke'],'audit trail in order');
 perform sdi_test.check(not exists(select 1 from sdi_private.credential_audit a where to_jsonb(a)::text ~ 'fixture-'),'audit never holds values');
end $$;

-- 2. Audit tables are append-only outside the account purge.
do $$
declare actor uuid; audit uuid; r jsonb; refused boolean;
begin
 r:=sdi_private.audit_integrity_report();
 perform sdi_test.check((r->>'unguarded')::integer=0 and jsonb_array_length(r->'tables')>=16,'every audit table guarded: '||left(r::text,300));
 perform sdi_test.check((select count(*) from jsonb_array_elements(r->'tables') t where t->>'table'='credential_audit' and (t->>'guarded')::boolean)=1,'credential audit guarded');
 actor:=sdi_test.user('audited-member');
 insert into sdi_private.consent_audit(actor,action,reason) values(actor,'fixture','Fixture.') returning id into audit;
 refused:=false; begin update sdi_private.consent_audit set reason='Edited.' where id=audit; exception when insufficient_privilege then refused:=true; end;
 perform sdi_test.check(refused,'audit update refused');
 refused:=false; begin delete from sdi_private.consent_audit where id=audit; exception when insufficient_privilege then refused:=true; end;
 perform sdi_test.check(refused,'audit delete refused');
 refused:=false; begin truncate sdi_private.admin_access_audit; exception when insufficient_privilege then refused:=true; end;
 perform sdi_test.check(refused,'audit truncate refused');
 delete from auth.users where id=actor;
 perform sdi_test.check((select c.actor is null and c.reason='Fixture.' from sdi_private.consent_audit c where c.id=audit),'FK set-null still clears the departed member reference');
 perform sdi_test.check(sdi_test.denied('service_role','select public.sdi_audit_integrity_report()')=false,'service role can read the integrity report');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_audit_integrity_report()'),'clients cannot read the integrity report');
end $$;

-- 3. Account deletion: consent withdrawn at phase one, proof retained after purge,
--    push devices revoked, membership in another member's room revoked.
do $$
declare owner uuid; member uuid; host uuid; room uuid; r jsonb; digest text;
begin
 owner:=sdi_test.admin('ret-owner',true,array[]::text[]); member:=sdi_test.user('ret-member'); host:=sdi_test.user('ret-host');
 perform sdi_test.login(owner,'aal2',60);
 perform sdi_private.consent_action('publish','terms','terms-v1',summary=>'Terms v1.',reason=>'Fixture.');
 perform sdi_test.login(host);
 r:=sdi_private.room_action('create',title=>'Host room',consent=>true); room:=(r->>'room_id')::uuid;
 perform sdi_test.check(room is not null,'host room created: '||r::text);
 insert into public.sdi_room_members(room_id,user_id,owner_approved,member_accepted) values(room,member,true,true);
 perform sdi_test.login(member);
 r:=sdi_private.consent_action('accept','terms','terms-v1','ios');
 perform sdi_test.check(r->>'error' is null,'member accepted terms: '||r::text);
 insert into sdi_private.notification_preferences(user_id,push_product,email_product) values(member,true,true);
 insert into sdi_private.device_tokens(user_id,platform,environment,device_token) values(member,'ios','sandbox',repeat('a',64));
 r:=sdi_private.account_lifecycle('export');
 perform sdi_test.check(jsonb_array_length(r->'consents')=1 and r->'consents'->0->>'version'='terms-v1','export lists consents: '||left(r::text,200));
 perform sdi_test.check(jsonb_array_length(r->'push_devices')=1 and r::text !~ repeat('a',64),'export lists devices without the push token');
 perform sdi_test.check((r->'notification_preferences'->>'push_product')::boolean,'export has notification preferences');
 r:=sdi_private.account_lifecycle('request_deletion');
 update sdi_private.deletion_requests set scheduled_for=clock_timestamp()-interval '1 minute' where user_id=member;
 r:=sdi_private.account_deletion_run();
 perform sdi_test.check(r->>'action'='prepared','phase one: '||r::text);
 perform sdi_test.check((select withdrawn_at is not null from sdi_private.consent_records where user_id=member),'consent withdrawn at phase one');
 perform sdi_test.check(not sdi_private.consent_current(member,'terms'),'withdrawn consent no longer current');
 perform sdi_test.check((select revoked_at is not null from sdi_private.device_tokens where user_id=member),'push device revoked');
 perform sdi_test.check((select not push_product and not email_product from sdi_private.notification_preferences where user_id=member),'notifications off');
 perform sdi_test.check((select revoked and not owner_approved and not member_accepted from public.sdi_room_members where room_id=room and user_id=member),'membership in another room revoked');
 perform sdi_test.check(not (select closed from public.sdi_rooms where id=room),'the host''s room stays open');
 update sdi_private.deletion_requests set purge_after=clock_timestamp()-interval '1 minute' where user_id=member;
 r:=sdi_private.account_deletion_run();
 perform sdi_test.check(r->>'action'='purged','purged: '||r::text);
 perform sdi_test.check(coalesce(current_setting('sdi.audit_purge',true),'')='','purge flag cleared after the purge');
 digest:=encode(extensions.digest(member::text,'sha256'),'hex');
 perform sdi_test.check((select count(*) from sdi_private.consent_retention where subject_digest=digest and policy='terms' and version='terms-v1' and withdrawn_at is not null)=1,'consent proof retained pseudonymously');
 perform sdi_test.check(not exists(select 1 from sdi_private.consent_retention c where to_jsonb(c)::text ~ member::text),'retained proof holds no account id');
 perform sdi_test.check((select retain_until>clock_timestamp()+interval '1000 days' from sdi_private.consent_retention where subject_digest=digest),'retained for the configured period');
 perform sdi_test.check(not exists(select 1 from public.sdi_room_members where user_id=member),'membership rows gone with the account');
 perform sdi_test.check(sdi_private.consent_retention_sweep()=0,'nothing expired yet');
 update sdi_private.retention_settings set consent_proof_days=0;
 update sdi_private.consent_retention set retain_until=clock_timestamp()-interval '1 day' where subject_digest=digest;
 perform sdi_test.check(sdi_private.consent_retention_sweep()=1,'expired proof swept');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.sdi_consent_retention_sweep()'),'clients cannot sweep');
end $$;

-- 4. Daily quotas: burst to the cap, refusal, duplicates, member status.
do $$
declare member uuid; other uuid; room uuid; review uuid; r jsonb; i integer; refused text;
begin
 member:=sdi_test.user('quota-member'); other:=sdi_test.user('quota-other');
 for i in 1..20 loop
  insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,destinations)
  values(member,'Q'||i,'rev',repeat('c',64),'https://intake.example.test/q',clock_timestamp()+interval '1 day','v1','Mine',array['feed']) returning id into review;
  insert into sdi_private.upload_registrations(upload_id,creator,review_id,metadata,object_key) values(gen_random_uuid(),member,review,jsonb_build_object('size',1048576),'q.mp4');
 end loop;
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,destinations)
 values(member,'Q21','rev',repeat('c',64),'https://intake.example.test/q',clock_timestamp()+interval '1 day','v1','Mine',array['feed']) returning id into review;
 refused:=null;
 begin insert into sdi_private.upload_registrations(upload_id,creator,review_id,metadata,object_key) values(gen_random_uuid(),member,review,'{"size":1}','q.mp4');
 exception when raise_exception then refused:=sqlerrm; end;
 perform sdi_test.check(refused='Daily upload limit reached. Try again tomorrow.','21st registration refused: '||coalesce(refused,'allowed'));
 perform sdi_test.check((select count(*) from sdi_private.upload_registrations where creator=member)=20,'exactly 20 registrations stored');
 -- Byte ceiling for another creator: 8 GiB per day.
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,destinations)
 values(other,'Big','rev',repeat('d',64),'https://intake.example.test/b',clock_timestamp()+interval '1 day','v1','Mine',array['feed']) returning id into review;
 insert into sdi_private.upload_registrations(upload_id,creator,review_id,metadata,object_key) values(gen_random_uuid(),other,review,'{"size":8589934592}','b.mp4');
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,destinations)
 values(other,'Big2','rev',repeat('d',64),'https://intake.example.test/b',clock_timestamp()+interval '1 day','v1','Mine',array['feed']) returning id into review;
 refused:=null;
 begin insert into sdi_private.upload_registrations(upload_id,creator,review_id,metadata,object_key) values(gen_random_uuid(),other,review,'{"size":1}','b2.mp4');
 exception when raise_exception then refused:=sqlerrm; end;
 perform sdi_test.check(refused='Daily upload size limit reached. Try again tomorrow.','byte ceiling refused: '||coalesce(refused,'allowed'));
 -- An expired window admits again.
 update sdi_private.upload_registrations set created_at=clock_timestamp()-interval '25 hours' where creator=other;
 insert into sdi_private.upload_registrations(upload_id,creator,review_id,metadata,object_key) values(gen_random_uuid(),other,review,'{"size":1}','b2.mp4');

 -- Publication: duplicate requests create one job and use no quota; the 31st distinct job is refused.
 select id into review from sdi_private.render_reviews where creator=member order by created_at limit 1;
 insert into sdi_private.publish_jobs(review_id,review_version,render_digest,creator,destination) values(review,1,repeat('c',64),member,'feed') on conflict do nothing;
 insert into sdi_private.publish_jobs(review_id,review_version,render_digest,creator,destination) values(review,1,repeat('c',64),member,'feed') on conflict do nothing;
 perform sdi_test.check((select count(*) from sdi_private.publish_jobs where creator=member)=1,'duplicate job collapsed');
 for i in 2..30 loop
  insert into sdi_private.publish_jobs(review_id,review_version,render_digest,creator,destination) values(review,i,repeat('c',64),member,'feed');
 end loop;
 refused:=null;
 begin insert into sdi_private.publish_jobs(review_id,review_version,render_digest,creator,destination) values(review,31,repeat('c',64),member,'feed');
 exception when raise_exception then refused:=sqlerrm; end;
 perform sdi_test.check(refused='Daily publishing limit reached. Try again tomorrow.','31st job refused: '||coalesce(refused,'allowed'));
 insert into sdi_private.publish_jobs(review_id,review_version,render_digest,creator,destination) values(review,30,repeat('c',64),member,'feed') on conflict do nothing;
 perform sdi_test.check((select count(*) from sdi_private.publish_jobs where creator=member)=30,'a duplicate at the cap is still a no-op');

 -- Invitations: 50 codes per owner per day across all rooms.
 perform sdi_test.login(member);
 r:=sdi_private.room_action('create',title=>'Quota room',consent=>true); room:=(r->>'room_id')::uuid;
 for i in 1..50 loop
  insert into sdi_private.room_invites(room_id,token_hash,expires_at,remaining) values(room,extensions.digest('fixture-invite-'||i,'sha256'),clock_timestamp()+interval '1 day',1);
 end loop;
 refused:=null;
 begin insert into sdi_private.room_invites(room_id,token_hash,expires_at,remaining) values(room,extensions.digest('fixture-invite-51','sha256'),clock_timestamp()+interval '1 day',1);
 exception when raise_exception then refused:=sqlerrm; end;
 perform sdi_test.check(refused='Daily invitation limit reached. Try again tomorrow.','51st invite refused: '||coalesce(refused,'allowed'));
 refused:=null;
 begin r:=sdi_private.room_action('invite',room); refused:='allowed: '||coalesce(r::text,'');
 exception when raise_exception then refused:=sqlerrm; end;
 perform sdi_test.check(refused='Daily invitation limit reached. Try again tomorrow.','the invite RPC cannot bypass the cap: '||refused);

 r:=sdi_private.quota_status();
 perform sdi_test.check((r->'uploads'->>'used')::integer=20 and (r->'uploads'->>'limit')::integer=20,'status uploads: '||r::text);
 perform sdi_test.check((r->'upload_bytes'->>'used')::bigint=20*1048576,'status bytes');
 perform sdi_test.check((r->'publish_requests'->>'used')::integer=30 and (r->'room_invites'->>'used')::integer=50,'status publish and invites');
 perform sdi_test.logout();
 perform sdi_test.check((sdi_private.quota_status()->>'error') like 'A current signed-in%','status needs a session');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_quota_status()'),'anon cannot read quota status');
end $$;

-- 5. Legacy messaging/calling objects: client access closed, rows kept.
do $$
declare r jsonb;
begin
 perform sdi_test.check(sdi_private.legacy_communication_exposure()='{"relations":[],"functions":[]}'::jsonb,'fresh candidate schema exposes nothing');
 create table public.chat_rooms(id integer primary key, name text);
 create table public.messages(id integer primary key, room_id integer, content text);
 create table public.video_calls(id integer primary key);
 create function public.send_message(room integer, body text) returns void language sql as $f$ select null::void $f$;
 grant select,insert on public.chat_rooms,public.messages,public.video_calls to anon,authenticated;
 grant execute on function public.send_message(integer,text) to authenticated;
 insert into public.messages values(1,1,'Legacy row.');
 r:=sdi_private.legacy_communication_exposure();
 perform sdi_test.check(jsonb_array_length(r->'relations')=3 and r->'functions'='["send_message"]'::jsonb,'legacy objects detected: '||r::text);
 r:=sdi_private.retire_legacy_communications();
 perform sdi_test.check(r->'closed_relations'='["chat_rooms", "messages", "video_calls"]'::jsonb and jsonb_array_length(r->'closed_functions')=1,'closed: '||r::text);
 perform sdi_test.check(sdi_private.legacy_communication_exposure()='{"relations":[],"functions":[]}'::jsonb,'nothing client-reachable afterwards');
 perform sdi_test.check(sdi_test.denied('authenticated','insert into public.messages values(2,1,''new'')'),'new messages refused');
 perform sdi_test.check(sdi_test.denied('authenticated','select public.send_message(1,''x'')'),'legacy send refused');
 perform sdi_test.check((select count(*) from public.messages)=1,'existing rows kept');
 perform sdi_test.check(has_table_privilege('authenticated','public.sdi_watch_media','select') or not has_table_privilege('authenticated','public.sdi_watch_media','insert'),'sdi objects untouched');
 perform sdi_test.check(not sdi_private.legacy_communication_name('sdi_rooms') and not sdi_private.legacy_communication_name('spatter_chat')
  and not sdi_private.legacy_communication_name('users') and sdi_private.legacy_communication_name('direct_messages'),'name rule');
end $$;
rollback;
