-- Unapplied candidate. Requires upload-registration.sql and upload-preview.sql.
begin;
create table sdi_private.preview_permits (
 id uuid primary key default gen_random_uuid(), actor uuid not null references auth.users(id), session_id text not null,
 review_id uuid not null references sdi_private.render_reviews(id), review_version bigint not null, digest text not null,
 expires_at timestamptz not null, consumed boolean not null default false
);
alter table sdi_private.preview_permits enable row level security;
revoke all on sdi_private.preview_permits from public,anon,authenticated;
create function sdi_private.preview_permit(review uuid,digest text,version bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; a sdi_private.render_artifacts; u sdi_private.upload_registrations; permit uuid;
begin
 if not sdi_private.admin_can('reviews') or not sdi_private.account_active() then
  return jsonb_build_object('error','Current review permission and MFA required.');end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(auth.uid()::text,811));
 delete from sdi_private.preview_permits where actor=auth.uid() and expires_at<clock_timestamp();
 if (select count(*) from sdi_private.preview_permits where actor=auth.uid())>=20 then
  return jsonb_build_object('error','Too many preview requests. Wait one minute.');end if;
 select * into r from sdi_private.render_reviews where id=review;
 if not found or r.version<>version or r.render_digest<>digest or length(r.consent_version)=0
  or cardinality(r.destinations)=0 or r.state not in('pending','approved','changes') then
  return jsonb_build_object('error','This review changed or is unavailable.');end if;
 select * into a from sdi_private.render_artifacts where review_id=r.id and render_artifacts.version=r.version
  and render_digest=r.render_digest and expires_at>clock_timestamp();
 if not found then return jsonb_build_object('error','The retained render has expired. Request a new upload.');end if;
 select * into u from sdi_private.upload_registrations where review_id=r.id;
 if not found then return jsonb_build_object('error','Preview renewal is unavailable for this legacy render.');end if;
 insert into sdi_private.preview_permits(actor,session_id,review_id,review_version,digest,expires_at)
 values(auth.uid(),auth.jwt()->>'session_id',r.id,r.version,r.render_digest,clock_timestamp()+interval '1 minute') returning id into permit;
 return jsonb_build_object('permit',permit,'upload',u.upload_id,'creator',r.creator,'digest',r.render_digest,'byte_count',a.byte_count);
end $$;
revoke all on function sdi_private.preview_permit(uuid,text,bigint) from public,anon;
grant execute on function sdi_private.preview_permit(uuid,text,bigint) to authenticated;
create function public.sdi_preview_permit(review uuid,digest text,version bigint) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.preview_permit(review,digest,version)$$;
revoke all on function public.sdi_preview_permit(uuid,text,bigint) from public,anon;
grant execute on function public.sdi_preview_permit(uuid,text,bigint) to authenticated;

-- Only the trusted host signer can fulfill a permit; clients cannot replace a
-- preview with their own URL or extend artifact retention.
create function sdi_private.preview_renew(permit uuid,url text,expires timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p sdi_private.preview_permits; r sdi_private.render_reviews;
begin
 select * into p from sdi_private.preview_permits where id=permit for update;
 if not found or p.consumed or p.expires_at<=clock_timestamp() or url is null or url !~ '^https://'
  or length(url)>4096 or expires is null or expires<=clock_timestamp() or expires>clock_timestamp()+interval '15 minutes' then
  return jsonb_build_object('error','Preview permission expired.');end if;
 if not exists(select 1 from auth.sessions where user_id=p.actor and id::text=p.session_id)
  or not exists(select 1 from sdi_private.admin_roles where user_id=p.actor and enabled and (owner or 'reviews'=any(permissions)))
  or exists(select 1 from sdi_private.account_controls where user_id=p.actor and state<>'active') then
  return jsonb_build_object('error','Review authorization changed.');end if;
 select * into r from sdi_private.render_reviews where id=p.review_id for update;
 if r.version<>p.review_version or r.render_digest<>p.digest or length(r.consent_version)=0 or cardinality(r.destinations)=0
  or r.state not in('pending','approved','changes')
  or exists(select 1 from sdi_private.account_controls where user_id=r.creator and state<>'active')
  or not exists(select 1 from sdi_private.render_artifacts where review_id=r.id and version=r.version and render_digest=r.render_digest and expires_at>clock_timestamp()) then
  return jsonb_build_object('error','Render authorization or retention changed.');end if;
 update sdi_private.render_reviews set preview_url=url,preview_expires_at=expires where id=r.id;
 update sdi_private.preview_permits set consumed=true where id=p.id;
 return jsonb_build_object('preview_url',url,'preview_expires_at',expires);
end $$;
revoke all on function sdi_private.preview_renew(uuid,text,timestamptz) from public,anon,authenticated;
grant execute on function sdi_private.preview_renew(uuid,text,timestamptz) to service_role;
create function public.sdi_preview_renew(permit uuid,url text,expires timestamptz) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.preview_renew(permit,url,expires)$$;
revoke all on function public.sdi_preview_renew(uuid,text,timestamptz) from public,anon,authenticated;
grant execute on function public.sdi_preview_renew(uuid,text,timestamptz) to service_role;
commit;
