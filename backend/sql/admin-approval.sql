-- Unapplied candidate. Provision role records through a protected owner operation,
-- never from a client-supplied password, profile, username or email.
begin;
create table sdi_private.admin_roles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 enabled boolean not null default false, owner boolean not null default false, revision bigint not null default 1,
 permissions text[] not null default '{}' check(permissions <@ array['users','reviews','moderation','publishing','overview','finance'])
);
create table sdi_private.render_reviews (
 id uuid primary key default gen_random_uuid(), creator uuid not null references auth.users(id) on delete cascade,
 title text not null check(length(title) between 1 and 200), source_revision text not null,
 render_digest text not null check(render_digest ~ '^[a-f0-9]{64}$'),
 preview_url text not null check(preview_url ~ '^https://'), preview_expires_at timestamptz not null,
 consent_version text not null, rights_summary text not null, rights_cleared boolean not null default false,
 destinations text[] not null check(destinations <@ array['feed','youtube','social']),
 spatter_generated boolean not null default false,
 state text not null default 'pending' check(state in('pending','approved','rejected','changes')),
 version bigint not null default 1, created_at timestamptz not null default clock_timestamp()
);
create table sdi_private.render_decisions (
 id uuid primary key default gen_random_uuid(), review_id uuid not null references sdi_private.render_reviews(id),
 actor uuid not null references auth.users(id), owner_at_decision boolean not null,
 render_title text not null, source_revision text not null, rights_summary text not null,
 render_digest text not null, review_version bigint not null, consent_version text not null,
 destinations text[] not null, decision text not null, note text not null check(length(note)<=2000),
 created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.admin_roles enable row level security;
alter table sdi_private.render_reviews enable row level security;
alter table sdi_private.render_decisions enable row level security;
revoke all on sdi_private.admin_roles,sdi_private.render_reviews,sdi_private.render_decisions from public,anon,authenticated;
create function sdi_private.admin_authorized() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and auth.jwt()->>'aal'='aal2'
 and exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and enabled)
 and exists(select 1 from auth.sessions s where s.user_id=auth.uid() and s.id::text=auth.jwt()->>'session_id')
$$;
revoke all on function sdi_private.admin_authorized() from public;
grant execute on function sdi_private.admin_authorized() to authenticated;
create function sdi_private.admin_can(capability text) returns boolean language sql stable security definer set search_path='' as $$
 select sdi_private.admin_authorized() and capability=any(array['users','reviews','moderation','publishing','overview','finance'])
 and exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and enabled
  and (owner or capability=any(permissions)))
$$;
revoke all on function sdi_private.admin_can(text) from public,anon;
grant execute on function sdi_private.admin_can(text) to authenticated;
-- Service-side revisions invalidate approval. A preview URL renewal does not
-- change the render, but also cannot alter consent/destination evidence silently.
create function sdi_private.invalidate_render_approval() returns trigger language plpgsql set search_path='' as $$
begin
 if row(new.render_digest,new.source_revision,new.consent_version,new.rights_cleared,new.destinations,new.spatter_generated,new.creator,new.rights_summary)
 is distinct from row(old.render_digest,old.source_revision,old.consent_version,old.rights_cleared,old.destinations,old.spatter_generated,old.creator,old.rights_summary) then
  new.version=old.version+1; new.state='pending';
 end if;
 return new;
