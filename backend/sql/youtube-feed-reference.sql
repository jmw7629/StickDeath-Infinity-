-- Unapplied candidate. Install last, after feed-publication.sql, rooms-v2.sql,
-- account-lifecycle.sql and consent-versions.sql. No provider requests run in SQL.
-- A YouTube feed item is metadata, not an AVPlayer rendition. Only the service
-- worker's verified owner-channel receipt can authorize its reference transaction.
begin;
alter table sdi_private.publish_jobs add column youtube_receipt jsonb,
 add column youtube_verified_at timestamptz,
 add constraint publish_youtube_receipt_object check(youtube_receipt is null or
  (destination='youtube' and jsonb_typeof(youtube_receipt)='object' and octet_length(youtube_receipt::text)<=4096));
alter table public.sdi_watch_media add column playback_provider text not null default 'rendition'
 check(playback_provider in('rendition','youtube')),
 add column provider_url text,
 -- Deliberately retained as audit identity if account purge deletes its job.
 -- Eligibility always requires the actual matching job; a UUID alone proves nothing.
 add column youtube_job uuid;
alter table public.sdi_watch_media alter column url drop not null,
 alter column duration drop not null,
 drop constraint sdi_watch_media_url_check;
alter table public.sdi_watch_media add constraint watch_media_provider_contract check(
 (playback_provider='rendition' and url is not null and url ~ '^https://' and duration is not null
  and provider_url is null and youtube_job is null)
 or (playback_provider='youtube' and url is null and duration is null and not approved
  and poster_url is null and poster_digest is null and poster_bytes is null
  and ((owner_id is not null and youtube_job is not null and provider_url is not null and provider_url ~ '^https://www[.]youtube[.]com/watch[?]v=[A-Za-z0-9_-]{11}$')
   or (owner_id is null and youtube_job is null and provider_url is null))));

-- An account purge anonymizes existing media in place. Clear provider locators
-- as well; never convert a reference into a playable raw rendition.
create function sdi_private.youtube_media_guard() returns trigger language plpgsql set search_path='' as $$
begin
 if new.playback_provider='youtube' and new.owner_id is null then
  new.provider_url=null; new.youtube_job=null; new.url=null; new.duration=null; new.approved=false;
 end if;
 return new;
end $$;
revoke all on function sdi_private.youtube_media_guard() from public,anon,authenticated;
create trigger youtube_media_guard before insert or update on public.sdi_watch_media
 for each row execute function sdi_private.youtube_media_guard();

-- Publication eligibility after staging cleanup deliberately omits artifact
-- retention. Exact review/consent/rights/owner approval and both destination jobs
-- must still agree. New publication itself continues to require release_allowed.
create function sdi_private.feed_media_available(media public.sdi_watch_media) returns boolean
language sql stable security definer set search_path='' as $$
 select case when media.playback_provider='rendition' then media.approved else exists(
  select 1 from sdi_private.publish_jobs y join sdi_private.render_reviews r on r.id=y.review_id
  join sdi_private.publish_jobs f on f.review_id=y.review_id and f.review_version=y.review_version
   and f.render_digest=y.render_digest and f.creator=y.creator and f.destination='feed'
  where y.id=media.youtube_job and y.destination='youtube' and y.state='published' and f.state='published'
   and f.provider_id='ytref:'||y.id::text and f.result_url=media.provider_url
   and y.render_digest=media.render_digest and y.creator=media.owner_id and y.review_id=media.review_id
   and y.result_url=media.provider_url and y.youtube_verified_at is not null
   and y.youtube_receipt->>'video_id'=y.provider_id and y.youtube_receipt->>'url'=y.result_url
   and y.youtube_receipt->>'digest'=y.render_digest and y.youtube_receipt->>'visibility'='public'
   and y.youtube_receipt->'processing_verified'='true'::jsonb and y.youtube_receipt->'embeddable'='true'::jsonb
   and r.creator=y.creator and r.version=y.review_version and r.render_digest=y.render_digest
   and r.state='approved' and r.rights_cleared and length(r.consent_version)>0
   and 'feed'=any(r.destinations) and 'youtube'=any(r.destinations)
   and not sdi_private.creator_restricted(r.creator)
   and exists(select 1 from sdi_private.render_decisions d join sdi_private.admin_roles role on role.user_id=d.actor
    where d.review_id=r.id and d.review_version=r.version and d.render_digest=r.render_digest
     and d.consent_version=r.consent_version and d.destinations=r.destinations and d.decision='approved'
     and role.enabled and (role.owner or 'reviews'=any(role.permissions))
     and (not r.spatter_generated or (d.owner_at_decision and role.owner)))) end
$$;
revoke all on function sdi_private.feed_media_available(public.sdi_watch_media) from public,anon,authenticated;

-- The existing channel finish keeps cancellation/reconciliation semantics. The
-- extra receipt is accepted only from service_role and committed atomically.
create function sdi_private.publish_finish_youtube(job uuid,token uuid,receipt jsonb) returns boolean
language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs; parent uuid; provider text; canonical text;
begin
 if receipt is null or jsonb_typeof(receipt)<>'object' or octet_length(receipt::text)>4096 then return false;end if;
 provider:=receipt->>'video_id'; canonical:='https://www.youtube.com/watch?v='||provider;
 if provider is null or provider !~ '^[A-Za-z0-9_-]{11}$' or receipt->>'url' is distinct from canonical
  or receipt->>'state' is distinct from 'published' or receipt->>'visibility' is distinct from 'public'
  or receipt->'processing_verified' is distinct from 'true'::jsonb
  or jsonb_typeof(receipt->'embeddable') is distinct from 'boolean'
  or coalesce(receipt->>'channel_id','') !~ '^UC[A-Za-z0-9_-]{1,126}$' then return false;end if;
 select review_id into parent from sdi_private.publish_jobs where id=job;
 if not found then return false;end if;
 perform 1 from sdi_private.render_reviews where id=parent for update;
 select * into j from sdi_private.publish_jobs where id=job and lease=token and destination='youtube' for update;
 if not found or receipt->>'digest' is distinct from j.render_digest or j.provider_id is distinct from provider then return false;end if;
 if j.state='published' then return coalesce(j.youtube_receipt=receipt and j.result_url=canonical,false);end if;
 if j.state not in('leased','cancel_requested','reconcile') then return false;end if;
 if not sdi_private.publish_finish(job,token,provider,canonical,null) then return false;end if;
 update sdi_private.publish_jobs set youtube_receipt=receipt,youtube_verified_at=clock_timestamp() where id=j.id;
 return true;
