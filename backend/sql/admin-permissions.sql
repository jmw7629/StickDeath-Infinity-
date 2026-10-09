-- Unapplied candidate. Requires admin-approval.sql and admin-users.sql.
-- Initial owner provisioning remains a private, verified server operation.
begin;
create table sdi_private.admin_permission_audit (
 id uuid primary key default gen_random_uuid(), actor uuid not null references auth.users(id),
 subject uuid not null references auth.users(id), previous_permissions text[] not null,
 new_permissions text[] not null, previous_enabled boolean not null,new_enabled boolean not null,
 reason text not null check(length(reason) between 1 and 2000),created_at timestamptz not null default clock_timestamp()
);
alter table sdi_private.admin_permission_audit enable row level security;
revoke all on sdi_private.admin_permission_audit from public,anon,authenticated;
create function sdi_private.admin_permissions(action text,subject uuid default null,capabilities text[] default '{}',
 enabled boolean default false,reason text default '',revision bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare role_record sdi_private.admin_roles; items jsonb;
begin
 if not sdi_private.admin_authorized() or not sdi_private.account_active() then return jsonb_build_object('error','Current admin MFA session required.');end if;
 if action='mine' then
  select * into role_record from sdi_private.admin_roles where user_id=auth.uid();
  return jsonb_build_object('owner',role_record.owner,'capabilities',case when role_record.owner
   then array['users','reviews','moderation','publishing','overview','finance'] else role_record.permissions end);
 end if;
 if not exists(select 1 from sdi_private.admin_roles where user_id=auth.uid() and owner and admin_roles.enabled) then
  return jsonb_build_object('error','Owner permission required.');end if;
 if action='list' then
  select coalesce(jsonb_agg(row_to_json(item)),'[]'::jsonb) into items from (
   select user_id,owner,admin_roles.enabled,permissions,admin_roles.revision from sdi_private.admin_roles order by user_id limit 100
  ) item;
  return jsonb_build_object('roles',items);
 end if;
 if action is null or action<>'save' or subject is null or subject=auth.uid() or capabilities is null or enabled is null
 or reason is null or length(trim(reason)) not between 1 and 2000
 or not capabilities <@ array['users','reviews','moderation','publishing','overview','finance'] or cardinality(capabilities)>6 then
  return jsonb_build_object('error','Valid subject, explicit permissions and reason required.');end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('sdi-admin-permissions',0));
 perform 1 from auth.users where id=subject for update;
 if not found then return jsonb_build_object('error','Account unavailable.');end if;
 select * into role_record from sdi_private.admin_roles where user_id=subject for update;
 if coalesce(role_record.revision,0) is distinct from revision then return jsonb_build_object('error','Role changed. Refresh before saving.');end if;
 if found and role_record.owner then return jsonb_build_object('error','Owner accounts require the separate recovery procedure.');end if;
 insert into sdi_private.admin_permission_audit(actor,subject,previous_permissions,new_permissions,previous_enabled,new_enabled,reason)
 values(auth.uid(),subject,coalesce(role_record.permissions,'{}'),capabilities,coalesce(role_record.enabled,false),enabled,trim(reason));
 insert into sdi_private.admin_roles(user_id,enabled,permissions) values(subject,enabled,capabilities)
 on conflict(user_id) do update set enabled=excluded.enabled,permissions=excluded.permissions,revision=admin_roles.revision+1;
 -- Force a fresh sign-in/MFA after every role change; existing token sessions
 -- cease to authorize through the sensitive RPC session checks.
 delete from auth.sessions where user_id=subject;
 return jsonb_build_object('status','confirmed');
end $$;
revoke all on function sdi_private.admin_permissions(text,uuid,text[],boolean,text,bigint) from public,anon;
grant execute on function sdi_private.admin_permissions(text,uuid,text[],boolean,text,bigint) to authenticated;
create function public.sdi_admin_permissions(action text,subject uuid default null,capabilities text[] default '{}',enabled boolean default false,reason text default '',revision bigint default null) returns jsonb
language sql security invoker set search_path='' as $$select sdi_private.admin_permissions(action,subject,capabilities,enabled,reason,revision)$$;
revoke all on function public.sdi_admin_permissions(text,uuid,text[],boolean,text,bigint) from public,anon;
grant execute on function public.sdi_admin_permissions(text,uuid,text[],boolean,text,bigint) to authenticated;
commit;
