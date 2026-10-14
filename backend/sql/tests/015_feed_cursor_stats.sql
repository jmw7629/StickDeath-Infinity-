-- Local assertions for keyset feed paging, download entitlement, creator totals
-- and handle rules (#217, #219, #220, #224). Runs on the throwaway cluster only.
begin;
do $$
declare alice uuid; bob uuid; carol uuid; dave uuid; media uuid; post uuid; i integer; r jsonb; r2 jsonb; snapshot timestamptz;
 seen uuid[]:='{}'; ids uuid[]; base timestamptz:=clock_timestamp()-interval '2 hours'; newest uuid; hot uuid;
begin
 alice:=sdi_test.user('alice'); bob:=sdi_test.user('bob'); carol:=sdi_test.user('carol'); dave:=sdi_test.user('dave');
 -- 30 eligible posts by alice with distinct publication instants, plus one hidden
 -- and one unapproved post that must never appear.
 for i in 1..30 loop
  insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
  values('Clip '||i,'https://cdn.example.test/'||i||'.mp4',5,true,alice,lpad(to_hex(i),64,'c')) returning id into media;
  insert into sdi_private.feed_posts(media_id,creator,creator_name,visible,published_at,allow_export)
  values(media,alice,'alice',true,base+make_interval(secs=>i),i=30) returning id into post;
  if i=30 then newest:=post; end if;
  if i=3 then hot:=post; end if;
 end loop;
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
 values('Hidden','https://cdn.example.test/h.mp4',5,true,alice,repeat('d',64)) returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,visible,published_at) values(media,alice,'alice',false,base);
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
 values('Unapproved','https://cdn.example.test/u.mp4',5,false,alice,repeat('e',64)) returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,visible,published_at) values(media,alice,'alice',true,base);

 perform sdi_test.login(bob);
 r:=sdi_private.feed_page('recent');
 perform sdi_test.check(r->>'error' is null and jsonb_array_length(r->'posts')=25 and (r->>'has_more')::boolean,'first page bounded to 25: '||left(r::text,200));
 perform sdi_test.check((r->'posts'->0->>'id')::uuid=newest,'newest first');
 perform sdi_test.check(r->>'next_cursor' ~ '^0\|[0-9-]{10}T[0-9:]{8}\.[0-9]{6}Z\|[0-9a-f-]{36}$','opaque cursor shape: '||coalesce(r->>'next_cursor','null'));
 perform sdi_test.check((r->>'download_requires_plan')::boolean and (r->'posts'->0->>'allow_export')::boolean and not (r->'posts'->0->>'can_download')::boolean,
  'creator permits export but the free viewer cannot download');
 snapshot:=(r->>'as_of')::timestamptz;
 select array_agg((x->>'id')::uuid) into ids from jsonb_array_elements(r->'posts') x; seen:=seen||ids;

 -- A post published after page 0 and a burst of likes do not shift page 2.
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
 values('Late','https://cdn.example.test/late.mp4',5,true,alice,repeat('f',64)) returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,visible,published_at) values(media,alice,'alice',true,clock_timestamp());
 r2:=sdi_private.feed_page('recent',r->>'next_cursor',snapshot);
 perform sdi_test.check(jsonb_array_length(r2->'posts')=5 and not (r2->>'has_more')::boolean and r2->'next_cursor'='null'::jsonb,'second page holds the remaining five: '||left(r2::text,200));
 select array_agg((x->>'id')::uuid) into ids from jsonb_array_elements(r2->'posts') x;
 perform sdi_test.check(not (ids && seen),'no row repeats across pages'); seen:=seen||ids;
 perform sdi_test.check(cardinality(seen)=30,'all thirty eligible posts seen exactly once, hidden/unapproved/late excluded');

 -- Cursor validation.
 r2:=sdi_private.feed_page('recent','0|2026-01-01T00:00:00.000000Z|'||gen_random_uuid()::text,null);
 perform sdi_test.check(r2->>'error' like 'A feed cursor needs its snapshot%','cursor without snapshot refused');
 r2:=sdi_private.feed_page('recent','drop table',snapshot);
 perform sdi_test.check(r2->>'error' like 'Invalid feed cursor%','malformed cursor refused');
 r2:=sdi_private.feed_page('recent','0|2026-13-45T00:00:00.000000Z|00000000-0000-0000-0000-000000000000',snapshot);
 perform sdi_test.check(r2->>'error' like 'Invalid feed cursor%','impossible timestamp refused');
 r2:=sdi_private.feed_page('nonsense');
 perform sdi_test.check(r2->>'error'='Invalid feed page.','unknown category refused');

 -- Trending: likes up to the snapshot rank first; a later like does not reorder that snapshot.
 perform sdi_test.login(carol);
 perform sdi_private.feed_action('like',hot);
 perform sdi_test.login(bob);
 perform sdi_private.feed_action('like',hot);
 r:=sdi_private.feed_page('trending');
 perform sdi_test.check((r->'posts'->0->>'id')::uuid=hot and (r->'posts'->0->>'score')::int=2 and (r->'posts'->0->>'likes')::int=2,'most-liked first in trending');
 perform sdi_test.check(r->>'next_cursor' like '0|%','trending cursor after 25 rows carries the boundary score');
 snapshot:=(r->>'as_of')::timestamptz;
 perform sdi_test.login(dave);
 perform sdi_private.feed_action('like',newest);
 perform sdi_test.login(bob);
 r2:=sdi_private.feed_page('trending',r->>'next_cursor',snapshot);
 select array_agg((x->>'id')::uuid) into ids from jsonb_array_elements(r2->'posts') x;
 perform sdi_test.check(not (newest = any(ids)),'post liked after the snapshot is not moved into page 2');
 perform sdi_test.check(cardinality(ids)=6,'trending page 2 completes the thirty-one');

 -- Following and blocks.
 r:=sdi_private.feed_page('following');
 perform sdi_test.check(jsonb_array_length(r->'posts')=0 and not (r->>'has_more')::boolean,'following empty before following anyone');
 perform sdi_private.feed_action('follow',target=>alice);
 r:=sdi_private.feed_page('following');
 perform sdi_test.check(jsonb_array_length(r->'posts')=25,'following lists the followed creator');

 -- Creator totals are counted, not estimated.
 r:=sdi_private.creator_stats(alice);
 perform sdi_test.check((r->>'published_videos')::int=31 and (r->>'likes_received')::int=3 and (r->>'followers')::int=1 and r->'following'='null'::jsonb,
  'other creator totals, following hidden: '||r::text);
 r:=sdi_private.creator_stats();
 perform sdi_test.check((r->>'following')::int=1 and (r->>'published_videos')::int=0,'own totals include following: '||r::text);
 perform sdi_test.login(alice);
 perform sdi_private.feed_action('block',target=>bob);
 perform sdi_test.login(bob);
 r:=sdi_private.creator_stats(alice);
 perform sdi_test.check(r->>'error'='Profile unavailable.','blocked creator totals unavailable');
 r:=sdi_private.feed_page('recent');
 perform sdi_test.check(jsonb_array_length(r->'posts')=0,'blocked creator absent from paged feed');
 perform sdi_test.logout();
 r:=sdi_private.feed_page('recent');
 perform sdi_test.check(r->>'error'='Sign in with a full account.','signed-out paging refused');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_feed_page()'),'anon cannot execute sdi_feed_page');
 perform sdi_test.check(sdi_test.denied('anon','select public.sdi_creator_stats()'),'anon cannot execute sdi_creator_stats');