end $$;
revoke all on function sdi_private.publish_finish_youtube(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function sdi_private.publish_finish_youtube(uuid,uuid,jsonb) to service_role;
create function public.sdi_publish_finish_youtube(job uuid,token uuid,receipt jsonb) returns boolean
language sql security invoker set search_path='' as $$select sdi_private.publish_finish_youtube(job,token,receipt)$$;
revoke all on function public.sdi_publish_finish_youtube(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.sdi_publish_finish_youtube(uuid,uuid,jsonb) to service_role;

-- Withdraw a feed reference before any external operation. A reference job has
-- no hosted file to delete; the channel job retains the real provider withdrawal.
create function sdi_private.hide_youtube_reference() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.destination='youtube' and new.state<>'published' then
  update sdi_private.feed_posts p set visible=false,featured=false from public.sdi_watch_media m
   where m.id=p.media_id and m.playback_provider='youtube' and m.youtube_job=new.id;
  update sdi_private.publish_jobs set state='cancelled',result_url=null,lease=null,lease_expires=null,
   last_error='Feed reference hidden after channel withdrawal.',updated_at=clock_timestamp()
   where destination='feed' and provider_id='ytref:'||new.id::text and state='published';
 end if;
 if new.destination='feed' and new.provider_id like 'ytref:%' and new.state<>'published' then
  update sdi_private.feed_posts p set visible=false,featured=false from public.sdi_watch_media m
   where m.id=p.media_id and m.playback_provider='youtube' and m.review_id=new.review_id
    and m.owner_id=new.creator and m.render_digest=new.render_digest;
  if new.state in('removal_pending','cancel_requested') then
   update sdi_private.publish_jobs set state='cancelled',result_url=null,lease=null,lease_expires=null,
    last_error='Feed reference hidden; channel withdrawal is tracked by its YouTube job.',updated_at=clock_timestamp() where id=new.id;
  end if;
 end if;
 return new;
end $$;
revoke all on function sdi_private.hide_youtube_reference() from public,anon,authenticated;
create trigger hide_youtube_reference after update of state,result_url on sdi_private.publish_jobs
 for each row execute function sdi_private.hide_youtube_reference();

-- Moderation/account deletion already invalidate the review and channel job.
-- Do not misroute a metadata reference through the raw HostingAdapter worker.
create function sdi_private.youtube_removal_route() returns trigger
language plpgsql security definer set search_path='' as $$
declare media public.sdi_watch_media;
begin
 select * into media from public.sdi_watch_media where id=new.media_id;
 if media.playback_provider='youtube' then
  update sdi_private.feed_posts set visible=false,featured=false where media_id=media.id;
  update sdi_private.publish_jobs set state=case when state in('leased','cancel_requested') then 'cancel_requested'
    when provider_id is not null then 'removal_pending' else state end,
   last_error='Channel withdrawal requested after feed removal.',updated_at=clock_timestamp()
   where id=media.youtube_job and state not in('cancelled','removal_pending');
  return null;
 end if;
 return new;
end $$;
revoke all on function sdi_private.youtube_removal_route() from public,anon,authenticated;
create trigger youtube_removal_route before insert on sdi_private.removal_jobs
 for each row execute function sdi_private.youtube_removal_route();

create or replace function sdi_private.feed_publish_claim() returns jsonb
language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs; y sdi_private.publish_jobs; a sdi_private.render_artifacts; r sdi_private.render_reviews; name text;
begin
 update sdi_private.publish_jobs set state='reconcile',last_error='Worker lease expired; reconcile before retry.',updated_at=clock_timestamp()
  where destination='feed' and state='leased' and lease_expires<clock_timestamp();
 select pj.* into j from sdi_private.publish_jobs pj join sdi_private.render_reviews rr on rr.id=pj.review_id
  where pj.state='queued' and pj.destination='feed' and pj.attempts<5 and pj.next_attempt<=clock_timestamp()
   and (not ('youtube'=any(rr.destinations)) or exists(select 1 from sdi_private.publish_jobs yy
    where yy.review_id=pj.review_id and yy.review_version=pj.review_version and yy.render_digest=pj.render_digest
     and yy.creator=pj.creator and yy.destination='youtube' and yy.state='published' and yy.youtube_verified_at is not null))
  order by pj.created_at for update of pj skip locked limit 1;
 if not found then return jsonb_build_object('empty',true);end if;
 if not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,'feed') then
  update sdi_private.publish_jobs set state='cancelled',last_error='Approval, consent, rights or artifact no longer valid.',updated_at=clock_timestamp() where id=j.id;
  return jsonb_build_object('empty',true);
 end if;
 select * into r from sdi_private.render_reviews where id=j.review_id;
 update sdi_private.publish_jobs set state='leased',attempts=attempts+1,lease=gen_random_uuid(),lease_expires=clock_timestamp()+interval '2 minutes',updated_at=clock_timestamp()
  where id=j.id returning * into j;
 if 'youtube'=any(r.destinations) then
  return jsonb_build_object('job',j.id,'lease',j.lease,'destination','feed','digest',j.render_digest,'playback_provider','youtube');
 end if;
 select * into a from sdi_private.render_artifacts where review_id=j.review_id and version=j.review_version;
 select left(coalesce(nullif(trim(raw_user_meta_data->>'username'),''),'Member'),100) into name from auth.users where id=j.creator;
 return jsonb_build_object('job',j.id,'lease',j.lease,'destination','feed','digest',j.render_digest,'playback_provider','rendition',
  'object_key',a.object_key,'byte_count',a.byte_count,'title',a.title,'description',a.description,'made_for_kids',a.made_for_kids,
  'creator',j.creator,'creator_name',name,'allow_export',r.allow_export,'spatter_generated',r.spatter_generated);
end $$;

create function sdi_private.feed_publish_reference(job uuid,token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs; y sdi_private.publish_jobs; r sdi_private.render_reviews;
 a sdi_private.render_artifacts; parent uuid; media uuid; name text;
begin
 select review_id into parent from sdi_private.publish_jobs where id=job;
 if not found then return jsonb_build_object('state','rejected');end if;
 select * into r from sdi_private.render_reviews where id=parent for update;
 select * into y from sdi_private.publish_jobs where review_id=parent and review_version=r.version
  and render_digest=r.render_digest and destination='youtube' for share;
 select * into j from sdi_private.publish_jobs where id=job and lease=token and destination='feed' for update;
 if not found then return jsonb_build_object('state','rejected');end if;
 if j.state='published' then
  if exists(select 1 from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id
   where m.review_id=j.review_id and m.render_digest=j.render_digest and p.visible and sdi_private.feed_media_available(m)) then
   return jsonb_build_object('state','published','url',j.result_url);
  end if;
  return jsonb_build_object('state','rejected');
 end if;
 if j.state in('cancelled','cancel_requested') then
  update sdi_private.publish_jobs set state='cancelled',lease_expires=null where id=j.id;
  return jsonb_build_object('state','cancelled');
 end if;
 if j.state<>'leased' or j.lease_expires is null or j.lease_expires<=clock_timestamp() then return jsonb_build_object('state','rejected');end if;
 if not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,'feed')
  or not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,'youtube') then
  update sdi_private.publish_jobs set state='cancelled',lease_expires=null,last_error='Feed or channel approval/consent changed.' where id=j.id;
  return jsonb_build_object('state','cancelled');
 end if;
 if y.id is null or y.creator<>j.creator or y.state<>'published' or y.youtube_verified_at is null
  or y.youtube_receipt->'embeddable' is distinct from 'true'::jsonb
  or y.youtube_receipt->'processing_verified' is distinct from 'true'::jsonb
  or y.youtube_receipt->>'visibility' is distinct from 'public'
  or y.youtube_receipt->>'digest' is distinct from j.render_digest
  or y.youtube_receipt->>'url' is distinct from y.result_url
  or y.youtube_receipt->>'video_id' is distinct from y.provider_id
  or y.result_url is distinct from 'https://www.youtube.com/watch?v='||y.provider_id then
  update sdi_private.publish_jobs set state='failed',lease_expires=null,
   last_error='No verified public, embeddable owner-channel receipt. Feed publication did not occur.' where id=j.id;
  return jsonb_build_object('state','unavailable');
 end if;
 select * into a from sdi_private.render_artifacts where review_id=j.review_id and version=j.review_version;
 select left(coalesce(nullif(trim(raw_user_meta_data->>'username'),''),'Member'),100) into name from auth.users where id=j.creator;
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest,review_id,playback_provider,provider_url,youtube_job)
  values(left(a.title,200),null,null,false,j.creator,j.render_digest,j.review_id,'youtube',y.result_url,y.id)
  on conflict(render_digest) where render_digest is not null do update set title=excluded.title,review_id=excluded.review_id,
   provider_url=excluded.provider_url,youtube_job=excluded.youtube_job,expires_at=null
  where sdi_watch_media.playback_provider='youtube' and sdi_watch_media.owner_id=excluded.owner_id
  returning id into media;
 if media is null then
  update sdi_private.publish_jobs set state='failed',lease_expires=null,
   last_error='Existing hosted or differently owned rendition needs separate verified retirement before migration.' where id=j.id;
  return jsonb_build_object('state','unavailable');
 end if;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,caption,visible,allow_export)
  values(media,j.creator,name,left(a.description,2000),true,false)
  on conflict(media_id) do update set caption=excluded.caption,creator_name=excluded.creator_name,visible=true,allow_export=false,published_at=clock_timestamp();
 update sdi_private.publish_jobs set state='published',phase='release',provider_id='ytref:'||y.id::text,
  result_url=y.result_url,lease_expires=null,last_error=null,updated_at=clock_timestamp() where id=j.id;
 return jsonb_build_object('state','published','url',y.result_url);
