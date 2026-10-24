-- Local assertions for feed poster thumbnails (#217) and keyset-only listing with a
-- stable id tiebreak in every ranking (#220). Runs on the throwaway cluster only.
begin;
create function sdi_test.approved_review(creator uuid, reviewer uuid, digest text) returns uuid language plpgsql as $$
declare review uuid; r jsonb;
begin
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,rights_cleared,destinations)
 values(creator,'Render '||left(digest,6),'rev1',digest,'https://intake.example.test/'||left(digest,6),clock_timestamp()+interval '1 day','terms-v1','Own work',true,array['feed'])
 returning id into review;
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at)
 values(review,1,digest,left(digest,6)||'.mp4',1024,'Render '||left(digest,6),'A caption.',false,clock_timestamp()+interval '24 hours');
 perform sdi_test.login(reviewer,'aal2');
 r:=sdi_private.review_action('decide',review,digest,1,'approved','Exact render approved.');
 perform sdi_test.check(r->>'status'='confirmed','approval: '||r::text);
 perform sdi_test.login(creator);
 r:=sdi_private.publish_action('enqueue',review,'feed');
 perform sdi_test.check(r->>'status'='queued','feed job queued: '||r::text);
 return review;
end $$;

-- Posters: recorded with the verified copy, bounded, all-or-none, returned by the feed.
do $$
declare creator uuid; viewer uuid; reviewer uuid; claimed jsonb; job uuid; token uuid; r jsonb; post jsonb;
 d1 text:=repeat('a',64); d2 text:=repeat('b',64); d3 text:=repeat('c',64); pd text:=repeat('9',64);
 video text; poster text;
begin
 creator:=sdi_test.user('poster-creator'); viewer:=sdi_test.user('poster-viewer');
 reviewer:=sdi_test.admin('poster-reviewer',false,array['reviews']);

 perform sdi_test.approved_review(creator,reviewer,d1);
 claimed:=sdi_private.feed_publish_claim(); job:=(claimed->>'job')::uuid; token:=(claimed->>'lease')::uuid;
 video:='https://media.example.test/'||d1||'.mp4'; poster:='https://media.example.test/'||d1||'.poster.jpg';
 perform sdi_test.check(not sdi_private.feed_publish_finish(job,token,video,10,null,poster,null,null),'partial poster refused');
 perform sdi_test.check(not sdi_private.feed_publish_finish(job,token,video,10,null,poster,pd,262145),'poster over 256 KiB refused');
 perform sdi_test.check(not sdi_private.feed_publish_finish(job,token,video,10,null,poster,pd,0),'empty poster refused');
 perform sdi_test.check(not sdi_private.feed_publish_finish(job,token,video,10,null,'http://media.example.test/p.jpg',pd,2048),'insecure poster URL refused');
 perform sdi_test.check(not sdi_private.feed_publish_finish(job,token,video,10,null,poster,'NOT-A-DIGEST',2048),'malformed poster digest refused');
 perform sdi_test.check(not sdi_private.feed_publish_finish(job,token,video,10,null,video,pd,2048),'poster cannot be the video itself');
 perform sdi_test.check((select state from sdi_private.publish_jobs where id=job)='leased','refused finishes changed nothing');
 perform sdi_test.check(sdi_private.feed_publish_finish(job,token,video,10,null,poster,pd,2048),'finish with poster accepted');
 perform sdi_test.check((select poster_url||'|'||poster_digest||'|'||poster_bytes from public.sdi_watch_media where render_digest=d1)=poster||'|'||pd||'|2048',
  'poster URL, digest and size recorded on the media row');
 perform sdi_test.check((select poster_url from sdi_private.publish_jobs where id=job)=poster,'job keeps the hosted poster for later removal');
 begin
  update public.sdi_watch_media set poster_digest=null where render_digest=d1;
  perform sdi_test.check(false,'a poster without its digest must violate the constraint');
 exception when check_violation then null;
 end;

 -- A render published without a poster stays posterless (placeholder on clients).
 perform sdi_test.approved_review(creator,reviewer,d2);
 claimed:=sdi_private.feed_publish_claim();
 perform sdi_test.check(sdi_private.feed_publish_finish((claimed->>'job')::uuid,(claimed->>'lease')::uuid,'https://media.example.test/'||d2||'.mp4',8),'finish without poster');

 perform sdi_test.login(viewer);
 r:=sdi_private.feed_page('recent');
 perform sdi_test.check(jsonb_array_length(r->'posts')=2,'both posts listed: '||left(r::text,300));
 select x into post from jsonb_array_elements(r->'posts') x where x->>'url' like '%'||d1||'.mp4';
 perform sdi_test.check(post->>'poster_url'=poster,'feed returns the recorded poster URL: '||post::text);
 select x into post from jsonb_array_elements(r->'posts') x where x->>'url' like '%'||d2||'.mp4';
 perform sdi_test.check(post ? 'poster_url' and post->'poster_url'='null'::jsonb,'posterless post reports null, never a guessed image');
 perform sdi_test.check(not (post ? 'poster_digest'),'digest stays server-side');

 -- Removal hands the worker the poster with the video, for both removal sources.
 perform sdi_test.login(creator);
 perform sdi_test.approved_review(creator,reviewer,d3);
 claimed:=sdi_private.feed_publish_claim(); job:=(claimed->>'job')::uuid; token:=(claimed->>'lease')::uuid;
 perform sdi_test.login(reviewer,'aal2');
 r:=sdi_private.review_rights((select id from sdi_private.render_reviews where render_digest=d3),d3,1,false,'Rights dispute.');
 perform sdi_test.check(sdi_private.feed_publish_finish(job,token,'https://media.example.test/'||d3||'.mp4',8,null,'https://media.example.test/'||d3||'.poster.jpg',pd,1000),
  'lapsed approval accepted for cleanup');
 perform sdi_test.check(not exists(select 1 from public.sdi_watch_media where render_digest=d3),'no media row for the lapsed render');
 claimed:=sdi_private.feed_removal_claim();
 perform sdi_test.check(claimed->>'source'='publish_job' and claimed->>'poster_url'='https://media.example.test/'||d3||'.poster.jpg','removal claim carries the orphan poster: '||claimed::text);
 perform sdi_test.check(sdi_private.feed_removal_finish('publish_job',(claimed->>'job')::uuid,(claimed->>'lease')::uuid,true),'removal confirmed');
 perform sdi_test.check((select poster_url from sdi_private.publish_jobs where id=job) is null,'confirmed removal clears the poster record');

 insert into sdi_private.removal_jobs(media_id,render_digest,reason)
  select id,render_digest,'moderation' from public.sdi_watch_media where render_digest=d1;
 claimed:=sdi_private.feed_removal_claim();
 perform sdi_test.check(claimed->>'source'='removal_job' and claimed->>'poster_url'=poster,'moderation removal carries the poster: '||claimed::text);
