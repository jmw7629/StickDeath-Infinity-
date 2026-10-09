-- Unapplied implementation candidate; requires collaboration-watch.sql.
begin;
alter table public.sdi_watch_media add column owner_id uuid references auth.users(id) on delete cascade;
alter table public.sdi_watch_media add column render_digest text check(render_digest ~ '^[a-f0-9]{64}$');
create table sdi_private.war_matches (
 id uuid primary key default gen_random_uuid(), creator uuid not null references auth.users(id) on delete cascade,
 opponent uuid not null references auth.users(id) on delete cascade,
 left_media uuid not null references public.sdi_watch_media(id), right_media uuid references public.sdi_watch_media(id),
 left_digest text not null, right_digest text,
 status text not null default 'pending' check(status in ('pending','active','completed','withdrawn','removed')),
 starts_at timestamptz, ends_at timestamptz, created_at timestamptz not null default clock_timestamp(),
 check(creator<>opponent)
);
create table sdi_private.war_votes (
 match_id uuid not null references sdi_private.war_matches(id) on delete cascade,
 voter uuid not null references auth.users(id) on delete cascade,
 choice text not null check(choice in ('left','right')), primary key(match_id,voter)
);
create table sdi_private.war_results (
 match_id uuid primary key references sdi_private.war_matches(id),
 left_votes bigint not null check(left_votes>=0), right_votes bigint not null check(right_votes>=0),
 outcome text not null check(outcome in('left','right','tie')),
 left_digest text not null, right_digest text not null,
 finalized_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.war_results enable row level security;
revoke all on sdi_private.war_results from public,anon,authenticated;
create table sdi_private.war_budget (
 user_id uuid primary key references auth.users(id) on delete cascade,
 starts_at timestamptz not null, attempts integer not null
);
create table sdi_private.war_blocks (
 blocker uuid not null references auth.users(id) on delete cascade,
 blocked uuid not null references auth.users(id) on delete cascade, primary key(blocker,blocked)
);
alter table sdi_private.war_matches enable row level security;
alter table sdi_private.war_votes enable row level security;
alter table sdi_private.war_budget enable row level security;
alter table sdi_private.war_blocks enable row level security;
revoke all on sdi_private.war_matches,sdi_private.war_votes,sdi_private.war_budget,sdi_private.war_blocks from public,anon,authenticated;
-- Every privileged path binds to auth.uid(). Client never supplies voter identity.
create function sdi_private.war_action(action text, match uuid default null, media uuid default null,
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
   where (w.status in('active','completed') or (w.status='pending' and actor in(w.creator,w.opponent)))
   and l.approved and l.render_digest=w.left_digest and (l.expires_at is null or l.expires_at>clock_timestamp())
   and (w.status='pending' or (r.approved and r.render_digest=w.right_digest and (r.expires_at is null or r.expires_at>clock_timestamp())))
   and not exists(select 1 from sdi_private.war_blocks b where
     (b.blocker=actor and b.blocked in(w.creator,w.opponent)) or (b.blocked=actor and b.blocker in(w.creator,w.opponent)))
   order by w.created_at desc limit 100
  ) items;
  return jsonb_build_object('matches',result);
 elsif action='propose' then
  if opponent is null or opponent=actor or not exists(select 1 from auth.users where id=opponent and not is_anonymous) then
   return jsonb_build_object('error','Choose another eligible creator.'); end if;
  if exists(select 1 from sdi_private.war_blocks b where (b.blocker=actor and b.blocked=opponent) or (b.blocker=opponent and b.blocked=actor)) then
   return jsonb_build_object('error','Matchup unavailable.'); end if;
  if (select count(*) from sdi_private.war_matches where creator=actor and status in('pending','active') and (ends_at is null or ends_at>clock_timestamp()))>=5 then
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
  if action='withdraw' then
   if actor not in(m.creator,m.opponent) then return jsonb_build_object('error','Only participants can withdraw.'); end if;
   if m.ends_at is not null and m.ends_at<=clock_timestamp() then return jsonb_build_object('error','Voting has ended; contact moderation for an appeal.'); end if;
   update sdi_private.war_matches set status='withdrawn' where id=match;
  elsif action='accept' then
   if m.opponent<>actor or m.status<>'pending' then return jsonb_build_object('error','No pending invitation.'); end if;
   if exists(select 1 from sdi_private.war_blocks b where (b.blocker=actor and b.blocked=m.creator) or (b.blocker=m.creator and b.blocked=actor)) then
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
   if exists(select 1 from sdi_private.war_blocks b where (b.blocker=actor and b.blocked in(m.creator,m.opponent)) or (b.blocked=actor and b.blocker in(m.creator,m.opponent))) then
    return jsonb_build_object('error','Voting is unavailable.'); end if;
   if (select count(*) from public.sdi_watch_media where approved and (expires_at is null or expires_at>clock_timestamp())
     and ((id=m.left_media and render_digest=m.left_digest) or (id=m.right_media and render_digest=m.right_digest)))<>2 then
    return jsonb_build_object('error','A submitted video is no longer approved.'); end if;
   insert into sdi_private.war_votes values(match,actor,choice) on conflict(match_id,voter) do update set choice=excluded.choice;
  else return jsonb_build_object('error','Unsupported operation.'); end if;
 end if;
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.war_action(text,uuid,uuid,uuid,text) from public;
grant execute on function sdi_private.war_action(text,uuid,uuid,uuid,text) to authenticated;
create function public.sdi_war_action(action text,match uuid default null,media uuid default null,opponent uuid default null,choice text default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.war_action(action,match,media,opponent,choice)$$;
revoke all on function public.sdi_war_action(text,uuid,uuid,uuid,text) from public,anon;
grant execute on function public.sdi_war_action(text,uuid,uuid,uuid,text) to authenticated;
commit;