end $$;
revoke all on function sdi_private.feed_publish_reference(uuid,uuid) from public,anon,authenticated;
grant execute on function sdi_private.feed_publish_reference(uuid,uuid) to service_role;
create function public.sdi_feed_publish_reference(job uuid,token uuid) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.feed_publish_reference(job,token)$$;
revoke all on function public.sdi_feed_publish_reference(uuid,uuid) from public,anon,authenticated;
grant execute on function public.sdi_feed_publish_reference(uuid,uuid) to service_role;

-- Existing feed auth, abuse budgets, blocks, keysets and counts remain.
create or replace function sdi_private.feed_action(action text, post_id uuid default null, target uuid default null,
 enabled boolean default true, category text default 'recent', page integer default 0, reason text default null,
 as_of timestamptz default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=auth.uid(); entry sdi_private.feed_posts; n integer;
begin
 if actor_id is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor_id and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 -- Listing is keyset-only (#220): the offset path and its 40-page cap are gone.
 -- 'list' answers the first page through feed_page (which meters the call once);
 -- every later page must use sdi_feed_page with the returned cursor.
 if action='list' then
  if page is distinct from 0 then
   return jsonb_build_object('error','Feed pages after the first use sdi_feed_page with the returned cursor.'); end if;
  return sdi_private.feed_page(category,null,as_of);
 end if;
 insert into sdi_private.feed_budget values(actor_id,clock_timestamp(),1)
 on conflict(actor) do update set attempts=case when feed_budget.started_at<clock_timestamp()-interval '1 minute' then 1 else feed_budget.attempts+1 end,
 started_at=case when feed_budget.started_at<clock_timestamp()-interval '1 minute' then clock_timestamp() else feed_budget.started_at end returning attempts into n;
 if n>60 then return jsonb_build_object('error','Please wait before trying again.'); end if;
 if action in('follow','block') then
  if target is null or target=actor_id or not exists(select 1 from auth.users where id=target) then return jsonb_build_object('error','Creator unavailable.'); end if;
  if action='block' then
   if enabled then
    insert into sdi_private.feed_blocks values(actor_id,target) on conflict do nothing;
    delete from sdi_private.feed_follows where (actor=actor_id and creator=target) or (actor=target and creator=actor_id);
   else delete from sdi_private.feed_blocks where actor=actor_id and creator=target; end if;
  else
   if sdi_private.creator_restricted(target) or exists(select 1 from sdi_private.feed_blocks where (actor=actor_id and creator=target) or (actor=target and creator=actor_id)) then
    return jsonb_build_object('error','Creator unavailable.'); end if;
   if enabled then insert into sdi_private.feed_follows values(actor_id,target) on conflict do nothing;
   else delete from sdi_private.feed_follows where actor=actor_id and creator=target; end if;
  end if;
 else
  select p.* into entry from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id
   where p.id=post_id and p.visible and sdi_private.feed_media_available(m) and m.owner_id=p.creator and m.render_digest is not null
   and (m.expires_at is null or m.expires_at>clock_timestamp())
   and not sdi_private.creator_restricted(p.creator)
   and not exists(select 1 from sdi_private.feed_blocks b where (b.actor=actor_id and b.creator=p.creator) or (b.actor=p.creator and b.creator=actor_id));
  if not found then return jsonb_build_object('error','Post unavailable.'); end if;
  if action='like' then
   if entry.creator=actor_id then return jsonb_build_object('error','You cannot like your own video.'); end if;
   if enabled then insert into sdi_private.feed_likes(post,actor) values(post_id,actor_id) on conflict do nothing;
   else delete from sdi_private.feed_likes where post=post_id and actor=actor_id; end if;
  elsif action='report' and reason in('rights','abuse','unsafe','spam') then
   if entry.creator=actor_id then return jsonb_build_object('error','Use consent withdrawal for your own video.'); end if;
   if (select count(*) from sdi_private.feed_reports r where r.actor=actor_id and r.created_at>clock_timestamp()-interval '1 day')>=10 then
    return jsonb_build_object('error','Daily report limit reached.'); end if;
   -- One report per account per post. A dismissed or actioned report is final;
   -- a repeat submission records nothing new and never reopens the queue item.
   insert into sdi_private.feed_reports(post,actor,reason) values(post_id,actor_id,reason) on conflict(post,actor) do nothing;
   return jsonb_build_object('status','recorded');
  else return jsonb_build_object('error','Unsupported feed operation.'); end if;
 end if;
 return jsonb_build_object('status','confirmed');
end $$;

-- Existing feed auth, abuse budgets, blocks, keysets and counts remain.
create or replace function sdi_private.feed_page(category text default 'recent', page_cursor text default null, as_of timestamptz default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=auth.uid(); n integer; items jsonb; snapshot timestamptz; total integer; paid boolean;
 parts text[]; c_score bigint; c_published timestamptz; c_id uuid; last_row jsonb; next_cursor text;
begin
 if actor_id is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor_id and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 insert into sdi_private.feed_budget values(actor_id,clock_timestamp(),1)
 on conflict(actor) do update set attempts=case when feed_budget.started_at<clock_timestamp()-interval '1 minute' then 1 else feed_budget.attempts+1 end,
 started_at=case when feed_budget.started_at<clock_timestamp()-interval '1 minute' then clock_timestamp() else feed_budget.started_at end returning attempts into n;
 if n>60 then return jsonb_build_object('error','Please wait before trying again.'); end if;
 if category is null or category not in('recent','following','featured','trending') then return jsonb_build_object('error','Invalid feed page.'); end if;
 if page_cursor is not null then
  if as_of is null then return jsonb_build_object('error','A feed cursor needs its snapshot. Refresh the feed.'); end if;
  if length(page_cursor)>120 or page_cursor !~ '^[0-9]{1,9}\|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z\|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
   return jsonb_build_object('error','Invalid feed cursor. Refresh the feed.'); end if;
  parts:=string_to_array(page_cursor,'|');
  begin
   c_score:=parts[1]::bigint; c_published:=parts[2]::timestamptz; c_id:=parts[3]::uuid;
  exception when others then return jsonb_build_object('error','Invalid feed cursor. Refresh the feed.');
  end;
 end if;
 snapshot:=least(coalesce(as_of,clock_timestamp()),clock_timestamp());
 if snapshot<clock_timestamp()-interval '1 day' then return jsonb_build_object('error','This feed snapshot has expired. Refresh the feed.'); end if;
 paid:=exists(select 1 from sdi_private.entitlements e where e.user_id=actor_id);
 with eligible as (
  select p.id,p.creator,p.creator_name,p.caption,p.published_at,(p.allow_export and m.playback_provider='rendition') as allow_export,m.title,
   case m.playback_provider when 'youtube' then m.provider_url else m.url end as url,m.poster_url,m.playback_provider,
   case when category='trending' then (select count(*) from sdi_private.feed_likes l where l.post=p.id
    and l.created_at>snapshot-interval '7 days' and l.created_at<=snapshot) else 0 end::bigint as score
  from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id
  where p.visible and sdi_private.feed_media_available(m) and m.owner_id=p.creator and m.render_digest is not null
  and p.published_at<=snapshot
  and (m.expires_at is null or m.expires_at>clock_timestamp())
  and not sdi_private.creator_restricted(p.creator)
  and not exists(select 1 from sdi_private.feed_blocks b where (b.actor=actor_id and b.creator=p.creator) or (b.actor=p.creator and b.creator=actor_id))
  and (category<>'featured' or p.featured)
  and (category<>'following' or exists(select 1 from sdi_private.feed_follows f where f.actor=actor_id and f.creator=p.creator))
 ), window_rows as (
  select * from eligible e
  where page_cursor is null or (e.score,e.published_at,e.id)<(c_score,c_published,c_id)
  order by e.score desc,e.published_at desc,e.id desc limit 26
 ), numbered as (
  select w.*,row_number() over(order by w.score desc,w.published_at desc,w.id desc) as position from window_rows w
 )
 select count(*)::integer,
  coalesce(jsonb_agg(jsonb_build_object('id',x.id,'creator',x.creator,'creator_name',x.creator_name,'caption',x.caption,
   'published_at',x.published_at,'allow_export',x.allow_export,'can_download',x.allow_export and paid,'title',x.title,'url',x.url,
   'poster_url',x.poster_url,'playback_provider',x.playback_provider,'score',x.score,
   'likes',(select count(*) from sdi_private.feed_likes l where l.post=x.id),
   'liked',exists(select 1 from sdi_private.feed_likes l where l.post=x.id and l.actor=actor_id),
   'following',exists(select 1 from sdi_private.feed_follows f where f.actor=actor_id and f.creator=x.creator))
   order by x.position) filter(where x.position<=25),'[]'::jsonb),
  (select jsonb_build_object('score',y.score,'published_at',y.published_at,'id',y.id) from numbered y where y.position=25)
 into total,items,last_row from numbered x;
 if total>25 then
  next_cursor:=(last_row->>'score')||'|'||to_char((last_row->>'published_at')::timestamptz at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')||'|'||(last_row->>'id');
 end if;
 return jsonb_build_object('posts',items,'has_more',total>25,'next_cursor',next_cursor,'as_of',snapshot,'download_requires_plan',not paid);
end $$;

-- Existing feed auth, abuse budgets, blocks, keysets and counts remain.
create or replace function sdi_private.creator_stats(subject uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare viewer uuid:=auth.uid(); target uuid:=coalesce(subject,auth.uid()); posts bigint; likes bigint; followers bigint; follows bigint;
begin
 if viewer is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=viewer and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 if not exists(select 1 from auth.users where id=target and not is_anonymous)
  or (target<>viewer and (sdi_private.creator_restricted(target)
   or exists(select 1 from sdi_private.feed_blocks b where (b.actor=viewer and b.creator=target) or (b.actor=target and b.creator=viewer)))) then
  return jsonb_build_object('error','Profile unavailable.'); end if;
 select count(*),coalesce(sum((select count(*) from sdi_private.feed_likes l where l.post=p.id)),0) into posts,likes
 from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id
 where p.creator=target and p.visible and sdi_private.feed_media_available(m) and m.owner_id=p.creator and m.render_digest is not null
  and (m.expires_at is null or m.expires_at>clock_timestamp());
 select count(*) into followers from sdi_private.feed_follows f where f.creator=target and not sdi_private.creator_restricted(f.actor);
 if target=viewer then select count(*) into follows from sdi_private.feed_follows f where f.actor=target; end if;
 return jsonb_build_object('subject',target,'published_videos',posts,'likes_received',likes,'followers',followers,'following',follows);
end $$;

-- Existing raw rendition publication retains its complete finalization path.
create or replace function sdi_private.feed_publish_finish(job uuid,token uuid,url text,duration double precision,failure text default null,
 poster_url text default null,poster_digest text default null,poster_bytes integer default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs; a sdi_private.render_artifacts; r sdi_private.render_reviews; media uuid; name text;
begin
 select * into j from sdi_private.publish_jobs where id=job and lease=token and destination='feed' for update;
 if not found then return false;end if;
 if j.state='published' then return j.result_url=url;end if;
 if j.state not in('leased','cancel_requested','reconcile') then return false;end if;
 if failure is not null then
  update sdi_private.publish_jobs set state=case when j.state='cancel_requested' then 'cancelled' else 'failed' end,
   last_error=left(failure,500),next_attempt=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,j.attempts)::integer)),updated_at=clock_timestamp() where id=j.id;
  return true;
 end if;
 if url ~* '^https://([^/@]+[.])?(youtube[.]com|youtu[.]be|youtube-nocookie[.]com|googlevideo[.]com|ytimg[.]com)([:/?#]|$)' then return false;end if;
 -- A pre-upgrade raw lease for a dual-destination render must retire its hosted
 -- copy instead of publishing it. New claims select the reference path above.
 if exists(select 1 from sdi_private.render_reviews where id=j.review_id and 'youtube'=any(destinations)) then
  if url is null or url !~ '^https://' or length(url)>2048 then return false;end if;
  update sdi_private.publish_jobs set state='removal_pending',provider_id='feed:'||j.render_digest,result_url=url,
   poster_url=feed_publish_finish.poster_url,lease=null,lease_expires=null,
   last_error='Raw copy predates the YouTube reference contract; verified hosting removal required.',updated_at=clock_timestamp() where id=j.id;
  return true;
 end if;
 if url is null or url !~ '^https://' or length(url)>2048 or duration is null or duration<=0 or duration>3600 then return false;end if;
 if not coalesce((poster_url is null and poster_digest is null and poster_bytes is null)
  or (poster_url ~ '^https://' and length(poster_url)<=2048 and poster_url<>url and poster_digest ~ '^[0-9a-f]{64}$' and poster_bytes between 1 and 262144),false) then
  return false;end if;
 if j.state='cancel_requested' or not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,'feed') then
  -- The copy step is over, so the lease is released and removal may start at once.
  update sdi_private.publish_jobs set state='removal_pending',provider_id='feed:'||j.render_digest,result_url=url,poster_url=feed_publish_finish.poster_url,lease=null,lease_expires=null,
   last_error='Hosted copy must be removed: approval or consent changed before release.',updated_at=clock_timestamp() where id=j.id;
  return true;
 end if;
 select * into a from sdi_private.render_artifacts where review_id=j.review_id and version=j.review_version;
 select * into r from sdi_private.render_reviews where id=j.review_id;
 select left(coalesce(nullif(trim(raw_user_meta_data->>'username'),''),'Member'),100) into name from auth.users where id=j.creator;
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest,review_id,poster_url,poster_digest,poster_bytes,playback_provider,provider_url,youtube_job)
 values(left(a.title,200),url,duration,true,j.creator,j.render_digest,j.review_id,poster_url,poster_digest,poster_bytes,'rendition',null,null)
 on conflict(render_digest) where render_digest is not null do update set title=excluded.title,url=excluded.url,duration=excluded.duration,
  approved=true,owner_id=excluded.owner_id,review_id=excluded.review_id,expires_at=null,
  playback_provider='rendition',provider_url=null,youtube_job=null,
  poster_url=excluded.poster_url,poster_digest=excluded.poster_digest,poster_bytes=excluded.poster_bytes
 returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,caption,visible,allow_export)
 values(media,j.creator,name,left(a.description,2000),true,r.allow_export)
 on conflict(media_id) do update set creator=excluded.creator,creator_name=excluded.creator_name,caption=excluded.caption,
  visible=true,allow_export=excluded.allow_export,published_at=clock_timestamp();
 update sdi_private.publish_jobs set state='published',provider_id='feed:'||media::text,result_url=url,poster_url=feed_publish_finish.poster_url,phase='release',updated_at=clock_timestamp() where id=j.id;
 return true;
