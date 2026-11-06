-- Installed-schema upgrade for daily Spatter owner review, from 96b68b8 to 6cf904d.
-- Apply as the schema owner to an already installed parent schema. Fresh projects use the current bundle.
-- Definitions mirror the four published candidates. Existing signatures, owners, and grants are preserved.
begin;

-- admin-approval.sql
create or replace function sdi_private.review_is_daily_spatter_draft(review uuid) returns boolean
language plpgsql stable set search_path='' as $$
declare linked boolean;
begin
 if review is null or to_regclass('sdi_private.spatter_draft_jobs') is null then return false; end if;
 execute 'select exists(select 1 from sdi_private.spatter_draft_jobs where review_id=$1)' into linked using review;
 return linked;
end $$;
revoke all on function sdi_private.review_is_daily_spatter_draft(uuid) from public,anon,authenticated;

-- admin-approval.sql
create or replace function sdi_private.review_action(action text,review uuid default null,digest text default null,
 version bigint default null,decision text default null,note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; is_owner boolean; result jsonb;
begin
 if sdi_private.admin_can('reviews') is not true or sdi_private.account_active() is not true then
  return jsonb_build_object('error','Current video-review permission and MFA are required.'); end if;
 select exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and enabled and owner) into is_owner;
 if action='list' then
  -- Storyboard and source-project digest columns are installed by
  -- spatter-draft-jobs.sql; read them through the row so this list keeps working
  -- before that candidate and returns null (shown as "not supplied") when absent.
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
   select rr.id,rr.title,rr.source_revision,rr.render_digest,rr.preview_url,rr.preview_expires_at,rr.consent_version,rr.rights_summary,
    rr.rights_cleared,rr.destinations,rr.spatter_generated,rr.state,rr.version,
    to_jsonb(rr)->'storyboard' as storyboard,to_jsonb(rr)->>'source_project_digest' as source_project_digest,
    sdi_private.review_quality_report(rr.id) as quality_report
   from sdi_private.render_reviews rr where rr.state='pending'
    and (is_owner or not sdi_private.review_is_daily_spatter_draft(rr.id)) order by rr.created_at limit 50
  ) item;
  return jsonb_build_object('reviews',result,'owner',is_owner);
 end if;
 if action is null or action<>'decide' or review is null or digest is null or version is null or decision is null or note is null or decision not in('approved','rejected','changes') or length(note)>2000 then
  return jsonb_build_object('error','Invalid review decision.'); end if;
 select * into r from sdi_private.render_reviews rr where rr.id=review
  and (is_owner or not sdi_private.review_is_daily_spatter_draft(rr.id)) for update;
 if not found or r.render_digest<>digest or r.version<>version or r.state<>'pending' then
  return jsonb_build_object('error','This render changed or was already reviewed. Reload the queue.'); end if;
 if decision='approved' and (not r.rights_cleared or length(r.consent_version)=0
  or (cardinality(r.destinations)=0 and not (coalesce(is_owner,false) and sdi_private.review_spatter_draft_retained(r.id)))
  or r.preview_expires_at<=clock_timestamp() or (r.spatter_generated and not is_owner)) then
  return jsonb_build_object('error','Approval requires current rights, consent, a playable render and owner approval for Spatter.'); end if;
 insert into sdi_private.render_decisions(review_id,actor,owner_at_decision,render_title,source_revision,rights_summary,render_digest,review_version,consent_version,destinations,decision,note)
 values(r.id,auth.uid(),is_owner,r.title,r.source_revision,r.rights_summary,r.render_digest,r.version,r.consent_version,r.destinations,decision,note);
 update sdi_private.render_reviews set state=decision where id=r.id;
 return jsonb_build_object('status','confirmed');
end $$;

-- admin-approval.sql
create or replace function sdi_private.review_history(page integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; is_owner boolean;
begin
 if sdi_private.admin_can('reviews') is not true or sdi_private.account_active() is not true then
  return jsonb_build_object('error','Current administrator MFA session required.');end if;
 select exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and enabled and owner) into is_owner;
 if page is null or page not between 0 and 199 then return jsonb_build_object('error','Invalid history page.');end if;
 select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
  select id,review_id,actor,owner_at_decision,render_title,source_revision,rights_summary,
   render_digest,review_version,consent_version,destinations,decision,note,created_at
  from sdi_private.render_decisions d where is_owner or not sdi_private.review_is_daily_spatter_draft(d.review_id)
  order by created_at desc,id limit 50 offset page*50
 ) item;
 return jsonb_build_object('decisions',result);
end $$;

