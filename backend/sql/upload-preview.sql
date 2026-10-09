-- Unapplied candidate. Requires upload-registration.sql and publishing-jobs.sql.
begin;
create function sdi_private.upload_preview(upload uuid,creator uuid,digest text) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('byte_count',a.byte_count,'expires',extract(epoch from least(a.expires_at,r.preview_expires_at)))
 from sdi_private.upload_registrations u join sdi_private.render_reviews r on r.id=u.review_id
 join sdi_private.render_artifacts a on a.review_id=r.id and a.version=r.version and a.render_digest=r.render_digest
 where u.upload_id=upload and u.creator=creator and r.creator=creator and r.render_digest=digest
  and a.object_key=upload::text||'.mp4' and a.expires_at>clock_timestamp() and r.preview_expires_at>clock_timestamp()
  and r.state in('pending','approved','changes') and length(r.consent_version)>0 and cardinality(r.destinations)>0
  and not exists(select 1 from sdi_private.account_controls c where c.user_id=creator and c.state<>'active')
$$;
revoke all on function sdi_private.upload_preview(uuid,uuid,text) from public,anon,authenticated;
grant execute on function sdi_private.upload_preview(uuid,uuid,text) to service_role;
create function public.sdi_upload_preview(upload uuid,creator uuid,digest text) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.upload_preview(upload,creator,digest)$$;
revoke all on function public.sdi_upload_preview(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.sdi_upload_preview(uuid,uuid,text) to service_role;
commit;