end $$;

-- Admin preview keeps an explicit unavailable raw URL for provider references.
create or replace function sdi_private.moderation_action(action text,report uuid default null,version bigint default null,note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; r sdi_private.feed_reports; p sdi_private.feed_posts; video public.sdi_watch_media; denial jsonb;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA authorization required.');end if;
 -- Decisions are rate limited per administrator with a denial audit (admin_gate,
 -- admin-hardening.sql, resolved at run time).
 if action in('dismiss','remove') then
  denial:=sdi_private.admin_gate('moderation_action.'||action,'moderation',false,60);
  if denial is not null then return denial; end if;
 end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
   select r.id,r.reason,r.version,r.created_at,p.caption,p.creator,m.title,coalesce(m.url,'') as url,m.render_digest,m.playback_provider,
    case when m.playback_provider='youtube' then 'YouTube playback is unavailable in this admin preview.' end as preview_unavailable
   from sdi_private.feed_reports r join sdi_private.feed_posts p on p.id=r.post
   join public.sdi_watch_media m on m.id=p.media_id where r.state='pending'
   order by r.created_at,r.id limit 50
  ) item;
  return jsonb_build_object('reports',result);
 end if;
 if action is null or action not in('dismiss','remove') or report is null or version is null or note is null or length(trim(note)) not between 1 and 2000 then
  return jsonb_build_object('error','A current report and decision reason are required.');end if;
 select * into r from sdi_private.feed_reports where id=report for update;
 if not found or r.state<>'pending' or r.version<>version then return jsonb_build_object('error','Report changed. Refresh the queue.');end if;
 select * into p from sdi_private.feed_posts where id=r.post for update;
 if p.creator=auth.uid() or r.actor=auth.uid() then return jsonb_build_object('error','Another administrator must review this report.');end if;
 select * into video from public.sdi_watch_media where id=p.media_id for update;
 if action='remove' then
  update public.sdi_watch_media set approved=false where id=video.id;
  update sdi_private.feed_posts set visible=false where media_id=video.id;
  update sdi_private.war_matches set status='removed' where left_media=video.id or right_media=video.id;
  update sdi_private.render_reviews set state='pending',version=render_reviews.version+1 where render_digest=video.render_digest;
  insert into sdi_private.removal_jobs(media_id,render_digest,reason) values(video.id,video.render_digest,trim(note))
   on conflict(media_id,render_digest) do update set state='pending',reason=excluded.reason;
 end if;
 update sdi_private.feed_reports set state=case action when 'remove' then 'removed' else 'dismissed' end where id=r.id;
 insert into sdi_private.moderation_audit(report_id,actor,action,reason,media_id,render_digest)
 values(r.id,auth.uid(),action,trim(note),video.id,video.render_digest);
 return jsonb_build_object('status','confirmed');
