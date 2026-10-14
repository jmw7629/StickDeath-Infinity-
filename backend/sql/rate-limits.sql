-- Unapplied candidate (#263). Install after worker-configuration.sql. Daily account
-- quotas for the paths the per-minute budgets do not bound: media transfer (intake
-- registrations and bytes), publication requests and room invitations. The limits
-- are owner configuration in sdi_private.resource_quotas (candidate defaults sized
-- for the existing single-project infrastructure, not measured capacity). Enforcement
-- is a BEFORE INSERT trigger, so every insert path is bounded, including service
-- paths; a refusal aborts the whole statement with SQLSTATE P0001 and a plain
-- message, and nothing partial is written. Members read their own usage with
-- sdi_quota_status; nothing here estimates provider cost or spends money. AI runs
-- are already bounded by agent daily run caps and monthly cost caps (agent-controls).
begin;
create table sdi_private.resource_quotas (
 key text primary key check(key in('upload_registrations','upload_bytes','publish_requests','room_invites')),
 per_day bigint not null check(per_day between 0 and 1099511627776),
 description text not null check(length(description) between 1 and 200),
 updated_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.resource_quotas enable row level security;
revoke all on sdi_private.resource_quotas from public,anon,authenticated;
insert into sdi_private.resource_quotas(key,per_day,description) values
 ('upload_registrations',20,'Render intake registrations per creator per rolling 24 hours'),
 ('upload_bytes',8589934592,'Registered render bytes per creator per rolling 24 hours (8 GiB)'),
 ('publish_requests',30,'Publication jobs created per creator per rolling 24 hours'),
 ('room_invites',50,'Room invitation codes created per room owner per rolling 24 hours');

create function sdi_private.quota(key text) returns bigint language sql stable security definer set search_path='' as $$
 select q.per_day from sdi_private.resource_quotas q where q.key=quota.key
$$;
revoke all on function sdi_private.quota(text) from public,anon,authenticated;

-- Invitations had no creation time; existing rows count as created at install.
alter table sdi_private.room_invites add column if not exists created_at timestamptz not null default clock_timestamp();
create index if not exists room_invites_created on sdi_private.room_invites(room_id,created_at);
create index if not exists upload_registrations_creator_created on sdi_private.upload_registrations(creator,created_at);
create index if not exists publish_jobs_creator_created on sdi_private.publish_jobs(creator,created_at);

create function sdi_private.enforce_upload_quota() returns trigger language plpgsql security definer set search_path='' as $$
declare used bigint; bytes bigint; incoming bigint;
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.creator::text,263));
 select count(*),coalesce(sum(case when (u.metadata->>'size') ~ '^[0-9]{1,13}$' then (u.metadata->>'size')::bigint else 0 end),0) into used,bytes
  from sdi_private.upload_registrations u where u.creator=new.creator and u.created_at>clock_timestamp()-interval '1 day';
 incoming:=case when (new.metadata->>'size') ~ '^[0-9]{1,13}$' then (new.metadata->>'size')::bigint else 0 end;
 if used>=sdi_private.quota('upload_registrations') then
  raise exception 'Daily upload limit reached. Try again tomorrow.' using errcode='P0001';
 end if;
 if bytes+incoming>sdi_private.quota('upload_bytes') then
  raise exception 'Daily upload size limit reached. Try again tomorrow.' using errcode='P0001';
 end if;
 return new;
end $$;
create trigger enforce_upload_quota before insert on sdi_private.upload_registrations for each row execute function sdi_private.enforce_upload_quota();

create function sdi_private.enforce_publish_quota() returns trigger language plpgsql security definer set search_path='' as $$
begin
 -- A duplicate request is left to the unique constraint (no new job, no quota use).
 if exists(select 1 from sdi_private.publish_jobs j where j.review_id=new.review_id and j.review_version=new.review_version and j.destination=new.destination) then
  return new; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.creator::text,264));
 if (select count(*) from sdi_private.publish_jobs j where j.creator=new.creator and j.created_at>clock_timestamp()-interval '1 day')>=sdi_private.quota('publish_requests') then
  raise exception 'Daily publishing limit reached. Try again tomorrow.' using errcode='P0001';
 end if;
 return new;
end $$;
create trigger enforce_publish_quota before insert on sdi_private.publish_jobs for each row execute function sdi_private.enforce_publish_quota();

create function sdi_private.enforce_invite_quota() returns trigger language plpgsql security definer set search_path='' as $$
declare owner uuid;
begin
 select r.owner_id into owner from public.sdi_rooms r where r.id=new.room_id;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(coalesce(owner,new.room_id)::text,265));
 if (select count(*) from sdi_private.room_invites i join public.sdi_rooms r on r.id=i.room_id
     where r.owner_id is not distinct from owner and i.created_at>clock_timestamp()-interval '1 day')>=sdi_private.quota('room_invites') then
  raise exception 'Daily invitation limit reached. Try again tomorrow.' using errcode='P0001';
 end if;
 return new;
end $$;
create trigger enforce_invite_quota before insert on sdi_private.room_invites for each row execute function sdi_private.enforce_invite_quota();
revoke all on function sdi_private.enforce_upload_quota(),sdi_private.enforce_publish_quota(),sdi_private.enforce_invite_quota() from public,anon,authenticated;

-- A member's own usage against each daily quota. Factual counts only.
create function sdi_private.quota_status() returns jsonb language plpgsql security definer set search_path='' as $$
declare me uuid:=auth.uid();
begin
 if me is null or not exists(select 1 from auth.sessions where user_id=me and id::text=auth.jwt()->>'session_id') then
  return jsonb_build_object('error','A current signed-in account is required.'); end if;
 return jsonb_build_object(
  'window','rolling 24 hours',
  'uploads',jsonb_build_object('used',(select count(*) from sdi_private.upload_registrations u where u.creator=me and u.created_at>clock_timestamp()-interval '1 day'),
   'limit',sdi_private.quota('upload_registrations')),
  'upload_bytes',jsonb_build_object('used',(select coalesce(sum(case when (u.metadata->>'size') ~ '^[0-9]{1,13}$' then (u.metadata->>'size')::bigint else 0 end),0)
   from sdi_private.upload_registrations u where u.creator=me and u.created_at>clock_timestamp()-interval '1 day'),'limit',sdi_private.quota('upload_bytes')),
  'publish_requests',jsonb_build_object('used',(select count(*) from sdi_private.publish_jobs j where j.creator=me and j.created_at>clock_timestamp()-interval '1 day'),
   'limit',sdi_private.quota('publish_requests')),
  'room_invites',jsonb_build_object('used',(select count(*) from sdi_private.room_invites i join public.sdi_rooms r on r.id=i.room_id where r.owner_id=me and i.created_at>clock_timestamp()-interval '1 day'),
   'limit',sdi_private.quota('room_invites')));
end $$;
revoke all on function sdi_private.quota_status() from public,anon;
grant execute on function sdi_private.quota_status() to authenticated;
create function public.sdi_quota_status() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.quota_status()$$;
revoke all on function public.sdi_quota_status() from public,anon;
grant execute on function public.sdi_quota_status() to authenticated;
commit;
