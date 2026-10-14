-- Unapplied candidate. Install after admin-overview.sql (needs video-feed, moderation,
-- war-room, admin-users, publishing-jobs and upload-registration).
-- Closes feed/War Room integrity gaps: self-likes, restricted creators in listings,
-- report upserts reopening decided reports, proposals that never expire, and
-- 24-hour artifact expiry defeating review approval.
begin;
-- Restricted (suspended/banned) creators disappear from every listing and reaction.
create function sdi_private.creator_restricted(subject uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select subject is null or exists(select 1 from sdi_private.account_controls c where c.user_id=subject and c.state<>'active')
$$;
revoke all on function sdi_private.creator_restricted(uuid) from public,anon;
grant execute on function sdi_private.creator_restricted(uuid) to authenticated,service_role;

-- A decided report keeps its decision; only a pending report can change reason.
create or replace function sdi_private.report_revision() returns trigger language plpgsql set search_path='' as $$
begin
 if old.state<>'pending' then new.reason=old.reason; new.state=old.state; new.version=old.version; return new; end if;
 if new.reason is distinct from old.reason then new.version=old.version+1; end if;
 return new;
end $$;

-- Same signature as video-feed.sql (snapshot-stable paging through `as_of`, #217/#220).
create or replace function sdi_private.feed_action(action text, post_id uuid default null, target uuid default null,
 enabled boolean default true, category text default 'recent', page integer default 0, reason text default null,
 as_of timestamptz default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=auth.uid(); entry sdi_private.feed_posts; n integer; items jsonb; snapshot timestamptz;
begin
 if actor_id is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor_id and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 insert into sdi_private.feed_budget values(actor_id,clock_timestamp(),1)
 on conflict(actor) do update set attempts=case when feed_budget.started_at<clock_timestamp()-interval '1 minute' then 1 else feed_budget.attempts+1 end,
 started_at=case when feed_budget.started_at<clock_timestamp()-interval '1 minute' then clock_timestamp() else feed_budget.started_at end returning attempts into n;
 if n>60 then return jsonb_build_object('error','Please wait before trying again.'); end if;
 if action='list' then
  if page<0 or page>39 or category not in('recent','following','featured','trending') then return jsonb_build_object('error','Invalid feed page.'); end if;
  snapshot:=least(coalesce(as_of,clock_timestamp()),clock_timestamp());
  if snapshot<clock_timestamp()-interval '1 day' then return jsonb_build_object('error','This feed snapshot has expired. Refresh the feed.'); end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select p.id,p.creator,p.creator_name,p.caption,p.published_at,p.allow_export,m.title,m.url,
    (select count(*) from sdi_private.feed_likes l where l.post=p.id) as likes,
    exists(select 1 from sdi_private.feed_likes l where l.post=p.id and l.actor=actor_id) as liked,
    exists(select 1 from sdi_private.feed_follows f where f.actor=actor_id and f.creator=p.creator) as following
   from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id
   where p.visible and m.approved and m.owner_id=p.creator and m.render_digest is not null
   and p.published_at<=snapshot
   and (m.expires_at is null or m.expires_at>clock_timestamp())
   and not sdi_private.creator_restricted(p.creator)
   and not exists(select 1 from sdi_private.feed_blocks b where (b.actor=actor_id and b.creator=p.creator) or (b.actor=p.creator and b.creator=actor_id))
   and (category<>'featured' or p.featured)
   and (category<>'following' or exists(select 1 from sdi_private.feed_follows f where f.actor=actor_id and f.creator=p.creator))
   order by case when category='trending' then (select count(*) from sdi_private.feed_likes l where l.post=p.id and l.created_at>clock_timestamp()-interval '7 days') else 0 end desc,
    p.published_at desc,p.id desc limit 25 offset page*25
  ) item;
  return jsonb_build_object('posts',items,'has_more',jsonb_array_length(items)=25,'as_of',snapshot);
 end if;
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
   where p.id=post_id and p.visible and m.approved and m.owner_id=p.creator and m.render_digest is not null
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

-- War Room: proposals expire after seven days and stop counting toward the
-- five-active limit; restricted creators and their matches leave listings.
alter table sdi_private.war_matches drop constraint war_matches_status_check;
alter table sdi_private.war_matches add constraint war_matches_status_check
 check(status in ('pending','active','completed','withdrawn','removed','expired'));
create function sdi_private.war_proposal_live(m sdi_private.war_matches) returns boolean
language sql stable set search_path='' as $$
 select m.status='pending' and m.created_at>clock_timestamp()-interval '7 days'
$$;
revoke all on function sdi_private.war_proposal_live(sdi_private.war_matches) from public,anon;
grant execute on function sdi_private.war_proposal_live(sdi_private.war_matches) to authenticated,service_role;
create function sdi_private.war_expire_proposals() returns integer
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 update sdi_private.war_matches set status='expired' where status='pending' and created_at<=clock_timestamp()-interval '7 days';
 get diagnostics n=row_count; return n;
end $$;
revoke all on function sdi_private.war_expire_proposals() from public,anon,authenticated;
grant execute on function sdi_private.war_expire_proposals() to service_role;
create function public.sdi_war_expire_proposals() returns integer language sql security invoker set search_path='' as $$select sdi_private.war_expire_proposals()$$;
revoke all on function public.sdi_war_expire_proposals() from public,anon,authenticated;
grant execute on function public.sdi_war_expire_proposals() to service_role;

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
    coalesce(final.left_votes,(select count(*) from sdi_private.war_votes where match_id=w.id and war_votes.choice='left')) as left_votes,
    coalesce(final.right_votes,(select count(*) from sdi_private.war_votes where match_id=w.id and war_votes.choice='right')) as right_votes,
    (select war_votes.choice from sdi_private.war_votes where match_id=w.id and voter=actor) as my_vote
   from sdi_private.war_matches w join public.sdi_watch_media l on l.id=w.left_media
   left join public.sdi_watch_media r on r.id=w.right_media
   left join sdi_private.war_results final on final.match_id=w.id
   where (w.status in('active','completed') or (sdi_private.war_proposal_live(w) and actor in(w.creator,w.opponent)))
   and l.approved and l.render_digest=w.left_digest and (l.expires_at is null or l.expires_at>clock_timestamp())
   and (w.status='pending' or (r.approved and r.render_digest=w.right_digest and (r.expires_at is null or r.expires_at>clock_timestamp())))
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
  select * into video from public.sdi_watch_media where id=media and owner_id=actor and approved and render_digest is not null
   and (expires_at is null or expires_at>clock_timestamp());
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
   select * into video from public.sdi_watch_media where id=media and owner_id=actor and approved and render_digest is not null
    and (expires_at is null or expires_at>clock_timestamp()+interval '24 hours');
   if not found then return jsonb_build_object('error','Select an approved video available for the voting period.'); end if;
   if not exists(select 1 from public.sdi_watch_media where id=m.left_media and approved and render_digest=m.left_digest and (expires_at is null or expires_at>clock_timestamp()+interval '24 hours')) then
    return jsonb_build_object('error','The other video is unavailable.'); end if;
   update sdi_private.war_matches set right_media=media,right_digest=video.render_digest,status='active',starts_at=clock_timestamp(),ends_at=clock_timestamp()+interval '24 hours' where id=match;
  elsif action='vote' then
   if choice is null or choice not in('left','right') or actor in(m.creator,m.opponent) or m.status<>'active' or m.ends_at<=clock_timestamp() then
    return jsonb_build_object('error','Voting is not available to this account.'); end if;
   if sdi_private.creator_restricted(m.creator) or sdi_private.creator_restricted(m.opponent)
    or exists(select 1 from sdi_private.war_blocks b where (b.blocker=actor and b.blocked in(m.creator,m.opponent)) or (b.blocked=actor and b.blocker in(m.creator,m.opponent))) then
    return jsonb_build_object('error','Voting is unavailable.'); end if;
   if (select count(*) from public.sdi_watch_media where approved and (expires_at is null or expires_at>clock_timestamp())
     and ((id=m.left_media and render_digest=m.left_digest) or (id=m.right_media and render_digest=m.right_digest)))<>2 then
    return jsonb_build_object('error','A submitted video is no longer approved.'); end if;
   insert into sdi_private.war_votes values(match,actor,choice) on conflict(match_id,voter) do update set choice=excluded.choice;
  else return jsonb_build_object('error','Unsupported operation.'); end if;
 end if;
 return jsonb_build_object('status','confirmed');
end $$;

-- Problem 6: intake registers artifacts with a 24-hour expiry while approval and
-- every publishing lease require an unexpired artifact. Private renders under
-- review are retained seven days; an approved render is retained thirty days so
-- the publishing worker can finish. Retention is bounded and documented; nothing
-- here publishes or extends a preview URL. Rejected renders expire as registered.
create function sdi_private.retain_artifact_for_review() returns trigger language plpgsql set search_path='' as $$
begin
 new.expires_at=greatest(new.expires_at,clock_timestamp()+interval '7 days');
 return new;
end $$;
revoke all on function sdi_private.retain_artifact_for_review() from public;
create trigger retain_artifact_for_review before insert on sdi_private.render_artifacts
for each row execute function sdi_private.retain_artifact_for_review();
create function sdi_private.retain_artifact_after_approval() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.state='approved' and (old.state is distinct from 'approved' or new.version<>old.version) then
  update sdi_private.render_artifacts set expires_at=greatest(expires_at,clock_timestamp()+interval '30 days')
  where review_id=new.id and version=new.version and render_digest=new.render_digest;
 end if;
 return new;
end $$;
revoke all on function sdi_private.retain_artifact_after_approval() from public,anon,authenticated;
create trigger retain_artifact_after_approval after update on sdi_private.render_reviews
for each row execute function sdi_private.retain_artifact_after_approval();
-- Keyset (cursor) paging for the social wall (#217, #220). Each page is ordered by
-- (score desc, published_at desc, id desc) and the next page starts strictly after
-- the last row's key, so posts published, liked or removed meanwhile can neither
-- duplicate nor skip a row the member has not reached. `score` is 0 except in
-- Trending, where it counts likes inside the seven days ending at the snapshot
-- instant; likes recorded after the snapshot do not move rows. An unlike or a
-- moderation removal can still lower or drop a row: that row is simply absent or
-- appears once more further down, which the client de-duplicates by identity.
-- `can_download` is the creator's export permission AND a current paid
-- entitlement of the viewer (billing.sql); the Free plan cannot download (#219).
create index if not exists feed_posts_recent on sdi_private.feed_posts(published_at desc,id desc) where visible;
create index if not exists feed_likes_post_time on sdi_private.feed_likes(post,created_at);
create function sdi_private.feed_page(category text default 'recent', page_cursor text default null, as_of timestamptz default null)
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
  select p.id,p.creator,p.creator_name,p.caption,p.published_at,p.allow_export,m.title,m.url,
   case when category='trending' then (select count(*) from sdi_private.feed_likes l where l.post=p.id
    and l.created_at>snapshot-interval '7 days' and l.created_at<=snapshot) else 0 end::bigint as score
  from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id
  where p.visible and m.approved and m.owner_id=p.creator and m.render_digest is not null
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
   'score',x.score,
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
revoke all on function sdi_private.feed_page(text,text,timestamptz) from public,anon;
grant execute on function sdi_private.feed_page(text,text,timestamptz) to authenticated;
create function public.sdi_feed_page(category text default 'recent', page_cursor text default null, as_of timestamptz default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.feed_page(category,page_cursor,as_of)$$;
revoke all on function public.sdi_feed_page(text,text,timestamptz) from public,anon;
grant execute on function public.sdi_feed_page(text,text,timestamptz) to authenticated;

-- Creator totals for the profile (#224): counted from the same eligible rows the
-- feed shows, never estimated. A blocked or restricted creator is unavailable.
-- `following` is returned only to the account itself.
create function sdi_private.creator_stats(subject uuid default null) returns jsonb
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
 where p.creator=target and p.visible and m.approved and m.owner_id=p.creator and m.render_digest is not null
  and (m.expires_at is null or m.expires_at>clock_timestamp());
 select count(*) into followers from sdi_private.feed_follows f where f.creator=target and not sdi_private.creator_restricted(f.actor);
 if target=viewer then select count(*) into follows from sdi_private.feed_follows f where f.actor=target; end if;
 return jsonb_build_object('subject',target,'published_videos',posts,'likes_received',likes,'followers',followers,'following',follows);
end $$;
revoke all on function sdi_private.creator_stats(uuid) from public,anon;
grant execute on function sdi_private.creator_stats(uuid) to authenticated;
create function public.sdi_creator_stats(subject uuid default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.creator_stats(subject)$$;
revoke all on function public.sdi_creator_stats(uuid) from public,anon;
grant execute on function public.sdi_creator_stats(uuid) to authenticated;
commit;
