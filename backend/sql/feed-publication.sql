-- Unapplied candidate. Install after feed-integrity.sql.
-- Publication path for the 'feed' destination. Only the publishing service claims
-- and finishes feed jobs; every claim, renewal and finish re-evaluates
-- release_allowed(review, version, digest, 'feed'): owner/admin approval of the
-- exact digest, creator consent, cleared rights, active account, retained artifact
-- and owner approval for Spatter renders. Nothing here publishes without it.
begin;
-- Creator-controlled file-export permission. Not part of approval evidence, so
-- toggling it does not invalidate the review; it is copied to the live post.
alter table sdi_private.render_reviews add column allow_export boolean not null default false;
alter table public.sdi_watch_media add column review_id uuid references sdi_private.render_reviews(id);
create unique index watch_media_render_digest on public.sdi_watch_media(render_digest) where render_digest is not null;
create function sdi_private.export_consent(review uuid,version bigint,allowed boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Current account session required.');end if;
 if review is null or version is null or allowed is null then return jsonb_build_object('error','Select a render and an explicit export choice.');end if;
 select * into r from sdi_private.render_reviews where id=review and creator=auth.uid() for update;
 if not found or r.version<>version then return jsonb_build_object('error','Render changed. Refresh before changing export permission.');end if;
 update sdi_private.render_reviews set allow_export=allowed where id=r.id;
 update sdi_private.feed_posts p set allow_export=allowed from public.sdi_watch_media m
  where m.id=p.media_id and m.render_digest=r.render_digest and p.creator=auth.uid();
 return jsonb_build_object('status','confirmed','allow_export',allowed);
end $$;
revoke all on function sdi_private.export_consent(uuid,bigint,boolean) from public,anon;
grant execute on function sdi_private.export_consent(uuid,bigint,boolean) to authenticated;
create function public.sdi_export_consent(review uuid,version bigint,allowed boolean) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.export_consent(review,version,allowed)$$;
revoke all on function public.sdi_export_consent(uuid,bigint,boolean) from public,anon;
grant execute on function public.sdi_export_consent(uuid,bigint,boolean) to authenticated;

-- Creators can queue the feed destination of an approved render themselves.
create or replace function sdi_private.creator_review(action text,review uuid default null,version bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; items jsonb; target text;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Current account session required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select id,title,render_digest,render_reviews.version,state,consent_version,destinations,allow_export,
    sdi_private.release_allowed(id,render_reviews.version,render_digest,'youtube') as can_publish,
    sdi_private.release_allowed(id,render_reviews.version,render_digest,'feed') as can_publish_feed
   from sdi_private.render_reviews where creator=auth.uid() order by created_at desc,id limit 100
  ) item;
  return jsonb_build_object('reviews',items);
 end if;
 if action is null or action not in('withdraw_consent','publish_youtube','publish_feed') or review is null or version is null then
  return jsonb_build_object('error','Select a current reviewed render.');end if;
 select * into r from sdi_private.render_reviews where id=review and creator=auth.uid() for update;
 if not found or r.version<>version then return jsonb_build_object('error','Render changed. Refresh before acting.');end if;
 if action='withdraw_consent' then
  update sdi_private.render_reviews set consent_version='',destinations=array[]::text[],state='pending' where id=r.id;
  return jsonb_build_object('status','consent_withdrawn');
 end if;
 target:=case action when 'publish_feed' then 'feed' else 'youtube' end;
 if exists(select 1 from sdi_private.publish_jobs where review_id=r.id and review_version=r.version and destination=target) then
  return jsonb_build_object('error','This render already has a publishing job. Manage it in Publishing activity.');end if;
 return sdi_private.publish_action('enqueue',r.id,target,null);
end $$;

-- Worker claim for feed jobs. Mirrors publish_claim but for the feed destination;
-- the worker copies the private artifact bytes to the approved HTTPS hosting and
-- must verify the SHA-256 of the actual bytes before calling finish.
create function sdi_private.feed_publish_claim() returns jsonb language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs; a sdi_private.render_artifacts; r sdi_private.render_reviews; name text;
begin
 update sdi_private.publish_jobs set state='reconcile',last_error='Worker lease expired; reconcile hosting before retry.',updated_at=clock_timestamp()
 where state='leased' and lease_expires<clock_timestamp();
 select * into j from sdi_private.publish_jobs where state='queued' and destination='feed' and attempts<5 and next_attempt<=clock_timestamp()
 order by created_at for update skip locked limit 1;
 if not found then return jsonb_build_object('empty',true);end if;
 if not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,'feed') then
  update sdi_private.publish_jobs set state='cancelled',last_error='Approval, consent, rights or artifact no longer valid.',updated_at=clock_timestamp() where id=j.id;
  return jsonb_build_object('empty',true);
 end if;
 select * into a from sdi_private.render_artifacts where review_id=j.review_id and version=j.review_version;
 select * into r from sdi_private.render_reviews where id=j.review_id;
 select left(coalesce(nullif(trim(raw_user_meta_data->>'username'),''),'Member'),100) into name from auth.users where id=j.creator;
 update sdi_private.publish_jobs set state='leased',attempts=attempts+1,lease=gen_random_uuid(),lease_expires=clock_timestamp()+interval '2 minutes',updated_at=clock_timestamp()
 where id=j.id returning * into j;
 return jsonb_build_object('job',j.id,'lease',j.lease,'destination','feed','digest',j.render_digest,'object_key',a.object_key,
  'byte_count',a.byte_count,'title',a.title,'description',a.description,'made_for_kids',a.made_for_kids,
  'creator',j.creator,'creator_name',name,'allow_export',r.allow_export,'spatter_generated',r.spatter_generated);
