-- Unapplied candidate. Install after rooms-v2.sql (needs war-room.sql, feed-integrity.sql,
-- admin-approval.sql and admin-users.sql). Challenges reuse the War Room rules: only
-- the creator's own approved rendition with an immutable digest may be entered, one
-- entry per creator, one mutable favorite vote per nonparticipant, server times decide
-- Upcoming/Active/Voting/Completed. reward_text is a configured real reward description
-- or empty; nothing here creates coins, prizes or money.
begin;
create table sdi_private.challenges (
 id uuid primary key default gen_random_uuid(), title text not null check(length(title) between 1 and 100),
 brief text not null default '' check(length(brief)<=2000), reward_text text not null default '' check(length(reward_text)<=500),
 created_by uuid not null references auth.users(id), state text not null default 'draft' check(state in('draft','scheduled','cancelled')),
 starts_at timestamptz, submissions_close_at timestamptz, voting_ends_at timestamptz,
 revision bigint not null default 1, created_at timestamptz not null default clock_timestamp(),
 check(starts_at is null or (submissions_close_at>starts_at and voting_ends_at>submissions_close_at))
);
create table sdi_private.challenge_entries (
 id uuid primary key default gen_random_uuid(), challenge_id uuid not null references sdi_private.challenges(id),
 creator uuid not null references auth.users(id) on delete cascade, media_id uuid not null references public.sdi_watch_media(id),
 render_digest text not null, withdrawn boolean not null default false, created_at timestamptz not null default clock_timestamp(),
 unique(challenge_id,creator)
);
create table sdi_private.challenge_votes (
 challenge_id uuid not null references sdi_private.challenges(id), voter uuid not null references auth.users(id) on delete cascade,
 entry_id uuid not null references sdi_private.challenge_entries(id) on delete cascade, created_at timestamptz not null default clock_timestamp(),
 primary key(challenge_id,voter)
);
create table sdi_private.challenge_results (
 challenge_id uuid primary key references sdi_private.challenges(id), finalized_at timestamptz not null default clock_timestamp(),
 tally jsonb not null, winner_entry uuid references sdi_private.challenge_entries(id),
 outcome text not null check(outcome in('winner','tie','no_entries'))
);
create table sdi_private.challenge_audit (
 id uuid primary key default gen_random_uuid(), challenge_id uuid not null references sdi_private.challenges(id),
 actor uuid not null references auth.users(id), action text not null, reason text not null check(length(reason)<=2000),
 created_at timestamptz not null default clock_timestamp()
);
create table sdi_private.challenge_budget (
 user_id uuid primary key references auth.users(id) on delete cascade, starts_at timestamptz not null, attempts integer not null
);
alter table sdi_private.challenges enable row level security;
alter table sdi_private.challenge_entries enable row level security;
alter table sdi_private.challenge_votes enable row level security;
alter table sdi_private.challenge_results enable row level security;
alter table sdi_private.challenge_audit enable row level security;
alter table sdi_private.challenge_budget enable row level security;
revoke all on sdi_private.challenges,sdi_private.challenge_entries,sdi_private.challenge_votes,sdi_private.challenge_results,sdi_private.challenge_audit,sdi_private.challenge_budget from public,anon,authenticated;
create function sdi_private.challenge_phase(c sdi_private.challenges) returns text language sql stable set search_path='' as $$
 select case when c.state='cancelled' then 'cancelled' when c.state='draft' or c.starts_at is null then 'draft'
  when clock_timestamp()<c.starts_at then 'upcoming' when clock_timestamp()<c.submissions_close_at then 'active'
  when clock_timestamp()<c.voting_ends_at then 'voting' else 'completed' end
$$;
revoke all on function sdi_private.challenge_phase(sdi_private.challenges) from public,anon;
grant execute on function sdi_private.challenge_phase(sdi_private.challenges) to authenticated,service_role;
-- An entry counts only while its exact approved rendition is still available.
create function sdi_private.challenge_entry_live(e sdi_private.challenge_entries) returns boolean language sql stable security definer set search_path='' as $$
 select not e.withdrawn and not sdi_private.creator_restricted(e.creator) and exists(select 1 from public.sdi_watch_media m
  where m.id=e.media_id and m.approved and m.owner_id=e.creator and m.render_digest=e.render_digest and (m.expires_at is null or m.expires_at>clock_timestamp()))
$$;
revoke all on function sdi_private.challenge_entry_live(sdi_private.challenge_entries) from public,anon;
grant execute on function sdi_private.challenge_entry_live(sdi_private.challenge_entries) to authenticated,service_role;

