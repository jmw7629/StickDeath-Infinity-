-- Unapplied candidate. Install after challenges.sql (needs profile-records.sql and
-- war-finalization.sql). Badges are awarded only from server-finalized results, keyed
-- on the source event so reprocessing never double-awards. Criteria are versioned rows;
-- the profile-records preferences (show_badges, default off) still govern visibility.
begin;
create table sdi_private.achievement_criteria (
 badge_key text primary key check(badge_key ~ '^[a-z0-9_]{1,40}$'), title text not null check(length(title) between 1 and 100),
 description text not null check(length(description)<=500), criterion_version text not null,
 kind text not null check(kind in('war_matches','war_wins','challenge_wins')), threshold integer not null check(threshold>0),
 enabled boolean not null default true
);
-- Idempotency ledger: one processing record per finalized source event.
create table sdi_private.achievement_events (
 source_kind text not null check(source_kind in('war_result','challenge_result')), source_event uuid not null,
 processed_at timestamptz not null default clock_timestamp(), awarded integer not null default 0, primary key(source_kind,source_event)
);
alter table sdi_private.achievement_criteria enable row level security;
alter table sdi_private.achievement_events enable row level security;
revoke all on sdi_private.achievement_criteria,sdi_private.achievement_events from public,anon,authenticated;
-- Both participants of one matchup may earn a badge from the same result, so the
-- per-event uniqueness moves to (user, badge). A badge is earned once per account.
alter table sdi_private.earned_badges drop constraint earned_badges_source_event_key;
alter table sdi_private.earned_badges add column source_kind text not null default 'war_result';
insert into sdi_private.achievement_criteria(badge_key,title,description,criterion_version,kind,threshold) values
 ('war_first_match','First Matchup','Completed a War Room matchup that reached its voting deadline.','2026-10-12.1','war_matches',1),
 ('war_first_win','Crowd Favorite','Won a completed War Room matchup by viewer favorite.','2026-10-12.1','war_wins',1),
 ('war_five_wins','Five Favorites','Won five completed War Room matchups.','2026-10-12.1','war_wins',5),
 ('challenge_first_win','Challenge Winner','Won a scheduled community challenge by viewer favorite.','2026-10-12.1','challenge_wins',1);

