-- Burst/rate-limit rehearsal fixtures (#263). Runs only on the throwaway cluster
-- created by scripts/backend/run_sql_tests.sh (invoked by burst_rehearsal.sh).
-- Each surface is driven past its documented limit through the real functions and
-- the outcome of every call is classified into sdi_burst.results:
--   accepted  = passed the limiter and the operation reported success
--   limited   = refused with the surface's exact rate/quota message
--   other     = passed the limiter but refused for another reason (counted, not hidden)
-- No assertion is made here; burst_rehearsal.sh prints the measured counts.
create schema sdi_burst;
create table sdi_burst.results (surface text, mode text, attempts integer, accepted integer, limited integer, other integer, note text default '');
create table sdi_burst.fixture (key text primary key, id uuid not null);

do $$
#variable_conflict use_variable
declare a uuid; b uuid; voter uuid; media_a uuid; media_b uuid; match uuid; cv uuid;
begin
 a:=sdi_test.user('burst-creator-a'); b:=sdi_test.user('burst-creator-b'); voter:=sdi_test.user('burst-voter');
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
  values('Burst A','https://cdn.example.test/burst-a.mp4',10,true,a,repeat('1',64)) returning id into media_a;
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
  values('Burst B','https://cdn.example.test/burst-b.mp4',10,true,b,repeat('2',64)) returning id into media_b;
 insert into sdi_private.war_matches(creator,opponent,left_media,right_media,left_digest,right_digest,status,starts_at,ends_at)
  values(a,b,media_a,media_b,repeat('1',64),repeat('2',64),'active',clock_timestamp(),clock_timestamp()+interval '1 day') returning id into match;
 insert into sdi_burst.fixture values('creator_a',a),('creator_b',b),('voter',voter),('match',match);
 -- Separate members for the concurrent phase so each starts with an empty window.
 cv:=sdi_test.user('burst-concurrent-feed'); insert into sdi_burst.fixture values('concurrent_feed',cv);
 cv:=sdi_test.user('burst-concurrent-voter'); insert into sdi_burst.fixture values('concurrent_voter',cv);
end $$;

-- Feed listing: documented 60/minute.
do $$
#variable_conflict use_variable
declare member uuid; r jsonb; i integer; ok integer:=0; lim integer:=0; oth integer:=0;
begin
 member:=sdi_test.user('burst-feed'); perform sdi_test.login(member);
 for i in 1..120 loop
  r:=sdi_private.feed_action('list');
  if r->>'error' is null then ok:=ok+1; elsif r->>'error'='Please wait before trying again.' then lim:=lim+1; else oth:=oth+1; end if;
 end loop;
 insert into sdi_burst.results values('feed list','sequential',120,ok,lim,oth);
end $$;

-- War Room votes: documented 60/minute per account, one stored vote per voter and match.
do $$
#variable_conflict use_variable
declare voter uuid; match uuid; r jsonb; i integer; ok integer:=0; lim integer:=0; oth integer:=0; stored integer;
begin
 select id into voter from sdi_burst.fixture where key='voter'; select id into match from sdi_burst.fixture where key='match';
 perform sdi_test.login(voter);
 for i in 1..120 loop
  r:=sdi_private.war_action('vote',match,choice=>case when i%2=0 then 'left' else 'right' end);
  if r->>'status'='confirmed' then ok:=ok+1; elsif r->>'error'='Too many requests. Wait a minute.' then lim:=lim+1; else oth:=oth+1; end if;
 end loop;
 select count(*) into stored from sdi_private.war_votes v where v.match_id=match and v.voter=voter;
 insert into sdi_burst.results values('war votes','sequential',120,ok,lim,oth,'stored vote rows for this voter: '||stored);
end $$;

-- Room commands: documented 300/minute per member (room creation uses the separate request budget).
do $$
#variable_conflict use_variable
declare member uuid; room uuid; r jsonb; i integer; ok integer:=0; lim integer:=0; oth integer:=0;
begin
 member:=sdi_test.user('burst-room'); perform sdi_test.login(member);
 r:=sdi_private.room_action('create',title=>'Burst rehearsal room',consent=>true); room:=(r->>'room_id')::uuid;
 if room is null then raise exception 'room fixture failed: %', r; end if;
 for i in 1..400 loop
  r:=sdi_private.room_command('since',room,after=>0);
  if r->>'error' is null then ok:=ok+1; elsif r->>'error'='Too many edits per minute. Pause and resynchronize.' then lim:=lim+1; else oth:=oth+1; end if;
 end loop;
 insert into sdi_burst.results values('room commands','sequential',400,ok,lim,oth);
end $$;

-- Upload registrations: daily quota (resource_quotas.upload_registrations, default 20),
-- through the real service registration; then 10 retries of one accepted upload id.
do $$
#variable_conflict use_variable
declare creator uuid; upload uuid; first_upload uuid; r jsonb; i integer; ok integer:=0; lim integer:=0; oth integer:=0; message text;
 dup_ok integer:=0; dup_other integer:=0; stored integer; meta jsonb;
begin
 creator:=sdi_test.user('burst-uploader');
 for i in 1..30 loop
  upload:=gen_random_uuid();
  meta:=jsonb_build_object('size',1048576,'made_for_kids',false,'destinations',jsonb_build_array('feed'),'sha256',encode(sha256(convert_to(upload::text,'UTF8')),'hex'),
   'title','Burst '||i,'source_revision','rev'||i,'rights_summary','Own work','consent_version','terms-v1');
  begin
   r:=sdi_private.register_upload(upload,creator,meta,upload::text||'.mp4','https://intake.example.test/p/'||upload,clock_timestamp()+interval '1 hour',clock_timestamp()+interval '1 hour');
   if r ? 'review_id' then ok:=ok+1; if first_upload is null then first_upload:=upload; insert into sdi_burst.fixture values('first_upload_meta',upload); end if; else oth:=oth+1; end if;
  exception when raise_exception then
   get stacked diagnostics message=message_text;
   if message like 'Daily upload%limit reached%' then lim:=lim+1; else oth:=oth+1; end if;
  end;
 end loop;
 insert into sdi_burst.results values('upload registrations','sequential',30,ok,lim,oth,'quota per_day='||sdi_private.quota('upload_registrations'));
 -- Duplicate registration of an accepted upload is idempotent and must not use quota or add rows.
 select metadata into meta from sdi_private.upload_registrations where upload_id=first_upload;
 for i in 1..10 loop
  begin
   r:=sdi_private.register_upload(first_upload,creator,meta,first_upload::text||'.mp4','https://intake.example.test/p/'||first_upload,clock_timestamp()+interval '1 hour',clock_timestamp()+interval '1 hour');
   if r ? 'review_id' then dup_ok:=dup_ok+1; else dup_other:=dup_other+1; end if;
  exception when raise_exception then dup_other:=dup_other+1;
  end;
 end loop;
 select count(*) into stored from sdi_private.upload_registrations where upload_registrations.creator=creator;
 insert into sdi_burst.results values('upload duplicate retries','sequential',10,dup_ok,0,dup_other,'stored registrations for creator: '||stored);
end $$;
