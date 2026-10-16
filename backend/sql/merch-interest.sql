-- Unapplied candidate. Install after security-audit-integrity.sql (needs admin-hardening.sql,
-- admin-users.sql and pgcrypto in extensions). Merch interest poll for the website's
-- "coming soon" store page (owner decision 2026-10-15: no Shopify until the community
-- wants it). Three things are counted, never invented: a store poll ("should we open the
-- SDI merch store?"), a thumbs up/down per gallery concept, and a thumbs up/down per
-- moderator-approved design idea. Visitors may suggest ideas; every idea starts pending
-- and only approved ideas are ever returned to the public.
--
-- Voter identity: a signed-in, active account votes as its user id. A browser without a
-- session sends a random UUID kept in its own localStorage; the server stores only an
-- HMAC-SHA256 of it under a server-held salt, so the stored key cannot be linked back to
-- the browser value without the salt. One vote per voter per target, changeable or
-- removable (value 0). Anonymous keys are free to mint, so anonymous totals are a
-- sentiment signal, not verified counts: totals report member and anonymous votes apart,
-- and per-key plus global per-minute/hour budgets bound abuse. No IP address, email,
-- name or device data is stored; the only free-text personal datum is an optional
-- public handle that the submitter types next to an idea.
--
-- This is the first surface the anon role may call. Exactly the three read/vote/suggest
-- wrappers are granted to anon; tests/080_rls_review.sql lists them explicitly and
-- tests/140_merch_interest.sql checks that anon can execute nothing else in sdi_private.
begin;
grant usage on schema sdi_private to anon;
-- Schema usage would otherwise let anon run any earlier sdi_private function still
-- executable by PUBLIC (today two trigger functions in users-profiles.sql). Move those
-- PUBLIC grants to authenticated so existing callers keep exactly what they had.
do $$
declare item record;
begin
 for item in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='sdi_private' and has_function_privilege('public',p.oid,'execute') loop
  execute format('revoke execute on function %s from public',item.sig);
  execute format('grant execute on function %s to authenticated',item.sig);
 end loop;
end $$;

create table sdi_private.merch_settings (
 id boolean primary key default true check(id),
 salt bytea not null default extensions.gen_random_bytes(32) check(length(salt)=32),
 voting_open boolean not null default true,
 suggestions_open boolean not null default true,
 voter_actions_per_minute integer not null default 30 check(voter_actions_per_minute between 1 and 600),
 anon_votes_per_minute integer not null default 600 check(anon_votes_per_minute between 0 and 100000),
 ideas_per_hour integer not null default 30 check(ideas_per_hour between 0 and 1000),
 ideas_per_voter_per_day integer not null default 3 check(ideas_per_voter_per_day between 0 and 50),
 pending_cap integer not null default 300 check(pending_cap between 0 and 10000),
 revision bigint not null default 1, updated_at timestamptz not null default clock_timestamp()
);
insert into sdi_private.merch_settings default values;

-- Gallery concepts on website/store.html; the slug is the image basename.
create table sdi_private.merch_concepts (
 slug text primary key check(slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug)<=60),
 title text not null check(length(title) between 1 and 80), active boolean not null default true,
 sort integer not null default 0
);
insert into sdi_private.merch_concepts(slug,title,sort) values
 ('super-beast-tee','Super Beast tee',1),('walk-in-the-park-poster','Walk in the Park poster',2),
 ('summoning-the-beast-hoodie','Summoning the Beast hoodie',3),('body-count-tee','Body Count tee',4),
 ('swat-tee','S.W.A.T. tee',5),('swat-cap','S.W.A.T. cap',6),('swat-patch','S.W.A.T. patch',7),
 ('escape-from-greenville-tee','Escape from Greenville tee',8),('greenville-mug','Greenville mug',9),
 ('green-gene-pin','Green Gene pin',10),('anti-auto-theft-tee','Anti-Auto Theft tee',11),
 ('stickzilla-poster','Stickzilla poster',12),('penitentiary-tee','StickDeath Penitentiary tee',13),
 ('stick-tour-tote','Stick Tour tote',14),('anger-management-mug','Anger Management mug',15),
 ('survivor-beanie','Survivor beanie',16),('super-beast-deck','Super Beast skate deck',17),
 ('swat-phone-case','S.W.A.T. phone case',18),('stickdeath-drip-hoodie','StickDeath drip hoodie',19),
 ('classic-splatter-tee','Classic splatter tee',20),('character-sticker-sheet','Character sticker sheet',21),
 ('series-enamel-pins','Series enamel pin set',22);