end $$;

create or replace function sdi_private.admin_content(page integer default 0,query text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare items jsonb;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then
  return jsonb_build_object('error','Current moderation permission and MFA required.');end if;
 if page is null or page<0 or page>199 or query is null or length(query)>100 then
  return jsonb_build_object('error','Invalid content query.');end if;
 select coalesce(jsonb_agg(row_to_json(entry)),'[]'::jsonb) into items from (
  select p.id,p.creator,p.creator_name,p.caption,p.published_at,p.visible,p.featured,p.feature_revision,p.allow_export,
   m.title,sdi_private.feed_media_available(m) as approved,m.expires_at,m.playback_provider,
   (select count(*) from sdi_private.feed_reports r where r.post=p.id) as report_count,
   (select count(*) from sdi_private.feed_reports r where r.post=p.id and r.state='pending') as pending_report_count
  from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id
  where query='' or p.id::text=query or p.creator::text=query
   or position(lower(query) in lower(p.creator_name))>0 or position(lower(query) in lower(m.title))>0
  order by p.published_at desc,p.id limit 51 offset page*50
 ) entry;
 return jsonb_build_object('posts',(select coalesce(jsonb_agg(value),'[]'::jsonb)
  from (select value from jsonb_array_elements(items) with ordinality as v(value,n) where n<=50 order by n) bounded),
  'has_more',jsonb_array_length(items)>50);
end $$;

create or replace function sdi_private.feature_content(post uuid,revision bigint,featured boolean,reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item sdi_private.feed_posts; media public.sdi_watch_media;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then
  return jsonb_build_object('error','Current moderation permission and MFA required.');end if;
 if post is null or revision is null or featured is null or reason is null or length(trim(reason)) not between 1 and 2000 then
  return jsonb_build_object('error','A current post and curation reason are required.');end if;
 select * into item from sdi_private.feed_posts where id=post for update;
 if not found or item.feature_revision<>revision then return jsonb_build_object('error','Content changed. Refresh before curating.');end if;
 if item.featured=featured then return jsonb_build_object('status','unchanged');end if;
 if featured then
  select * into media from public.sdi_watch_media where id=item.media_id for update;
  if not found or not item.visible or not sdi_private.feed_media_available(media) or media.owner_id<>item.creator
   or media.render_digest is null or (media.expires_at is not null and media.expires_at<=clock_timestamp())
   or exists(select 1 from sdi_private.account_controls where user_id=item.creator and state<>'active') then
   return jsonb_build_object('error','Only currently visible, approved and eligible content can be featured.');end if;
 end if;
 update sdi_private.feed_posts set featured=feature_content.featured,feature_revision=feature_revision+1 where id=post;
 insert into sdi_private.feed_curation_audit(post,actor,previous_featured,featured,revision,reason)
 values(post,auth.uid(),item.featured,featured,item.feature_revision+1,trim(reason));
 return jsonb_build_object('status','confirmed');
end $$;

-- Appeals remain reviewable; accepting a provider reference cannot invent an MP4.
create or replace function sdi_private.moderation_appeal(action text,media uuid default null,explanation text default '',appeal uuid default null,
 revision bigint default null,note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=auth.uid(); m public.sdi_watch_media; a sdi_private.moderation_appeals; removal sdi_private.moderation_audit; items jsonb;
begin
 if actor_id is null or not exists(select 1 from auth.users where id=actor_id and not is_anonymous)
 or not exists(select 1 from auth.sessions where user_id=actor_id and id::text=auth.jwt()->>'session_id') then
  return jsonb_build_object('error','A current signed-in account is required.');end if;
 if action in('mine','submit') then
  if action='submit' then
   if media is null or explanation is null or length(trim(explanation)) not between 1 and 2000 then
    return jsonb_build_object('error','Select your removed video and explain your appeal.');end if;
   select * into m from public.sdi_watch_media where id=media and owner_id=actor_id for update;
   select d.* into removal from sdi_private.moderation_audit d where d.media_id=media and d.action='remove' order by d.created_at desc limit 1;
   if not found or m.id is null or m.approved or removal.created_at<clock_timestamp()-interval '30 days' then
    return jsonb_build_object('error','No removal of your video is open for appeal.');end if;
   if exists(select 1 from sdi_private.moderation_appeals where media_id=media and state='pending') then return jsonb_build_object('status','recorded');end if;
   if (select count(*) from sdi_private.moderation_appeals where creator=actor_id and created_at>clock_timestamp()-interval '1 day')>=3 then
    return jsonb_build_object('error','Daily appeal limit reached.');end if;
   insert into sdi_private.moderation_appeals(media_id,creator,explanation,render_digest) values(media,actor_id,trim(explanation),removal.render_digest);
  end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select ap.id,ap.media_id,v.title,ap.explanation,ap.state,ap.reply,ap.created_at,ap.decided_at from sdi_private.moderation_appeals ap
   join public.sdi_watch_media v on v.id=ap.media_id where ap.creator=actor_id order by ap.created_at desc,ap.id limit 50
  ) item;
  return jsonb_build_object('appeals',items);
 end if;
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA session required.');end if;
 if action='queue' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select ap.id,ap.media_id,ap.creator,ap.explanation,ap.render_digest,ap.revision,ap.created_at,v.title,coalesce(v.url,'') as url,v.playback_provider,
    (select d.reason from sdi_private.moderation_audit d where d.media_id=ap.media_id and d.action='remove' order by d.created_at desc limit 1) as removal_reason,
    (select j.state from sdi_private.removal_jobs j where j.media_id=ap.media_id and j.render_digest=ap.render_digest) as removal_state
   from sdi_private.moderation_appeals ap join public.sdi_watch_media v on v.id=ap.media_id where ap.state='pending' order by ap.created_at,ap.id limit 50
  ) item;
  return jsonb_build_object('appeals',items);
 end if;
 if action is null or action not in('accept','reject') or appeal is null or revision is null or note is null or length(trim(note)) not between 1 and 2000 then
  return jsonb_build_object('error','Select an appeal and provide a member-visible decision reason.');end if;
 select * into a from sdi_private.moderation_appeals where id=appeal for update;
 if not found or a.state<>'pending' or a.revision<>revision then return jsonb_build_object('error','Appeal changed. Refresh the queue.');end if;
 select * into m from public.sdi_watch_media where id=a.media_id for update;
 if actor_id=a.creator or exists(select 1 from sdi_private.moderation_audit d where d.media_id=a.media_id and d.actor=actor_id) then
  return jsonb_build_object('error','Another uninvolved administrator must review this appeal.');end if;
 if action='accept' then
  if m.playback_provider='youtube' then
   return jsonb_build_object('error','YouTube reference restoration requires a new approved, verified channel publication. No raw rendition is available to restore.');end if;
  if m.render_digest is distinct from a.render_digest or m.approved then return jsonb_build_object('error','The removed render changed; nothing to restore.');end if;
  if not exists(select 1 from sdi_private.removal_jobs where media_id=m.id and render_digest=a.render_digest and state in('pending','failed')) then
   return jsonb_build_object('error','The hosted copy is already removed. The creator can resubmit the render for review.');end if;
  update sdi_private.removal_jobs set state='withdrawn' where media_id=m.id and render_digest=a.render_digest and state in('pending','failed');
  update public.sdi_watch_media set approved=true where id=m.id;
  update sdi_private.feed_posts set visible=true where media_id=m.id;
 end if;
 update sdi_private.moderation_appeals set state=case action when 'accept' then 'accepted' else 'rejected' end,reviewer=actor_id,
  reply=trim(note),decided_at=clock_timestamp(),revision=moderation_appeals.revision+1 where id=a.id;
 insert into sdi_private.moderation_audit(report_id,actor,action,reason,media_id,render_digest)
 values(a.id,actor_id,'appeal_'||action,trim(note),m.id,coalesce(a.render_digest,m.render_digest,''));
 return jsonb_build_object('status','confirmed');
end $$;

-- War Room is provider-aware; generic Watch Together/export readers deliberately
-- retain approved-only RLS. A typed projection is not permission to download.
-- Reuse the exact verified feed reference gate and require its visible post, so
-- consent withdrawal, moderation, deletion and provider revocation win every read.
create function sdi_private.war_media_available(media public.sdi_watch_media,available_at timestamptz default null) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(media.owner_id is not null and media.render_digest is not null
  and not sdi_private.creator_restricted(media.owner_id)
  and (media.expires_at is null or media.expires_at>coalesce(available_at,clock_timestamp()))
  and case media.playback_provider when 'rendition' then media.approved
   when 'youtube' then media.url is null and not media.approved
    and media.provider_url ~ '^https://www[.]youtube[.]com/watch[?]v=[A-Za-z0-9_-]{11}$'
    and sdi_private.feed_media_available(media)
    and exists(select 1 from sdi_private.feed_posts p where p.media_id=media.id and p.creator=media.owner_id and p.visible)
   else false end,false)
$$;
revoke all on function sdi_private.war_media_available(public.sdi_watch_media,timestamptz) from public,anon,authenticated,service_role;
create function sdi_private.war_video_source(media public.sdi_watch_media) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('provider',media.playback_provider,'url',
  case media.playback_provider when 'youtube' then media.provider_url else media.url end)
$$;
revoke all on function sdi_private.war_video_source(public.sdi_watch_media) from public,anon,authenticated,service_role;

-- Caller cannot supply an owner. This endpoint never widens watch_media RLS.
create function sdi_private.war_media() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); items jsonb;
begin
 if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.');end if;
 select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
  select m.id,m.title,m.url,m.duration,m.expires_at,sdi_private.war_video_source(m) as video_source
  from public.sdi_watch_media m where m.owner_id=actor and sdi_private.war_media_available(m)
  order by m.id limit 100
 ) item;
 return jsonb_build_object('media',items);