end $$;

-- Keyset listing: the offset path is gone and equal timestamps break ties on id in
-- every ranking, so a walk visits each eligible post exactly once.
do $$
declare alice uuid; bob uuid; media uuid; i integer; r jsonb; cat text; cursor_text text; snapshot timestamptz;
 seen uuid[]; ids uuid[]; expected uuid[]; pages integer; tie timestamptz:=clock_timestamp()-interval '1 hour';
begin
 alice:=sdi_test.user('keyset-alice'); bob:=sdi_test.user('keyset-bob');
 update sdi_private.feed_posts set visible=false;   -- only this block's posts are listed
 for i in 1..57 loop
  insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
  values('Tie '||i,'https://cdn.example.test/tie'||i||'.mp4',5,true,alice,lpad(to_hex(i),64,'7')) returning id into media;
  insert into sdi_private.feed_posts(media_id,creator,creator_name,visible,published_at,featured)
  values(media,alice,'alice',true,tie,true);
 end loop;
 perform sdi_test.login(bob);
 perform sdi_private.feed_action('follow',target=>alice);
 select array_agg(p.id order by p.id desc) into expected from sdi_private.feed_posts p where p.creator=alice;

 r:=sdi_private.feed_action('list',page=>1);
 perform sdi_test.check(r->>'error' like 'Feed pages after the first use sdi_feed_page%','offset page refused: '||r::text);
 r:=sdi_private.feed_action('list',category=>'recent');
 perform sdi_test.check(jsonb_array_length(r->'posts')=25 and r->>'next_cursor' is not null,'list is the first keyset page: '||left(r::text,200));

 foreach cat in array array['recent','following','featured','trending'] loop
  update sdi_private.feed_budget set started_at=clock_timestamp()-interval '2 minutes' where actor=bob;
  seen:='{}'; cursor_text:=null; snapshot:=null; pages:=0;
  loop
   r:=sdi_private.feed_page(cat,cursor_text,snapshot);
   perform sdi_test.check(r->>'error' is null,cat||' page: '||coalesce(r->>'error',''));
   select coalesce(array_agg((x->>'id')::uuid),'{}') into ids from jsonb_array_elements(r->'posts') x;
   perform sdi_test.check(not (ids && seen),cat||': no post repeats across pages');
   seen:=seen||ids; pages:=pages+1; snapshot:=(r->>'as_of')::timestamptz; cursor_text:=r->>'next_cursor';
   exit when not (r->>'has_more')::boolean;
   perform sdi_test.check(cursor_text is not null,cat||': has_more always carries a cursor');
  end loop;
  perform sdi_test.check(seen=expected,cat||': 57 equal-time posts walked once each in id order ('||cardinality(seen)||' seen, '||pages||' pages)');
  perform sdi_test.check(pages=3,cat||': three pages of 25/25/7');
 end loop;
end $$;
rollback;