create function sdi_private.challenge_action(action text,challenge uuid default null,media uuid default null,entry uuid default null,
 title text default null,brief text default '',reward text default '',starts_at timestamptz default null,closes_at timestamptz default null,
 ends_at timestamptz default null,revision bigint default null,reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare actor uuid:=auth.uid(); n integer; c sdi_private.challenges; e sdi_private.challenge_entries; items jsonb; phase text; created uuid;
begin
 if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous) then
  return jsonb_build_object('error','Sign in with a full account.'); end if;
 insert into sdi_private.challenge_budget values(actor,clock_timestamp(),1)
 on conflict(user_id) do update set
 attempts=case when challenge_budget.starts_at<clock_timestamp()-interval '1 minute' then 1 else challenge_budget.attempts+1 end,
 starts_at=case when challenge_budget.starts_at<clock_timestamp()-interval '1 minute' then clock_timestamp() else challenge_budget.starts_at end
 returning attempts into n;
 if n>60 then return jsonb_build_object('error','Too many requests. Wait a minute.'); end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select ch.id,ch.title,ch.brief,ch.reward_text,ch.starts_at,ch.submissions_close_at,ch.voting_ends_at,ch.revision,sdi_private.challenge_phase(ch) as phase,
    (select count(*) from sdi_private.challenge_entries en where en.challenge_id=ch.id and sdi_private.challenge_entry_live(en)) as entry_count,
    exists(select 1 from sdi_private.challenge_entries en where en.challenge_id=ch.id and en.creator=actor and not en.withdrawn) as my_entry,
    res.outcome,res.winner_entry
   from sdi_private.challenges ch left join sdi_private.challenge_results res on res.challenge_id=ch.id
   where ch.state='scheduled' and ch.voting_ends_at>clock_timestamp()-interval '30 days'
   order by ch.starts_at limit 100
  ) item;
  return jsonb_build_object('challenges',items,'server_time',clock_timestamp());
 end if;
 if action='entries' then
  select * into c from sdi_private.challenges where id=challenge and state='scheduled';
  if not found then return jsonb_build_object('error','Challenge unavailable.'); end if;
  phase:=sdi_private.challenge_phase(c);
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select en.id,en.creator,m.title,m.url,en.created_at,
    case when phase in('voting','completed') then (select count(*) from sdi_private.challenge_votes v where v.entry_id=en.id) end as votes,
    exists(select 1 from sdi_private.challenge_votes v where v.entry_id=en.id and v.voter=actor) as my_vote
   from sdi_private.challenge_entries en join public.sdi_watch_media m on m.id=en.media_id
   where en.challenge_id=c.id and sdi_private.challenge_entry_live(en)
   and not exists(select 1 from sdi_private.feed_blocks b where (b.actor=actor and b.creator=en.creator) or (b.actor=en.creator and b.creator=actor))
   order by en.created_at limit 200
  ) item;
  return jsonb_build_object('phase',phase,'entries',items);
 end if;
 if action in('submit','withdraw','vote') then
  if action='withdraw' then
   select * into e from sdi_private.challenge_entries where id=entry and creator=actor for update;
   if not found then return jsonb_build_object('error','Entry unavailable.'); end if;
   challenge:=e.challenge_id;
  end if;
  select * into c from sdi_private.challenges where id=challenge and state='scheduled' for update;
  if not found then return jsonb_build_object('error','Challenge unavailable.'); end if;
  phase:=sdi_private.challenge_phase(c);
  if action='submit' then
   if phase<>'active' then return jsonb_build_object('error','Submissions are not open.'); end if;
   if not exists(select 1 from public.sdi_watch_media m where m.id=media and m.owner_id=actor and m.approved and m.render_digest is not null
    and (m.expires_at is null or m.expires_at>c.voting_ends_at)) then return jsonb_build_object('error','Select your approved rendered video available through voting.'); end if;
   select * into e from sdi_private.challenge_entries where challenge_id=c.id and creator=actor for update;
   if found and not e.withdrawn then return jsonb_build_object('error','One entry per creator. Withdraw it to change your entry.'); end if;
   if found then
    update sdi_private.challenge_entries set media_id=media,render_digest=(select render_digest from public.sdi_watch_media where id=media),withdrawn=false,created_at=clock_timestamp() where id=e.id;
   else
    insert into sdi_private.challenge_entries(challenge_id,creator,media_id,render_digest)
    select c.id,actor,m.id,m.render_digest from public.sdi_watch_media m where m.id=media;
   end if;
   return jsonb_build_object('status','entered');
  elsif action='withdraw' then
   if phase='completed' then return jsonb_build_object('error','This challenge is complete.'); end if;
   update sdi_private.challenge_entries set withdrawn=true where id=e.id;
   delete from sdi_private.challenge_votes where entry_id=e.id;
   return jsonb_build_object('status','withdrawn');
  else
   if phase<>'voting' then return jsonb_build_object('error','Voting is not open.'); end if;
   select * into e from sdi_private.challenge_entries where id=entry and challenge_id=c.id;
   if not found or not sdi_private.challenge_entry_live(e) then return jsonb_build_object('error','Entry unavailable.'); end if;
   if e.creator=actor or exists(select 1 from sdi_private.challenge_entries own where own.challenge_id=c.id and own.creator=actor and not own.withdrawn) then
    return jsonb_build_object('error','Participants cannot vote in their own challenge.'); end if;
   insert into sdi_private.challenge_votes(challenge_id,voter,entry_id) values(c.id,actor,e.id)
   on conflict(challenge_id,voter) do update set entry_id=excluded.entry_id,created_at=clock_timestamp();
   return jsonb_build_object('status','confirmed');
  end if;
 end if;
 -- Administrative lifecycle. Challenges are scheduled by moderators with MFA.
 if not sdi_private.admin_can('moderation') then return jsonb_build_object('error','Challenge administration requires current moderation permission and MFA.'); end if;
 if action='create' then
  if title is null or length(trim(title)) not between 1 and 100 or brief is null or length(brief)>2000 or reward is null or length(reward)>500 then
   return jsonb_build_object('error','A title, bounded brief and configured reward text are required.'); end if;
  insert into sdi_private.challenges(title,brief,reward_text,created_by) values(trim(title),brief,reward,actor) returning id into created;
  insert into sdi_private.challenge_audit(challenge_id,actor,action,reason) values(created,actor,'create','');
  return jsonb_build_object('status','created','challenge_id',created,'revision',1);
 end if;
 select * into c from sdi_private.challenges where id=challenge for update;
 if not found or revision is distinct from c.revision then return jsonb_build_object('error','Challenge changed. Refresh before acting.'); end if;
 if action='schedule' then
  if c.state='cancelled' or sdi_private.challenge_phase(c) in('voting','completed') then return jsonb_build_object('error','This challenge can no longer be rescheduled.'); end if;
  if starts_at is null or closes_at is null or ends_at is null or starts_at<clock_timestamp()-interval '5 minutes'
   or closes_at<starts_at+interval '1 hour' or ends_at<closes_at+interval '1 hour' or ends_at>starts_at+interval '60 days' then
   return jsonb_build_object('error','Provide future start, at least one hour of submissions, at least one hour of voting and at most sixty days overall.'); end if;
  update sdi_private.challenges set state='scheduled',starts_at=challenge_action.starts_at,submissions_close_at=closes_at,voting_ends_at=ends_at,revision=revision+1 where id=c.id;
 elsif action='cancel' then
  if reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','A cancellation reason is required.'); end if;
  update sdi_private.challenges set state='cancelled',revision=revision+1 where id=c.id;
 elsif action='remove_entry' then
  if entry is null or reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','Select an entry and give a reason.'); end if;
  update sdi_private.challenge_entries set withdrawn=true where id=entry and challenge_id=c.id;
  if not found then return jsonb_build_object('error','Entry unavailable.'); end if;
  delete from sdi_private.challenge_votes where entry_id=entry;
 else return jsonb_build_object('error','Unsupported challenge operation.'); end if;
 insert into sdi_private.challenge_audit(challenge_id,actor,action,reason) values(c.id,actor,action,coalesce(trim(reason),''));
 return jsonb_build_object('status','confirmed','revision',c.revision+1);
