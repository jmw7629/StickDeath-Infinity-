-- Transaction tests for the service receipt -> metadata-only feed reference.
-- Provider responses here are deliberate test fixtures, never live verification.
begin;
create function sdi_test.yt_review(creator uuid,digest text,destinations text[] default array['feed','youtube'],spatter boolean default false)
 returns uuid language plpgsql as $$
declare review uuid; upload uuid:=gen_random_uuid();
begin
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,destinations,spatter_generated)
 values(creator,'Channel reference','rev1',digest,'https://intake.example.test/preview',clock_timestamp()+interval '1 day','terms-v1','Own work',true,destinations,spatter)
 returning id into review;
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at)
 values(review,1,digest,upload::text||'.mp4',1024,'Channel reference','Actual approved caption',false,clock_timestamp()+interval '1 day');
 insert into sdi_private.upload_registrations(upload_id,creator,review_id,metadata,object_key)
 values(upload,creator,review,jsonb_build_object('sha256',digest),upload::text||'.mp4');
 return review;
end $$;
create function sdi_test.yt_receipt(video text,digest text,embeddable boolean default true) returns jsonb language sql as $$
 select jsonb_build_object('state','published','video_id',video,'channel_id','UCownerchannel','digest',digest,
 'url','https://www.youtube.com/watch?v='||video,'visibility','public','processing_verified',true,'embeddable',embeddable)
$$;
create function sdi_test.yt_record(review uuid,video text,digest text,embeddable boolean default true) returns uuid language plpgsql as $$
declare claimed jsonb; job uuid; token uuid;
begin
 perform sdi_private.publish_action('enqueue',review,'youtube');
 claimed:=sdi_private.publish_claim();job:=(claimed->>'job')::uuid;token:=(claimed->>'lease')::uuid;
 perform sdi_test.check(sdi_private.publish_progress(job,token,video,true),'private processing progress recorded');
 update sdi_private.publish_jobs set next_attempt=clock_timestamp() where id=job;
 claimed:=sdi_private.publish_claim();token:=(claimed->>'lease')::uuid;
 perform sdi_test.check(sdi_private.publish_finish_youtube(job,token,sdi_test.yt_receipt(video,digest,embeddable)),'service verified receipt recorded');
 return job;
end $$;
do $$
declare creator uuid; viewer uuid; reviewer uuid; owner uuid; review uuid; withdrawn uuid; nonembed uuid; race uuid; spatter uuid;
 y uuid; f uuid; token uuid; media uuid; upload uuid; claimed jsonb; result jsonb; receipt jsonb; before_time timestamptz; visible_count integer; opponent uuid; raw_media uuid; active_match uuid; final_match uuid; war_report uuid;
 d1 text:=repeat('41',32); d2 text:=repeat('42',32); d3 text:=repeat('43',32); d4 text:=repeat('44',32); d5 text:=repeat('45',32);
