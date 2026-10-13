-- Unapplied candidate. Requires publishing-jobs.sql and admin-users.sql.
-- Only the authenticated host intake service calls this after full-file validation.
begin;
create table sdi_private.upload_registrations (
 upload_id uuid primary key, creator uuid not null references auth.users(id),
 review_id uuid not null unique references sdi_private.render_reviews(id),
 metadata jsonb not null, object_key text not null, created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.upload_registrations enable row level security;
revoke all on sdi_private.upload_registrations from public,anon,authenticated;
create function sdi_private.register_upload(upload uuid,creator uuid,metadata jsonb,object_key text,
 preview_url text,expires_at timestamptz,artifact_expires_at timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare prior sdi_private.upload_registrations; review uuid; destinations text[]; bytes bigint;
begin
 if upload is null or creator is null or metadata is null or jsonb_typeof(metadata)<>'object'
  or object_key is distinct from upload::text||'.mp4' then
  return jsonb_build_object('error','Invalid upload registration.');end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(upload::text,810));
 select * into prior from sdi_private.upload_registrations where upload_id=upload;
 if found then
  if prior.creator<>creator or prior.metadata<>metadata or prior.object_key<>object_key then
   return jsonb_build_object('error','Upload identity belongs to different content.');end if;
  -- Do not restore withdrawn consent, expired previews or earlier approval.
  return jsonb_build_object('review_id',prior.review_id);
 end if;
 if not exists(select 1 from auth.users where id=creator and not is_anonymous)
  or exists(select 1 from sdi_private.account_controls c where c.user_id=creator and c.state<>'active') then
  return jsonb_build_object('error','Creator unavailable.');end if;
 if preview_url is null or preview_url !~ '^https://' or length(preview_url)>4096
  or expires_at is null or expires_at<=clock_timestamp() or expires_at>clock_timestamp()+interval '24 hours'
  or artifact_expires_at is null or artifact_expires_at<=clock_timestamp()
  or artifact_expires_at>clock_timestamp()+interval '24 hours'
  or jsonb_typeof(metadata->'size') is distinct from 'number'
  or (metadata->>'size') !~ '^[0-9]{1,10}$'
  or jsonb_typeof(metadata->'made_for_kids') is distinct from 'boolean'
  or jsonb_typeof(metadata->'destinations') is distinct from 'array'
  or coalesce(metadata->>'sha256','') !~ '^[a-f0-9]{64}$'
  or length(trim(coalesce(metadata->>'title',''))) not between 1 and 100
  or length(trim(coalesce(metadata->>'source_revision',''))) not between 1 and 200
  or length(trim(coalesce(metadata->>'rights_summary',''))) not between 1 and 2000
  or length(trim(coalesce(metadata->>'consent_version',''))) not between 1 and 100 then
  return jsonb_build_object('error','Complete current metadata and private preview required.');end if;
 bytes:=(metadata->>'size')::bigint;
 if bytes not between 1 and 2147483648 then return jsonb_build_object('error','Invalid artifact size.');end if;
 select array_agg(v order by v) into destinations from jsonb_array_elements_text(metadata->'destinations') v;
 if destinations is null or cardinality(destinations) not between 1 and 3
  or not destinations <@ array['feed','youtube','social'] then
  return jsonb_build_object('error','Explicit destinations required.');end if;
 insert into sdi_private.render_reviews(creator,title,source_revision,render_digest,preview_url,preview_expires_at,
  consent_version,rights_summary,rights_cleared,destinations,spatter_generated)
 values(creator,metadata->>'title',metadata->>'source_revision',metadata->>'sha256',preview_url,expires_at,
  metadata->>'consent_version',metadata->>'rights_summary',false,destinations,true) returning id into review;
 -- Unknown provenance defaults to the stricter owner approval requirement.
 -- Rights are a declaration pending review, never automatically cleared by intake.
 insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,made_for_kids,expires_at)
 values(review,1,metadata->>'sha256',object_key,bytes,metadata->>'title',(metadata->>'made_for_kids')::boolean,artifact_expires_at);
 insert into sdi_private.upload_registrations(upload_id,creator,review_id,metadata,object_key)
 values(upload,creator,review,metadata,object_key);
 return jsonb_build_object('review_id',review);
end $$;
revoke all on function sdi_private.register_upload(uuid,uuid,jsonb,text,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function sdi_private.register_upload(uuid,uuid,jsonb,text,text,timestamptz,timestamptz) to service_role;
create function public.sdi_register_upload(upload uuid,creator uuid,metadata jsonb,object_key text,
 preview_url text,expires_at timestamptz,artifact_expires_at timestamptz) returns jsonb language sql security invoker set search_path='' as $$
 select sdi_private.register_upload(upload,creator,metadata,object_key,preview_url,expires_at,artifact_expires_at)$$;
revoke all on function public.sdi_register_upload(uuid,uuid,jsonb,text,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.sdi_register_upload(uuid,uuid,jsonb,text,text,timestamptz,timestamptz) to service_role;
commit;
