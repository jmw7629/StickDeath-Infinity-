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