create function sdi_private.award_for_user(subject uuid,source_kind text,source_event uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare matches bigint; wins bigint; challenge_wins bigint; awarded integer:=0; crit sdi_private.achievement_criteria; value bigint;
begin
 if subject is null or exists(select 1 from auth.users where id=subject and is_anonymous) then return 0; end if;
 select count(*),count(*) filter(where (w.creator=subject and r.outcome='left') or (w.opponent=subject and r.outcome='right'))
  into matches,wins from sdi_private.war_results r join sdi_private.war_matches w on w.id=r.match_id
  where w.status='completed' and subject in(w.creator,w.opponent);
 select count(*) into challenge_wins from sdi_private.challenge_results cr join sdi_private.challenge_entries e on e.id=cr.winner_entry
  where cr.outcome='winner' and e.creator=subject;
 for crit in select * from sdi_private.achievement_criteria where enabled order by badge_key loop
  value:=case crit.kind when 'war_matches' then matches when 'war_wins' then wins else challenge_wins end;
  if value>=crit.threshold then
   insert into sdi_private.earned_badges(user_id,badge_key,title,criterion_version,source_event,source_kind)
   values(subject,crit.badge_key,crit.title,crit.criterion_version,source_event,source_kind) on conflict(user_id,badge_key) do nothing;
   if found then awarded:=awarded+1; end if;
  end if;
 end loop;
 return awarded;
end $$;
revoke all on function sdi_private.award_for_user(uuid,text,uuid) from public,anon,authenticated;
-- Service function: award from one finalized War Room result. Reprocessing is a no-op.
create function sdi_private.award_from_war_result(match uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m sdi_private.war_matches; total integer:=0;
begin
 select * into m from sdi_private.war_matches where id=match for update;
 if not found or m.status<>'completed' or not exists(select 1 from sdi_private.war_results r where r.match_id=m.id) then
  return jsonb_build_object('error','Only completed, finalized matchups award badges.'); end if;
 insert into sdi_private.achievement_events(source_kind,source_event) values('war_result',m.id) on conflict do nothing;
 if not found then return jsonb_build_object('duplicate',true,'awarded',0); end if;
 total:=sdi_private.award_for_user(m.creator,'war_result',m.id)+sdi_private.award_for_user(m.opponent,'war_result',m.id);
 update sdi_private.achievement_events set awarded=total where source_kind='war_result' and source_event=m.id;
 return jsonb_build_object('awarded',total);
end $$;
create function sdi_private.award_from_challenge_result(challenge uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare res sdi_private.challenge_results; winner uuid; total integer:=0;
begin
 select * into res from sdi_private.challenge_results where challenge_id=challenge;
 if not found then return jsonb_build_object('error','Challenge is not finalized.'); end if;
 insert into sdi_private.achievement_events(source_kind,source_event) values('challenge_result',res.challenge_id) on conflict do nothing;
 if not found then return jsonb_build_object('duplicate',true,'awarded',0); end if;
 if res.outcome='winner' then
  select creator into winner from sdi_private.challenge_entries where id=res.winner_entry;
  total:=sdi_private.award_for_user(winner,'challenge_result',res.challenge_id);
 end if;
 update sdi_private.achievement_events set awarded=total where source_kind='challenge_result' and source_event=res.challenge_id;
 return jsonb_build_object('awarded',total);
end $$;
-- Bounded sweep for the scheduler after war_finalize/challenge_finalize.
create function sdi_private.award_pending() returns jsonb language plpgsql security definer set search_path='' as $$
declare item record; processed integer:=0; awarded integer:=0; result jsonb;
begin
 for item in select r.match_id as id from sdi_private.war_results r join sdi_private.war_matches w on w.id=r.match_id where w.status='completed'
  and not exists(select 1 from sdi_private.achievement_events e where e.source_kind='war_result' and e.source_event=r.match_id) order by r.finalized_at limit 100 loop
  result:=sdi_private.award_from_war_result(item.id); processed:=processed+1; awarded:=awarded+coalesce((result->>'awarded')::integer,0);
 end loop;
 for item in select r.challenge_id as id from sdi_private.challenge_results r
  where not exists(select 1 from sdi_private.achievement_events e where e.source_kind='challenge_result' and e.source_event=r.challenge_id) order by r.finalized_at limit 100 loop
  result:=sdi_private.award_from_challenge_result(item.id); processed:=processed+1; awarded:=awarded+coalesce((result->>'awarded')::integer,0);
 end loop;
 return jsonb_build_object('processed',processed,'awarded',awarded);
end $$;
revoke all on function sdi_private.award_from_war_result(uuid),sdi_private.award_from_challenge_result(uuid),sdi_private.award_pending() from public,anon,authenticated;
grant execute on function sdi_private.award_from_war_result(uuid),sdi_private.award_from_challenge_result(uuid),sdi_private.award_pending() to service_role;
create function public.sdi_award_achievements() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.award_pending()$$;
revoke all on function public.sdi_award_achievements() from public,anon,authenticated;
grant execute on function public.sdi_award_achievements() to service_role;

-- Members read the earned/locked catalogue for their own account only; other
-- accounts' badges stay behind the show_badges preference in profile-records.
create function sdi_private.achievement_catalog() returns jsonb language plpgsql security definer set search_path='' as $$
declare items jsonb;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Sign in to view achievements.'); end if;
 select coalesce(jsonb_agg(row_to_json(item) order by item.earned_at desc nulls last,item.badge_key),'[]'::jsonb) into items from (
  select c.badge_key,c.title,c.description,c.criterion_version,c.kind,c.threshold,b.earned_at,b.id as badge_id
  from sdi_private.achievement_criteria c left join sdi_private.earned_badges b on b.badge_key=c.badge_key and b.user_id=auth.uid() and not b.revoked
  where c.enabled
 ) item;
 return jsonb_build_object('achievements',items);
end $$;
revoke all on function sdi_private.achievement_catalog() from public,anon;
grant execute on function sdi_private.achievement_catalog() to authenticated;
create function public.sdi_achievement_catalog() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.achievement_catalog()$$;
revoke all on function public.sdi_achievement_catalog() from public,anon;
grant execute on function public.sdi_achievement_catalog() to authenticated;
commit;
