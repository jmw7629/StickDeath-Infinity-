-- Unapplied candidate. Requires upload-registration.sql and publishing-jobs.sql.
begin;
alter table sdi_private.upload_registrations add column retirement_authorized_at timestamptz;
create function sdi_private.retire_upload(upload uuid, review uuid default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare item sdi_private.upload_registrations;
begin
 if upload is null then return false; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(upload::text,810));
 select * into item from sdi_private.upload_registrations where upload_id=upload for update;
 -- An unknown registration is an uncertain completion, not proof of absence.
 if not found or (review is not null and review<>item.review_id)
  or item.object_key<>upload::text||'.mp4' then return false; end if;
 perform 1 from sdi_private.render_reviews where id=item.review_id for update;
 if not found then return false; end if;
 -- Rights revisions can reference the same bytes. Every version must expire.
 if not exists(select 1 from sdi_private.render_artifacts where review_id=item.review_id)
  or exists(select 1 from sdi_private.render_artifacts where review_id=item.review_id
   and (object_key<>item.object_key or expires_at>clock_timestamp())) then return false; end if;
 perform 1 from sdi_private.publish_jobs where review_id=item.review_id order by id for update;
 -- Never infer that a timed-out worker or ambiguous provider request stopped.
 if exists(select 1 from sdi_private.publish_jobs where review_id=item.review_id
  and (state in('leased','cancel_requested','reconcile')
   or lease_expires>=clock_timestamp()-interval '60 seconds')) then return false; end if;
 -- Already published results remain intact. Incomplete provider uploads still
 -- need provider removal, but that operation does not need the local MP4.
 update sdi_private.publish_jobs set
  state=case when provider_id is null then 'cancelled' else 'removal_pending' end,
  last_error='Temporary render expired. Export and submit again to publish.',updated_at=clock_timestamp()
 where review_id=item.review_id and state in('queued','failed');
 update sdi_private.upload_registrations set retirement_authorized_at=coalesce(retirement_authorized_at,clock_timestamp())
 where upload_id=upload;
 return true;
end $$;
revoke all on function sdi_private.retire_upload(uuid,uuid) from public,anon,authenticated;
grant execute on function sdi_private.retire_upload(uuid,uuid) to service_role;
create function public.sdi_retire_upload(upload uuid,review uuid default null) returns boolean
language sql security invoker set search_path='' as $$select sdi_private.retire_upload(upload,review)$$;
revoke all on function public.sdi_retire_upload(uuid,uuid) from public,anon,authenticated;
grant execute on function public.sdi_retire_upload(uuid,uuid) to service_role;
commit;