end $$;
revoke all on function sdi_private.invalidate_render_approval() from public;
create trigger invalidate_render_approval before update on sdi_private.render_reviews for each row execute function sdi_private.invalidate_render_approval();
-- Measured quality report a Spatter draft job attached to this review, if any
-- (spatter-draft-jobs.sql installs the table later; absent means null).
create function sdi_private.review_quality_report(review uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare report jsonb;
begin
 if to_regclass('sdi_private.spatter_draft_jobs') is null then return null; end if;
 execute 'select quality_report from sdi_private.spatter_draft_jobs where review_id=$1 limit 1' into report using review;
 return report;
end $$;
revoke all on function sdi_private.review_quality_report(uuid) from public,anon,authenticated;
create function sdi_private.review_action(action text,review uuid default null,digest text default null,
 version bigint default null,decision text default null,note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; is_owner boolean; result jsonb;
begin
 if not sdi_private.admin_can('reviews') or not sdi_private.account_active() then return jsonb_build_object('error','Current video-review permission and MFA are required.'); end if;
 select owner into is_owner from sdi_private.admin_roles where user_id=auth.uid();
 if action='list' then
  -- Storyboard and source-project digest columns are installed by
  -- spatter-draft-jobs.sql; read them through the row so this list keeps working
  -- before that candidate and returns null (shown as "not supplied") when absent.
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
   select rr.id,rr.title,rr.source_revision,rr.render_digest,rr.preview_url,rr.preview_expires_at,rr.consent_version,rr.rights_summary,
    rr.rights_cleared,rr.destinations,rr.spatter_generated,rr.state,rr.version,
    to_jsonb(rr)->'storyboard' as storyboard,to_jsonb(rr)->>'source_project_digest' as source_project_digest,
    sdi_private.review_quality_report(rr.id) as quality_report
   from sdi_private.render_reviews rr where rr.state='pending' order by rr.created_at limit 50
  ) item;
  return jsonb_build_object('reviews',result,'owner',is_owner);
 end if;
 if action is null or action<>'decide' or review is null or digest is null or version is null or decision is null or note is null or decision not in('approved','rejected','changes') or length(note)>2000 then
  return jsonb_build_object('error','Invalid review decision.'); end if;
 select * into r from sdi_private.render_reviews where id=review for update;
 if not found or r.render_digest<>digest or r.version<>version or r.state<>'pending' then
  return jsonb_build_object('error','This render changed or was already reviewed. Reload the queue.'); end if;
 if decision='approved' and (not r.rights_cleared or length(r.consent_version)=0 or cardinality(r.destinations)=0
  or r.preview_expires_at<=clock_timestamp() or (r.spatter_generated and not is_owner)) then
  return jsonb_build_object('error','Approval requires current rights, consent, a playable render and owner approval for Spatter.'); end if;
 insert into sdi_private.render_decisions(review_id,actor,owner_at_decision,render_title,source_revision,rights_summary,render_digest,review_version,consent_version,destinations,decision,note)
 values(r.id,auth.uid(),is_owner,r.title,r.source_revision,r.rights_summary,r.render_digest,r.version,r.consent_version,r.destinations,decision,note);
 update sdi_private.render_reviews set state=decision where id=r.id;
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.review_action(text,uuid,text,bigint,text,text) from public;
grant execute on function sdi_private.review_action(text,uuid,text,bigint,text,text) to authenticated;
create function public.sdi_review_action(action text,review uuid default null,digest text default null,
 version bigint default null,decision text default null,note text default '') returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.review_action(action,review,digest,version,decision,note)$$;
revoke all on function public.sdi_review_action(text,uuid,text,bigint,text,text) from public,anon;
grant execute on function public.sdi_review_action(text,uuid,text,bigint,text,text) to authenticated;
-- History returns snapshots from the decision, never mutable current render
-- metadata or an expired private preview link.
create function sdi_private.review_history(page integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not sdi_private.admin_can('reviews') or not sdi_private.account_active() then
  return jsonb_build_object('error','Current administrator MFA session required.');end if;
 if page is null or page not between 0 and 199 then return jsonb_build_object('error','Invalid history page.');end if;
 select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
  select id,review_id,actor,owner_at_decision,render_title,source_revision,rights_summary,
   render_digest,review_version,consent_version,destinations,decision,note,created_at
  from sdi_private.render_decisions order by created_at desc,id limit 50 offset page*50
 ) item;
 return jsonb_build_object('decisions',result);
end $$;
revoke all on function sdi_private.review_history(integer) from public,anon;
grant execute on function sdi_private.review_history(integer) to authenticated;
create function public.sdi_review_history(page integer default 0) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.review_history(page)$$;
revoke all on function public.sdi_review_history(integer) from public,anon;
grant execute on function public.sdi_review_history(integer) to authenticated;
-- Service-only (#214): bind the editable project's canonical digest, declared in
-- the upload metadata, to the review registered for that upload. Writing it goes
-- through invalidate_render_approval, so a changed digest returns the review to
-- pending under a new version; the same retained bytes are carried forward to
-- that version exactly as review-rights.sql does. Idempotent for the same digest.
create function sdi_private.review_bind_source_digest(upload uuid,review uuid,digest text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; declared text; found_registration boolean; next_version bigint;
begin
 if upload is null or review is null or digest is null or digest !~ '^[a-f0-9]{64}$' then
  return jsonb_build_object('error','Invalid source digest binding.'); end if;
 if to_regclass('sdi_private.upload_registrations') is null then
  return jsonb_build_object('error','Upload registration is not installed.'); end if;
 execute 'select true,metadata->>''source_project_digest'' from sdi_private.upload_registrations where upload_id=$1 and review_id=$2'
  into found_registration,declared using upload,review;
 if not coalesce(found_registration,false) then return jsonb_build_object('error','Upload registration not found.'); end if;
 if declared is distinct from digest then
  return jsonb_build_object('error','Source digest does not match the registered upload.'); end if;
 select * into r from sdi_private.render_reviews where id=review for update;
 if not found then return jsonb_build_object('error','Upload registration not found.'); end if;
 if not (to_jsonb(r) ? 'source_project_digest') then
  return jsonb_build_object('error','Source digest storage is not installed.'); end if;
 if to_jsonb(r)->>'source_project_digest' is not distinct from digest then
  return jsonb_build_object('status','confirmed','version',r.version,'changed',false); end if;
 execute 'update sdi_private.render_reviews set source_project_digest=$1 where id=$2 returning version' into next_version using digest,r.id;
 if next_version<>r.version and to_regclass('sdi_private.render_artifacts') is not null then
  execute 'insert into sdi_private.render_artifacts(review_id,version,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at)
   select review_id,$2,render_digest,object_key,byte_count,title,description,made_for_kids,expires_at
   from sdi_private.render_artifacts where review_id=$1 and version=$3 and render_digest=$4 on conflict do nothing'
   using r.id,next_version,r.version,r.render_digest;
 end if;
 return jsonb_build_object('status','confirmed','version',next_version,'changed',true);
end $$;
revoke all on function sdi_private.review_bind_source_digest(uuid,uuid,text) from public,anon,authenticated;
grant execute on function sdi_private.review_bind_source_digest(uuid,uuid,text) to service_role;
create function public.sdi_review_bind_source_digest(upload uuid,review uuid,digest text) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.review_bind_source_digest(upload,review,digest)$$;
revoke all on function public.sdi_review_bind_source_digest(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.sdi_review_bind_source_digest(uuid,uuid,text) to service_role;
commit;
