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
-- Handles are unique regardless of letter case (#224). A changed username must
-- follow the public handle rules the app enforces (CreatorHandle): 3-30 ASCII
-- letters, digits or underscores, starting with a letter or digit, not reserved.
-- Sign-up rows keep the original 1-80 character check until the member edits.
create unique index users_username_ci on public.users(lower(username)) where username is not null;
create function sdi_private.users_handle_rules() returns trigger language plpgsql set search_path='' as $$
begin
 if new.username is distinct from old.username then
  if new.username is null or new.username !~ '^[A-Za-z0-9][A-Za-z0-9_]{2,29}$'
   or lower(new.username) in('admin','administrator','owner','moderator','support','system','official',
    'stickdeath','stickdeathinfinity','sdi','spatter','root') then
   raise exception 'Choose a 3-30 character handle of letters, digits or underscores that is not reserved.' using errcode='23514';
  end if;
 end if;
 return new;
end $$;
create trigger users_handle_rules before update of username on public.users for each row execute function sdi_private.users_handle_rules();
-- Avatar storage (#224): a public-read bucket holding one bounded JPEG per member
-- at `<account>/avatar.jpg` (AvatarImagePolicy). Members may write, replace and
-- delete only their own object. Applied only where the Supabase storage schema
-- exists; the local SQL harness has no storage schema and skips this block.
do $avatars$
begin
 if to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null then
  execute $q$insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
   values('avatars','avatars',true,307200,array['image/jpeg'])
   on conflict(id) do update set public=true,file_size_limit=307200,allowed_mime_types=array['image/jpeg']$q$;
  execute $q$create policy avatars_owner_read on storage.objects for select to authenticated
   using (bucket_id='avatars' and name=(auth.uid()::text||'/avatar.jpg'))$q$;
  execute $q$create policy avatars_owner_insert on storage.objects for insert to authenticated
   with check (bucket_id='avatars' and name=(auth.uid()::text||'/avatar.jpg'))$q$;
  execute $q$create policy avatars_owner_update on storage.objects for update to authenticated
   using (bucket_id='avatars' and name=(auth.uid()::text||'/avatar.jpg'))
   with check (bucket_id='avatars' and name=(auth.uid()::text||'/avatar.jpg'))$q$;
  execute $q$create policy avatars_owner_delete on storage.objects for delete to authenticated
   using (bucket_id='avatars' and name=(auth.uid()::text||'/avatar.jpg'))$q$;
 end if;
end $avatars$;
commit;