-- Post-publication release of the temporary server copy (#190) and the creator's
-- unified publishing status (#245). Requires the block above. The PL/pgSQL bodies
-- also read feed-publication.sql (sdi_watch_media.review_id), moderation.sql and
-- marketing-workspace.sql at run time; install the full apply order before use.
begin;
-- True only when every destination of the current approved render has a verified
-- provider receipt and nothing can still need these bytes: no in-flight, failed,
-- reconciling or removal job, no lease inside the grace interval, no social or
-- marketing reuse and no pending appeal. The creator's original stays on the
-- device and is never part of this decision.
create function sdi_private.publication_releasable(upload uuid) returns boolean
language plpgsql stable security definer set search_path='' as $$
declare item sdi_private.upload_registrations; r sdi_private.render_reviews;
begin
 select * into item from sdi_private.upload_registrations where upload_id=upload;
 if not found or item.object_key<>upload::text||'.mp4' then return false; end if;
 select * into r from sdi_private.render_reviews where id=item.review_id;
 if not found or r.state<>'approved' or cardinality(r.destinations)=0 or 'social'=any(r.destinations) then return false; end if;
 if exists(select 1 from unnest(r.destinations) d where not exists(
   select 1 from sdi_private.publish_jobs j where j.review_id=r.id and j.review_version=r.version
   and j.render_digest=r.render_digest and j.destination=d and j.state='published'
   and j.provider_id is not null and j.result_url ~ '^https://')) then return false; end if;
 if exists(select 1 from sdi_private.publish_jobs j where j.review_id=r.id
   and (j.state not in('published','cancelled') or j.lease_expires>=clock_timestamp()-interval '60 seconds')) then return false; end if;
 if exists(select 1 from sdi_private.marketing_drafts m where m.review_id=r.id
   and m.state in('draft','approved','queued','leased')) then return false; end if;
 if exists(select 1 from sdi_private.moderation_appeals a join public.sdi_watch_media w on w.id=a.media_id
   where w.review_id=r.id and a.state='pending') then return false; end if;
 return true;
end $$;
-- Bounded list for the intake host. Recently authorized releases are repeated for
-- two days so a host that crashed between authorization and unlink finishes the job.
create function sdi_private.publication_release_candidates(lim integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare items jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('upload',c.upload_id,'review',c.review_id)),'[]'::jsonb) into items from (
  select u.upload_id,u.review_id from sdi_private.upload_registrations u
  where u.retirement_authorized_at>clock_timestamp()-interval '2 days'
   or (u.retirement_authorized_at is null
    and exists(select 1 from sdi_private.render_artifacts a where a.review_id=u.review_id and a.expires_at>clock_timestamp())
    and sdi_private.publication_releasable(u.upload_id))
  order by u.created_at,u.upload_id limit least(greatest(coalesce(lim,25),1),100)
 ) c;
 return items;
end $$;
-- Fences every artifact version (release_allowed then refuses new leases) and
-- records the authorization before the host unlinks its copy. Idempotent.
create function sdi_private.release_published_upload(upload uuid,review uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare item sdi_private.upload_registrations;
begin
 if upload is null or review is null then return false; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(upload::text,810));
 select * into item from sdi_private.upload_registrations where upload_id=upload for update;
 if not found or item.review_id<>review or item.object_key<>upload::text||'.mp4' then return false; end if;
 if item.retirement_authorized_at is not null then return true; end if;
 perform 1 from sdi_private.render_reviews where id=item.review_id for update;
 perform 1 from sdi_private.publish_jobs where review_id=item.review_id order by id for update;
 if not sdi_private.publication_releasable(upload) then return false; end if;
 update sdi_private.render_artifacts set expires_at=least(expires_at,clock_timestamp())
 where review_id=item.review_id;
 update sdi_private.upload_registrations set retirement_authorized_at=clock_timestamp() where upload_id=upload;
 return true;
end $$;
revoke all on function sdi_private.publication_releasable(uuid),sdi_private.publication_release_candidates(integer),
 sdi_private.release_published_upload(uuid,uuid) from public,anon,authenticated;
grant execute on function sdi_private.publication_release_candidates(integer),sdi_private.release_published_upload(uuid,uuid) to service_role;
create function public.sdi_publication_release_candidates(lim integer default 25) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.publication_release_candidates(lim)$$;
create function public.sdi_release_published_upload(upload uuid,review uuid) returns boolean
language sql security invoker set search_path='' as $$select sdi_private.release_published_upload(upload,review)$$;
revoke all on function public.sdi_publication_release_candidates(integer),public.sdi_release_published_upload(uuid,uuid) from public,anon,authenticated;
grant execute on function public.sdi_publication_release_candidates(integer),public.sdi_release_published_upload(uuid,uuid) to service_role;

-- One creator-facing stage per job (#245). Admin and native UI read the same words.
create function sdi_private.publish_stage(state text,phase text,attempts integer,provider text) returns text
language sql immutable set search_path='' as $$
 select case
  when state='published' then 'published'
  when state='failed' then 'failed'
  when state='reconcile' then 'needs_reconciliation'
  when state='cancel_requested' then 'cancelling'
  when state='removal_pending' then 'removal_in_progress'
  when state='cancelled' and provider is not null then 'removed'
  when state='cancelled' then 'cancelled'
  when phase='processing' then 'provider_processing'
  when phase='release' then 'releasing'
  when state='queued' and attempts=0 then 'queued'
  else 'transferring' end
$$;
revoke all on function sdi_private.publish_stage(text,text,integer,text) from public,anon;
grant execute on function sdi_private.publish_stage(text,text,integer,text) to authenticated,service_role;
-- Creator status: review (moderation and approval), every destination job, the
-- server copy's retention and only links the provider confirmed. Reads only the
-- caller's rows; failure text is the sanitized stored reason.
create function sdi_private.publish_status(page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare items jsonb;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Current account session required.'); end if;
 if page is null or page not between 0 and 199 then return jsonb_build_object('error','Invalid page.'); end if;
 select coalesce(jsonb_agg(item order by created_at desc,id),'[]'::jsonb) into items from (
  select r.id,r.created_at,jsonb_build_object(
   'review_id',r.id,'title',r.title,'render_digest',r.render_digest,'version',r.version,
   'review_state',case r.state when 'pending' then 'awaiting_review' when 'changes' then 'changes_requested' else r.state end,
   'owner_approval_required',r.spatter_generated,'destinations',to_jsonb(r.destinations),
   'server_copy',case when u.retirement_authorized_at is not null then 'deleted'
     when coalesce((select max(a.expires_at) from sdi_private.render_artifacts a where a.review_id=r.id),'-infinity')<=clock_timestamp() then 'expired'
     else 'retained' end,
   'server_copy_expires_at',case when u.retirement_authorized_at is null then
     (select max(a.expires_at) from sdi_private.render_artifacts a where a.review_id=r.id) end,
   'jobs',coalesce((select jsonb_agg(jsonb_build_object(
     'id',j.id,'destination',j.destination,'state',j.state,'phase',j.phase,
     'stage',sdi_private.publish_stage(j.state,j.phase,j.attempts,j.provider_id),
     'attempts',j.attempts,'current_render',j.review_version=r.version and j.render_digest=r.render_digest,
     'can_retry',j.state='failed' and j.attempts<5,
     'can_cancel',j.state in('queued','leased','failed','published'),
     'result_url',case when j.state='published' then j.result_url end,
     'last_error',j.last_error,'updated_at',j.updated_at) order by j.created_at,j.id)
    from sdi_private.publish_jobs j where j.review_id=r.id and j.creator=auth.uid()),'[]'::jsonb)) item
  from sdi_private.render_reviews r
  left join sdi_private.upload_registrations u on u.review_id=r.id
  where r.creator=auth.uid()
  order by r.created_at desc,r.id limit 25 offset page*25
 ) rows;
 return jsonb_build_object('reviews',items);
end $$;
revoke all on function sdi_private.publish_status(integer) from public,anon;
grant execute on function sdi_private.publish_status(integer) to authenticated;
create function public.sdi_publish_status(page integer default 0) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.publish_status(page)$$;
revoke all on function public.sdi_publish_status(integer) from public,anon;
grant execute on function public.sdi_publish_status(integer) to authenticated;
commit;
