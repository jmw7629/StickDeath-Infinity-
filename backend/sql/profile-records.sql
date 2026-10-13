-- Unapplied candidate. Requires war-finalization.sql, video-feed.sql and admin-users.sql.
begin;
create table sdi_private.record_preferences (
 user_id uuid primary key references auth.users(id) on delete cascade,
 show_records boolean not null default false, show_badges boolean not null default false,
 revision bigint not null default 1
);
create table sdi_private.earned_badges (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 badge_key text not null, title text not null, criterion_version text not null,
 source_event uuid not null unique, earned_at timestamptz not null default clock_timestamp(),
 revoked boolean not null default false, unique(user_id,badge_key)
);
alter table sdi_private.record_preferences enable row level security;
alter table sdi_private.earned_badges enable row level security;
revoke all on sdi_private.record_preferences,sdi_private.earned_badges from public,anon,authenticated;
create function sdi_private.profile_records(action text,subject uuid default null,revision bigint default null,
 records boolean default null,badges boolean default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target uuid:=coalesce(subject,auth.uid()); prefs sdi_private.record_preferences;
 wins bigint; losses bigint; ties bigint; awards jsonb;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Sign in to view account records.');end if;
 if action is null or action not in('read','save') then return jsonb_build_object('error','Unsupported records operation.');end if;
 if target is null or not exists(select 1 from auth.users where id=target and not is_anonymous) then
  return jsonb_build_object('error','Profile unavailable.');end if;
 if target<>auth.uid() and (
  exists(select 1 from sdi_private.war_blocks where (blocker=auth.uid() and blocked=target) or (blocker=target and blocked=auth.uid()))
  or exists(select 1 from sdi_private.feed_blocks where (actor=auth.uid() and creator=target) or (actor=target and creator=auth.uid()))
  or exists(select 1 from sdi_private.account_controls where user_id=target and state<>'active')) then
  return jsonb_build_object('error','Profile unavailable.');end if;
 if action='save' then
  if target<>auth.uid() or records is null or badges is null or revision is null then
   return jsonb_build_object('error','Current account preferences required.');end if;
  insert into sdi_private.record_preferences(user_id) values(target) on conflict do nothing;
  select * into prefs from sdi_private.record_preferences where user_id=target for update;
  if prefs.revision<>revision then return jsonb_build_object('error','Preferences changed. Refresh before saving.');end if;
  update sdi_private.record_preferences set show_records=records,show_badges=badges,
   revision=record_preferences.revision+1 where user_id=target;
 end if;
 select * into prefs from sdi_private.record_preferences where user_id=target;
 if target=auth.uid() or coalesce(prefs.show_records,false) then
  select count(*) filter(where (w.creator=target and r.outcome='left') or (w.opponent=target and r.outcome='right')),
   count(*) filter(where (w.creator=target and r.outcome='right') or (w.opponent=target and r.outcome='left')),
   count(*) filter(where r.outcome='tie') into wins,losses,ties
  from sdi_private.war_results r join sdi_private.war_matches w on w.id=r.match_id
  where w.status='completed' and target in(w.creator,w.opponent);
 end if;
 if target=auth.uid() or coalesce(prefs.show_badges,false) then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into awards from (
   select id,title,criterion_version,earned_at from sdi_private.earned_badges
   where user_id=target and not revoked order by earned_at desc limit 100
  ) item;
 end if;
 return jsonb_build_object('show_records',coalesce(prefs.show_records,false),'show_badges',coalesce(prefs.show_badges,false),
  'revision',case when target=auth.uid() then coalesce(prefs.revision,1) else null end,
  'wins',wins,'losses',losses,'ties',ties,'badges',awards);
end $$;
revoke all on function sdi_private.profile_records(text,uuid,bigint,boolean,boolean) from public,anon;
grant execute on function sdi_private.profile_records(text,uuid,bigint,boolean,boolean) to authenticated;
create function public.sdi_profile_records(action text,subject uuid default null,revision bigint default null,
 records boolean default null,badges boolean default null) returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.profile_records(action,subject,revision,records,badges)$$;
revoke all on function public.sdi_profile_records(text,uuid,bigint,boolean,boolean) from public,anon;
grant execute on function public.sdi_profile_records(text,uuid,bigint,boolean,boolean) to authenticated;
-- Rank only consenting, eligible creators. Hidden accounts never enter the
-- aggregate or rank calculation. Badge visibility is independent of records.
create function sdi_private.war_leaderboard() returns jsonb
language plpgsql security definer set search_path='' as $$
declare payload jsonb;
begin
 if not sdi_private.account_active() or not exists(select 1 from auth.users where id=auth.uid() and not is_anonymous) then
  return jsonb_build_object('error','Sign in to view the leaderboard.');end if;
 with eligible as (
  select u.id,left(coalesce(nullif(trim(u.raw_user_meta_data->>'username'),''),'Member'),100) as name,p.show_badges
  from sdi_private.record_preferences p join auth.users u on u.id=p.user_id
  where p.show_records and not u.is_anonymous
   and not exists(select 1 from sdi_private.account_controls c where c.user_id=u.id and c.state<>'active')
   and not exists(select 1 from sdi_private.war_blocks b where
    (b.blocker=auth.uid() and b.blocked=u.id) or (b.blocked=auth.uid() and b.blocker=u.id))
   and not exists(select 1 from sdi_private.feed_blocks b where
    (b.actor=auth.uid() and b.creator=u.id) or (b.creator=auth.uid() and b.actor=u.id))
 ), totals as (
  select e.id,e.name,e.show_badges,
   count(*) filter(where (m.creator=e.id and r.outcome='left') or (m.opponent=e.id and r.outcome='right')) as wins,
   count(*) filter(where (m.creator=e.id and r.outcome='right') or (m.opponent=e.id and r.outcome='left')) as losses,
   count(*) filter(where r.outcome='tie') as ties
  from eligible e join sdi_private.war_matches m on e.id in(m.creator,m.opponent) and m.status='completed'
   join sdi_private.war_results r on r.match_id=m.id
  group by e.id,e.name,e.show_badges
 ), ranked as (
  select *,dense_rank() over(order by wins desc) as rank from totals
 ), limited as (
  select * from ranked order by rank,name,id limit 100
 )
 select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'name',l.name,'rank',l.rank,
  'wins',l.wins,'losses',l.losses,'ties',l.ties,'badges',case when l.show_badges then (
   select coalesce(jsonb_agg(row_to_json(b)),'[]'::jsonb) from (
    select a.id,a.title from sdi_private.earned_badges a where a.user_id=l.id and not a.revoked
    order by a.earned_at desc,a.id limit 100
   ) b
  ) else null end) order by l.rank,l.name,l.id),'[]'::jsonb) into payload from limited l;
 return jsonb_build_object('leaders',payload,'generated_at',clock_timestamp());
end $$;
revoke all on function sdi_private.war_leaderboard() from public,anon;
grant execute on function sdi_private.war_leaderboard() to authenticated;
create function public.sdi_war_leaderboard() returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.war_leaderboard()$$;
revoke all on function public.sdi_war_leaderboard() from public,anon;
grant execute on function public.sdi_war_leaderboard() to authenticated;
commit;
