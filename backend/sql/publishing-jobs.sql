-- Unapplied candidate. Requires admin-approval.sql and admin-users.sql.
begin;
create table sdi_private.render_artifacts (
 review_id uuid not null references sdi_private.render_reviews(id), version bigint not null,
 render_digest text not null, object_key text not null check(length(object_key) between 1 and 512),
 byte_count bigint not null check(byte_count between 1 and 2147483648),
 title text not null check(length(title) between 1 and 100),
 description text not null default '' check(octet_length(description)<=5000),
 made_for_kids boolean not null,
 expires_at timestamptz not null, primary key(review_id,version)
);
create table sdi_private.publish_jobs (
 id uuid primary key default gen_random_uuid(), review_id uuid not null references sdi_private.render_reviews(id),
 review_version bigint not null, render_digest text not null, creator uuid not null references auth.users(id),
 destination text not null check(destination in('feed','youtube','social')),
 state text not null default 'queued' check(state in('queued','leased','failed','cancelled','cancel_requested','published','removal_pending','reconcile')),
 phase text not null default 'upload' check(phase in('upload','processing','release')),
 attempts integer not null default 0, next_attempt timestamptz not null default clock_timestamp(),
 lease uuid, lease_expires timestamptz, result_url text, provider_id text, last_error text,
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 unique(review_id,review_version,destination)
);
alter table sdi_private.render_artifacts enable row level security;
alter table sdi_private.publish_jobs enable row level security;
revoke all on sdi_private.render_artifacts,sdi_private.publish_jobs from public,anon,authenticated;
create function sdi_private.release_allowed(review uuid,version bigint,digest text,destination text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from sdi_private.render_reviews r
 where r.id=review and r.version=version and r.render_digest=digest and r.state='approved' and r.rights_cleared
 and destination=any(r.destinations) and length(r.consent_version)>0
 and not exists(select 1 from sdi_private.account_controls c where c.user_id=r.creator and c.state<>'active')
 and exists(select 1 from sdi_private.render_artifacts a where a.review_id=r.id and a.version=r.version
  and a.render_digest=r.render_digest and a.expires_at>clock_timestamp())
 and exists(select 1 from sdi_private.render_decisions d join sdi_private.admin_roles role on role.user_id=d.actor
  where d.review_id=r.id and d.review_version=r.version and d.render_digest=r.render_digest
  and d.consent_version=r.consent_version and d.destinations=r.destinations and d.decision='approved'
  and role.enabled and (role.owner or 'reviews'=any(role.permissions))
  and (not r.spatter_generated or (d.owner_at_decision and role.owner))))
$$;
revoke all on function sdi_private.release_allowed(uuid,bigint,text,text) from public,anon,authenticated;
create function sdi_private.publish_action(action text,review uuid default null,destination text default null,job uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r sdi_private.render_reviews; j sdi_private.publish_jobs; items jsonb;
begin
 if not sdi_private.account_active() then return jsonb_build_object('error','Current account session required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select id,review_id,render_digest,publish_jobs.destination,state,phase,attempts,result_url,last_error,updated_at
   from sdi_private.publish_jobs where creator=auth.uid() order by created_at desc limit 100
  ) item;
  return jsonb_build_object('jobs',items);
 elsif action='enqueue' then
  select * into r from sdi_private.render_reviews where id=review and creator=auth.uid() for update;
  if not found or destination is null or not sdi_private.release_allowed(r.id,r.version,r.render_digest,destination) then
   return jsonb_build_object('error','This exact render and destination need current approval, rights and consent.');end if;
  if (select count(*) from sdi_private.publish_jobs where creator=auth.uid() and state in('queued','leased','cancel_requested'))>=20 then
   return jsonb_build_object('error','Publishing queue capacity reached.');end if;
  insert into sdi_private.publish_jobs(review_id,review_version,render_digest,creator,destination)
  values(r.id,r.version,r.render_digest,auth.uid(),destination)
  on conflict(review_id,review_version,destination) do nothing;
  return jsonb_build_object('status','queued');
 elsif action='cancel' then
  select * into j from sdi_private.publish_jobs where id=job and creator=auth.uid() for update;
  if not found then return jsonb_build_object('error','Job unavailable.');end if;
  update sdi_private.publish_jobs set state=case when state='cancelled' then 'cancelled' when state in('leased','cancel_requested') then 'cancel_requested'
   when state='removal_pending' or provider_id is not null then 'removal_pending'
   when state='reconcile' then 'reconcile' else 'cancelled' end,
   updated_at=clock_timestamp() where id=j.id;
  return jsonb_build_object('status','cancellation_recorded');
 elsif action='retry' then
  select * into j from sdi_private.publish_jobs where id=job and creator=auth.uid() for update;
  if not found or j.state<>'failed' or j.attempts>=5 or not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,j.destination) then
   return jsonb_build_object('error','This job cannot be retried.');end if;
  update sdi_private.publish_jobs set state='queued',next_attempt=greatest(next_attempt,clock_timestamp()),updated_at=clock_timestamp() where id=j.id;
  return jsonb_build_object('status','queued');
 end if;
 return jsonb_build_object('error','Unsupported publishing operation.');