end $$;
revoke all on function sdi_private.war_media() from public,anon,service_role;
grant execute on function sdi_private.war_media() to authenticated;
create function public.sdi_war_media() returns jsonb language sql stable security invoker set search_path='' as $$select sdi_private.war_media()$$;
revoke all on function public.sdi_war_media() from public,anon,service_role;
grant execute on function public.sdi_war_media() to authenticated;

create or replace function sdi_private.war_action(action text, match uuid default null, media uuid default null,
 opponent uuid default null, choice text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); n integer; m sdi_private.war_matches; video public.sdi_watch_media; result jsonb;
begin
 if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 insert into sdi_private.war_budget values(actor,clock_timestamp(),1)
 on conflict(user_id) do update set
 attempts=case when sdi_private.war_budget.starts_at<clock_timestamp()-interval '1 minute' then 1 else sdi_private.war_budget.attempts+1 end,
 starts_at=case when sdi_private.war_budget.starts_at<clock_timestamp()-interval '1 minute' then clock_timestamp() else sdi_private.war_budget.starts_at end
 returning attempts into n;
 if n>60 then return jsonb_build_object('error','Too many requests. Wait a minute.'); end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(items)),'[]'::jsonb) into result from (
   select w.id,w.creator,w.opponent,w.status,w.ends_at,l.title as left_title,l.url as left_url,
    r.title as right_title,r.url as right_url,final.outcome,
    sdi_private.war_video_source(l) as left_video_source,
    case when r.id is not null then sdi_private.war_video_source(r) end as right_video_source,
    coalesce(final.left_votes,(select count(*) from sdi_private.war_votes where match_id=w.id and war_votes.choice='left')) as left_votes,
    coalesce(final.right_votes,(select count(*) from sdi_private.war_votes where match_id=w.id and war_votes.choice='right')) as right_votes,
    (select war_votes.choice from sdi_private.war_votes where match_id=w.id and voter=actor) as my_vote
   from sdi_private.war_matches w join public.sdi_watch_media l on l.id=w.left_media
   left join public.sdi_watch_media r on r.id=w.right_media
   left join sdi_private.war_results final on final.match_id=w.id
   where (w.status in('active','completed') or (sdi_private.war_proposal_live(w) and actor in(w.creator,w.opponent)))
   and sdi_private.war_media_available(l) and l.owner_id=w.creator and l.render_digest=w.left_digest
   and (w.status='pending' or (sdi_private.war_media_available(r) and r.owner_id=w.opponent and r.render_digest=w.right_digest))
   and not sdi_private.creator_restricted(w.creator) and not sdi_private.creator_restricted(w.opponent)
   and not exists(select 1 from sdi_private.war_blocks b where
     (b.blocker=actor and b.blocked in(w.creator,w.opponent)) or (b.blocked=actor and b.blocker in(w.creator,w.opponent)))
   order by w.created_at desc limit 100
  ) items;
  return jsonb_build_object('matches',result);
 elsif action='propose' then
  if opponent is null or opponent=actor or not exists(select 1 from auth.users where id=opponent and not is_anonymous)
   or sdi_private.creator_restricted(opponent) then
   return jsonb_build_object('error','Choose another eligible creator.'); end if;
  if exists(select 1 from sdi_private.war_blocks b where (b.blocker=actor and b.blocked=opponent) or (b.blocker=opponent and b.blocked=actor)) then
   return jsonb_build_object('error','Matchup unavailable.'); end if;
  if (select count(*) from sdi_private.war_matches w where w.creator=actor and
   (sdi_private.war_proposal_live(w) or (w.status='active' and (w.ends_at is null or w.ends_at>clock_timestamp()))))>=5 then
   return jsonb_build_object('error','Finish or withdraw an existing matchup first.'); end if;
  select v.* into video from public.sdi_watch_media v where v.id=media and v.owner_id=actor and sdi_private.war_media_available(v);
  if not found then return jsonb_build_object('error','Select your approved rendered video.'); end if;
  insert into sdi_private.war_matches(creator,opponent,left_media,left_digest) values(actor,opponent,media,video.render_digest);
 elsif action='block' then
  if opponent is null or opponent=actor then return jsonb_build_object('error','Invalid creator.'); end if;
  insert into sdi_private.war_blocks values(actor,opponent) on conflict do nothing;
  update sdi_private.war_matches set status='withdrawn' where status in('pending','active') and
   ((creator=actor and war_matches.opponent=war_action.opponent) or (creator=war_action.opponent and war_matches.opponent=actor));
 else
  select * into m from sdi_private.war_matches where id=match for update;
  if not found then return jsonb_build_object('error','Matchup unavailable.'); end if;
  if m.status='pending' and not sdi_private.war_proposal_live(m) then
   update sdi_private.war_matches set status='expired' where id=m.id;
   return jsonb_build_object('error','This proposal expired after seven days.'); end if;
  if action='withdraw' then
   if actor not in(m.creator,m.opponent) then return jsonb_build_object('error','Only participants can withdraw.'); end if;
   if m.ends_at is not null and m.ends_at<=clock_timestamp() then return jsonb_build_object('error','Voting has ended; contact moderation for an appeal.'); end if;
   update sdi_private.war_matches set status='withdrawn' where id=match;
  elsif action='accept' then
   if m.opponent<>actor or m.status<>'pending' then return jsonb_build_object('error','No pending invitation.'); end if;
   if sdi_private.creator_restricted(m.creator) or exists(select 1 from sdi_private.war_blocks b where (b.blocker=actor and b.blocked=m.creator) or (b.blocker=m.creator and b.blocked=actor)) then
    return jsonb_build_object('error','Matchup unavailable.'); end if;
   select v.* into video from public.sdi_watch_media v where v.id=media and v.owner_id=actor
    and sdi_private.war_media_available(v,clock_timestamp()+interval '24 hours');
   if not found then return jsonb_build_object('error','Select an approved video available for the voting period.'); end if;
   if not exists(select 1 from public.sdi_watch_media v where v.id=m.left_media and v.owner_id=m.creator and v.render_digest=m.left_digest
    and sdi_private.war_media_available(v,clock_timestamp()+interval '24 hours')) then
    return jsonb_build_object('error','The other video is unavailable.'); end if;
   update sdi_private.war_matches set right_media=media,right_digest=video.render_digest,status='active',starts_at=clock_timestamp(),ends_at=clock_timestamp()+interval '24 hours' where id=match;
  elsif action='vote' then
   if choice is null or choice not in('left','right') or actor in(m.creator,m.opponent) or m.status<>'active' or m.ends_at<=clock_timestamp() then
    return jsonb_build_object('error','Voting is not available to this account.'); end if;
   if sdi_private.creator_restricted(m.creator) or sdi_private.creator_restricted(m.opponent)
    or exists(select 1 from sdi_private.war_blocks b where (b.blocker=actor and b.blocked in(m.creator,m.opponent)) or (b.blocked=actor and b.blocker in(m.creator,m.opponent))) then
    return jsonb_build_object('error','Voting is unavailable.'); end if;
   if (select count(*) from public.sdi_watch_media v where sdi_private.war_media_available(v)
     and ((v.id=m.left_media and v.owner_id=m.creator and v.render_digest=m.left_digest)
       or (v.id=m.right_media and v.owner_id=m.opponent and v.render_digest=m.right_digest)))<>2 then
    return jsonb_build_object('error','A submitted video is no longer approved.'); end if;
   insert into sdi_private.war_votes values(match,actor,choice) on conflict(match_id,voter) do update set choice=excluded.choice;
  else return jsonb_build_object('error','Unsupported operation.'); end if;
 end if;
 return jsonb_build_object('status','confirmed');