end $$;
-- Finish inserts the approved public rendition and the visible post atomically.
-- If approval lapsed or cancellation raced the copy, the hosted copy is already
-- public, so the job becomes removal_pending for the feed removal worker.
create function sdi_private.feed_publish_finish(job uuid,token uuid,url text,duration double precision,failure text default null) returns boolean
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
 if url is null or url !~ '^https://' or length(url)>2048 or duration is null or duration<=0 or duration>3600 then return false;end if;
 if j.state='cancel_requested' or not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,'feed') then
  -- The copy step is over, so the lease is released and removal may start at once.
  update sdi_private.publish_jobs set state='removal_pending',provider_id='feed:'||j.render_digest,result_url=url,lease=null,lease_expires=null,
   last_error='Hosted copy must be removed: approval or consent changed before release.',updated_at=clock_timestamp() where id=j.id;
  return true;
 end if;
 select * into a from sdi_private.render_artifacts where review_id=j.review_id and version=j.review_version;
 select * into r from sdi_private.render_reviews where id=j.review_id;
 select left(coalesce(nullif(trim(raw_user_meta_data->>'username'),''),'Member'),100) into name from auth.users where id=j.creator;
 insert into public.sdi_watch_media(title,url,duration,approved,owner_id,render_digest,review_id)
 values(left(a.title,200),url,duration,true,j.creator,j.render_digest,j.review_id)
 on conflict(render_digest) where render_digest is not null do update set title=excluded.title,url=excluded.url,duration=excluded.duration,
  approved=true,owner_id=excluded.owner_id,review_id=excluded.review_id,expires_at=null
 returning id into media;
 insert into sdi_private.feed_posts(media_id,creator,creator_name,caption,visible,allow_export)
 values(media,j.creator,name,left(a.description,2000),true,r.allow_export)
 on conflict(media_id) do update set creator=excluded.creator,creator_name=excluded.creator_name,caption=excluded.caption,
  visible=true,allow_export=excluded.allow_export,published_at=clock_timestamp();
 update sdi_private.publish_jobs set state='published',provider_id='feed:'||media::text,result_url=url,phase='release',updated_at=clock_timestamp() where id=j.id;
 return true;
