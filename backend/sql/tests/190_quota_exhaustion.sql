-- Quota-exhaustion and duplicate-job fixtures (#263). Complements 100_burst_limits.sql
-- (per-minute member budgets) with the daily quotas in rate-limits.sql, the active
-- publishing queue cap, duplicate publication and upload requests at exhaustion,
-- the daily report cap, and the per-surface administrator budgets for finance,
-- marketing, announcements (push/email) and support. Every refusal is asserted with
-- its documented message and checked to have written nothing. Quotas are lowered
-- inside this rolled-back transaction the way the owner configures them; nothing
-- sleeps, windows are moved by ageing rows. Throwaway cluster only.
begin;
create function sdi_test.quota_review(creator uuid, digest text) returns uuid language plpgsql as $$
declare review uuid;
begin
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,destinations)
 values(creator,'Quota '||left(digest,8),'rev1',digest,'https://intake.example.test/'||left(digest,8),clock_timestamp()+interval '1 day','terms-v1','Own work',true,array['feed'])
 returning id into review;
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at)
 values(review,1,digest,left(digest,8)||'.mp4',1024,'Quota '||left(digest,8),'',false,clock_timestamp()+interval '24 hours');
 return review;
end $$;
create function sdi_test.raised(statement text) returns text language plpgsql as $$
declare message text;
begin
 execute statement;
 return null;
exception when raise_exception then
 get stacked diagnostics message=message_text; return message;
end $$;

-- 1. Publishing: active queue cap (20), daily request quota, duplicate enqueue.
do $$
#variable_conflict use_variable
declare creator uuid; reviewer uuid; filler uuid; a uuid; b uuid; r jsonb; i integer; jobs integer; msg text;
begin
 creator:=sdi_test.user('quota-publisher'); reviewer:=sdi_test.admin('quota-reviewer',false,array['reviews']);
 update sdi_private.resource_quotas set per_day=24 where key='publish_requests';
 a:=sdi_test.quota_review(creator,repeat('a',63)||'1'); b:=sdi_test.quota_review(creator,repeat('b',63)||'1');
 perform sdi_test.login(reviewer,'aal2');
 perform sdi_test.check(sdi_private.review_action('decide',a,repeat('a',63)||'1',1,'approved','Exact render.')->>'status'='confirmed','approve A');
 perform sdi_test.check(sdi_private.review_action('decide',b,repeat('b',63)||'1',1,'approved','Exact render.')->>'status'='confirmed','approve B');
 -- Twenty active jobs from other renders fill the queue.
 for i in 1..20 loop
  filler:=sdi_test.quota_review(creator,lpad(to_hex(i),64,'e'));
  insert into sdi_private.publish_jobs(review_id,review_version,render_digest,creator,destination) values(filler,1,lpad(to_hex(i),64,'e'),creator,'feed');
 end loop;
 perform sdi_test.login(creator);
 r:=sdi_private.publish_action('enqueue',a,'feed');
 perform sdi_test.check(r->>'error'='Publishing queue capacity reached.','21st active job refused: '||r::text);
 perform sdi_test.check((select count(*) from sdi_private.publish_jobs where publish_jobs.creator=creator)=20,'capacity refusal wrote nothing');

 -- Finished jobs free the queue but still count toward the daily quota.
 update sdi_private.publish_jobs set state='published' where publish_jobs.creator=creator;
 r:=sdi_private.publish_action('enqueue',a,'feed');
 perform sdi_test.check(r->>'status'='queued','queue admits again: '||r::text);
 for i in 1..5 loop r:=sdi_private.publish_action('enqueue',a,'feed'); end loop;
 perform sdi_test.check(r->>'status'='queued' and (select count(*) from sdi_private.publish_jobs where review_id=a)=1,'duplicate enqueues create no second job');
 r:=sdi_private.creator_review('publish_feed',a,1);
 perform sdi_test.check(r->>'error' like 'This render already has a publishing job%','creator duplicate refused with guidance: '||r::text);
 perform sdi_test.check((sdi_private.quota_status()->'publish_requests'->>'used')::integer=21,'duplicates used no quota');

 for i in 21..23 loop
  filler:=sdi_test.quota_review(creator,lpad(to_hex(i),64,'e'));
  insert into sdi_private.publish_jobs(review_id,review_version,render_digest,creator,destination,state) values(filler,1,lpad(to_hex(i),64,'e'),creator,'feed','published');
 end loop;
 r:=sdi_private.quota_status();
 perform sdi_test.check((r->'publish_requests'->>'used')::integer=24 and (r->'publish_requests'->>'limit')::integer=24,'quota status reports exhaustion: '||r::text);
 msg:=sdi_test.raised(format('select sdi_private.publish_action(%L,%L::uuid,%L)','enqueue',b,'feed'));
 perform sdi_test.check(msg='Daily publishing limit reached. Try again tomorrow.','enqueue past the daily quota refused: '||coalesce(msg,'accepted'));
 filler:=sdi_test.quota_review(creator,repeat('f',64));
 msg:=sdi_test.raised(format('insert into sdi_private.publish_jobs(review_id,review_version,render_digest,creator,destination) values(%L,1,%L,%L,%L)',filler,repeat('f',64),creator,'feed'));
 perform sdi_test.check(msg='Daily publishing limit reached. Try again tomorrow.','service insert path bounded too');
 r:=sdi_private.publish_action('enqueue',a,'feed');
 perform sdi_test.check(r->>'status'='queued','a duplicate at exhaustion is answered idempotently, not refused');
 perform sdi_test.check((select count(*) from sdi_private.publish_jobs where publish_jobs.creator=creator)=24,'exhaustion wrote nothing');

 update sdi_private.publish_jobs set created_at=created_at-interval '25 hours' where publish_jobs.creator=creator;
 r:=sdi_private.publish_action('enqueue',b,'feed');
 perform sdi_test.check(r->>'status'='queued','rolling window admits again: '||r::text);