end $$;

-- Paid viewer: export-permitted posts become downloadable.
do $$
declare viewer uuid; author uuid; media uuid; r jsonb;
begin
 viewer:=sdi_test.user('payer'); author:=sdi_test.user('author');
 insert into sdi_private.billing_products(product_id,provider,tier,period,approved,owner_configured_at)
 values('test.creator.monthly','apple','creator','monthly',true,clock_timestamp());
 insert into sdi_private.subscriptions(user_id,provider,provider_subscription_id,product_id,status,paid_through,last_event_at)
 values(viewer,'apple','orig-feed','test.creator.monthly','active',clock_timestamp()+interval '10 days',clock_timestamp());
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest)
 values('Exportable','https://cdn.example.test/x.mp4',5,true,author,repeat('a',64)) returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,visible,allow_export) values(media,author,'author',true,true);
 perform sdi_test.login(viewer);
 r:=sdi_private.feed_page('recent');
 perform sdi_test.check(not (r->>'download_requires_plan')::boolean and (r->'posts'->0->>'can_download')::boolean,'paid viewer may download a permitted export: '||left(r::text,300));
end $$;

-- Handle rules apply when a member changes their username; case-insensitive uniqueness.
do $$
declare a uuid; b uuid; ok boolean;
begin
 a:=sdi_test.user('handle-a'); b:=sdi_test.user('handle-b');
 insert into public.users(id,username) values(a,'Stick_Fan'),(b,'legacy name from sign-up');
 begin update public.users set username='ab' where id=a; ok:=false; exception when check_violation then ok:=true; end;
 perform sdi_test.check(ok,'short handle refused on edit');
 begin update public.users set username='Admin' where id=a; ok:=false; exception when check_violation then ok:=true; end;
 perform sdi_test.check(ok,'reserved handle refused on edit');
 begin update public.users set username='stick_fan' where id=b; ok:=false; exception when unique_violation then ok:=true; end;
 perform sdi_test.check(ok,'handle unique regardless of case');
 update public.users set bio='still editable' where id=b;
 perform sdi_test.check((select bio from public.users where id=b)='still editable','legacy sign-up name does not block other edits');
 update public.users set username='new_handle_1' where id=b;
 perform sdi_test.check((select username from public.users where id=b)='new_handle_1','valid handle accepted');
end $$;
rollback;
