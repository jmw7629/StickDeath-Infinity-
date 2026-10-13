-- Unapplied candidate. Install last. The member profile row the native app reads and
-- writes as `users` (Models.swift `UserProfile`, AuthService): the member inserts their
-- own row after sign-up and may edit only the editable columns; `role` and
-- `subscription_tier` are server-owned and never client-writable. Administrator
-- authority lives in sdi_private.admin_roles, never in this row. Rows are private to
-- their member; community surfaces carry creator names as snapshots of their own.
begin;
create table public.users (
 id uuid primary key references auth.users(id) on delete cascade,
 email text check(email is null or (length(email) between 3 and 254 and position('@' in email)>1)),
 username text unique check(username is null or length(trim(username)) between 1 and 80),
 bio text not null default '' check(length(bio)<=2000),
 avatar_url text check(avatar_url is null or avatar_url ~ '^https://[^ ]{1,2000}$'),
 role text not null default 'user' check(role in('user','creator','moderator','superadmin')),
 subscription_tier text check(subscription_tier is null or subscription_tier in('free','monthly_4_99','monthly_9_99')),
 onboarded boolean not null default false,
 skill_level text check(skill_level is null or length(skill_level)<=40),
 interests text[] not null default '{}' check(cardinality(interests)<=20),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.users enable row level security;
revoke all on public.users from public,anon;
grant select on public.users to authenticated;
grant insert(id,email,username,bio,avatar_url,onboarded,skill_level,interests) on public.users to authenticated;
grant update(username,bio,avatar_url,onboarded,skill_level,interests) on public.users to authenticated;
create policy users_read_own on public.users for select to authenticated using (id=auth.uid());
create policy users_insert_own on public.users for insert to authenticated with check (id=auth.uid());
create policy users_update_own on public.users for update to authenticated using (id=auth.uid()) with check (id=auth.uid());
create function sdi_private.users_touch() returns trigger language plpgsql set search_path='' as $$
begin new.updated_at=clock_timestamp(); return new; end $$;
create trigger users_touch before update on public.users for each row execute function sdi_private.users_touch();
commit;
