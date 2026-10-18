-- Local test stubs for vanilla PostgreSQL 16. NOT a deployment artifact.
-- Supabase supplies all of this in production: the anon/authenticated/service_role
-- roles, the auth schema (users, sessions, identities, mfa_factors), auth.uid(),
-- auth.jwt() reading request.jwt.claims, and pgcrypto in the extensions schema.
-- Everything below is the minimum the candidate SQL references; nothing here is
-- a claim about the live project's schema.
begin;
do $$ begin
 if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
 if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
 if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema extensions;
create extension if not exists pgcrypto with schema extensions;
grant usage on schema extensions to public;
create schema auth;
create table auth.users (
 id uuid primary key default gen_random_uuid(), email text, is_anonymous boolean not null default false,
 raw_user_meta_data jsonb not null default '{}', raw_app_meta_data jsonb not null default '{}', created_at timestamptz not null default clock_timestamp(),
 last_sign_in_at timestamptz, email_confirmed_at timestamptz
);
create table auth.sessions (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default clock_timestamp(), aal text
);
create table auth.identities (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 provider text not null
);
create table auth.mfa_factors (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 factor_type text not null, status text not null check(status in('unverified','verified'))
);
grant usage on schema auth to anon,authenticated,service_role;
grant select on auth.users,auth.sessions,auth.identities,auth.mfa_factors to service_role;
-- Supabase reads these claims from the verified JWT; tests set them per statement.
create function auth.jwt() returns jsonb language sql stable as $$
 select nullif(current_setting('request.jwt.claims',true),'')::jsonb
$$;
create function auth.uid() returns uuid language sql stable as $$
 select nullif(auth.jwt()->>'sub','')::uuid
$$;
grant execute on function auth.jwt(),auth.uid() to public;

-- Test-only helpers. They never exist in a deployment.
create schema sdi_test;
create function sdi_test.check(ok boolean, message text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'ASSERTION FAILED: %', message; end if;
end $$;
create function sdi_test.user(label text, anonymous boolean default false) returns uuid language plpgsql as $$
declare id uuid;
begin
 insert into auth.users(email,is_anonymous,raw_user_meta_data,email_confirmed_at)
 values(label||'@example.test',anonymous,jsonb_build_object('username',label),case when anonymous then null else clock_timestamp() end)
 returning users.id into id;
 return id;
end $$;
-- Sets JWT claims for the rest of the current transaction: a live session row,
-- the requested assurance level and optional AMR timestamps for step-up checks.
create function sdi_test.login(subject uuid, aal text default 'aal1', mfa_age_seconds integer default null) returns uuid language plpgsql as $$
declare session uuid; claims jsonb;
begin
 insert into auth.sessions(user_id,aal) values(subject,aal) returning id into session;
 claims:=jsonb_build_object('sub',subject,'role','authenticated','aal',aal,'session_id',session,
  'amr',case when mfa_age_seconds is null then '[]'::jsonb else jsonb_build_array(
   jsonb_build_object('method','totp','timestamp',floor(extract(epoch from clock_timestamp()))::bigint-mfa_age_seconds)) end);
 perform set_config('request.jwt.claims',claims::text,true);
 return session;
end $$;
create function sdi_test.logout() returns void language sql as $$
 select set_config('request.jwt.claims','',true)
$$;
create function sdi_test.admin(label text, owner boolean, permissions text[]) returns uuid language plpgsql as $$
declare id uuid;
begin
 id:=sdi_test.user(label);
 insert into sdi_private.admin_roles(user_id,enabled,owner,permissions) values(id,true,owner,permissions);
 return id;
end $$;
-- Runs a statement as another role and reports whether it was refused for privilege.
create function sdi_test.denied(role_name text, statement text) returns boolean language plpgsql as $$
begin
 execute format('set local role %I',role_name);
 begin
  execute statement;
 exception when insufficient_privilege then
  reset role; return true;
 end;
 reset role; return false;
end $$;
commit;