end $$;
revoke all on function sdi_private.publish_action(text,uuid,text,uuid) from public;
grant execute on function sdi_private.publish_action(text,uuid,text,uuid) to authenticated;
create function public.sdi_publish_action(action text,review uuid default null,destination text default null,job uuid default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.publish_action(action,review,destination,job)$$;
revoke all on function public.sdi_publish_action(text,uuid,text,uuid) from public,anon;
grant execute on function public.sdi_publish_action(text,uuid,text,uuid) to authenticated;

-- Worker-only claim/finish. Client roles cannot call these privileged operations.
create function sdi_private.publish_claim() returns jsonb language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs; a sdi_private.render_artifacts;
begin
 -- Expired transfers need provider reconciliation, never blind duplicate upload.
 update sdi_private.publish_jobs set state='reconcile',last_error='Worker lease expired; reconcile provider before retry.',updated_at=clock_timestamp()
 where state='leased' and lease_expires<clock_timestamp();
 select * into j from sdi_private.publish_jobs where state='queued' and destination='youtube' and (attempts<5 or phase<>'upload') and next_attempt<=clock_timestamp()
 order by created_at for update skip locked limit 1;
 if not found then return jsonb_build_object('empty',true);end if;
 if not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,j.destination) then
  update sdi_private.publish_jobs set state='cancelled',last_error='Approval or artifact no longer valid.',updated_at=clock_timestamp() where id=j.id;
  return jsonb_build_object('empty',true);
 end if;
 select * into a from sdi_private.render_artifacts where review_id=j.review_id and version=j.review_version;
 update sdi_private.publish_jobs set state='leased',attempts=attempts+case when phase='upload' then 1 else 0 end,lease=gen_random_uuid(),lease_expires=clock_timestamp()+interval '2 minutes',updated_at=clock_timestamp()
 where id=j.id returning * into j;
 return jsonb_build_object('job',j.id,'lease',j.lease,'destination',j.destination,'digest',j.render_digest,'object_key',a.object_key,'byte_count',a.byte_count,'phase',j.phase,'title',a.title,'description',a.description,'made_for_kids',a.made_for_kids);
end $$;
create function sdi_private.publish_renew(job uuid,token uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs;
begin
 select * into j from sdi_private.publish_jobs where id=job and lease=token and state='leased' and lease_expires>clock_timestamp() for update;
 if not found or not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,j.destination) then return false;end if;
 update sdi_private.publish_jobs set lease_expires=clock_timestamp()+interval '2 minutes' where id=j.id;
 return true;
end $$;
create function sdi_private.publish_finish(job uuid,token uuid,provider text,url text,failure text default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs;
begin
 select * into j from sdi_private.publish_jobs where id=job and lease=token for update;
 if not found then return false;end if;
 if j.state='published' then return j.provider_id=provider and j.result_url=url;end if;
 if j.state not in('leased','cancel_requested','reconcile') then return false;end if;
 if failure is not null then
  update sdi_private.publish_jobs set state=case when j.state='cancel_requested' then
   case when j.provider_id is not null then 'removal_pending' else 'reconcile' end else 'failed' end,
   last_error=left(failure,500),next_attempt=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,j.attempts)::integer)),updated_at=clock_timestamp() where id=j.id;
  return true;
 end if;
 if provider is null or length(provider) not between 1 and 512 or url is null or url !~ '^https://' then return false;end if;
 update sdi_private.publish_jobs set provider_id=provider,result_url=url,
  state=case when j.state='cancel_requested' or not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,j.destination) then 'removal_pending' else 'published' end,
  updated_at=clock_timestamp() where id=j.id;
 return true;