create table sdi_private.merch_ideas (
 id uuid primary key default gen_random_uuid(),
 title text not null check(length(title) between 3 and 80),
 description text not null check(length(description) between 10 and 500),
 handle text check(handle is null or handle ~ '^[A-Za-z0-9_.]{2,30}$'),
 status text not null default 'pending' check(status in('pending','approved','rejected')),
 submitter text not null check(submitter ~ '^(u:[0-9a-f-]{36}|k:[0-9a-f]{64})$'),
 submitter_user uuid references auth.users(id) on delete set null,
 idempotency_key uuid not null,
 moderated_by uuid references auth.users(id) on delete set null, moderated_at timestamptz,
 moderation_note text not null default '' check(length(moderation_note)<=500),
 revision bigint not null default 1, created_at timestamptz not null default clock_timestamp(),
 unique(submitter,idempotency_key)
);
create index merch_ideas_status on sdi_private.merch_ideas(status,created_at desc,id);
create index merch_ideas_submitter on sdi_private.merch_ideas(submitter,created_at);

create table sdi_private.merch_votes (
 voter text not null check(voter ~ '^(u:[0-9a-f-]{36}|k:[0-9a-f]{64})$'),
 voter_user uuid references auth.users(id) on delete cascade,
 member boolean not null,
 target_kind text not null check(target_kind in('store','concept','idea')),
 target_key text not null check(length(target_key) between 1 and 60),
 value smallint not null check(value in(-1,1)),
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 primary key(voter,target_kind,target_key),
 check((voter_user is null and voter like 'k:%' and not member) or (voter_user is not null and voter='u:'||voter_user::text))
);
create index merch_votes_target on sdi_private.merch_votes(target_kind,target_key);

-- Per-voter (anonymous key hash or account) and global budgets, like the *_budget tables.
create table sdi_private.merch_budget (
 voter text primary key, window_start timestamptz not null, attempts integer not null
);
create table sdi_private.merch_global_budget (
 bucket text primary key check(bucket in('anon_vote','idea')), window_start timestamptz not null, attempts integer not null
);
alter table sdi_private.merch_settings enable row level security;
alter table sdi_private.merch_concepts enable row level security;
alter table sdi_private.merch_ideas enable row level security;
alter table sdi_private.merch_votes enable row level security;
alter table sdi_private.merch_budget enable row level security;
alter table sdi_private.merch_global_budget enable row level security;
revoke all on sdi_private.merch_settings,sdi_private.merch_concepts,sdi_private.merch_ideas,sdi_private.merch_votes,
 sdi_private.merch_budget,sdi_private.merch_global_budget from public,anon,authenticated;

-- Resolves the caller to a voter id, or null. Accounts that are signed in but not
-- active (suspended, signed out) cannot fall back to an anonymous key.
create function sdi_private.merch_voter(voter_key uuid) returns text language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is not null then
  if not sdi_private.account_active() then return null; end if;
  return 'u:'||auth.uid()::text;
 end if;
 if voter_key is null then return null; end if;
 return 'k:'||encode(extensions.hmac(convert_to(voter_key::text,'UTF8'),(select s.salt from sdi_private.merch_settings s),'sha256'),'hex');
end $$;
revoke all on function sdi_private.merch_voter(uuid) from public,anon,authenticated;

create function sdi_private.merch_voter_ok(voter text) returns boolean language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 insert into sdi_private.merch_budget values(voter,clock_timestamp(),1)
 on conflict on constraint merch_budget_pkey do update set
 attempts=case when merch_budget.window_start<clock_timestamp()-interval '1 minute' then 1 else merch_budget.attempts+1 end,
 window_start=case when merch_budget.window_start<clock_timestamp()-interval '1 minute' then clock_timestamp() else merch_budget.window_start end
 returning attempts into n;
 return n<=(select s.voter_actions_per_minute from sdi_private.merch_settings s);
end $$;
revoke all on function sdi_private.merch_voter_ok(text) from public,anon,authenticated;

create function sdi_private.merch_global_ok(bucket text,window_length interval,cap integer) returns boolean language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 insert into sdi_private.merch_global_budget values(bucket,clock_timestamp(),1)
 on conflict on constraint merch_global_budget_pkey do update set
 attempts=case when merch_global_budget.window_start<clock_timestamp()-window_length then 1 else merch_global_budget.attempts+1 end,
 window_start=case when merch_global_budget.window_start<clock_timestamp()-window_length then clock_timestamp() else merch_global_budget.window_start end
 returning attempts into n;
 return n<=cap;
