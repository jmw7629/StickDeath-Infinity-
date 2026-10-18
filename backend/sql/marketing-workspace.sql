-- Unapplied candidate. Install after notifications.sql (needs consent-versions.sql,
-- publishing-jobs.sql, admin-hardening.sql, feed-publication.sql).
-- Approval-based marketing workspace for #274 and #283: campaigns, drafts per
-- destination, a versioned brand-voice guide, per-destination cadence settings and a
-- service claim/finish contract for the destination adapters. Every draft that
-- carries a video is bound to the exact approved render (review, version, digest):
-- approval requires release_allowed(..., 'social') and, for a member's render, the
-- creator's current marketing consent; owner approval is recorded with the digest and
-- a hash of the copy; any later edit, render revision, approval change or consent
-- withdrawal moves the draft back to draft or to invalidated. Cadence can only queue
-- drafts the owner already approved; it never approves. Nothing posts from here: the
-- adapters (backend/publishing/destinations.py) post only when configured and never
-- during development tests.
begin;
create table sdi_private.brand_voice_versions (
 version integer primary key check(version>0), body text not null check(length(body) between 1 and 20000),
 author uuid not null references auth.users(id), created_at timestamptz not null default clock_timestamp()
);
create table sdi_private.marketing_campaigns (
 id uuid primary key default gen_random_uuid(), title text not null check(length(title) between 1 and 120), goal text not null default '' check(length(goal)<=1000),
 state text not null default 'draft' check(state in('draft','active','archived')), created_by uuid not null references auth.users(id),
 revision bigint not null default 1, created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp()
);
create table sdi_private.marketing_drafts (
 id uuid primary key default gen_random_uuid(), campaign_id uuid not null references sdi_private.marketing_campaigns(id) on delete cascade,
 destination text not null check(destination in('discord','facebook','x','youtube','instagram','tiktok','email')),
 review_id uuid references sdi_private.render_reviews(id) on delete set null, review_version bigint, render_digest text check(render_digest ~ '^[a-f0-9]{64}$'),
 copy text not null check(length(copy) between 1 and 2000), scheduled_for timestamptz,
 state text not null default 'draft' check(state in('draft','approved','queued','leased','published','failed','cancelled','invalidated')),
 approved_by uuid references auth.users(id), approved_at timestamptz, approved_digest text, approved_copy_hash text, brand_voice_version integer,
 attempts integer not null default 0, lease uuid, lease_expires timestamptz, provider_ref text, result_url text, last_error text not null default '',
 created_by uuid not null references auth.users(id), revision bigint not null default 1,
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 check((review_id is null)=(render_digest is null))
);
create table sdi_private.marketing_cadence (
 destination text primary key check(destination in('discord','facebook','x','youtube','instagram','tiktok','email')),
 enabled boolean not null default false, cadence text not null default 'weekly' check(cadence in('daily','weekly')),
 hour_utc integer not null default 16 check(hour_utc between 0 and 23), weekday integer check(weekday between 0 and 6),
 last_run_at timestamptz, updated_by uuid references auth.users(id), updated_at timestamptz not null default clock_timestamp()
);
create table sdi_private.marketing_audit (
 id uuid primary key default gen_random_uuid(), actor uuid not null references auth.users(id), draft_id uuid, action text not null,
 reason text not null check(length(reason) between 1 and 2000), created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.brand_voice_versions enable row level security;
alter table sdi_private.marketing_campaigns enable row level security;
alter table sdi_private.marketing_drafts enable row level security;
alter table sdi_private.marketing_cadence enable row level security;
alter table sdi_private.marketing_audit enable row level security;
revoke all on sdi_private.brand_voice_versions,sdi_private.marketing_campaigns,sdi_private.marketing_drafts,sdi_private.marketing_cadence,sdi_private.marketing_audit from public,anon,authenticated;
create index marketing_drafts_queue on sdi_private.marketing_drafts(state,scheduled_for,created_at);
create index marketing_drafts_review on sdi_private.marketing_drafts(review_id);

-- A render revision or approval change invalidates approved, queued or leased drafts
-- bound to it (publishing's own triggers already handle its jobs).
create function sdi_private.marketing_invalidate_render() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if row(new.version,new.render_digest,new.state,new.rights_cleared,new.consent_version,new.destinations)
  is distinct from row(old.version,old.render_digest,old.state,old.rights_cleared,old.consent_version,old.destinations) then
  update sdi_private.marketing_drafts set state='invalidated',last_error='Render or its approval changed after marketing approval.',revision=revision+1,updated_at=clock_timestamp()
  where review_id=new.id and state in('approved','queued','leased') and not (new.state='approved' and new.rights_cleared and length(new.consent_version)>0
   and review_version=new.version and render_digest=new.render_digest and 'social'=any(new.destinations));
 end if;
 return new;
end $$;
revoke all on function sdi_private.marketing_invalidate_render() from public,anon,authenticated;
create trigger marketing_invalidate_render after update on sdi_private.render_reviews for each row execute function sdi_private.marketing_invalidate_render();
-- Withdrawing marketing consent invalidates drafts that use that creator's renders.
create function sdi_private.marketing_invalidate_consent() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.policy='marketing' and new.withdrawn_at is not null and old.withdrawn_at is null then
  update sdi_private.marketing_drafts d set state='invalidated',last_error='Creator withdrew marketing permission.',revision=revision+1,updated_at=clock_timestamp()
  from sdi_private.render_reviews r where r.id=d.review_id and r.creator=new.user_id and not r.spatter_generated and d.state in('approved','queued','leased');
 end if;
 return new;
end $$;
revoke all on function sdi_private.marketing_invalidate_consent() from public,anon,authenticated;
create trigger marketing_invalidate_consent after update on sdi_private.consent_records for each row execute function sdi_private.marketing_invalidate_consent();

create function sdi_private.marketing_release_ok(d sdi_private.marketing_drafts) returns text language plpgsql stable security definer set search_path='' as $$
declare r sdi_private.render_reviews;
begin
 if d.review_id is null then return null; end if;
 select * into r from sdi_private.render_reviews where id=d.review_id;
 if not found then return 'Render no longer exists.'; end if;
 if not sdi_private.release_allowed(d.review_id,d.review_version,d.render_digest,'social') then return 'This exact render lacks current approval, rights or consent for social release.'; end if;
 if not r.spatter_generated and not sdi_private.consent_current(r.creator,'marketing') then return 'The creator has not given current marketing permission.'; end if;
 return null;
end $$;
revoke all on function sdi_private.marketing_release_ok(sdi_private.marketing_drafts) from public,anon,authenticated;

create function sdi_private.marketing_action(action text,campaign uuid default null,draft uuid default null,revision bigint default null,payload jsonb default '{}',reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare denial jsonb; c sdi_private.marketing_campaigns; d sdi_private.marketing_drafts; r sdi_private.render_reviews; items jsonb; problem text; is_owner boolean; next_version integer;
begin
 denial:=sdi_private.admin_gate('marketing.'||coalesce(action,'?'),'publishing',action in('approve','set_cadence','brand_voice'),60);
 if denial is not null then return denial; end if;
 select owner into is_owner from sdi_private.admin_roles where user_id=auth.uid() and enabled;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(x) order by x.updated_at desc),'[]'::jsonb) into items from (select * from sdi_private.marketing_campaigns order by updated_at desc limit 100) x;
  return jsonb_build_object('campaigns',items,
   'drafts',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'campaign_id',m.campaign_id,'destination',m.destination,'review_id',m.review_id,'render_digest',m.render_digest,'copy',m.copy,
     'scheduled_for',m.scheduled_for,'state',m.state,'approved_at',m.approved_at,'result_url',m.result_url,'provider_ref',m.provider_ref,'last_error',m.last_error,'attempts',m.attempts,'revision',m.revision,
     'release_problem',sdi_private.marketing_release_ok(m)) order by m.updated_at desc),'[]'::jsonb)
     from (select id from sdi_private.marketing_drafts order by updated_at desc limit 200) s join sdi_private.marketing_drafts m on m.id=s.id),
   'cadence',(select coalesce(jsonb_agg(row_to_json(k) order by k.destination),'[]'::jsonb) from sdi_private.marketing_cadence k),
   'brand_voice_version',(select max(version) from sdi_private.brand_voice_versions));
 elsif action='brand_voice_list' then
  select coalesce(jsonb_agg(row_to_json(v) order by v.version desc),'[]'::jsonb) into items from sdi_private.brand_voice_versions v;
  return jsonb_build_object('versions',items);
 end if;
 if reason is null or length(trim(reason)) not between 1 and 2000 then return jsonb_build_object('error','A reason is required.'); end if;
 if action in('approve','set_cadence','brand_voice') and not coalesce(is_owner,false) then return jsonb_build_object('error','Owner permission required.'); end if;
 if action='brand_voice' then
  if length(coalesce(payload->>'body','')) not between 1 and 20000 then return jsonb_build_object('error','Brand voice text of at most 20000 characters required.'); end if;
  select coalesce(max(version),0)+1 into next_version from sdi_private.brand_voice_versions;
  insert into sdi_private.brand_voice_versions(version,body,author) values(next_version,payload->>'body',auth.uid());
  insert into sdi_private.marketing_audit(actor,action,reason) values(auth.uid(),'brand_voice v'||next_version,trim(reason));
  return jsonb_build_object('status','confirmed','version',next_version);
 elsif action='set_cadence' then
  if coalesce(payload->>'destination','') not in('discord','facebook','x','youtube','instagram','tiktok','email') or (payload->>'enabled') is null
   or coalesce(payload->>'cadence','weekly') not in('daily','weekly') or coalesce(payload->>'hour_utc','16') !~ '^([0-9]|1[0-9]|2[0-3])$'
   or (payload ? 'weekday' and (payload->>'weekday') !~ '^[0-6]$') then return jsonb_build_object('error','Destination, enabled, cadence, hour_utc and weekday required.'); end if;
  insert into sdi_private.marketing_cadence(destination,enabled,cadence,hour_utc,weekday,updated_by) values(payload->>'destination',(payload->>'enabled')::boolean,coalesce(payload->>'cadence','weekly'),
   coalesce(payload->>'hour_utc','16')::integer,(payload->>'weekday')::integer,auth.uid())
  on conflict(destination) do update set enabled=excluded.enabled,cadence=excluded.cadence,hour_utc=excluded.hour_utc,weekday=excluded.weekday,updated_by=excluded.updated_by,updated_at=clock_timestamp();
  insert into sdi_private.marketing_audit(actor,action,reason) values(auth.uid(),'set_cadence '||(payload->>'destination')||' enabled='||(payload->>'enabled'),trim(reason));
  return jsonb_build_object('status','confirmed');
 elsif action='create_campaign' then
  if length(coalesce(payload->>'title','')) not between 1 and 120 or length(coalesce(payload->>'goal',''))>1000 then return jsonb_build_object('error','Campaign title required.'); end if;
  insert into sdi_private.marketing_campaigns(title,goal,created_by) values(payload->>'title',coalesce(payload->>'goal',''),auth.uid()) returning * into c;
  insert into sdi_private.marketing_audit(actor,action,reason) values(auth.uid(),'create_campaign '||c.id,trim(reason));
  return jsonb_build_object('status','confirmed','campaign',c.id,'revision',c.revision);
 elsif action='create_draft' then
  select * into c from sdi_private.marketing_campaigns where id=campaign;
  if not found or c.state='archived' then return jsonb_build_object('error','Campaign unavailable.'); end if;
  if coalesce(payload->>'destination','') not in('discord','facebook','x','youtube','instagram','tiktok','email') or length(coalesce(payload->>'copy','')) not between 1 and 2000 then
   return jsonb_build_object('error','Destination and copy of at most 2000 characters required.'); end if;
  if payload->>'review' is not null then
   select * into r from sdi_private.render_reviews where id=(payload->>'review')::uuid;
   if not found then return jsonb_build_object('error','Render unavailable.'); end if;
  end if;
  insert into sdi_private.marketing_drafts(campaign_id,destination,review_id,review_version,render_digest,copy,scheduled_for,created_by)
  values(c.id,payload->>'destination',r.id,r.version,r.render_digest,payload->>'copy',(payload->>'scheduled_for')::timestamptz,auth.uid()) returning * into d;
  insert into sdi_private.marketing_audit(actor,draft_id,action,reason) values(auth.uid(),d.id,'create_draft',trim(reason));
  return jsonb_build_object('status','draft','draft',d.id,'revision',d.revision,'release_problem',sdi_private.marketing_release_ok(d));
 end if;
 select * into d from sdi_private.marketing_drafts where id=draft for update;
 if not found or revision is distinct from d.revision then return jsonb_build_object('error','Draft changed. Refresh before saving.'); end if;
 if action='update_draft' then
  if d.state not in('draft','approved','failed','invalidated') then return jsonb_build_object('error','Queued or finished drafts cannot be edited.'); end if;
  if payload ? 'copy' and length(coalesce(payload->>'copy','')) not between 1 and 2000 then return jsonb_build_object('error','Copy of at most 2000 characters required.'); end if;
  if payload ? 'review' then
   if payload->>'review' is null then r:=null; else
    select * into r from sdi_private.render_reviews where id=(payload->>'review')::uuid;
    if not found then return jsonb_build_object('error','Render unavailable.'); end if;
   end if;
   update sdi_private.marketing_drafts set review_id=r.id,review_version=r.version,render_digest=r.render_digest where id=d.id;
  end if;
  -- Any edit clears approval: the owner approves exact copy and exact render.
  update sdi_private.marketing_drafts set copy=coalesce(payload->>'copy',copy),scheduled_for=case when payload ? 'scheduled_for' then (payload->>'scheduled_for')::timestamptz else scheduled_for end,
   state='draft',approved_by=null,approved_at=null,approved_digest=null,approved_copy_hash=null,last_error='',revision=revision+1,updated_at=clock_timestamp() where id=d.id;
 elsif action='approve' then
  if d.state<>'draft' then return jsonb_build_object('error','Only drafts can be approved.'); end if;
  problem:=sdi_private.marketing_release_ok(d);
  if problem is not null then return jsonb_build_object('error',problem); end if;
  update sdi_private.marketing_drafts set state='approved',approved_by=auth.uid(),approved_at=clock_timestamp(),approved_digest=render_digest,
   approved_copy_hash=encode(extensions.digest(copy,'sha256'),'hex'),brand_voice_version=(select max(version) from sdi_private.brand_voice_versions),
   revision=revision+1,updated_at=clock_timestamp() where id=d.id;
 elsif action='queue' then
  if d.state<>'approved' then return jsonb_build_object('error','Approve the draft first.'); end if;
  problem:=sdi_private.marketing_release_ok(d);
  if problem is not null then update sdi_private.marketing_drafts set state='invalidated',last_error=problem,revision=revision+1,updated_at=clock_timestamp() where id=d.id; return jsonb_build_object('error',problem); end if;
  update sdi_private.marketing_drafts set state='queued',attempts=0,revision=revision+1,updated_at=clock_timestamp() where id=d.id;
 elsif action='cancel' then
  if d.state in('published','cancelled') then return jsonb_build_object('status','unchanged','state',d.state); end if;
  update sdi_private.marketing_drafts set state='cancelled',lease=null,lease_expires=null,last_error=case when d.state='leased' then 'Cancelled while the adapter was posting; check the provider.' else last_error end,
   revision=revision+1,updated_at=clock_timestamp() where id=d.id;
 elsif action='retry' then
  if d.state<>'failed' or d.attempts>=5 then return jsonb_build_object('error','Only failed drafts with attempts left can be retried.'); end if;
  problem:=sdi_private.marketing_release_ok(d);
  if problem is not null then return jsonb_build_object('error',problem); end if;
  update sdi_private.marketing_drafts set state='queued',revision=revision+1,updated_at=clock_timestamp() where id=d.id;
 else return jsonb_build_object('error','Unsupported marketing operation.'); end if;
 insert into sdi_private.marketing_audit(actor,draft_id,action,reason) values(auth.uid(),d.id,action,trim(reason));
 return jsonb_build_object('status','confirmed','revision',d.revision+1);
exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
 return jsonb_build_object('error','Invalid identifier or time.');
end $$;
revoke all on function sdi_private.marketing_action(text,uuid,uuid,bigint,jsonb,text) from public,anon;
grant execute on function sdi_private.marketing_action(text,uuid,uuid,bigint,jsonb,text) to authenticated;
create function public.sdi_marketing_action(action text,campaign uuid default null,draft uuid default null,revision bigint default null,payload jsonb default '{}',reason text default '')
returns jsonb language sql security invoker set search_path='' as $$select sdi_private.marketing_action(action,campaign,draft,revision,payload,reason)$$;
revoke all on function public.sdi_marketing_action(text,uuid,uuid,bigint,jsonb,text) from public,anon;
grant execute on function public.sdi_marketing_action(text,uuid,uuid,bigint,jsonb,text) to authenticated;

-- Service: lease one due approved+queued draft after re-checking the binding;
-- finish with the provider's real result or a failure. Posting happens only in the
-- adapter, which refuses unconfigured destinations and dry-runs during development.
create function sdi_private.marketing_claim() returns jsonb language plpgsql security definer set search_path='' as $$
declare d sdi_private.marketing_drafts; problem text; media text; a sdi_private.render_artifacts;
begin
 update sdi_private.marketing_drafts set state='failed',last_error='Adapter lease expired; verify the provider before retrying.',lease=null,lease_expires=null,updated_at=clock_timestamp()
 where state='leased' and lease_expires<clock_timestamp();
 select * into d from sdi_private.marketing_drafts where state='queued' and (scheduled_for is null or scheduled_for<=clock_timestamp()) and attempts<5
  order by scheduled_for nulls first,created_at for update skip locked limit 1;
 if not found then return jsonb_build_object('empty',true); end if;
 problem:=sdi_private.marketing_release_ok(d);
 if problem is not null or d.approved_digest is distinct from d.render_digest or d.approved_copy_hash<>encode(extensions.digest(d.copy,'sha256'),'hex') then
  update sdi_private.marketing_drafts set state='invalidated',last_error=coalesce(problem,'Approved render or copy no longer matches.'),updated_at=clock_timestamp() where id=d.id;
  return jsonb_build_object('empty',true);
 end if;
 if d.review_id is not null then
  select url into media from public.sdi_watch_media where render_digest=d.render_digest and approved;
  select * into a from sdi_private.render_artifacts where review_id=d.review_id and version=d.review_version;
 end if;
 update sdi_private.marketing_drafts set state='leased',attempts=attempts+1,lease=gen_random_uuid(),lease_expires=clock_timestamp()+interval '5 minutes',updated_at=clock_timestamp() where id=d.id returning * into d;
 return jsonb_build_object('draft',d.id,'lease',d.lease,'destination',d.destination,'copy',d.copy,'digest',d.render_digest,'media_url',media,
  'object_key',a.object_key,'byte_count',a.byte_count,'title',a.title,'brand_voice_version',d.brand_voice_version,'attempt',d.attempts);