end $$;
-- Removal worker for hosted feed copies: moderation removals (removal_jobs) and
-- cancelled-after-copy publish jobs. Confirmed deletion is the only success.
alter table sdi_private.removal_jobs add column attempts integer not null default 0;
alter table sdi_private.removal_jobs add column lease uuid;
alter table sdi_private.removal_jobs add column lease_expires timestamptz;
create function sdi_private.feed_removal_claim() returns jsonb language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs; d sdi_private.removal_jobs; target text;
begin
 select * into j from sdi_private.publish_jobs where state='removal_pending' and destination='feed' and result_url is not null
  and removal_attempts<5 and (lease_expires is null or lease_expires<clock_timestamp()-interval '60 seconds')
  order by updated_at for update skip locked limit 1;
 if found then
  update sdi_private.publish_jobs set lease=gen_random_uuid(),lease_expires=clock_timestamp()+interval '2 minutes',
   removal_attempts=removal_attempts+1,updated_at=clock_timestamp() where id=j.id returning * into j;
  return jsonb_build_object('source','publish_job','job',j.id,'lease',j.lease,'url',j.result_url,'digest',j.render_digest);
 end if;
 select rj.* into d from sdi_private.removal_jobs rj join public.sdi_watch_media m on m.id=rj.media_id
  where rj.state in('pending','failed') and rj.attempts<5 and m.review_id is not null
  and (rj.lease_expires is null or rj.lease_expires<clock_timestamp()-interval '60 seconds')
  order by rj.created_at for update of rj skip locked limit 1;
 if not found then return jsonb_build_object('empty',true);end if;
 select url into target from public.sdi_watch_media where id=d.media_id;
 update sdi_private.removal_jobs set state='running',lease=gen_random_uuid(),lease_expires=clock_timestamp()+interval '2 minutes',attempts=attempts+1
  where id=d.id returning * into d;
 return jsonb_build_object('source','removal_job','job',d.id,'lease',d.lease,'url',target,'digest',d.render_digest);
end $$;
create function sdi_private.feed_removal_finish(source text,job uuid,token uuid,confirmed boolean) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if confirmed is null then return false;end if;
 if source='publish_job' then
  update sdi_private.publish_jobs set state=case when confirmed then 'cancelled' else 'removal_pending' end,
   result_url=case when confirmed then null else result_url end,
   last_error=case when confirmed then 'Hosted feed copy removed; originals preserved.' else 'Feed copy removal not confirmed; bounded retry pending.' end,
   lease=null,lease_expires=null,updated_at=clock_timestamp()
  where id=job and lease=token and state='removal_pending' and destination='feed';
  return found;
 elsif source='removal_job' then
  update sdi_private.removal_jobs set state=case when confirmed then 'complete' else 'failed' end,lease=null,lease_expires=null
  where id=job and lease=token and state='running';
  return found;
 end if;
 return false;
end $$;
revoke all on function sdi_private.feed_publish_claim(),sdi_private.feed_publish_finish(uuid,uuid,text,double precision,text),
 sdi_private.feed_removal_claim(),sdi_private.feed_removal_finish(text,uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function sdi_private.feed_publish_claim(),sdi_private.feed_publish_finish(uuid,uuid,text,double precision,text),
 sdi_private.feed_removal_claim(),sdi_private.feed_removal_finish(text,uuid,uuid,boolean) to service_role;
create function public.sdi_feed_publish_claim() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.feed_publish_claim()$$;
create function public.sdi_feed_publish_finish(job uuid,token uuid,url text,duration double precision,failure text default null) returns boolean
language sql security invoker set search_path='' as $$select sdi_private.feed_publish_finish(job,token,url,duration,failure)$$;
create function public.sdi_feed_removal_claim() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.feed_removal_claim()$$;
create function public.sdi_feed_removal_finish(source text,job uuid,token uuid,confirmed boolean) returns boolean
language sql security invoker set search_path='' as $$select sdi_private.feed_removal_finish(source,job,token,confirmed)$$;
revoke all on function public.sdi_feed_publish_claim(),public.sdi_feed_publish_finish(uuid,uuid,text,double precision,text),
 public.sdi_feed_removal_claim(),public.sdi_feed_removal_finish(text,uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.sdi_feed_publish_claim(),public.sdi_feed_publish_finish(uuid,uuid,text,double precision,text),
 public.sdi_feed_removal_claim(),public.sdi_feed_removal_finish(text,uuid,uuid,boolean) to service_role;
commit;