end $$;
revoke all on function sdi_private.merch_global_ok(text,interval,integer) from public,anon,authenticated;

create function sdi_private.merch_counts(kind text,key text) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind',kind,'key',key,
  'up',count(*) filter(where v.value=1),'down',count(*) filter(where v.value=-1),
  'member_up',count(*) filter(where v.value=1 and v.member),'member_down',count(*) filter(where v.value=-1 and v.member))
 from sdi_private.merch_votes v where v.target_kind=kind and v.target_key=key
$$;
revoke all on function sdi_private.merch_counts(text,text) from public,anon,authenticated;

-- Public read: store poll, every active concept (zeros included) and approved ideas.
create function sdi_private.merch_totals(voter_key uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare settings sdi_private.merch_settings; caller text; targets jsonb; ideas jsonb; mine jsonb:='{}'::jsonb;
begin
 select * into settings from sdi_private.merch_settings;
 caller:=sdi_private.merch_voter(voter_key);
 with t as (
  select 'store'::text kind,'open-store'::text key,0 sort
  union all select 'concept',c.slug,c.sort from sdi_private.merch_concepts c where c.active
 ), counted as (
  select t.kind,t.key,t.sort,
   count(v.*) filter(where v.value=1) up,count(v.*) filter(where v.value=-1) down,
   count(v.*) filter(where v.value=1 and v.member) member_up,count(v.*) filter(where v.value=-1 and v.member) member_down
  from t left join sdi_private.merch_votes v on v.target_kind=t.kind and v.target_key=t.key group by t.kind,t.key,t.sort
 ) select coalesce(jsonb_agg(jsonb_build_object('kind',kind,'key',key,'up',up,'down',down,'member_up',member_up,'member_down',member_down) order by sort),'[]'::jsonb)
 into targets from counted;
 select coalesce(jsonb_agg(item order by item_created desc),'[]'::jsonb) into ideas from (
  select jsonb_build_object('id',i.id,'title',i.title,'description',i.description,'handle',i.handle,'created_at',i.created_at,
   'up',count(v.*) filter(where v.value=1),'down',count(v.*) filter(where v.value=-1),
   'member_up',count(v.*) filter(where v.value=1 and v.member),'member_down',count(v.*) filter(where v.value=-1 and v.member)) item,
   i.created_at item_created
  from (select * from sdi_private.merch_ideas where status='approved' order by created_at desc,id limit 100) i
  left join sdi_private.merch_votes v on v.target_kind='idea' and v.target_key=i.id::text
  group by i.id,i.title,i.description,i.handle,i.created_at) x;
 if caller is not null then
  select coalesce(jsonb_object_agg(v.target_kind||':'||v.target_key,v.value),'{}'::jsonb) into mine
  from sdi_private.merch_votes v where v.voter=caller;
 end if;
 return jsonb_build_object('voting_open',settings.voting_open,'suggestions_open',settings.suggestions_open,
  'targets',targets,'ideas',ideas,'mine',mine,'signed_in',auth.uid() is not null,
  'note','Anonymous browser votes are a sentiment signal, not verified people; member_* counts signed-in accounts only.');
end $$;

create function sdi_private.merch_vote(target_kind text,target_key text,value integer,voter_key uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare settings sdi_private.merch_settings; caller text; member boolean:=false;
begin
 select * into settings from sdi_private.merch_settings;
 if not settings.voting_open then return jsonb_build_object('error','Voting is closed right now.','code','closed'); end if;
 if value is null or value not in(-1,0,1) then return jsonb_build_object('error','Vote up, down or clear.'); end if;
 if target_kind is null or target_key is null then return jsonb_build_object('error','Unknown vote target.'); end if;
 if target_kind='store' then
  if target_key<>'open-store' then return jsonb_build_object('error','Unknown vote target.'); end if;
 elsif target_kind='concept' then
  if not exists(select 1 from sdi_private.merch_concepts c where c.slug=target_key and c.active) then return jsonb_build_object('error','Unknown vote target.'); end if;
 elsif target_kind='idea' then
  if target_key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   or not exists(select 1 from sdi_private.merch_ideas i where i.id=target_key::uuid and i.status='approved') then
   return jsonb_build_object('error','Unknown vote target.'); end if;
 else return jsonb_build_object('error','Unknown vote target.'); end if;
 caller:=sdi_private.merch_voter(voter_key);
 if caller is null then return jsonb_build_object('error','Voting needs this browser''s voter key or an active signed-in account.','code','no_voter'); end if;
 if not sdi_private.merch_voter_ok(caller) then return jsonb_build_object('error','Too many votes from this browser. Wait a minute.','code','rate_limited'); end if;
 if caller like 'k:%' and not sdi_private.merch_global_ok('anon_vote',interval '1 minute',settings.anon_votes_per_minute) then
  return jsonb_build_object('error','Voting is busy. Try again in a minute.','code','rate_limited'); end if;
 if caller like 'u:%' then member:=exists(select 1 from auth.users u where u.id=auth.uid() and not u.is_anonymous); end if;
 if value=0 then
  delete from sdi_private.merch_votes v where v.voter=caller and v.target_kind=merch_vote.target_kind and v.target_key=merch_vote.target_key;
 else
  insert into sdi_private.merch_votes(voter,voter_user,member,target_kind,target_key,value)
  values(caller,case when caller like 'u:%' then auth.uid() end,member,target_kind,target_key,value)
  on conflict on constraint merch_votes_pkey do update set value=excluded.value,member=excluded.member,updated_at=clock_timestamp();
 end if;
 return jsonb_build_object('status','recorded','mine',value,'counts',sdi_private.merch_counts(target_kind,target_key));
end $$;

create function sdi_private.merch_suggest(title text,description text,handle text default null,idempotency uuid default null,voter_key uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare settings sdi_private.merch_settings; caller text; existing sdi_private.merch_ideas; clean_title text; clean_description text; clean_handle text;
begin
 select * into settings from sdi_private.merch_settings;
 if not settings.suggestions_open then return jsonb_build_object('error','Suggestions are closed right now.','code','closed'); end if;
 clean_title:=btrim(coalesce(title,'')); clean_description:=btrim(coalesce(description,''));
 clean_handle:=nullif(ltrim(btrim(coalesce(handle,'')),'@'),'');
 if idempotency is null then return jsonb_build_object('error','Missing request key. Reload the page and try again.'); end if;
 if length(clean_title) not between 3 and 80 or length(clean_description) not between 10 and 500 then
  return jsonb_build_object('error','Give the idea a title of 3 to 80 characters and a description of 10 to 500.'); end if;
 if clean_title ~ '[[:cntrl:]<>]' or translate(clean_description,E'\n','') ~ '[[:cntrl:]<>]' then
  return jsonb_build_object('error','Use plain text without angle brackets or control characters.'); end if;
 if (clean_title||' '||clean_description) ~* '(https?:|www\.|mailto:|@[a-z0-9-]+\.[a-z]{2,})' then
  return jsonb_build_object('error','Leave out links and email addresses; describe the design in words.'); end if;
 if clean_handle is not null and clean_handle !~ '^[A-Za-z0-9_.]{2,30}$' then
  return jsonb_build_object('error','A handle is 2 to 30 letters, digits, dots or underscores (optional).'); end if;
 caller:=sdi_private.merch_voter(voter_key);
 if caller is null then return jsonb_build_object('error','Suggestions need this browser''s voter key or an active signed-in account.','code','no_voter'); end if;
 select * into existing from sdi_private.merch_ideas i where i.submitter=caller and i.idempotency_key=idempotency;
 if found then return jsonb_build_object('status','duplicate','id',existing.id,'idea_status',existing.status); end if;
 if not sdi_private.merch_voter_ok(caller) then return jsonb_build_object('error','Too many requests from this browser. Wait a minute.','code','rate_limited'); end if;
 if (select count(*) from sdi_private.merch_ideas i where i.submitter=caller and i.created_at>clock_timestamp()-interval '1 day')>=settings.ideas_per_voter_per_day then
  return jsonb_build_object('error','Daily idea limit reached. Thanks; try again tomorrow.','code','rate_limited'); end if;
 if (select count(*) from sdi_private.merch_ideas i where i.status='pending')>=settings.pending_cap then
  return jsonb_build_object('error','The review queue is full. Try again later.','code','queue_full'); end if;
 if not sdi_private.merch_global_ok('idea',interval '1 hour',settings.ideas_per_hour) then
  return jsonb_build_object('error','Lots of ideas this hour. Try again later.','code','rate_limited'); end if;
 insert into sdi_private.merch_ideas(title,description,handle,submitter,submitter_user,idempotency_key)
 values(clean_title,clean_description,clean_handle,caller,case when caller like 'u:%' then auth.uid() end,idempotency) returning * into existing;
 return jsonb_build_object('status','pending','id',existing.id,
  'message','Thanks. A moderator reviews every idea before it appears on the page.');
end $$;

-- Moderation and results for administrators with the moderation capability (MFA, live
-- session, rate limit; decisions and settings need a recent second factor).
create function sdi_private.merch_moderate(action text,idea uuid default null,decision text default null,note text default '',
 revision bigint default null,page integer default 0,status text default 'pending',voting_open boolean default null,suggestions_open boolean default null) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare denial jsonb; items jsonb; existing sdi_private.merch_ideas; settings sdi_private.merch_settings;
begin
 if action in('queue','results') then
  denial:=sdi_private.admin_gate('merch_moderate.'||action,'moderation',false,120);
 elsif action in('decide','settings') then
  denial:=sdi_private.admin_gate('merch_moderate.'||action,'moderation',true,30);
 else return jsonb_build_object('error','Unsupported merch operation.'); end if;
 if denial is not null then return denial; end if;
 if action='queue' then
  if page is null or page not between 0 and 199 or status is null or status not in('pending','approved','rejected') then
   return jsonb_build_object('error','Invalid page or status.'); end if;
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select i.id,i.title,i.description,i.handle,i.status,i.revision,i.created_at,i.moderated_at,i.moderation_note,
    case when i.submitter like 'u:%' then 'member' else 'anonymous' end submitter_kind
   from sdi_private.merch_ideas i where i.status=merch_moderate.status
   order by case when merch_moderate.status='pending' then i.created_at end asc,i.created_at desc,i.id limit 50 offset page*50) item;
  return jsonb_build_object('ideas',items,'has_more',jsonb_array_length(items)=50);
 elsif action='results' then
  select * into settings from sdi_private.merch_settings;
  select coalesce(jsonb_agg(row_to_json(r) order by r.kind,r.up-r.down desc,r.key),'[]'::jsonb) into items from (
   select v.target_kind kind,v.target_key key,
    case when v.target_kind='concept' then (select c.title from sdi_private.merch_concepts c where c.slug=v.target_key)
     when v.target_kind='idea' then (select i.title from sdi_private.merch_ideas i where i.id::text=v.target_key) else 'Open the SDI merch store' end title,
    count(*) filter(where v.value=1) up,count(*) filter(where v.value=-1) down,
    count(*) filter(where v.value=1 and v.member) member_up,count(*) filter(where v.value=-1 and v.member) member_down,
    count(*) filter(where v.updated_at>clock_timestamp()-interval '7 days') changed_last_7_days
   from sdi_private.merch_votes v group by v.target_kind,v.target_key) r;
  return jsonb_build_object('targets',items,
   'distinct_voters',(select count(distinct v.voter) from sdi_private.merch_votes v),
   'distinct_members',(select count(distinct v.voter) from sdi_private.merch_votes v where v.member),
   'ideas',(select jsonb_build_object('pending',count(*) filter(where i.status='pending'),'approved',count(*) filter(where i.status='approved'),
     'rejected',count(*) filter(where i.status='rejected')) from sdi_private.merch_ideas i),
   'settings',jsonb_build_object('voting_open',settings.voting_open,'suggestions_open',settings.suggestions_open,'revision',settings.revision),
   'note','Anonymous votes come from browser keys anyone can reset; weigh member_* counts accordingly.');
 elsif action='decide' then
  if idea is null or revision is null or decision is null or decision not in('approved','rejected') or note is null or length(btrim(note))>500 then
   return jsonb_build_object('error','Select an idea, approve or reject, and keep the note under 500 characters.'); end if;
  select * into existing from sdi_private.merch_ideas i where i.id=idea for update;
  if not found or existing.revision<>revision then return jsonb_build_object('error','Idea changed or missing. Refresh the queue.'); end if;
  update sdi_private.merch_ideas set status=decision,moderated_by=auth.uid(),moderated_at=clock_timestamp(),moderation_note=btrim(note),
   revision=merch_ideas.revision+1 where id=existing.id;
  if decision='rejected' then delete from sdi_private.merch_votes v where v.target_kind='idea' and v.target_key=existing.id::text; end if;
  insert into sdi_private.admin_access_audit(actor,operation,allowed,detail) values(auth.uid(),'merch_moderate.decide',true,decision||':'||existing.id::text);
  return jsonb_build_object('status','confirmed','revision',existing.revision+1);
 else
  select * into settings from sdi_private.merch_settings for update;
  if revision is null or settings.revision<>revision or (voting_open is null and suggestions_open is null) then
   return jsonb_build_object('error','Settings changed or nothing to change. Refresh.'); end if;
  update sdi_private.merch_settings set voting_open=coalesce(merch_moderate.voting_open,merch_settings.voting_open),
   suggestions_open=coalesce(merch_moderate.suggestions_open,merch_settings.suggestions_open),revision=merch_settings.revision+1,updated_at=clock_timestamp();
  insert into sdi_private.admin_access_audit(actor,operation,allowed,detail)
  values(auth.uid(),'merch_moderate.settings',true,'voting='||coalesce(voting_open::text,'-')||' suggestions='||coalesce(suggestions_open::text,'-'));
  return jsonb_build_object('status','confirmed','revision',settings.revision+1);
 end if;
end $$;

-- Service sweep: budget rows older than a day and rejected ideas after 30 days.
create function sdi_private.merch_retention() returns integer language plpgsql security definer set search_path='' as $$
declare n integer; m integer;
begin
 delete from sdi_private.merch_budget where window_start<clock_timestamp()-interval '1 day';
 get diagnostics n=row_count;
 delete from sdi_private.merch_ideas where status='rejected' and moderated_at<clock_timestamp()-interval '30 days';
 get diagnostics m=row_count;
 return n+m;
end $$;

revoke all on function sdi_private.merch_totals(uuid),sdi_private.merch_vote(text,text,integer,uuid),
 sdi_private.merch_suggest(text,text,text,uuid,uuid) from public;
grant execute on function sdi_private.merch_totals(uuid),sdi_private.merch_vote(text,text,integer,uuid),
 sdi_private.merch_suggest(text,text,text,uuid,uuid) to anon,authenticated;
revoke all on function sdi_private.merch_moderate(text,uuid,text,text,bigint,integer,text,boolean,boolean) from public,anon;
grant execute on function sdi_private.merch_moderate(text,uuid,text,text,bigint,integer,text,boolean,boolean) to authenticated;
revoke all on function sdi_private.merch_retention() from public,anon,authenticated;
grant execute on function sdi_private.merch_retention() to service_role;

create function public.sdi_merch_totals(voter_key uuid default null) returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.merch_totals(voter_key)$$;
create function public.sdi_merch_vote(target_kind text,target_key text,value integer,voter_key uuid default null) returns jsonb
language sql security invoker set search_path='' as $$ select sdi_private.merch_vote(target_kind,target_key,value,voter_key)$$;
create function public.sdi_merch_suggest(title text,description text,handle text default null,idempotency uuid default null,voter_key uuid default null) returns jsonb
language sql security invoker set search_path='' as $$ select sdi_private.merch_suggest(title,description,handle,idempotency,voter_key)$$;
create function public.sdi_merch_moderate(action text,idea uuid default null,decision text default null,note text default '',
 revision bigint default null,page integer default 0,status text default 'pending',voting_open boolean default null,suggestions_open boolean default null) returns jsonb
language sql security invoker set search_path='' as $$ select sdi_private.merch_moderate(action,idea,decision,note,revision,page,status,voting_open,suggestions_open)$$;
create function public.sdi_merch_retention() returns integer language sql security invoker set search_path='' as $$ select sdi_private.merch_retention()$$;
revoke all on function public.sdi_merch_totals(uuid),public.sdi_merch_vote(text,text,integer,uuid),
 public.sdi_merch_suggest(text,text,text,uuid,uuid) from public;
grant execute on function public.sdi_merch_totals(uuid),public.sdi_merch_vote(text,text,integer,uuid),
 public.sdi_merch_suggest(text,text,text,uuid,uuid) to anon,authenticated;
revoke all on function public.sdi_merch_moderate(text,uuid,text,text,bigint,integer,text,boolean,boolean) from public,anon;
grant execute on function public.sdi_merch_moderate(text,uuid,text,text,bigint,integer,text,boolean,boolean) to authenticated;
revoke all on function public.sdi_merch_retention() from public,anon,authenticated;
grant execute on function public.sdi_merch_retention() to service_role;
commit;
