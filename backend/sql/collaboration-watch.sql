-- Deployment candidate, not applied. Shared project-room identity for collaboration
-- and synchronized viewing. No drafts, media binaries or user communications.
begin;
create schema if not exists sdi_private;
revoke all on schema sdi_private from public;
grant usage on schema sdi_private to authenticated;
create table public.sdi_rooms (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 title text not null check (length(trim(title)) between 1 and 100),
 closed boolean not null default false,
 created_at timestamptz not null default now()
);
create table public.sdi_room_members (
 room_id uuid not null references public.sdi_rooms(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 owner_approved boolean not null default false,
 member_accepted boolean not null default false,
 revoked boolean not null default false,
 primary key(room_id,user_id)
);
-- Private lookup avoids recursive membership RLS. Never accepts an arbitrary
-- subject; every read is evaluated against the current JWT identity.
create function sdi_private.room_access(r uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists (
  select 1 from public.sdi_rooms room where room.id=r and not room.closed
  and (room.owner_id=auth.uid() or exists (
   select 1 from public.sdi_room_members m where m.room_id=r and m.user_id=auth.uid()
   and m.owner_approved and m.member_accepted and not m.revoked)))
$$;
create function sdi_private.room_owner(r uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists (
  select 1 from public.sdi_rooms where id=r and owner_id=auth.uid() and not closed)
$$;
revoke all on function sdi_private.room_access(uuid), sdi_private.room_owner(uuid) from public;
grant execute on function sdi_private.room_access(uuid), sdi_private.room_owner(uuid) to authenticated;
alter table public.sdi_rooms enable row level security;
alter table public.sdi_room_members enable row level security;
create policy room_read on public.sdi_rooms for select to authenticated using (sdi_private.room_access(id));
create policy room_create on public.sdi_rooms for insert to authenticated with check (owner_id=auth.uid());
create policy room_update on public.sdi_rooms for update to authenticated using (owner_id=auth.uid()) with check(owner_id=auth.uid());
create policy member_read on public.sdi_room_members for select to authenticated using (user_id=auth.uid() or sdi_private.room_owner(room_id));
-- Membership creation/consent uses narrowly validated service operations. No
-- direct client mutation can self-approve, forge consent, or undo revocation.
revoke all on public.sdi_rooms, public.sdi_room_members from public, anon, authenticated;
grant select,insert on public.sdi_rooms to authenticated;
grant update(title,closed) on public.sdi_rooms to authenticated;
grant select on public.sdi_room_members to authenticated;

-- Only the publication service inserts approved, rights-cleared public renditions.
-- Private media needs a separately authorized short-lived delivery service.
create table public.sdi_watch_media (
 id uuid primary key default gen_random_uuid(),
 title text not null check(length(title) between 1 and 200),
 url text not null check(url ~ '^https://'),
 duration double precision not null check(duration > 0 and duration <= 3600),
 approved boolean not null default false,
 expires_at timestamptz
);
alter table public.sdi_watch_media enable row level security;
create policy media_read on public.sdi_watch_media for select to authenticated using (approved and (expires_at is null or expires_at>now()));
revoke all on public.sdi_watch_media from public, anon, authenticated;
grant select on public.sdi_watch_media to authenticated;
create table public.sdi_watch_sessions (
 id uuid primary key default gen_random_uuid(),
 room_id uuid not null unique references public.sdi_rooms(id) on delete cascade,
 media_id uuid not null references public.sdi_watch_media(id),
 position double precision not null default 0 check(position >= 0 and position <= 3600),
 playing boolean not null default false,
 revision bigint not null default 0,
 updated_at timestamptz not null default clock_timestamp()
);
alter table public.sdi_watch_sessions enable row level security;
create policy watch_read on public.sdi_watch_sessions for select to authenticated using(sdi_private.room_access(room_id));
create policy watch_create on public.sdi_watch_sessions for insert to authenticated with check(sdi_private.room_owner(room_id) and exists(select 1 from public.sdi_watch_media where id=media_id));
create policy watch_update on public.sdi_watch_sessions for update to authenticated using(sdi_private.room_owner(room_id)) with check(sdi_private.room_owner(room_id) and exists(select 1 from public.sdi_watch_media where id=media_id));
create function sdi_private.watch_stamp() returns trigger language plpgsql set search_path='' as $$
begin
 if TG_OP='UPDATE' then new.revision=old.revision+1;
 else new.revision=0; end if;
 new.updated_at=clock_timestamp();
 return new;
end $$;
revoke all on function sdi_private.watch_stamp() from public;
create trigger watch_stamp before insert or update on public.sdi_watch_sessions for each row execute function sdi_private.watch_stamp();
revoke all on public.sdi_watch_sessions from public, anon, authenticated;
grant select,insert on public.sdi_watch_sessions to authenticated;
grant update(position,playing,media_id) on public.sdi_watch_sessions to authenticated;
commit;