end $$;
revoke all on function sdi_private.publish_claim(),sdi_private.publish_renew(uuid,uuid),sdi_private.publish_finish(uuid,uuid,text,text,text) from public,anon,authenticated;
grant usage on schema sdi_private to service_role;
grant execute on function sdi_private.publish_claim(),sdi_private.publish_renew(uuid,uuid),sdi_private.publish_finish(uuid,uuid,text,text,text) to service_role;
-- Expose worker wrappers only to the server service role.
create function public.sdi_publish_claim() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.publish_claim()$$;
create function public.sdi_publish_renew(job uuid,token uuid) returns boolean language sql security invoker set search_path='' as $$select sdi_private.publish_renew(job,token)$$;
create function public.sdi_publish_finish(job uuid,token uuid,provider text,url text,failure text default null) returns boolean language sql security invoker set search_path='' as $$select sdi_private.publish_finish(job,token,provider,url,failure)$$;
revoke all on function public.sdi_publish_claim(),public.sdi_publish_renew(uuid,uuid),public.sdi_publish_finish(uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.sdi_publish_claim(),public.sdi_publish_renew(uuid,uuid),public.sdi_publish_finish(uuid,uuid,text,text,text) to service_role;

-- Persist private upload completion without claiming public release. Processing
-- jobs return to the queue with delay; provider metadata is never uploaded twice.
create function sdi_private.publish_progress(job uuid,token uuid,provider text,wait_for_processing boolean default true) returns boolean
language plpgsql security definer set search_path='' as $$
declare j sdi_private.publish_jobs;
begin
 select * into j from sdi_private.publish_jobs where id=job and lease=token and state='leased' and lease_expires>clock_timestamp() for update;
 if not found or provider is null or provider !~ '^[A-Za-z0-9_-]{11}$'
  or not sdi_private.release_allowed(j.review_id,j.review_version,j.render_digest,j.destination) then return false;end if;
 if j.provider_id is not null and j.provider_id<>provider then return false;end if;
 update sdi_private.publish_jobs set provider_id=provider,phase='processing',
  state=case when wait_for_processing then 'queued' else 'leased' end,
  next_attempt=clock_timestamp()+interval '60 seconds',updated_at=clock_timestamp() where id=j.id;
 return true;
end $$;
create function sdi_private.publish_uncertain(job uuid,token uuid) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 update sdi_private.publish_jobs set state=case when state='cancel_requested' then 'removal_pending' else 'reconcile' end,
  last_error='Provider outcome requires reconciliation. No automatic duplicate release.',updated_at=clock_timestamp()
 where id=job and lease=token and state in('leased','cancel_requested');
 return found;
end $$;
revoke all on function sdi_private.publish_progress(uuid,uuid,text,boolean),sdi_private.publish_uncertain(uuid,uuid) from public,anon,authenticated;
grant execute on function sdi_private.publish_progress(uuid,uuid,text,boolean),sdi_private.publish_uncertain(uuid,uuid) to service_role;
create function public.sdi_publish_progress(job uuid,token uuid,provider text,wait_for_processing boolean default true) returns boolean
language sql security invoker set search_path='' as $$select sdi_private.publish_progress(job,token,provider,wait_for_processing)$$;
create function public.sdi_publish_uncertain(job uuid,token uuid) returns boolean
language sql security invoker set search_path='' as $$select sdi_private.publish_uncertain(job,token)$$;
revoke all on function public.sdi_publish_progress(uuid,uuid,text,boolean),public.sdi_publish_uncertain(uuid,uuid) from public,anon,authenticated;
grant execute on function public.sdi_publish_progress(uuid,uuid,text,boolean),public.sdi_publish_uncertain(uuid,uuid) to service_role;

commit;