end $$;
revoke all on function sdi_private.challenge_action(text,uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,timestamptz,bigint,text) from public,anon;
grant execute on function sdi_private.challenge_action(text,uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,timestamptz,bigint,text) to authenticated;
create function public.sdi_challenge_action(action text,challenge uuid default null,media uuid default null,entry uuid default null,
 title text default null,brief text default '',reward text default '',starts_at timestamptz default null,closes_at timestamptz default null,
 ends_at timestamptz default null,revision bigint default null,reason text default '') returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.challenge_action(action,challenge,media,entry,title,brief,reward,starts_at,closes_at,ends_at,revision,reason)$$;
revoke all on function public.sdi_challenge_action(text,uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,timestamptz,bigint,text) from public,anon;
grant execute on function public.sdi_challenge_action(text,uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,timestamptz,bigint,text) to authenticated;

-- Scheduler-invoked finalization; a tie records no winner. No scheduler is installed here.
create function sdi_private.challenge_finalize() returns jsonb language plpgsql security definer set search_path='' as $$
declare c sdi_private.challenges; tally jsonb; top uuid; top_votes bigint; second bigint; completed integer:=0;
begin
 for c in select * from sdi_private.challenges where state='scheduled' and voting_ends_at<=clock_timestamp()
  and not exists(select 1 from sdi_private.challenge_results r where r.challenge_id=challenges.id) order by voting_ends_at for update skip locked limit 100 loop
  with live as (select e.id,e.creator,(select count(*) from sdi_private.challenge_votes v where v.entry_id=e.id) as votes
   from sdi_private.challenge_entries e where e.challenge_id=c.id and sdi_private.challenge_entry_live(e))
  select coalesce(jsonb_agg(jsonb_build_object('entry',id,'creator',creator,'votes',votes) order by votes desc,id),'[]'::jsonb),
   (array_agg(id order by votes desc,id))[1],(array_agg(votes order by votes desc,id))[1],(array_agg(votes order by votes desc,id))[2]
   into tally,top,top_votes,second from live;
  insert into sdi_private.challenge_results(challenge_id,tally,winner_entry,outcome) values(c.id,tally,
   case when top is not null and (second is null or top_votes>second) then top end,
   case when top is null then 'no_entries' when second is null or top_votes>second then 'winner' else 'tie' end);
  completed:=completed+1;
 end loop;
 return jsonb_build_object('completed',completed);