end $$;

-- 2. Upload registrations and bytes, and a duplicate retry at exhaustion.
do $$
#variable_conflict use_variable
declare creator uuid; upload uuid; first_upload uuid; meta jsonb; r jsonb; i integer; msg text; stored integer;
begin
 creator:=sdi_test.user('quota-uploader');
 update sdi_private.resource_quotas set per_day=3 where key='upload_registrations';
 update sdi_private.resource_quotas set per_day=3145728 where key='upload_bytes';
 for i in 1..4 loop
  upload:=gen_random_uuid();
  meta:=jsonb_build_object('size',1048576,'made_for_kids',false,'destinations',jsonb_build_array('feed'),'sha256',encode(sha256(convert_to(upload::text,'UTF8')),'hex'),
   'title','Quota '||i,'source_revision','rev'||i,'rights_summary','Own work','consent_version','terms-v1');
  msg:=sdi_test.raised(format('select sdi_private.register_upload(%L::uuid,%L::uuid,%L::jsonb,%L,%L,clock_timestamp()+interval %L,clock_timestamp()+interval %L)',
   upload,creator,meta,upload::text||'.mp4','https://intake.example.test/p/'||upload,'1 hour','1 hour'));
  if i<=3 then
   perform sdi_test.check(msg is null,'upload '||i||' registered: '||coalesce(msg,''));
   if first_upload is null then first_upload:=upload; end if;
  else
   perform sdi_test.check(msg='Daily upload limit reached. Try again tomorrow.','fourth registration refused: '||coalesce(msg,'accepted'));
  end if;
 end loop;
 update sdi_private.resource_quotas set per_day=10 where key='upload_registrations';
 upload:=gen_random_uuid();
 meta:=jsonb_build_object('size',1,'made_for_kids',false,'destinations',jsonb_build_array('feed'),'sha256',encode(sha256(convert_to(upload::text,'UTF8')),'hex'),
  'title','One byte','source_revision','rev9','rights_summary','Own work','consent_version','terms-v1');
 msg:=sdi_test.raised(format('select sdi_private.register_upload(%L::uuid,%L::uuid,%L::jsonb,%L,%L,clock_timestamp()+interval %L,clock_timestamp()+interval %L)',
  upload,creator,meta,upload::text||'.mp4','https://intake.example.test/p/'||upload,'1 hour','1 hour'));
 perform sdi_test.check(msg='Daily upload size limit reached. Try again tomorrow.','byte quota refuses one byte over: '||coalesce(msg,'accepted'));
 select metadata into meta from sdi_private.upload_registrations where upload_id=first_upload;
 for i in 1..5 loop
  r:=sdi_private.register_upload(first_upload,creator,meta,first_upload::text||'.mp4','https://intake.example.test/p/'||first_upload,clock_timestamp()+interval '1 hour',clock_timestamp()+interval '1 hour');
  perform sdi_test.check(r ? 'review_id','duplicate retry '||i||' answered with the original review: '||r::text);
 end loop;
 select count(*) into stored from sdi_private.upload_registrations u where u.creator=creator;
 perform sdi_test.check(stored=3,'exhaustion and retries stored exactly three registrations, found '||stored);
end $$;

-- 3. Room invitation codes per owner per day.
do $$
#variable_conflict use_variable
declare owner uuid; room uuid; r jsonb; i integer; msg text; codes integer;
begin
 owner:=sdi_test.user('quota-room-owner');
 update sdi_private.resource_quotas set per_day=3 where key='room_invites';
 perform sdi_test.login(owner);
 room:=(sdi_private.room_action('create',title=>'Quota room',consent=>true)->>'room_id')::uuid;
 perform sdi_test.check(room is not null,'room created');
 for i in 1..3 loop
  r:=sdi_private.room_action('invite',room);
  perform sdi_test.check(r->>'status'='invitation_created','invite '||i||': '||r::text);
 end loop;
 msg:=sdi_test.raised(format('select sdi_private.room_action(%L,%L::uuid)','invite',room));
 perform sdi_test.check(msg='Daily invitation limit reached. Try again tomorrow.','fourth invitation refused: '||coalesce(msg,'accepted'));
 select count(*) into codes from sdi_private.room_invites where room_id=room;
 perform sdi_test.check(codes=3,'no code issued past the quota');
 perform sdi_test.check((sdi_private.quota_status()->'room_invites'->>'used')::integer=3,'owner sees the invitation usage');
