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
create function sdi_private.review_action(action text,review uuid default null,digest text default null,
 version bigint default null,decision text default null,note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; is_owner boolean; result jsonb;
begin
 if not sdi_private.admin_can('reviews') or not sdi_private.account_active() then return jsonb_build_object('error','Current video-review permission and MFA are required.'); end if;
 select owner into is_owner from sdi_private.admin_roles where user_id=auth.uid();
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into result from (
   select id,title,source_revision,render_digest,preview_url,preview_expires_at,consent_version,rights_summary,
    rights_cleared,destinations,spatter_generated,state,render_reviews.version
   from sdi_private.render_reviews where state='pending' order by created_at limit 50
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
commit;