end $$;

create or replace function sdi_private.war_finalize() returns jsonb
language plpgsql security definer set search_path='' as $$
declare m sdi_private.war_matches; left_count bigint; right_count bigint; completed integer:=0; removed integer:=0;
begin
 -- Same match lock as the vote endpoint serializes the terminal snapshot.
 for m in select * from sdi_private.war_matches where status='active' and ends_at<=clock_timestamp()
  order by ends_at,id for update skip locked limit 100 loop
  if (select count(*) from public.sdi_watch_media v where sdi_private.war_media_available(v,m.ends_at)
   and ((v.id=m.left_media and v.owner_id=m.creator and v.render_digest=m.left_digest)
     or (v.id=m.right_media and v.owner_id=m.opponent and v.render_digest=m.right_digest)))<>2 then
   update sdi_private.war_matches set status='removed' where id=m.id;
   removed:=removed+1;continue;
  end if;
  select count(*) filter(where choice='left'),count(*) filter(where choice='right')
   into left_count,right_count from sdi_private.war_votes where match_id=m.id;
  insert into sdi_private.war_results(match_id,left_votes,right_votes,outcome,left_digest,right_digest)
   values(m.id,left_count,right_count,case when left_count=right_count then 'tie' when left_count>right_count then 'left' else 'right' end,m.left_digest,m.right_digest)
   on conflict(match_id) do nothing;
  update sdi_private.war_matches set status='completed' where id=m.id;
  completed:=completed+1;
 end loop;
 return jsonb_build_object('completed',completed,'removed',removed);
end $$;

-- Raw-only administrator previews fail visibly; provider references cannot
-- bypass existing exact-media appeal restoration checks.
create or replace function sdi_private.war_moderate(action text,report uuid default null,revision bigint default null,reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.war_reports; m sdi_private.war_matches; items jsonb;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA session required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select report_row.id,report_row.match_id,report_row.reason,report_row.revision,report_row.created_at,w.status,
    l.title as left_title,v.title as right_title,coalesce(l.url,'') as left_url,v.url as right_url
   from sdi_private.war_reports report_row join sdi_private.war_matches w on w.id=report_row.match_id
   join public.sdi_watch_media l on l.id=w.left_media left join public.sdi_watch_media v on v.id=w.right_media
   where report_row.state='pending' order by report_row.created_at,report_row.id limit 50
  ) item;
  return jsonb_build_object('reports',items);
 end if;
 if action is null or action not in('dismiss','remove') or revision is null or reason is null or length(trim(reason)) not between 1 and 2000 then
  return jsonb_build_object('error','A current report and decision reason are required.');end if;
 select * into r from sdi_private.war_reports where id=report for update;
 if not found or r.state<>'pending' or r.revision<>revision then return jsonb_build_object('error','Report changed. Refresh.');end if;
 select * into m from sdi_private.war_matches where id=r.match_id for update;
 if auth.uid() in(m.creator,m.opponent,r.reporter) then return jsonb_build_object('error','An uninvolved administrator must decide.');end if;
 if action='remove' then
  update sdi_private.war_matches set status='removed' where id=m.id;
  -- Keep votes and final snapshot for audit, but removed matches do not count
  -- toward profile records. This does not delete a creator's media or original.
 end if;
 update sdi_private.war_reports set state=case action when 'remove' then 'removed' else 'dismissed' end,
  revision=war_reports.revision+1 where id=r.id;
 insert into sdi_private.war_moderation_audit(report_id,match_id,actor,decision,previous_status,reason)
 values(r.id,m.id,auth.uid(),action,m.status,trim(reason));
 return jsonb_build_object('status','confirmed');
end $$;