end $$;
revoke all on function sdi_private.challenge_finalize() from public,anon,authenticated;
grant execute on function sdi_private.challenge_finalize() to service_role;
create function public.sdi_challenge_finalize() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.challenge_finalize()$$;
revoke all on function public.sdi_challenge_finalize() from public,anon,authenticated;
grant execute on function public.sdi_challenge_finalize() to service_role;

-- Calendar month view: genuine scheduled challenge milestones and the caller's own
-- War Room deadlines inside a bounded range. No duplicate schedule storage.
create function sdi_private.calendar_range(range_start timestamptz,range_end timestamptz,page_size integer default 500) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); items jsonb;
begin
 if actor is null or not sdi_private.account_active() then return jsonb_build_object('error','Sign in to view the calendar.'); end if;
 if range_start is null or range_end is null or range_end<=range_start or range_end>range_start+interval '62 days'
  or page_size is null or page_size not between 1 and 500 then return jsonb_build_object('error','Choose a range of at most sixty-two days.'); end if;
 select coalesce(jsonb_agg(row_to_json(item) order by item.occurs_at,item.id),'[]'::jsonb) into items from (
  select * from (
   select 'challenge' as kind,c.id,c.title,m.occurs_at,m.milestone,sdi_private.challenge_phase(c) as status
   from sdi_private.challenges c cross join lateral (values(c.starts_at,'opens'),(c.submissions_close_at,'submissions_close'),(c.voting_ends_at,'voting_ends')) as m(occurs_at,milestone)
   where c.state='scheduled' and m.occurs_at>=range_start and m.occurs_at<range_end
   union all
   select 'war_match',w.id,coalesce(l.title,'Matchup'),w.ends_at,'voting_ends',w.status
   from sdi_private.war_matches w join public.sdi_watch_media l on l.id=w.left_media
   where actor in(w.creator,w.opponent) and w.status in('active','completed') and w.ends_at>=range_start and w.ends_at<range_end
  ) events order by occurs_at,id limit page_size
 ) item;
 return jsonb_build_object('items',items,'range_start',range_start,'range_end',range_end,'truncated',jsonb_array_length(items)>=page_size);
end $$;
revoke all on function sdi_private.calendar_range(timestamptz,timestamptz,integer) from public,anon;
grant execute on function sdi_private.calendar_range(timestamptz,timestamptz,integer) to authenticated;
create function public.sdi_calendar_range(range_start timestamptz,range_end timestamptz,page_size integer default 500) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.calendar_range(range_start,range_end,page_size)$$;
revoke all on function public.sdi_calendar_range(timestamptz,timestamptz,integer) from public,anon;
grant execute on function public.sdi_calendar_range(timestamptz,timestamptz,integer) to authenticated;
commit;