end $$;

-- 4. Feed reports: ten per day; a repeat report of the same post adds nothing.
do $$
#variable_conflict use_variable
declare alice uuid; bob uuid; media uuid; posts uuid[]:='{}'; post uuid; i integer; r jsonb;
begin
 alice:=sdi_test.user('quota-report-creator'); bob:=sdi_test.user('quota-reporter');
 for i in 1..11 loop
  insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
  values('Report '||i,'https://cdn.example.test/report'||i||'.mp4',5,true,alice,lpad(to_hex(i),64,'5')) returning id into media;
  insert into sdi_private.feed_posts(media_id,creator,creator_name,visible) values(media,alice,'alice',true) returning id into post;
  posts:=posts||post;
 end loop;
 perform sdi_test.login(bob);
 r:=sdi_private.feed_action('report',posts[1],reason=>'spam');
 r:=sdi_private.feed_action('report',posts[1],reason=>'abuse');
 perform sdi_test.check(r->>'status'='recorded' and (select count(*) from sdi_private.feed_reports where actor=bob)=1,'repeat report is one row');
 for i in 2..10 loop
  r:=sdi_private.feed_action('report',posts[i],reason=>'spam');
  perform sdi_test.check(r->>'status'='recorded','report '||i||': '||r::text);
 end loop;
 r:=sdi_private.feed_action('report',posts[11],reason=>'spam');
 perform sdi_test.check(r->>'error'='Daily report limit reached.','eleventh report refused: '||r::text);
 perform sdi_test.check((select count(*) from sdi_private.feed_reports where actor=bob)=10,'refused report wrote nothing');
end $$;

-- 5. Administrator budgets per surface: finance 30, marketing 60, announcements
--    (push and email) 60, support 120 per minute. The call after the cap is refused
--    as rate_limited, audited once, and the refused operation writes nothing.
do $$
#variable_conflict use_variable
declare admin uuid; r jsonb; i integer; surface record; ledger_before integer; drafts_before integer;
begin
 admin:=sdi_test.admin('quota-admin',false,array['finance','publishing','users']);
 perform sdi_test.login(admin,'aal2',30);
 for surface in select * from (values
   ('finance',30,'select sdi_private.finance_record(''burst_probe'',reason=>''fixture'')','finance_record.burst_probe'),
   ('marketing',60,'select sdi_private.marketing_action(''list'')','marketing.list'),
   ('announcements',60,'select sdi_private.announce_admin(''list'')','announce_admin.list'),
   ('support',120,'select sdi_private.support_action(''list'')','support_action.list')) s(name,cap,statement,operation)
 loop
  update sdi_private.admin_budget set window_start=clock_timestamp()-interval '2 minutes' where user_id=admin;
  for i in 1..surface.cap loop
   execute surface.statement into r;
   perform sdi_test.check(coalesce(r->>'code','')<>'rate_limited',surface.name||' call '||i||' within the cap: '||r::text);
  end loop;
  execute surface.statement into r;
  perform sdi_test.check(r->>'code'='rate_limited' and r->>'error'='Too many administrative requests. Wait a minute.',surface.name||' call past the cap refused: '||r::text);
  perform sdi_test.check((select count(*) from sdi_private.admin_access_audit where actor=admin and operation=surface.operation and detail='rate_limited')=1,
   surface.name||' refusal audited once');
 end loop;
 -- At exhaustion, a real write on each surface is refused before it writes.
 select count(*) into ledger_before from sdi_private.finance_ledger;
 r:=sdi_private.finance_record('expense',ref=>'quota-fixture',kind=>'hosting',amount_minor=>500,currency=>'USD',occurred_at=>clock_timestamp(),reason=>'fixture');
 perform sdi_test.check(r->>'code'='rate_limited' and (select count(*) from sdi_private.finance_ledger)=ledger_before,'finance write refused at exhaustion');
 select count(*) into drafts_before from sdi_private.marketing_campaigns;
 r:=sdi_private.marketing_action('create_campaign',payload=>'{"title":"Quota fixture"}'::jsonb,reason=>'fixture');
 perform sdi_test.check(r->>'code'='rate_limited' and (select count(*) from sdi_private.marketing_campaigns)=drafts_before,'marketing write refused at exhaustion');
 update sdi_private.admin_budget set window_start=clock_timestamp()-interval '2 minutes' where user_id=admin;
 r:=sdi_private.announce_admin('list');
 perform sdi_test.check(r->>'code' is null,'window expiry admits the administrator again: '||r::text);
end $$;
rollback;