create or replace function sdi_private.war_appeal_admin(action text,appeal uuid default null,revision bigint default null,note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare a sdi_private.war_appeals; d sdi_private.war_moderation_audit; m sdi_private.war_matches; items jsonb;
begin
 if not sdi_private.admin_can('moderation') or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA session required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select appeal_row.id,appeal_row.explanation,appeal_row.revision,appeal_row.created_at,decision_row.match_id,decision_row.reason as decision_reason,decision_row.previous_status,
    w.left_digest,w.right_digest,l.title as left_title,r.title as right_title,coalesce(l.url,'') as left_url,r.url as right_url
   from sdi_private.war_appeals appeal_row join sdi_private.war_moderation_audit decision_row on decision_row.id=appeal_row.decision_id
   join sdi_private.war_matches w on w.id=decision_row.match_id
   join public.sdi_watch_media l on l.id=w.left_media left join public.sdi_watch_media r on r.id=w.right_media
   where appeal_row.state='pending' order by appeal_row.created_at,appeal_row.id limit 50
  ) item;
  return jsonb_build_object('appeals',items);
 end if;
 if action is null or action not in('accept','reject') or revision is null or note is null or length(trim(note)) not between 1 and 2000 then
  return jsonb_build_object('error','A current appeal and reason are required.');end if;
 select * into a from sdi_private.war_appeals where id=appeal for update;
 if not found or a.state<>'pending' or a.revision<>revision then return jsonb_build_object('error','Appeal changed. Refresh.');end if;
 select * into d from sdi_private.war_moderation_audit where id=a.decision_id;
 select * into m from sdi_private.war_matches where id=d.match_id for update;
 if auth.uid() in(a.appellant,d.actor,m.creator,m.opponent) or exists(select 1 from sdi_private.war_reports where id=d.report_id and reporter=auth.uid()) then
  return jsonb_build_object('error','Another uninvolved administrator must review this appeal.');end if;
 if action='accept' then
  if m.status<>'removed' or exists(select 1 from sdi_private.war_moderation_audit where match_id=m.id and created_at>d.created_at and decision='remove')
   or d.previous_status not in('pending','active','completed') then return jsonb_build_object('error','A newer restriction requires separate review.');end if;
  if not exists(select 1 from public.sdi_watch_media where id=m.left_media and approved and render_digest=m.left_digest
   and (expires_at is null or expires_at>clock_timestamp()))
   or (d.previous_status<>'pending' and not exists(select 1 from public.sdi_watch_media where id=m.right_media and approved
   and render_digest=m.right_digest and (expires_at is null or expires_at>clock_timestamp()))) then
   return jsonb_build_object('error','The exact submitted media must remain approved and available.');end if;
  update sdi_private.war_matches set status=d.previous_status where id=m.id;
 end if;
 update sdi_private.war_appeals set state=case action when 'accept' then 'accepted' else 'rejected' end,
 reviewer=auth.uid(),review_note=trim(note),revision=war_appeals.revision+1,decided_at=clock_timestamp() where id=a.id;
 return jsonb_build_object('status','confirmed');
end $$;


-- Room viewing has a separate, membership-bound projection. Generic raw-media
-- RLS, downloads and exports retain approved-only access. A YouTube reference
-- shares a video choice, not a fabricated AVPlayer duration or synchronized clock.
create function sdi_private.watch_media_available(media public.sdi_watch_media) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce((media.expires_at is null or media.expires_at>clock_timestamp())
  and (media.owner_id is null or not sdi_private.creator_restricted(media.owner_id))
  and not exists(select 1 from sdi_private.feed_blocks b where
   (b.actor=auth.uid() and b.creator=media.owner_id) or (b.creator=auth.uid() and b.actor=media.owner_id))
  and case media.playback_provider when 'rendition' then media.approved
   when 'youtube' then sdi_private.war_media_available(media) else false end,false)
$$;
revoke all on function sdi_private.watch_media_available(public.sdi_watch_media) from public,anon,authenticated,service_role;
create function sdi_private.watch_video(media public.sdi_watch_media) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('id',media.id,'title',media.title,'duration',media.duration,
  'expires_at',media.expires_at,'video_source',sdi_private.war_video_source(media))
$$;
revoke all on function sdi_private.watch_video(public.sdi_watch_media) from public,anon,authenticated,service_role;
create function sdi_private.watch_action(action text,room uuid,media uuid default null,
 revision bigint default null,"position" double precision default null,playing boolean default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); selected public.sdi_watch_media; current_session public.sdi_watch_sessions; items jsonb;
begin
 if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.');end if;
 if not sdi_private.room_access(room) then return jsonb_build_object('error','Room access ended.');end if;
 if action='catalog' then
  select coalesce(jsonb_agg(item.video),'[]'::jsonb) into items from (
   select sdi_private.watch_video(m) as video from public.sdi_watch_media m
   where sdi_private.watch_media_available(m) order by m.id limit 100
  ) item;
  return jsonb_build_object('media',items);
 end if;
 if action is null or action not in('status','select','control') then return jsonb_build_object('error','Unknown watch operation.');end if;
 if action<>'status' then
  if not sdi_private.room_owner(room) then return jsonb_build_object('error','Only the room host controls shared viewing.');end if;
  -- Serialize the missing-session case and host changes against one room row.
  perform 1 from public.sdi_rooms r where r.id=room and not r.closed for update;
  if not sdi_private.room_owner(room) then return jsonb_build_object('error','Room access ended.');end if;
  select w.* into current_session from public.sdi_watch_sessions w where w.room_id=room for update;
 else
  select w.* into current_session from public.sdi_watch_sessions w where w.room_id=room;
 end if;
 if action='status' and current_session.id is null then return jsonb_build_object('status','empty');end if;
 if action='select' then
  select m.* into selected from public.sdi_watch_media m where m.id=media and sdi_private.watch_media_available(m);
 else
  select m.* into selected from public.sdi_watch_media m where m.id=current_session.media_id and sdi_private.watch_media_available(m);
 end if;
 if selected.id is null then return jsonb_build_object('error','Shared video is no longer available.');end if;
 if action<>'status' then
  if current_session.id is not null and (revision is null or revision<>current_session.revision) then
   return jsonb_build_object('error','Playback changed elsewhere. Refresh before controlling it.');end if;
  if action='control' then
   if selected.playback_provider<>'rendition' then return jsonb_build_object('error','YouTube playback uses independent provider controls. Shared seek and play are unavailable.');end if;
   if watch_action."position" is null or watch_action."position" not between 0 and selected.duration or watch_action.playing is null then
    return jsonb_build_object('error','A valid playback position and state are required.');end if;
   update public.sdi_watch_sessions w set position=watch_action."position",playing=watch_action.playing
    where w.id=current_session.id returning w.* into current_session;
  elsif current_session.id is null then
   if revision is not null then return jsonb_build_object('error','Session changed. Refresh before sharing.');end if;
   insert into public.sdi_watch_sessions(room_id,media_id,position,playing) values(room,selected.id,0,false)
    returning * into current_session;
  else
   update public.sdi_watch_sessions w set media_id=selected.id,position=0,playing=false
    where w.id=current_session.id returning w.* into current_session;
  end if;
 end if;
 return jsonb_build_object('status','confirmed','session',row_to_json(current_session),'video',sdi_private.watch_video(selected));
end $$;
revoke all on function sdi_private.watch_action(text,uuid,uuid,bigint,double precision,boolean) from public,anon,service_role;
grant execute on function sdi_private.watch_action(text,uuid,uuid,bigint,double precision,boolean) to authenticated;
create function public.sdi_watch_action(action text,room uuid,media uuid default null,
 revision bigint default null,"position" double precision default null,playing boolean default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.watch_action(action,room,media,revision,"position",playing)$$;
revoke all on function public.sdi_watch_action(text,uuid,uuid,bigint,double precision,boolean) from public,anon,service_role;
grant execute on function public.sdi_watch_action(text,uuid,uuid,bigint,double precision,boolean) to authenticated;

commit;
