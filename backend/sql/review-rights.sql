-- Unapplied candidate. Requires publishing-jobs.sql, admin-approval.sql and withdrawal triggers.
begin;
create function sdi_private.review_rights(review uuid,digest text,version bigint,cleared boolean,note text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; artifact sdi_private.render_artifacts; is_owner boolean;
begin
 if not sdi_private.admin_can('reviews') or not sdi_private.account_active() then
  return jsonb_build_object('error','Current review permission and MFA required.');end if;
 if review is null or digest is null or version is null or cleared is null or note is null
  or length(trim(note)) not between 1 and 2000 then return jsonb_build_object('error','Document the rights evidence or revocation reason.');end if;
 select * into r from sdi_private.render_reviews where id=review for update;
 if not found or r.render_digest<>digest or r.version<>version then
  return jsonb_build_object('error','Render changed. Refresh before recording rights.');end if;
 select owner into is_owner from sdi_private.admin_roles where user_id=auth.uid() and enabled;
 if r.spatter_generated and not coalesce(is_owner,false) then
  return jsonb_build_object('error','Owner review is required for this render.');end if;
 if r.rights_cleared=cleared then return jsonb_build_object('status','confirmed');end if;
 select * into artifact from sdi_private.render_artifacts where review_id=r.id and render_artifacts.version=r.version
  and render_digest=r.render_digest;
 if cleared and (not found or artifact.expires_at<=clock_timestamp() or r.preview_expires_at<=clock_timestamp()
  or length(r.consent_version)=0 or cardinality(r.destinations)=0) then
  return jsonb_build_object('error','Current artifact, preview and creator permissions required.');end if;
 update sdi_private.render_reviews set rights_cleared=cleared where id=r.id returning * into r;
 -- Rights changes invalidate prior approval. Carry forward ONLY the same bytes;
 -- new approval must reference the new review version. Old audit remains intact.
 if artifact.review_id is not null then
  insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at)
  values(r.id,r.version,r.render_digest,artifact.object_key,artifact.byte_count,artifact.title,artifact.description,artifact.made_for_kids,artifact.expires_at);
 end if;
 insert into sdi_private.render_decisions(review_id,actor,owner_at_decision,render_title,source_revision,rights_summary,
  render_digest,review_version,consent_version,destinations,decision,note)
 values(r.id,auth.uid(),coalesce(is_owner,false),r.title,r.source_revision,r.rights_summary,r.render_digest,r.version,
  r.consent_version,r.destinations,case when cleared then 'rights_cleared' else 'rights_revoked' end,trim(note));
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.review_rights(uuid,text,bigint,boolean,text) from public,anon;
grant execute on function sdi_private.review_rights(uuid,text,bigint,boolean,text) to authenticated;
create function public.sdi_review_rights(review uuid,digest text,version bigint,cleared boolean,note text) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.review_rights(review,digest,version,cleared,note)$$;
revoke all on function public.sdi_review_rights(uuid,text,bigint,boolean,text) from public,anon;
grant execute on function public.sdi_review_rights(uuid,text,bigint,boolean,text) to authenticated;
commit;