begin
 creator:=sdi_test.user('yt-ref-creator');viewer:=sdi_test.user('yt-ref-viewer');
 reviewer:=sdi_test.admin('yt-ref-reviewer',false,array['reviews','moderation']);owner:=sdi_test.admin('yt-ref-owner',true,array[]::text[]);
 review:=sdi_test.yt_review(creator,d1);
 perform sdi_test.login(reviewer,'aal2');
 result:=sdi_private.review_action('decide',review,d1,1,'approved','Exact approved render.');
 perform sdi_test.check(result->>'status'='confirmed','reference render approved');
 perform sdi_test.login(creator);
 perform sdi_private.publish_action('enqueue',review,'feed');
 perform sdi_test.check((sdi_private.feed_publish_claim()->>'empty')::boolean,'dual-consent feed waits for channel receipt, never requests a raw copy');
 perform sdi_test.check(not exists(select 1 from public.sdi_watch_media where render_digest=d1),'no speculative media row');
 y:=sdi_test.yt_record(review,'abcdefghijk',d1);
 select lease into token from sdi_private.publish_jobs where id=y;
 receipt:=sdi_test.yt_receipt('abcdefghijk',d1);
 perform sdi_test.check(sdi_private.publish_finish_youtube(y,token,receipt),'channel receipt duplicate is idempotent');
 perform sdi_test.check(not sdi_private.publish_finish_youtube(y,token,receipt||'{"digest":"bad"}'::jsonb),'different digest receipt is refused');
 perform sdi_test.check(not sdi_private.publish_finish_youtube(y,token,receipt||'{"visibility":"private"}'::jsonb),'private receipt cannot authorize publication');
 perform sdi_test.check(sdi_test.denied('authenticated',format('select public.sdi_publish_finish_youtube(%L,%L,%L::jsonb)',y,token,receipt::text)),'authenticated cannot forge channel receipt');
 perform sdi_test.check(sdi_test.denied('anon',format('select public.sdi_publish_finish_youtube(%L,%L,%L::jsonb)',y,token,receipt::text)),'anon cannot forge channel receipt');
 claimed:=sdi_private.feed_publish_claim();f:=(claimed->>'job')::uuid;token:=(claimed->>'lease')::uuid;
 perform sdi_test.check(claimed->>'playback_provider'='youtube' and not (claimed ? 'object_key') and not (claimed ? 'byte_count'),'reference claim exposes no artifact transfer contract');
 perform sdi_test.check(sdi_test.denied('authenticated',format('select public.sdi_feed_publish_reference(%L,%L)',f,token)),'authenticated cannot publish a reference');
 result:=sdi_private.feed_publish_reference(f,token);
 perform sdi_test.check(result->>'state'='published' and result->>'url'=receipt->>'url','verified reference published');
 select id into media from public.sdi_watch_media where render_digest=d1;
 perform sdi_test.check((select playback_provider='youtube' and url is null and duration is null and not approved
  and provider_url=receipt->>'url' and youtube_job=y from public.sdi_watch_media where id=media),'no fake raw URL, duration or raw approval');
 select published_at into before_time from sdi_private.feed_posts where media_id=media;
 perform sdi_test.check(sdi_private.feed_publish_reference(f,token)->>'state'='published','reference finish duplicate is idempotent');
 perform sdi_test.check((select count(*) from sdi_private.feed_posts where media_id=media)=1
  and (select published_at from sdi_private.feed_posts where media_id=media)=before_time,'duplicate does not create or reorder a post');
 perform sdi_test.login(viewer);
 result:=sdi_private.feed_page('recent');
 perform sdi_test.check(result->'posts'->0->>'url'=receipt->>'url' and result->'posts'->0->>'playback_provider'='youtube','feed alone projects canonical provider link');
 perform sdi_test.check(not (result->'posts'->0->>'can_download')::boolean and not (result->'posts'->0->>'allow_export')::boolean,'reference never offers file download');
 execute 'set local role authenticated';
 select count(*) into visible_count from public.sdi_watch_media where id=media;
 reset role;
 perform sdi_test.check(visible_count=0,'raw REST/Watch Together reader cannot select reference');
 perform sdi_test.login(creator);
 perform sdi_private.export_consent(review,1,true);
 perform sdi_test.login(viewer);
 result:=sdi_private.feed_page('recent');
 perform sdi_test.check(not (result->'posts'->0->>'allow_export')::boolean,'creator raw-export flag cannot enable provider downloads');
 perform sdi_test.check(sdi_private.feed_action('like',(select id from sdi_private.feed_posts where media_id=media))->>'status'='confirmed','normal authenticated reactions work on reference');

 -- War Room accepts verified metadata through its own projection, while
 -- generic raw REST/Watch Together access and exports remain unchanged.
 opponent:=sdi_test.user('yt-war-opponent');
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
 values('Raw opponent','https://cdn.example.test/war.mp4',4,true,opponent,repeat('49',32)) returning id into raw_media;
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_war_media()'),'anonymous cannot request War Room media');
 perform sdi_test.login(creator);
 execute 'set local role authenticated';
 result:=public.sdi_war_media();
 reset role;
 perform sdi_test.check(jsonb_array_length(result->'media')=1 and (result->'media'->0->>'id')::uuid=media
  and result->'media'->0->'video_source'->>'provider'='youtube'
  and result->'media'->0->'video_source'->>'url'=receipt->>'url'
  and result->'media'->0->>'url' is null and result->'media'->0->>'duration' is null,'owned projection returns typed source without fake raw identity');
 begin
  delete from auth.sessions where user_id=creator;
  perform sdi_test.check(sdi_private.war_media()->>'error' is not null,'owned media requires a live session, not only JWT identity');
  raise sqlstate 'Z0001';
 exception when sqlstate 'Z0001' then null;end;
 result:=sdi_private.war_action('propose',media=>raw_media,opponent=>opponent);
 perform sdi_test.check(result->>'error' is not null,'cannot submit another creator media');
 result:=sdi_private.war_action('propose',media=>media,opponent=>opponent);
 perform sdi_test.check(result->>'status'='confirmed','verified YouTube media can propose');
 select id into active_match from sdi_private.war_matches where left_media=media order by created_at desc limit 1;
 perform sdi_test.login(viewer);
 perform sdi_test.check(jsonb_array_length(sdi_private.war_action('list')->'matches')=0,'pending matchup still requires participant consent');
 perform sdi_test.login(opponent);
 result:=sdi_private.war_action('accept',active_match,raw_media);
 perform sdi_test.check(result->>'status'='confirmed','raw opponent accepts verified YouTube proposal');
 result:=sdi_private.war_media();
 perform sdi_test.check(jsonb_array_length(result->'media')=1 and (result->'media'->0->>'id')::uuid=raw_media,'projection cannot list another creator YouTube reference');
 perform sdi_test.check(sdi_private.war_action('vote',active_match,choice=>'right')->>'error' is not null,'participants still cannot vote');
 perform sdi_test.login(viewer);
 result:=sdi_private.war_action('list');
 perform sdi_test.check(result->'matches'->0->>'left_url' is null
  and result->'matches'->0->'left_video_source'->>'provider'='youtube'
  and result->'matches'->0->'left_video_source'->>'url'=receipt->>'url'
  and result->'matches'->0->'right_video_source'->>'provider'='rendition','match projection binds each provider without watch page in raw field');
 perform sdi_test.check(sdi_private.war_action('vote',active_match,choice=>'left')->>'status'='confirmed','authenticated viewer can vote on verified reference');
 -- Each subtransaction restores its original data, never fabricating a new
 -- provider receipt or relaxing the production conditions to recover a test.
 begin
  update sdi_private.publish_jobs set youtube_receipt=jsonb_set(youtube_receipt,'{embeddable}','false') where id=y;
  perform sdi_test.check(jsonb_array_length(sdi_private.war_action('list')->'matches')=0,'changed embedding receipt hides matchup');
  perform sdi_test.check(sdi_private.war_action('vote',active_match,choice=>'right')->>'error' is not null,'changed receipt prevents votes');
  raise sqlstate 'Z0001';
 exception when sqlstate 'Z0001' then null;end;
 begin
  update sdi_private.feed_posts set visible=false where media_id=media;
  perform sdi_test.check(not sdi_private.war_media_available((select m from public.sdi_watch_media m where id=media)),'moderation visibility gate hides metadata matchup');
  raise sqlstate 'Z0001';
 exception when sqlstate 'Z0001' then null;end;
 begin
  update sdi_private.render_reviews set rights_cleared=false where id=review;
  perform sdi_test.check(jsonb_array_length(sdi_private.war_action('list')->'matches')=0,'lost rights clearance hides matchup');
  raise sqlstate 'Z0001';
 exception when sqlstate 'Z0001' then null;end;
 begin
  insert into sdi_private.account_controls(user_id,state,reason) values(creator,'suspended','test');
  perform sdi_test.check(sdi_private.war_action('vote',active_match,choice=>'right')->>'error' is not null,'suspended creator reference cannot receive votes');
  raise sqlstate 'Z0001';
 exception when sqlstate 'Z0001' then null;end;
 begin
  update public.sdi_watch_media set owner_id=null where id=media;
  perform sdi_test.check((select provider_url is null and youtube_job is null and url is null from public.sdi_watch_media where id=media)
   and jsonb_array_length(sdi_private.war_action('list')->'matches')=0,'anonymization clears locator and hides matchup');
  raise sqlstate 'Z0001';
 exception when sqlstate 'Z0001' then null;end;
 begin
  update public.sdi_watch_media set provider_url='https://youtu.be/abcdefghijk' where id=media;
  raise exception 'noncanonical source accepted';
 exception when check_violation then null;end;
 -- Finalization must count an eligible YouTube rendition without setting raw
 -- approval true. A separate active match remains for cancellation assertions.
 perform sdi_test.login(creator);
 perform sdi_private.war_action('propose',media=>media,opponent=>opponent);
 select id into final_match from sdi_private.war_matches where left_media=media and status='pending' order by created_at desc limit 1;
 perform sdi_test.login(opponent);perform sdi_private.war_action('accept',final_match,raw_media);
 update sdi_private.war_matches set ends_at=clock_timestamp()-interval '1 second' where id=final_match;
 result:=sdi_private.war_finalize();
 perform sdi_test.check((result->>'completed')::integer=1 and (select status='completed' from sdi_private.war_matches where id=final_match),'eligible YouTube matchup finalizes without raw approval');
 perform sdi_test.login(viewer);perform sdi_private.war_report(final_match,'Check this matchup.');
 select id into war_report from sdi_private.war_reports where match_id=final_match;
 perform sdi_test.login(reviewer,'aal2');
 result:=sdi_private.war_moderate('list');
 perform sdi_test.check(result->'reports'->0->>'left_url'='' and result->'reports'->0->>'right_url'='https://cdn.example.test/war.mp4','raw-only moderator queue stays decodable without handing watch URL to AVPlayer');
 result:=sdi_private.war_moderate('remove',war_report,1,'Matchup removed for review.');
 perform sdi_test.check(result->>'status'='confirmed' and (select status='removed' from sdi_private.war_matches where id=final_match),'moderator can still remove provider matchup');
 perform sdi_test.login(viewer);

 -- Staging retirement must not remove an otherwise authorized metadata reference.
 update sdi_private.publish_jobs set lease_expires=clock_timestamp()-interval '5 minutes' where review_id=review;
 select upload_id into upload from sdi_private.upload_registrations where review_id=review;
 perform sdi_test.check(sdi_private.publication_releasable(upload),'both verified destination jobs allow staging release');
 perform sdi_test.check(sdi_private.release_published_upload(upload,review),'staging release is authorized');
 perform sdi_test.check(sdi_private.feed_media_available((select m from public.sdi_watch_media m where id=media)),'reference survives temporary artifact expiry');
 perform sdi_test.login(creator);
 perform sdi_private.publish_action('cancel',job=>y);
 perform sdi_test.check(not (select visible from sdi_private.feed_posts where media_id=media),'channel cancellation hides feed before provider withdrawal');
 perform sdi_test.check((select state from sdi_private.publish_jobs where id=f)='cancelled','feed reference cancellation is terminal without host deletion');
 perform sdi_test.check((select state from sdi_private.publish_jobs where id=y)='removal_pending','channel privacy operation is still pending');
 result:=sdi_private.war_media();
 perform sdi_test.check(jsonb_array_length(result->'media')=0,'withdrawn reference leaves owned submission projection immediately');
 perform sdi_test.login(viewer);
 perform sdi_test.check(jsonb_array_length(sdi_private.war_action('list')->'matches')=0,'withdrawal hides matchup before external provider operation');
 perform sdi_test.check(sdi_private.war_action('vote',active_match,choice=>'right')->>'error' is not null,'withdrawal prevents later vote');
 update sdi_private.war_matches set ends_at=clock_timestamp()-interval '1 second' where id=active_match;
 result:=sdi_private.war_finalize();
 perform sdi_test.check((result->>'removed')::integer=1 and (select status='removed' from sdi_private.war_matches where id=active_match),'revoked metadata cannot finalize a contest');
 perform sdi_test.login(creator);

 perform sdi_test.check((sdi_private.feed_removal_claim()->>'empty')::boolean,'raw removal worker never receives YouTube watch URL');
 claimed:=sdi_private.publish_removal_claim();
 perform sdi_test.check((claimed->>'job')::uuid=y,'existing channel removal worker receives the real job');
 perform sdi_test.check(sdi_private.publish_removal_finish(y,(claimed->>'lease')::uuid,'abcdefghijk',false),'unconfirmed withdrawal recorded without success');
 perform sdi_test.check((select state from sdi_private.publish_jobs where id=y)='removal_pending','failed provider withdrawal stays pending');
 update sdi_private.publish_jobs set next_attempt=clock_timestamp() where id=y;
 claimed:=sdi_private.publish_removal_claim();
 perform sdi_test.check(sdi_private.publish_removal_finish(y,(claimed->>'lease')::uuid,'abcdefghijk',true),'provider privacy confirmation settles channel job');
 perform sdi_test.check((select state from sdi_private.publish_jobs where id=y)='cancelled','channel removal settles only after confirmation');
 perform sdi_test.check(sdi_private.feed_publish_reference(f,token)->>'state'<>'published','withdrawn reference cannot be revived by duplicate finish');

 -- Consent withdrawn after reference claim but before its transaction wins.
 withdrawn:=sdi_test.yt_review(creator,d2);
 perform sdi_test.login(reviewer,'aal2');perform sdi_private.review_action('decide',withdrawn,d2,1,'approved','Fine.');
 perform sdi_test.login(creator);perform sdi_private.publish_action('enqueue',withdrawn,'feed');
 y:=sdi_test.yt_record(withdrawn,'bcdefghijkl',d2);
 claimed:=sdi_private.feed_publish_claim();f:=(claimed->>'job')::uuid;token:=(claimed->>'lease')::uuid;
 perform sdi_private.creator_review('withdraw_consent',withdrawn,1);
 result:=sdi_private.feed_publish_reference(f,token);
 perform sdi_test.check(result->>'state'='cancelled','consent withdrawal wins reference finish race');
 perform sdi_test.check(not exists(select 1 from public.sdi_watch_media where render_digest=d2),'withdrawn claim never creates metadata or media copy');

 -- Public channel release can be valid while embedding is explicitly unavailable.
 nonembed:=sdi_test.yt_review(creator,d3);
 perform sdi_test.login(reviewer,'aal2');perform sdi_private.review_action('decide',nonembed,d3,1,'approved','Fine.');
 perform sdi_test.login(creator);perform sdi_private.publish_action('enqueue',nonembed,'feed');
 y:=sdi_test.yt_record(nonembed,'cdefghijklm',d3,false);
 claimed:=sdi_private.feed_publish_claim();f:=(claimed->>'job')::uuid;token:=(claimed->>'lease')::uuid;
 result:=sdi_private.feed_publish_reference(f,token);
 perform sdi_test.check(result->>'state'='unavailable' and (select state from sdi_private.publish_jobs where id=f)='failed','nonembeddable publication never claims feed success');
 perform sdi_test.check((select state from sdi_private.publish_jobs where id=y)='published','channel success is retained separately');
 perform sdi_test.check(sdi_private.publish_action('retry',job=>f)->>'status'='queued','bounded authorized retry remains available');
 claimed:=sdi_private.feed_publish_claim();
 perform sdi_test.check(sdi_private.feed_publish_reference(f,(claimed->>'lease')::uuid)->>'state'='unavailable','retry never changes missing embedding permission into success');

 -- Creator cancellation between final provider read and channel finish must
 -- record removal_pending and cannot create an eligible feed reference.
 race:=sdi_test.yt_review(creator,d4);
 perform sdi_test.login(reviewer,'aal2');perform sdi_private.review_action('decide',race,d4,1,'approved','Fine.');
 perform sdi_test.login(creator);perform sdi_private.publish_action('enqueue',race,'youtube');
 claimed:=sdi_private.publish_claim();y:=(claimed->>'job')::uuid;token:=(claimed->>'lease')::uuid;
 perform sdi_private.publish_progress(y,token,'defghijklmn',true);
 update sdi_private.publish_jobs set next_attempt=clock_timestamp() where id=y;
 claimed:=sdi_private.publish_claim();token:=(claimed->>'lease')::uuid;
 perform sdi_private.creator_review('withdraw_consent',race,1);
 perform sdi_test.check(sdi_private.publish_finish_youtube(y,token,sdi_test.yt_receipt('defghijklmn',d4)),'late provider result is recorded for reconciliation/removal');
 perform sdi_test.check((select state from sdi_private.publish_jobs where id=y)='removal_pending','late public response is not a publication success');
 perform sdi_test.check(not exists(select 1 from public.sdi_watch_media where render_digest=d4),'channel cancellation race creates no feed row');

 -- The existing exact-render owner gate remains in front of both paths.
 spatter:=sdi_test.yt_review(creator,d5,array['feed','youtube'],true);
 perform sdi_test.login(reviewer,'aal2');result:=sdi_private.review_action('decide',spatter,d5,1,'approved','Not owner.');
 perform sdi_test.check(result->>'error' like 'Approval requires%','Spatter reviewer cannot substitute for owner');
 perform sdi_test.check(not sdi_private.release_allowed(spatter,1,d5,'feed'),'owner approval is still required for new reference publication');
end $$;
rollback;
