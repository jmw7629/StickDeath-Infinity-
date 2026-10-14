-- Unapplied candidate (#238). Install after worker-configuration.sql and before
-- security-audit-integrity.sql. Server-side credential slots for provider keys and
-- the owner's OAuth refresh grant. The secret value lives only in the project's
-- existing secret store (Supabase Vault: encrypted at rest, readable only by the
-- database owner role); this schema keeps the slot's state, revision, a short
-- fingerprint and an audit trail, never the value. Only the service role can store,
-- load, rotate or revoke; administrators read presence and rotation status only.
-- When Vault is not enabled every call reports that plainly and nothing is stored.
-- Clients (iOS, Android, web) never call these functions and never hold these values.
begin;
create table sdi_private.credential_slots (
 slot text primary key check(slot ~ '^[a-z0-9_]{1,40}$'),
 purpose text not null check(length(purpose) between 1 and 200),
 store_ref uuid,
 state text not null default 'unconfigured' check(state in('unconfigured','active','reconnect_required','revoked')),
 revision bigint not null default 0,
 fingerprint text not null default '' check(fingerprint ~ '^([a-f0-9]{12})?$'),
 rotate_after_days integer not null default 90 check(rotate_after_days between 1 and 730),
 rotated_at timestamptz, revoked_at timestamptz, updated_at timestamptz not null default clock_timestamp()
);
create table sdi_private.credential_audit (
 id uuid primary key default gen_random_uuid(), slot text not null, action text not null check(action in('store','rotate','revoke','state','load_refused')),
 revision bigint not null, detail text not null default '' check(length(detail)<=200), created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.credential_slots enable row level security;
alter table sdi_private.credential_audit enable row level security;
revoke all on sdi_private.credential_slots,sdi_private.credential_audit from public,anon,authenticated;
insert into sdi_private.credential_slots(slot,purpose) values
 ('youtube_owner_grant','Owner channel OAuth client and refresh token (publishing worker)'),
 ('stripe_api','Stripe restricted API key (billing worker)'),
 ('stripe_webhook','Stripe webhook signing secret'),
 ('appstore_server','App Store Server API key'),
 ('push_apns','Apple Push Notification service key'),
 ('push_fcm','Firebase Cloud Messaging service credential'),
 ('mail_provider','Transactional mail provider key'),
 ('ai_provider','App-owned AI provider key (Spatter service)');

create function sdi_private.vault_ready() returns boolean language sql stable security definer set search_path='' as $$
 select to_regnamespace('vault') is not null and to_regclass('vault.decrypted_secrets') is not null
  and to_regprocedure('vault.create_secret(text,text,text,uuid)') is not null
$$;
revoke all on function sdi_private.vault_ready() from public,anon,authenticated;

-- Store or rotate. The previous Vault secret is deleted only after the new one exists,
-- so a failed rotation keeps the last working credential.
create function sdi_private.credential_store(slot text,secret text,detail text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare s sdi_private.credential_slots; created uuid; rotating boolean; print text;
begin
 if not sdi_private.vault_ready() then return jsonb_build_object('error','Server secret store is not enabled. Nothing was stored.'); end if;
 select * into s from sdi_private.credential_slots where slot=credential_store.slot for update;
 if not found then return jsonb_build_object('error','Unknown credential slot.'); end if;
 if secret is null or length(secret) not between 16 and 16384 or secret ~ '^\s|\s$' then
  return jsonb_build_object('error','Credential value rejected (length or surrounding whitespace). Nothing was stored.'); end if;
 rotating:=s.store_ref is not null;
 print:=left(encode(extensions.digest(secret,'sha256'),'hex'),12);
 execute 'select vault.create_secret($1,$2,$3)' into created using secret,'sdi_'||s.slot||'_r'||(s.revision+1),'SDI credential slot '||s.slot;
 if rotating then execute 'delete from vault.secrets where id=$1' using s.store_ref; end if;
 update sdi_private.credential_slots set store_ref=created,state='active',revision=s.revision+1,fingerprint=print,
  rotated_at=clock_timestamp(),revoked_at=null,updated_at=clock_timestamp() where slot=s.slot;
 insert into sdi_private.credential_audit(slot,action,revision,detail) values(s.slot,case when rotating then 'rotate' else 'store' end,s.revision+1,left(coalesce(detail,''),200));
 return jsonb_build_object('status',case when rotating then 'rotated' else 'stored' end,'revision',s.revision+1,'fingerprint',print);
end $$;

-- Load for a worker. Missing, revoked or reconnect-required slots return no value.
create function sdi_private.credential_load(slot text) returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare s sdi_private.credential_slots; value text;
begin
 select * into s from sdi_private.credential_slots where slot=credential_load.slot;
 if not found then return jsonb_build_object('configured',false,'state','unknown'); end if;
 if s.state<>'active' or s.store_ref is null then return jsonb_build_object('configured',false,'state',s.state,'revision',s.revision); end if;
 if not sdi_private.vault_ready() then return jsonb_build_object('configured',false,'state','store_unavailable','revision',s.revision); end if;
 execute 'select decrypted_secret from vault.decrypted_secrets where id=$1' into value using s.store_ref;
 if value is null then
  insert into sdi_private.credential_audit(slot,action,revision,detail) values(s.slot,'load_refused',s.revision,'Secret missing from the store.');
  return jsonb_build_object('configured',false,'state','store_missing','revision',s.revision);
 end if;
 return jsonb_build_object('configured',true,'state','active','revision',s.revision,'secret',value);
end $$;

-- Compare-and-set state from a worker (e.g. the provider answered invalid_grant). A
-- stale revision never overwrites a credential linked after the worker loaded its copy.
create function sdi_private.credential_record_state(slot text,revision bigint,state text) returns boolean
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
begin
 if credential_record_state.state not in('active','reconnect_required') then return false; end if;
 update sdi_private.credential_slots c set state=credential_record_state.state,updated_at=clock_timestamp()
  where c.slot=credential_record_state.slot and c.revision=credential_record_state.revision and c.store_ref is not null and c.state<>'revoked';
 if not found then return false; end if;
 insert into sdi_private.credential_audit(slot,action,revision,detail) values(credential_record_state.slot,'state',credential_record_state.revision,credential_record_state.state);
 return true;
end $$;

-- Revoke: the stored value is destroyed. Revocation at the provider (Google account
-- permissions, Stripe key roll) is a separate owner step listed in the runbook.
create function sdi_private.credential_revoke(slot text,detail text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare s sdi_private.credential_slots;
begin
 select * into s from sdi_private.credential_slots where slot=credential_revoke.slot for update;
 if not found then return jsonb_build_object('error','Unknown credential slot.'); end if;
 if s.store_ref is not null and sdi_private.vault_ready() then execute 'delete from vault.secrets where id=$1' using s.store_ref; end if;
 update sdi_private.credential_slots set store_ref=null,state='revoked',revision=s.revision+1,fingerprint='',revoked_at=clock_timestamp(),updated_at=clock_timestamp() where slot=s.slot;
 insert into sdi_private.credential_audit(slot,action,revision,detail) values(s.slot,'revoke',s.revision+1,left(coalesce(detail,''),200));
 return jsonb_build_object('status','revoked','revision',s.revision+1);
end $$;
revoke all on function sdi_private.credential_store(text,text,text),sdi_private.credential_load(text),
 sdi_private.credential_record_state(text,bigint,text),sdi_private.credential_revoke(text,text) from public,anon,authenticated;
grant execute on function sdi_private.credential_store(text,text,text),sdi_private.credential_load(text),
 sdi_private.credential_record_state(text,bigint,text),sdi_private.credential_revoke(text,text) to service_role;

-- Administrator view: presence, state, fingerprint and rotation due. Never the value.
create function sdi_private.credential_status() returns jsonb language plpgsql security definer set search_path='' as $$
declare denial jsonb; items jsonb;
begin
 denial:=sdi_private.admin_gate('credential_status','overview',false,60);
 if denial is not null then return denial; end if;
 select coalesce(jsonb_agg(jsonb_build_object('slot',c.slot,'purpose',c.purpose,'state',c.state,'revision',c.revision,'fingerprint',c.fingerprint,
   'rotated_at',c.rotated_at,'rotation_due',c.state='active' and c.rotated_at<clock_timestamp()-make_interval(days=>c.rotate_after_days)) order by c.slot),'[]'::jsonb)
  into items from sdi_private.credential_slots c;
 return jsonb_build_object('store_ready',sdi_private.vault_ready(),'slots',items,'note','Presence only. Values live in the server secret store and are never returned here.');
end $$;
revoke all on function sdi_private.credential_status() from public,anon;
grant execute on function sdi_private.credential_status() to authenticated;

create function public.sdi_credential_store(slot text,secret text,detail text default '') returns jsonb language sql security invoker set search_path='' as $$select sdi_private.credential_store(slot,secret,detail)$$;
create function public.sdi_credential_load(slot text) returns jsonb language sql security invoker set search_path='' as $$select sdi_private.credential_load(slot)$$;
create function public.sdi_credential_record_state(slot text,revision bigint,state text) returns boolean language sql security invoker set search_path='' as $$select sdi_private.credential_record_state(slot,revision,state)$$;
create function public.sdi_credential_revoke(slot text,detail text default '') returns jsonb language sql security invoker set search_path='' as $$select sdi_private.credential_revoke(slot,detail)$$;
revoke all on function public.sdi_credential_store(text,text,text),public.sdi_credential_load(text),
 public.sdi_credential_record_state(text,bigint,text),public.sdi_credential_revoke(text,text) from public,anon,authenticated;
grant execute on function public.sdi_credential_store(text,text,text),public.sdi_credential_load(text),
 public.sdi_credential_record_state(text,bigint,text),public.sdi_credential_revoke(text,text) to service_role;
create function public.sdi_credential_status() returns jsonb language sql security invoker set search_path='' as $$select sdi_private.credential_status()$$;
revoke all on function public.sdi_credential_status() from public,anon;
grant execute on function public.sdi_credential_status() to authenticated;
commit;
