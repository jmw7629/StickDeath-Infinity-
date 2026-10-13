-- Unapplied candidate. Install after billing-finance.sql (needs admin-hardening.sql,
-- creator-reviews.sql and publishing-withdrawal.sql). Consent-version registry for
-- #174, #261, #273 and #262: the owner publishes policy versions (terms, privacy,
-- publishing permission, marketing permission, content/age policy); members accept
-- exactly the current version from a named surface; publishing and marketing consent
-- are separate and separately withdrawable; a publishing withdrawal clears the
-- consent on every render of that creator, which the existing trigger turns into
-- job cancellation, removal or reconciliation. The intake service verifies the
-- submitted consent version with consent_verify before registering a render. The
-- content policy carries its age rule as metadata the owner sets (min_age); the
-- member records an attestation, the server never guesses an age.
begin;
create table sdi_private.policy_versions (
 policy text not null check(policy in('terms','privacy','publishing','marketing','content')),
 version text not null check(version ~ '^[a-z0-9][a-z0-9.-]{0,99}$'),
 summary text not null check(length(summary) between 1 and 2000),
 metadata jsonb not null default '{}' check(jsonb_typeof(metadata)='object'),
 effective_at timestamptz not null, created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default clock_timestamp(), primary key(policy,version)
);
create table sdi_private.consent_records (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 policy text not null, version text not null, source text not null check(source in('ios','android','web')),
 attestation jsonb not null default '{}' check(jsonb_typeof(attestation)='object'),
 accepted_at timestamptz not null default clock_timestamp(), withdrawn_at timestamptz,
 foreign key(policy,version) references sdi_private.policy_versions(policy,version), unique(user_id,policy,version)
);
create table sdi_private.consent_audit (
 id uuid primary key default gen_random_uuid(), actor uuid references auth.users(id) on delete set null, action text not null,
 policy text, version text, reason text not null default '', created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.policy_versions enable row level security;
alter table sdi_private.consent_records enable row level security;
alter table sdi_private.consent_audit enable row level security;
revoke all on sdi_private.policy_versions,sdi_private.consent_records,sdi_private.consent_audit from public,anon,authenticated;
create index consent_records_user on sdi_private.consent_records(user_id,policy);

create function sdi_private.policy_current(policy text) returns text language sql stable security definer set search_path='' as $$
 select v.version from sdi_private.policy_versions v where v.policy=policy_current.policy and v.effective_at<=clock_timestamp()
 order by v.effective_at desc,v.created_at desc limit 1
$$;
-- True when the subject holds an unwithdrawn acceptance of the given version (or of
-- the current version when none is given). A content policy with min_age also needs
-- the recorded attestation.
create function sdi_private.consent_current(subject uuid,policy text,version text default null) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from sdi_private.consent_records c join sdi_private.policy_versions v on v.policy=c.policy and v.version=c.version
  where c.user_id=subject and c.policy=consent_current.policy and c.withdrawn_at is null
  and c.version=coalesce(consent_current.version,sdi_private.policy_current(consent_current.policy))
  and (v.metadata->>'min_age' is null or (c.attestation->>'age_ok')='true'))
$$;
revoke all on function sdi_private.policy_current(text),sdi_private.consent_current(uuid,text,text) from public,anon,authenticated;

