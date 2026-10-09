-- Unapplied candidate. Requires collaboration-watch.sql and pgcrypto in extensions.
begin;
create table sdi_private.room_invites (
 id uuid primary key default gen_random_uuid(), room_id uuid not null references public.sdi_rooms(id) on delete cascade,
 token_hash bytea not null unique, expires_at timestamptz not null,
 remaining integer not null check(remaining between 0 and 20), revoked boolean not null default false
);
create table sdi_private.room_request_budget (
 user_id uuid primary key references auth.users(id) on delete cascade,
 window_start timestamptz not null, attempts integer not null
);
create table sdi_private.room_blocks (
 room_id uuid not null references public.sdi_rooms(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 primary key(room_id,user_id)
);
alter table public.sdi_room_members add column request_expires_at timestamptz;
alter table sdi_private.room_invites enable row level security;
alter table sdi_private.room_request_budget enable row level security;
alter table sdi_private.room_blocks enable row level security;
revoke all on sdi_private.room_invites,sdi_private.room_request_budget,sdi_private.room_blocks from public,anon,authenticated;
-- One bounded operation boundary. Token inputs must be redacted by gateway logs.
create function sdi_private.room_action(action text, room uuid default null, subject uuid default null,
 code text default null, title text default null, consent boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 actor uuid := auth.uid(); invitation sdi_private.room_invites; secret text;
 target public.sdi_rooms; count_attempts integer; created uuid;
begin
 if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous)
 then return jsonb_build_object('error','Sign in with a full account.'); end if;
 insert into sdi_private.room_request_budget values(actor,clock_timestamp(),1)
 on conflict(user_id) do update set
 attempts=case when sdi_private.room_request_budget.window_start < clock_timestamp()-interval '1 minute' then 1 else sdi_private.room_request_budget.attempts+1 end,
 window_start=case when sdi_private.room_request_budget.window_start < clock_timestamp()-interval '1 minute' then clock_timestamp() else sdi_private.room_request_budget.window_start end
 returning attempts into count_attempts;
 -- Return errors rather than raising so attempted operations remain rate counted.
 if count_attempts>30 then return jsonb_build_object('error','Too many requests. Wait a minute.'); end if;
 if action='create' then
  if title is null or length(trim(title)) not between 1 and 100 or not consent then
   return jsonb_build_object('error','A room name and explicit consent are required.'); end if;
  if (select count(*) from public.sdi_rooms where owner_id=actor and not closed)>=20 then
   return jsonb_build_object('error','Close an existing room before creating another.'); end if;
  insert into public.sdi_rooms(owner_id,title) values(actor,trim(title)) returning id into created;
  return jsonb_build_object('room_id',created,'status','created');
 end if;
 if action in ('preview','request') then
  if code is null or length(code)<>64 then return jsonb_build_object('error','Invitation is unavailable.'); end if;
  select * into invitation from sdi_private.room_invites where token_hash=extensions.digest(code,'sha256') for update;
  if not found or invitation.revoked or invitation.remaining<=0 or invitation.expires_at<=clock_timestamp() then
   return jsonb_build_object('error','Invitation is unavailable.'); end if;
  select * into target from public.sdi_rooms where id=invitation.room_id and not closed for update;
  if not found or exists(select 1 from sdi_private.room_blocks where room_id=invitation.room_id and user_id=actor) then
   return jsonb_build_object('error','Invitation is unavailable.'); end if;
  if action='preview' then return jsonb_build_object('room_id',target.id,'title',target.title,'status','preview'); end if;
  if not consent then return jsonb_build_object('error','Accept the room invitation first.'); end if;
  if target.owner_id=actor then return jsonb_build_object('error','You already own this room.'); end if;
  if exists(select 1 from public.sdi_room_members where room_id=target.id and user_id=actor and not revoked) then
   return jsonb_build_object('status','already_requested','room_id',target.id); end if;
  if (select count(*) from public.sdi_room_members where room_id=target.id and not revoked)>=50 then
   return jsonb_build_object('error','This room has reached its member limit.'); end if;
  insert into public.sdi_room_members(room_id,user_id,member_accepted,owner_approved,revoked,request_expires_at)
  values(target.id,actor,true,false,false,invitation.expires_at)
  on conflict(room_id,user_id) do update set member_accepted=true,owner_approved=false,revoked=false,request_expires_at=excluded.request_expires_at;
  update sdi_private.room_invites set remaining=remaining-1 where id=invitation.id;
  return jsonb_build_object('status','pending_owner_approval','room_id',target.id);
 end if;
 select * into target from public.sdi_rooms where id=room and not closed for update;
 if not found then return jsonb_build_object('error','Room is unavailable.'); end if;
 if action='leave' and target.owner_id<>actor then
  update public.sdi_room_members set revoked=true,member_accepted=false,owner_approved=false where room_id=room and user_id=actor;
  return jsonb_build_object('status','left');
 end if;
 if target.owner_id<>actor then return jsonb_build_object('error','Only the owner can perform this operation.'); end if;
 if action='invite' then
  update public.sdi_room_members set revoked=true where room_id=room and not owner_approved;
  update sdi_private.room_invites set revoked=true where room_id=room;
  secret=encode(extensions.gen_random_bytes(32),'hex');
  insert into sdi_private.room_invites(room_id,token_hash,expires_at,remaining)
  values(room,extensions.digest(secret,'sha256'),clock_timestamp()+interval '24 hours',20);
  return jsonb_build_object('status','invitation_created','code',secret);
 elsif action='revoke_invites' then
  update sdi_private.room_invites set revoked=true where room_id=room;
  update public.sdi_room_members set revoked=true where room_id=room and not owner_approved;
 elsif action='approve' then
  update public.sdi_room_members set owner_approved=true where room_id=room and user_id=subject
  and member_accepted and not revoked and request_expires_at>clock_timestamp()
  and not exists(select 1 from sdi_private.room_blocks where room_id=room and user_id=subject);
  if not found then return jsonb_build_object('error','The pending request expired or is unavailable.'); end if;
 elsif action in ('remove','block') then
  update public.sdi_room_members set revoked=true,owner_approved=false where room_id=room and user_id=subject;
  if action='block' and subject is not null then insert into sdi_private.room_blocks values(room,subject) on conflict do nothing; end if;
 elsif action='close' then
  update public.sdi_rooms set closed=true where id=room;
  update sdi_private.room_invites set revoked=true where room_id=room;
 else return jsonb_build_object('error','Unsupported room operation.');
 end if;
 return jsonb_build_object('status','updated');
end $$;
revoke all on function sdi_private.room_action(text,uuid,uuid,text,text,boolean) from public;
grant execute on function sdi_private.room_action(text,uuid,uuid,text,text,boolean) to authenticated;
create function public.sdi_room_action(action text,room uuid default null,subject uuid default null,
 code text default null,title text default null,consent boolean default false) returns jsonb
language sql security invoker set search_path='' as $$
 select sdi_private.room_action(action,room,subject,code,title,consent)
$$;
revoke all on function public.sdi_room_action(text,uuid,uuid,text,text,boolean) from public,anon;
grant execute on function public.sdi_room_action(text,uuid,uuid,text,text,boolean) to authenticated;
-- Only the bounded operation permits room creation/closure; no bypass via REST.
revoke insert,update on public.sdi_rooms from authenticated;
revoke update(title,closed) on public.sdi_rooms from authenticated;
commit;