-- preview-renewal.sql
create or replace function sdi_private.preview_permit(review uuid,digest text,version bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; a sdi_private.render_artifacts; u sdi_private.upload_registrations; permit uuid;
 draft boolean; upload_id uuid;
begin
 if sdi_private.admin_can('reviews') is not true or sdi_private.account_active() is not true then
  return jsonb_build_object('error','Current review permission and MFA required.');end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(auth.uid()::text,811));
 delete from sdi_private.preview_permits where actor=auth.uid() and expires_at<clock_timestamp();
 if (select count(*) from sdi_private.preview_permits where actor=auth.uid())>=20 then
  return jsonb_build_object('error','Too many preview requests. Wait one minute.');end if;
 select * into r from sdi_private.render_reviews rr where rr.id=review
  and (not sdi_private.review_is_daily_spatter_draft(rr.id)
   or exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and enabled and owner));
 if not found then return jsonb_build_object('error','This review changed or is unavailable.');end if;
 draft:=sdi_private.review_spatter_draft_retained(r.id);
 if r.version is distinct from version or r.render_digest is distinct from digest or length(r.consent_version)=0
  or (cardinality(r.destinations)=0 and not draft) or r.state not in('pending','approved','changes') then
  return jsonb_build_object('error','This review changed or is unavailable.');end if;
 select * into a from sdi_private.render_artifacts where review_id=r.id and render_artifacts.version=r.version
  and render_digest=r.render_digest and expires_at>clock_timestamp();
 if not found then return jsonb_build_object('error','The retained render has expired. Request a new upload.');end if;
 if draft then
  -- The worker's DraftPreviewStore keeps the copy as <upload>.mp4 in the intake directory.
  if a.object_key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.mp4$' then
   return jsonb_build_object('error','Preview renewal is unavailable for this legacy render.');end if;
  upload_id:=left(a.object_key,36)::uuid;
 else
  select * into u from sdi_private.upload_registrations where review_id=r.id;
  if not found then return jsonb_build_object('error','Preview renewal is unavailable for this legacy render.');end if;
  upload_id:=u.upload_id;
 end if;
 insert into sdi_private.preview_permits(actor,session_id,review_id,review_version,digest,expires_at)
 values(auth.uid(),auth.jwt()->>'session_id',r.id,r.version,r.render_digest,clock_timestamp()+interval '1 minute') returning id into permit;
 return jsonb_build_object('permit',permit,'upload',upload_id,'creator',r.creator,'digest',r.render_digest,'byte_count',a.byte_count);
end $$;

-- preview-renewal.sql
create or replace function sdi_private.preview_renew(permit uuid,url text,expires timestamptz) returns jsonb
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
 select * into r from sdi_private.render_reviews rr where rr.id=p.review_id
  and (not sdi_private.review_is_daily_spatter_draft(rr.id)
   or exists(select 1 from sdi_private.admin_roles where user_id=p.actor and enabled and owner)) for update;
 if not found or r.version<>p.review_version or r.render_digest<>p.digest or length(r.consent_version)=0
  or (cardinality(r.destinations)=0 and not sdi_private.review_spatter_draft_retained(r.id))
  or r.state not in('pending','approved','changes')
  or exists(select 1 from sdi_private.account_controls where user_id=r.creator and state<>'active')
  or not exists(select 1 from sdi_private.render_artifacts where review_id=r.id and version=r.version and render_digest=r.render_digest and expires_at>clock_timestamp()) then
  return jsonb_build_object('error','Render authorization or retention changed.');end if;
 update sdi_private.render_reviews set preview_url=url,preview_expires_at=expires where id=r.id;
 update sdi_private.preview_permits set consumed=true where id=p.id;
 return jsonb_build_object('preview_url',url,'preview_expires_at',expires);
end $$;

-- review-rights.sql
create or replace function sdi_private.review_rights(review uuid,digest text,version bigint,cleared boolean,note text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; artifact sdi_private.render_artifacts; is_owner boolean;
begin
 if sdi_private.admin_can('reviews') is not true or sdi_private.account_active() is not true then
  return jsonb_build_object('error','Current review permission and MFA required.');end if;
 if review is null or digest is null or version is null or cleared is null or note is null
  or length(trim(note)) not between 1 and 2000 then return jsonb_build_object('error','Document the rights evidence or revocation reason.');end if;
 select exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and enabled and owner) into is_owner;
 select * into r from sdi_private.render_reviews rr where rr.id=review
  and (is_owner or not sdi_private.review_is_daily_spatter_draft(rr.id)) for update;
 if not found or r.render_digest<>digest or r.version<>version then
  return jsonb_build_object('error','Render changed. Refresh before recording rights.');end if;
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

-- spatter-draft-jobs.sql
create or replace function sdi_private.spatter_draft_status(p_from date,p_to date) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if sdi_private.admin_can('reviews') is not true or sdi_private.account_active() is not true
  or not exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and enabled and owner) then
  return jsonb_build_object('error','Current owner permission and MFA are required.'); end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>62 then return jsonb_build_object('error','Choose a range of at most 62 days.'); end if;
 perform sdi_private.spatter_draft_sweep();
 select coalesce(jsonb_agg(jsonb_build_object('date',d::date,'state',coalesce(j.state,case when d::date<(clock_timestamp() at time zone 'utc')::date then 'missed' else 'unplanned' end),
  'attempts',coalesce(j.attempts,0),'error',coalesce(j.error,''),'review',j.review_id,'sha256',j.artifact_sha256,'seed',j.planner_seed) order by d),'[]'::jsonb)
  into result from generate_series(p_from,p_to,interval '1 day') d left join sdi_private.spatter_draft_jobs j on j.target_date=d::date;
 return jsonb_build_object('days',result,'capacity','owner-gated: no render capacity is approved or purchased by this queue');
end $$;

commit;
