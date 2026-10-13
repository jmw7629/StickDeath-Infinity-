-- Local assertions for feed-integrity.sql. Runs on the throwaway cluster only.
begin;
do $$
declare alice uuid; bob uuid; carol uuid; admin uuid; media uuid; media2 uuid; the_post uuid; later_post uuid; r jsonb; report uuid; i integer; snapshot timestamptz;
begin
 alice:=sdi_test.user('alice'); bob:=sdi_test.user('bob'); carol:=sdi_test.user('carol');
 admin:=sdi_test.admin('mod',false,array['moderation']);
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
 values('Alice render','https://cdn.example.test/a.mp4',12,true,alice,repeat('a',64)) returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,visible) values(media,alice,'alice',true) returning id into the_post;

 -- Self-like is refused; another member can like once.
 perform sdi_test.login(alice);
 r:=sdi_private.feed_action('like',the_post);
 perform sdi_test.check(r->>'error' like 'You cannot like%','self-like rejected: '||r::text);
 perform sdi_test.check((select count(*) from sdi_private.feed_likes where feed_likes.post=the_post)=0,'no self-like stored');
 perform sdi_test.login(bob);
 r:=sdi_private.feed_action('like',the_post);
 perform sdi_test.check(r->>'status'='confirmed','other member likes: '||r::text);
 r:=sdi_private.feed_action('like',the_post);
 perform sdi_test.check((select count(*) from sdi_private.feed_likes where feed_likes.post=the_post)=1,'like is idempotent');

 -- Report, dismiss, repeat report: the decision stands.
 r:=sdi_private.feed_action('report',the_post,reason=>'spam');
 perform sdi_test.check(r->>'status'='recorded','report recorded: '||r::text);
 select id into report from sdi_private.feed_reports where feed_reports.post=the_post and actor=bob;
 perform sdi_test.login(admin,'aal2');
 r:=sdi_private.moderation_action('dismiss',report,1,'Not spam on review.');
 perform sdi_test.check(r->>'status'='confirmed','admin dismisses: '||r::text);
 perform sdi_test.login(bob);
 r:=sdi_private.feed_action('report',the_post,reason=>'abuse');
 perform sdi_test.check(r->>'status'='recorded','repeat report accepted silently');
 perform sdi_test.check((select state||'/'||reason||'/'||version from sdi_private.feed_reports where id=report)='dismissed/spam/1','dismissed report unchanged');
 update sdi_private.feed_reports set reason='rights' where id=report;
 perform sdi_test.check((select state||'/'||reason from sdi_private.feed_reports where id=report)='dismissed/spam','direct update cannot reopen a decided report');

 -- Visible to others until the creator is suspended.
 r:=sdi_private.feed_action('list');
 perform sdi_test.check(jsonb_array_length(r->'posts')=1,'post listed before suspension');
 -- Snapshot-stable paging: a post published after the page-0 instant stays out
 -- of later pages requested with that instant; a fresh instant shows it; a
 -- stale instant is refused.
 snapshot:=(r->>'as_of')::timestamptz;
 perform sdi_test.check(snapshot is not null and snapshot<=clock_timestamp(),'list returns its snapshot instant');
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
 values('Alice later render','https://cdn.example.test/a2.mp4',9,true,alice,repeat('b',64)) returning id into media2;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,visible,published_at) values(media2,alice,'alice',true,clock_timestamp()) returning id into later_post;
 r:=sdi_private.feed_action('list',as_of=>snapshot);
 perform sdi_test.check(jsonb_array_length(r->'posts')=1 and (r->>'as_of')::timestamptz=snapshot,'post published after the snapshot excluded, snapshot echoed: '||r::text);
 r:=sdi_private.feed_action('list',as_of=>clock_timestamp());
 perform sdi_test.check(jsonb_array_length(r->'posts')=2 and (r->'posts'->0->>'id')::uuid=later_post,'fresh snapshot lists the newer post first');
 r:=sdi_private.feed_action('list',as_of=>clock_timestamp()+interval '1 hour');
 perform sdi_test.check(jsonb_array_length(r->'posts')=2 and (r->>'as_of')::timestamptz<=clock_timestamp(),'future instant clamped to now');
 r:=sdi_private.feed_action('list',as_of=>clock_timestamp()-interval '2 days');
 perform sdi_test.check(r->>'error'='This feed snapshot has expired. Refresh the feed.','stale snapshot refused');
 delete from sdi_private.feed_posts where id=later_post; delete from public.sdi_watch_media where id=media2;
 insert into sdi_private.account_controls(user_id,state,reason) values(alice,'suspended','test');
 r:=sdi_private.feed_action('list');
 perform sdi_test.check(jsonb_array_length(r->'posts')=0,'restricted creator hidden from feed');
 r:=sdi_private.feed_action('like',the_post,enabled=>false);
 perform sdi_test.check(r->>'error'='Post unavailable.','restricted creator post not reactable');
 r:=sdi_private.feed_action('follow',null,alice);
 perform sdi_test.check(r->>'error'='Creator unavailable.','restricted creator cannot be followed');
 delete from sdi_private.account_controls where user_id=alice;

 -- War Room: stale proposals stop counting toward the active limit and vanish from lists.
 perform sdi_test.login(alice);
 for i in 1..5 loop
  r:=sdi_private.war_action('propose',null,media,bob);
  perform sdi_test.check(r->>'status'='confirmed','proposal '||i||': '||r::text);
 end loop;
 r:=sdi_private.war_action('propose',null,media,bob);
 perform sdi_test.check(r->>'error' like 'Finish or withdraw%','sixth live proposal refused');
 update sdi_private.war_matches set created_at=clock_timestamp()-interval '8 days' where creator=alice;
 r:=sdi_private.war_action('propose',null,media,carol);
 perform sdi_test.check(r->>'status'='confirmed','expired proposals do not count: '||r::text);
 perform sdi_test.login(bob);
 r:=sdi_private.war_action('list');
 perform sdi_test.check(jsonb_array_length(r->'matches')=0,'stale proposals hidden from the opponent');
 perform sdi_test.check(sdi_private.war_expire_proposals()=5,'service expiry marks five proposals');
 perform sdi_test.check((select count(*) from sdi_private.war_matches where status='expired')=5,'expired status recorded');
 perform sdi_test.login(carol);
 r:=sdi_private.war_action('list');
 perform sdi_test.check(jsonb_array_length(r->'matches')=1,'live proposal visible to its opponent');
 insert into sdi_private.account_controls(user_id,state,reason) values(alice,'banned','test');
 r:=sdi_private.war_action('list');
 perform sdi_test.check(jsonb_array_length(r->'matches')=0,'restricted creator hidden from War Room');
end $$;

-- Problem 6: artifacts registered for 24 hours are retained for review/publishing.
do $$
declare creator uuid; review uuid; expiry timestamptz;
begin
 creator:=sdi_test.user('render-owner');
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,destinations)
 values(creator,'Clip','rev1',repeat('b',64),'https://intake.example.test/p',clock_timestamp()+interval '1 day','terms-v1','Own work',true,array['feed'])
 returning id into review;
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,made_for_kids,expires_at)
 values(review,1,repeat('b',64),'x.mp4',10,'Clip',false,clock_timestamp()+interval '24 hours');
 select expires_at into expiry from sdi_private.render_artifacts where review_id=review;
 perform sdi_test.check(expiry>clock_timestamp()+interval '6 days','review retention extended to seven days');
 update sdi_private.render_reviews set state='approved' where id=review;
 select expires_at into expiry from sdi_private.render_artifacts where review_id=review and version=1;
 perform sdi_test.check(expiry>clock_timestamp()+interval '29 days','approved render retained thirty days');
end $$;
rollback;