create function sdi_private.consent_action(action text,policy text default null,version text default null,source text default null,
 attestation jsonb default '{}',summary text default null,metadata jsonb default '{}',effective_at timestamptz default null,reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare actor uuid:=auth.uid(); items jsonb; current_version text; denial jsonb; affected integer;
begin
 if action='current' then
  select coalesce(jsonb_agg(jsonb_build_object('policy',t.policy,'version',t.version,'summary',t.summary,'metadata',t.metadata,'effective_at',t.effective_at) order by t.policy),'[]'::jsonb)
   into items from (select distinct on (v.policy) v.* from sdi_private.policy_versions v where v.effective_at<=clock_timestamp() order by v.policy,v.effective_at desc,v.created_at desc) t;
  return jsonb_build_object('policies',items);
 end if;
 if action in('mine','accept','withdraw') then
  if actor is null or not sdi_private.account_active() or not exists(select 1 from auth.users where id=actor and not is_anonymous) then
   return jsonb_build_object('error','Sign in with a full account.'); end if;
  if action='mine' then
   select coalesce(jsonb_agg(jsonb_build_object('policy',c.policy,'version',c.version,'source',c.source,'accepted_at',c.accepted_at,'withdrawn_at',c.withdrawn_at,
    'current',c.version=sdi_private.policy_current(c.policy) and c.withdrawn_at is null) order by c.policy,c.accepted_at desc),'[]'::jsonb) into items
    from sdi_private.consent_records c where c.user_id=actor;
   return jsonb_build_object('consents',items,'publishing_current',sdi_private.consent_current(actor,'publishing'),'marketing_current',sdi_private.consent_current(actor,'marketing'));
  end if;
  if policy is null or policy not in('terms','privacy','publishing','marketing','content') then return jsonb_build_object('error','Unknown policy.'); end if;
  if action='accept' then
   current_version:=sdi_private.policy_current(policy);
   if current_version is null then return jsonb_build_object('error','This policy has not been published yet.'); end if;
   if version is distinct from current_version then return jsonb_build_object('error','Policy version changed. Review the current version before accepting.','current',current_version); end if;
   if source is null or source not in('ios','android','web') then return jsonb_build_object('error','Record the surface where consent was given.'); end if;
   if exists(select 1 from sdi_private.policy_versions v where v.policy=consent_action.policy and v.version=current_version and v.metadata->>'min_age' is not null)
    and (attestation->>'age_ok') is distinct from 'true' then
    return jsonb_build_object('error','Confirm you meet the minimum age in the content policy.'); end if;
   insert into sdi_private.consent_records(user_id,policy,version,source,attestation) values(actor,policy,current_version,source,coalesce(attestation,'{}'))
   on conflict(user_id,policy,version) do update set withdrawn_at=null,accepted_at=clock_timestamp(),source=excluded.source,attestation=excluded.attestation;
   insert into sdi_private.consent_audit(actor,action,policy,version) values(actor,'accept',policy,current_version);
   return jsonb_build_object('status','accepted','policy',policy,'version',current_version);
  end if;
  -- withdraw
  if policy not in('publishing','marketing') then return jsonb_build_object('error','Only publishing and marketing permissions can be withdrawn here; terms, privacy and content policies end with account deletion.'); end if;
  update sdi_private.consent_records set withdrawn_at=clock_timestamp() where user_id=actor and policy=consent_action.policy and withdrawn_at is null;
  get diagnostics affected=row_count;
  if policy='publishing' then
   -- Every render of this creator loses its consent; the publishing triggers cancel
   -- or withdraw jobs that have not published and send live copies to removal.
   update sdi_private.render_reviews set consent_version='',destinations=array[]::text[],state='pending' where creator=actor and length(consent_version)>0;
  end if;
  insert into sdi_private.consent_audit(actor,action,policy) values(actor,'withdraw',policy);
  return jsonb_build_object('status','withdrawn','policy',policy,'records',affected);
 end if;
 if action in('publish','list','audit') then
  denial:=sdi_private.admin_gate('consent_action.'||action,'users',action='publish',30);
  if denial is not null then return denial; end if;
  if action='list' then
   select coalesce(jsonb_agg(row_to_json(v) order by v.policy,v.effective_at desc),'[]'::jsonb) into items from sdi_private.policy_versions v;
   return jsonb_build_object('versions',items,'acceptances',(select coalesce(jsonb_object_agg(t.k,t.n),'{}'::jsonb) from (select c.policy||':'||c.version as k,count(*) as n from sdi_private.consent_records c where c.withdrawn_at is null group by 1) t));
  elsif action='audit' then
   select coalesce(jsonb_agg(row_to_json(a) order by a.created_at desc),'[]'::jsonb) into items from (select * from sdi_private.consent_audit order by created_at desc limit 200) a;
   return jsonb_build_object('audit',items);
  end if;
  if not exists(select 1 from sdi_private.admin_roles where user_id=actor and enabled and owner) then return jsonb_build_object('error','Owner permission required to publish a policy version.'); end if;
  if policy is null or policy not in('terms','privacy','publishing','marketing','content') or version is null or version !~ '^[a-z0-9][a-z0-9.-]{0,99}$'
   or summary is null or length(trim(summary)) not between 1 and 2000 or metadata is null or jsonb_typeof(metadata)<>'object' or reason is null or length(trim(reason)) not between 1 and 2000 then
   return jsonb_build_object('error','Policy, version id, summary, metadata object and reason required.'); end if;
  if policy='content' and coalesce(metadata->>'min_age','') !~ '^[0-9]{1,2}$' then return jsonb_build_object('error','The content policy needs min_age in its metadata (an owner and legal decision).'); end if;
  insert into sdi_private.policy_versions(policy,version,summary,metadata,effective_at,created_by) values(policy,version,trim(summary),metadata,coalesce(effective_at,clock_timestamp()),actor)
  on conflict(policy,version) do nothing;
  if not found then return jsonb_build_object('error','That version id already exists; publish a new version instead of editing history.'); end if;
  insert into sdi_private.consent_audit(actor,action,policy,version,reason) values(actor,'publish',policy,version,trim(reason));
  return jsonb_build_object('status','published','policy',policy,'version',version);
 end if;
 return jsonb_build_object('error','Unsupported consent operation.');
end $$;
revoke all on function sdi_private.consent_action(text,text,text,text,jsonb,text,jsonb,timestamptz,text) from public,anon;
grant execute on function sdi_private.consent_action(text,text,text,text,jsonb,text,jsonb,timestamptz,text) to authenticated;
create function public.sdi_consent_action(action text,policy text default null,version text default null,source text default null,
 attestation jsonb default '{}',summary text default null,metadata jsonb default '{}',effective_at timestamptz default null,reason text default '')
returns jsonb language sql security invoker set search_path='' as $$select sdi_private.consent_action(action,policy,version,source,attestation,summary,metadata,effective_at,reason)$$;
revoke all on function public.sdi_consent_action(text,text,text,text,jsonb,text,jsonb,timestamptz,text) from public,anon;
grant execute on function public.sdi_consent_action(text,text,text,text,jsonb,text,jsonb,timestamptz,text) to authenticated;

-- Service check before a render is registered: the submitted publishing consent
-- version must be the creator's current, unwithdrawn acceptance, and when a content
-- policy is published the creator must also hold its current attested acceptance.
create function sdi_private.consent_verify(subject uuid,version text) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if subject is null or version is null then return jsonb_build_object('allowed',false,'reason','Creator and consent version required.'); end if;
 if sdi_private.policy_current('publishing') is null then return jsonb_build_object('allowed',false,'reason','No publishing policy is published.'); end if;
 if version<>sdi_private.policy_current('publishing') then return jsonb_build_object('allowed',false,'reason','Publishing terms changed. Confirm the current permissions before submitting.'); end if;
 if not sdi_private.consent_current(subject,'publishing',version) then return jsonb_build_object('allowed',false,'reason','Current publishing permission not recorded for this account.'); end if;
 if sdi_private.policy_current('content') is not null and not sdi_private.consent_current(subject,'content') then
  return jsonb_build_object('allowed',false,'reason','Current content policy acceptance and age confirmation required.'); end if;
 return jsonb_build_object('allowed',true,'publishing_version',version,'content_version',sdi_private.policy_current('content'),'marketing',sdi_private.consent_current(subject,'marketing'));
end $$;
revoke all on function sdi_private.consent_verify(uuid,text) from public,anon,authenticated;
grant execute on function sdi_private.consent_verify(uuid,text) to service_role;
create function public.sdi_consent_verify(subject uuid,version text) returns jsonb language sql security invoker set search_path='' as $$select sdi_private.consent_verify(subject,version)$$;
revoke all on function public.sdi_consent_verify(uuid,text) from public,anon,authenticated;
grant execute on function public.sdi_consent_verify(uuid,text) to service_role;
commit;