end $$;
create function sdi_private.marketing_finish(draft uuid,token uuid,result_url text default null,provider_ref text default null,failure text default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare d sdi_private.marketing_drafts;
begin
 select * into d from sdi_private.marketing_drafts where id=draft and lease=token for update;
 if not found then return false; end if;
 if d.state='cancelled' then
  -- Cancelled during the post: record what the provider did so an operator can act.
  update sdi_private.marketing_drafts set provider_ref=coalesce(marketing_finish.provider_ref,d.provider_ref),result_url=coalesce(marketing_finish.result_url,d.result_url),
   last_error=case when failure is null and marketing_finish.result_url is not null then 'Posted before cancellation was observed; remove at the provider if required.' else last_error end,lease=null,lease_expires=null,updated_at=clock_timestamp() where id=d.id;
  return false;
 end if;
 if d.state<>'leased' then return false; end if;
 if failure is not null then
  update sdi_private.marketing_drafts set state='failed',last_error=left(failure,500),lease=null,lease_expires=null,updated_at=clock_timestamp() where id=d.id;
  return true;
 end if;
 if d.destination='email' then
  -- An email blast has no public URL: success is the count the worker actually
  -- enqueued for opted-in, unsuppressed recipients (backend/mail/queue.py).
  if marketing_finish.result_url is not null or coalesce(marketing_finish.provider_ref,'') !~ '^email-queue:[1-9][0-9]{0,6}$' then return false; end if;
 elsif marketing_finish.result_url is null or marketing_finish.result_url !~ '^https://' or length(marketing_finish.result_url)>2048 then return false; end if;
 update sdi_private.marketing_drafts set state='published',result_url=marketing_finish.result_url,provider_ref=left(coalesce(marketing_finish.provider_ref,''),200),last_error='',lease=null,lease_expires=null,updated_at=clock_timestamp() where id=d.id;
 return true;
end $$;
-- Cadence sweep: for each enabled destination whose slot has passed, queue the
-- earliest approved draft that is due. Approval is never granted here.
create function sdi_private.marketing_cadence_due() returns jsonb language plpgsql security definer set search_path='' as $$
declare k sdi_private.marketing_cadence; d sdi_private.marketing_drafts; slot timestamptz; queued jsonb:='[]'; problem text;
begin
 for k in select * from sdi_private.marketing_cadence where enabled for update loop
  slot:=date_trunc('day',clock_timestamp())+make_interval(hours=>k.hour_utc);
  if slot>clock_timestamp() then slot:=slot-interval '1 day'; end if;
  if k.cadence='weekly' then
   slot:=slot-make_interval(days=>((extract(dow from slot)::integer-coalesce(k.weekday,1))+7)%7);
  end if;
  if k.last_run_at is not null and k.last_run_at>=slot then continue; end if;
  update sdi_private.marketing_cadence set last_run_at=clock_timestamp() where destination=k.destination;
  select * into d from sdi_private.marketing_drafts where destination=k.destination and state='approved' and (scheduled_for is null or scheduled_for<=clock_timestamp())
   order by scheduled_for nulls last,created_at for update skip locked limit 1;
  if not found then continue; end if;
  problem:=sdi_private.marketing_release_ok(d);
  if problem is not null then
   update sdi_private.marketing_drafts set state='invalidated',last_error=problem,revision=revision+1,updated_at=clock_timestamp() where id=d.id; continue; end if;
  update sdi_private.marketing_drafts set state='queued',attempts=0,revision=revision+1,updated_at=clock_timestamp() where id=d.id;
  queued:=queued||jsonb_build_object('draft',d.id,'destination',k.destination);
 end loop;
 return jsonb_build_object('queued',queued,'measured_at',clock_timestamp());
end $$;
revoke all on function sdi_private.marketing_claim(),sdi_private.marketing_finish(uuid,uuid,text,text,text),sdi_private.marketing_cadence_due() from public,anon,authenticated;
grant execute on function sdi_private.marketing_claim(),sdi_private.marketing_finish(uuid,uuid,text,text,text),sdi_private.marketing_cadence_due() to service_role;
create function public.sdi_marketing_claim() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.marketing_claim()$$;
create function public.sdi_marketing_finish(draft uuid,token uuid,result_url text default null,provider_ref text default null,failure text default null) returns boolean
language sql security invoker set search_path='' as $$select sdi_private.marketing_finish(draft,token,result_url,provider_ref,failure)$$;
create function public.sdi_marketing_cadence_due() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.marketing_cadence_due()$$;
revoke all on function public.sdi_marketing_claim(),public.sdi_marketing_finish(uuid,uuid,text,text,text),public.sdi_marketing_cadence_due() from public,anon,authenticated;
grant execute on function public.sdi_marketing_claim(),public.sdi_marketing_finish(uuid,uuid,text,text,text),public.sdi_marketing_cadence_due() to service_role;
commit;
