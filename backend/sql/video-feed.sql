-- Unapplied candidate. Requires war-room.sql approved-media ownership columns.
begin;
create table sdi_private.feed_posts (
 id uuid primary key default gen_random_uuid(), media_id uuid not null unique references public.sdi_watch_media(id) on delete cascade,
 creator uuid not null references auth.users(id) on delete cascade,
 creator_name text not null check(length(creator_name) between 1 and 100),
 caption text not null default '' check(length(caption)<=2000),
 published_at timestamptz not null default clock_timestamp(),
 featured boolean not null default false, visible boolean not null default false,
 allow_export boolean not null default false
);
create table sdi_private.feed_likes (
 post uuid not null references sdi_private.feed_posts(id) on delete cascade,
 actor uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default clock_timestamp(), primary key(post,actor)
);
create table sdi_private.feed_follows (
 actor uuid not null references auth.users(id) on delete cascade,
 creator uuid not null references auth.users(id) on delete cascade,
 primary key(actor,creator),check(actor<>creator)
);
create table sdi_private.feed_blocks (
 actor uuid not null references auth.users(id) on delete cascade,
 creator uuid not null references auth.users(id) on delete cascade,
 primary key(actor,creator),check(actor<>creator)
);
create table sdi_private.feed_reports (
 post uuid not null references sdi_private.feed_posts(id) on delete cascade,
 actor uuid not null references auth.users(id) on delete cascade,
 reason text not null check(reason in('rights','abuse','unsafe','spam')),
 created_at timestamptz not null default clock_timestamp(), primary key(post,actor)
);
create table sdi_private.feed_budget (
 actor uuid primary key references auth.users(id) on delete cascade,
 started_at timestamptz not null, attempts integer not null
);
alter table sdi_private.feed_posts enable row level security;
alter table sdi_private.feed_likes enable row level security;
alter table sdi_private.feed_follows enable row level security;
alter table sdi_private.feed_blocks enable row level security;
alter table sdi_private.feed_reports enable row level security;
alter table sdi_private.feed_budget enable row level security;
revoke all on sdi_private.feed_posts,sdi_private.feed_likes,sdi_private.feed_follows,sdi_private.feed_blocks,sdi_private.feed_reports,sdi_private.feed_budget from public,anon,authenticated;
-- Publication service alone inserts approved posts. API returns only eligible video.
create function sdi_private.feed_action(action text, post_id uuid default null, target uuid default null,
 enabled boolean default true, category text default 'recent', page integer default 0, reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=auth.uid(); entry sdi_private.feed_posts; n integer; items jsonb;
begin
 if actor_id is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor_id and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 insert into sdi_private.feed_budget values(actor_id,clock_timestamp(),1)
 on conflict(actor) do update set attempts=case when feed_budget.started_at<clock_timestamp()-interval '1 minute' then 1 else feed_budget.attempts+1 end,
 started_at=case when feed_budget.started_at<clock_timestamp()-interval '1 minute' then clock_timestamp() else feed_budget.started_at end returning attempts into n;
 if n>60 then return jsonb_build_object('error','Please wait before trying again.'); end if;
 if action='list' then
  if page<0 or page>39 or category not in('recent','following','featured','trending') then return jsonb_build_object('error','Invalid feed page.'); end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select p.id,p.creator,p.creator_name,p.caption,p.published_at,p.allow_export,m.title,m.url,
    (select count(*) from sdi_private.feed_likes l where l.post=p.id) as likes,
    exists(select 1 from sdi_private.feed_likes l where l.post=p.id and l.actor=actor_id) as liked,
    exists(select 1 from sdi_private.feed_follows f where f.actor=actor_id and f.creator=p.creator) as following
   from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id
   where p.visible and m.approved and m.owner_id=p.creator and m.render_digest is not null
   and (m.expires_at is null or m.expires_at>clock_timestamp())
   and not exists(select 1 from sdi_private.feed_blocks b where (b.actor=actor_id and b.creator=p.creator) or (b.actor=p.creator and b.creator=actor_id))
   and (category<>'featured' or p.featured)
   and (category<>'following' or exists(select 1 from sdi_private.feed_follows f where f.actor=actor_id and f.creator=p.creator))
   order by case when category='trending' then (select count(*) from sdi_private.feed_likes l where l.post=p.id and l.created_at>clock_timestamp()-interval '7 days') else 0 end desc,
    p.published_at desc,p.id desc limit 25 offset page*25
  ) item;
  return jsonb_build_object('posts',items,'has_more',jsonb_array_length(items)=25);
 end if;
 if action in('follow','block') then
  if target is null or target=actor_id or not exists(select 1 from auth.users where id=target) then return jsonb_build_object('error','Creator unavailable.'); end if;
  if action='block' then
   if enabled then
    insert into sdi_private.feed_blocks values(actor_id,target) on conflict do nothing;
    delete from sdi_private.feed_follows where (actor=actor_id and creator=target) or (actor=target and creator=actor_id);
   else delete from sdi_private.feed_blocks where actor=actor_id and creator=target; end if;
  else
   if exists(select 1 from sdi_private.feed_blocks where (actor=actor_id and creator=target) or (actor=target and creator=actor_id)) then return jsonb_build_object('error','Creator unavailable.'); end if;
   if enabled then insert into sdi_private.feed_follows values(actor_id,target) on conflict do nothing;
   else delete from sdi_private.feed_follows where actor=actor_id and creator=target; end if;
  end if;
 else
  select p.* into entry from sdi_private.feed_posts p join public.sdi_watch_media m on m.id=p.media_id
   where p.id=post_id and p.visible and m.approved and m.owner_id=p.creator and m.render_digest is not null
   and (m.expires_at is null or m.expires_at>clock_timestamp())
   and not exists(select 1 from sdi_private.feed_blocks b where (b.actor=actor_id and b.creator=p.creator) or (b.actor=p.creator and b.creator=actor_id));
  if not found then return jsonb_build_object('error','Post unavailable.'); end if;
  if action='like' then
   if enabled then insert into sdi_private.feed_likes(post,actor) values(post_id,actor_id) on conflict do nothing;
   else delete from sdi_private.feed_likes where post=post_id and actor=actor_id; end if;
  elsif action='report' and reason in('rights','abuse','unsafe','spam') then
   insert into sdi_private.feed_reports(post,actor,reason) values(post_id,actor_id,reason)
   on conflict(post,actor) do update set reason=excluded.reason;
  else return jsonb_build_object('error','Unsupported feed operation.'); end if;
 end if;
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.feed_action(text,uuid,uuid,boolean,text,integer,text) from public;
grant execute on function sdi_private.feed_action(text,uuid,uuid,boolean,text,integer,text) to authenticated;
create function public.sdi_feed_action(action text,post_id uuid default null,target uuid default null,
 enabled boolean default true,category text default 'recent',page integer default 0,reason text default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.feed_action(action,post_id,target,enabled,category,page,reason)$$;
revoke all on function public.sdi_feed_action(text,uuid,uuid,boolean,text,integer,text) from public,anon;
grant execute on function public.sdi_feed_action(text,uuid,uuid,boolean,text,integer,text) to authenticated;
commit;
